import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/library/paper_save_control.dart';
import 'package:pakperk/features/library/to_read_list.dart';

void main() {
  testWidgets('guest save records one credential-free intent before auth', (
    tester,
  ) async {
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) =>
              Scaffold(body: PaperSaveControl(paper: _paper('Guest paper', 3))),
        ),
        GoRoute(
          path: '/auth',
          builder: (_, __) => const Scaffold(body: Text('Auth route')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(_libraryFlags),
          libraryDisplayScopeProvider.overrideWithValue(null),
          paperSavedStateProvider.overrideWith(
            (ref, paperId) => Stream.value(const LibrarySavedState.notSaved()),
          ),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Save to To Read'));
    await tester.pumpAndSettle();
    expect(find.text('Save across your devices'), findsOneWidget);
    expect(pending.state, isNull);

    await tester.tap(find.byKey(const ValueKey('save-sign-in-continue')));
    await tester.pumpAndSettle();

    expect(find.text('Auth route'), findsOneWidget);
    expect(pending.state?.kind, AppPendingActionKind.savePaper);
    expect(pending.state?.targetId, _paper('Guest paper', 3).paperId);
  });

  testWidgets('save control exposes exact action and pending semantics', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaperSaveControlView(
            state: const LibrarySavedState(saved: false, syncPending: false),
            onPressed: () => taps += 1,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Save to To Read'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paper-save-control')));
    expect(taps, 1);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PaperSaveControlView(
            state: LibrarySavedState(saved: true, syncPending: true),
            onPressed: null,
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);
    expect(find.byKey(const ValueKey('save-sync-pending')), findsOneWidget);
  });

  testWidgets('To Read is newest first with explicit remove and open actions', (
    tester,
  ) async {
    final older = _item('Older paper', 1);
    final newer = _item('Newer paper', 2, pending: true);
    LibraryListItem? opened;
    LibraryListItem? removed;

    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ToReadListView(
            items: [older, newer],
            onOpen: (item) => opened = item,
            onRemove: (item) => removed = item,
            onRefresh: () async {},
          ),
        ),
      ),
    );

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(
      titles.indexOf('Newer paper'),
      lessThan(titles.indexOf('Older paper')),
    );
    expect(find.text('Waiting to sync'), findsOneWidget);

    await tester.tap(find.text('Newer paper'));
    expect(opened?.paper.title, 'Newer paper');
    await tester.tap(
      find.byKey(ValueKey('remove-to-read-${older.paper.paperId}')),
    );
    expect(removed?.paper.title, 'Older paper');
  });

  testWidgets('empty offline list remains usable at 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: ToReadListView(
                items: const [],
                offline: true,
                onOpen: (_) {},
                onRemove: (_) {},
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Your To Read list is empty'), findsOneWidget);
    expect(find.textContaining('Offline.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

LibraryListItem _item(String title, int day, {bool pending = false}) {
  final timestamp = DateTime.utc(2026, 7, day);
  return LibraryListItem(
    paper: _paper(title, day),
    savedAt: timestamp,
    savedState: LibrarySavedState(saved: true, syncPending: pending),
  );
}

PaperSummary _paper(String title, int day) {
  final paperId = '17060376-2000-4000-8000-${day.toString().padLeft(12, '0')}';
  final timestamp = DateTime.utc(2026, 7, day);
  return PaperSummary(
    paperId: paperId,
    arxivId: '2401.${day.toString().padLeft(5, '0')}v1',
    title: title,
    abstractText: 'Abstract',
    authors: const ['Ada Reader', 'Grace Hopper'],
    primaryCategory: 'cs.AI',
    categories: const ['cs.AI'],
    publishedAt: timestamp,
    updatedAt: timestamp,
    absUrl: 'https://arxiv.org/abs/2401.00001v1',
    pdfUrl: 'https://arxiv.org/pdf/2401.00001v1',
  );
}

const _libraryFlags = FeatureFlags(
  accounts: true,
  library: true,
  comments: false,
  openingMotion: false,
);
