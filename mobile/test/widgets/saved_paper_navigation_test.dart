import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pakperk/app/router.dart';
import 'package:pakperk/core/models/paper.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('saved paper push switches to Read and Back returns to list', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: PakPerkRoutes.youLibrary,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, _, navigationShell) {
            return Builder(
              builder: (context) {
                final routerPath = GoRouterState.of(context).uri.path;
                final visibleIndex = pakPerkVisibleBranchIndex(
                  routerPath: routerPath,
                  shellBranchIndex: navigationShell.currentIndex,
                );
                return Scaffold(
                  body: navigationShell,
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: visibleIndex,
                    onDestinationSelected: (index) {
                      if (index == navigationShell.currentIndex &&
                          index != visibleIndex &&
                          context.canPop()) {
                        context.pop();
                      } else {
                        navigationShell.goBranch(index);
                      }
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.book),
                        label: 'Read',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.person),
                        label: 'You',
                      ),
                    ],
                  ),
                );
              },
            );
          },
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: PakPerkRoutes.read,
                  builder: (_, __) => const Text('Read feed'),
                  routes: [
                    GoRoute(
                      path: 'paper/:paperId',
                      builder: (_, state) {
                        final paper = state.extra! as PaperSummary;
                        return Text('Reading ${paper.title} on Abstract');
                      },
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: PakPerkRoutes.you,
                  builder: (_, __) => const Text('You'),
                  routes: [
                    GoRoute(
                      path: 'library',
                      builder: (context, _) => FilledButton(
                        onPressed: () =>
                            openSavedPaperFromLibrary(context, samplePaper),
                        child: const Text('Open saved paper'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('Open saved paper'), findsOneWidget);
    expect(_selectedDestination(tester), 1);

    await tester.tap(find.text('Open saved paper'));
    await tester.pumpAndSettle();

    expect(
      find.text('Reading ${samplePaper.title} on Abstract'),
      findsOneWidget,
    );
    expect(router.state.uri.path, PakPerkRoutes.paper(samplePaper.paperId));
    expect(_selectedDestination(tester), 0);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Open saved paper'), findsOneWidget);
    expect(router.state.uri.path, PakPerkRoutes.youLibrary);
    expect(_selectedDestination(tester), 1);

    await tester.tap(find.text('Open saved paper'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.text('Open saved paper'), findsOneWidget);
    expect(router.state.uri.path, PakPerkRoutes.youLibrary);
    expect(_selectedDestination(tester), 1);
  });
}

int _selectedDestination(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
