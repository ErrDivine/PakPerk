import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/app/router.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/account/guest_you_screen.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';
import 'package:pakperk/features/settings/public_settings_screen.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('Read and You preserve independent branch state', (tester) async {
    final papers = _papers();
    final readerKey = feedReaderKey(papers[1]);
    final repository = _repositoryFor(papers);
    await _pumpApp(
      tester,
      repository: repository,
      restoration: AppRestorationState(
        feedIndex: 1,
        readerStates: {readerKey: const ReaderNavigationState()},
      ),
    );

    expect(find.text(papers[1].title), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    expect(repository.prepareCalls, 1);

    await _tapDestination(tester, 'You');
    expect(find.byType(GuestYouScreen), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PublicSettingsScreen), findsOneWidget);

    await _tapDestination(tester, 'Read');
    expect(find.text(papers[1].title), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    final readState = container
        .read(appRestorationControllerProvider)
        .readerState(readerKey);
    expect(readState.stageIndex, PaperStage.introduction.index);
    expect(readState.prepareRequested, isTrue);
    expect(repository.prepareCalls, 1);

    await _tapDestination(tester, 'You');
    expect(find.byType(PublicSettingsScreen), findsOneWidget);
    expect(container.read(activeAppBranchProvider), AppBranch.you);
  });

  testWidgets('active Read reselection keeps feed position then pops a paper', (
    tester,
  ) async {
    final papers = _papers();
    await _pumpApp(
      tester,
      repository: _repositoryFor(papers),
      restoration: const AppRestorationState(feedIndex: 1),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    await _tapDestination(tester, 'Read');
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(find.text(papers[1].title), findsOneWidget);

    container
        .read(appRestorationControllerProvider.notifier)
        .pushPaper(samplePaper);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to previous paper'), findsOneWidget);

    await _tapDestination(tester, 'Read');
    expect(
      container.read(appRestorationControllerProvider).routeStack,
      isEmpty,
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(find.byTooltip('Back to previous paper'), findsNothing);
    expect(find.text(papers[1].title), findsOneWidget);
  });

  testWidgets('system back removes one restored linked-paper route', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: AppRestorationState(
        routeStack: [
          PaperRouteEntry(routeId: 'restored-paper', paper: samplePaper),
        ],
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    expect(
      container.read(appRestorationControllerProvider).routeStack,
      hasLength(1),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      container.read(appRestorationControllerProvider).routeStack,
      isEmpty,
    );
    expect(find.byTooltip('Back to previous paper'), findsNothing);
  });

  testWidgets('restored active branch starts on guest You', (tester) async {
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: const AppRestorationState(activeBranchIndex: 1),
    );

    expect(find.byType(GuestYouScreen), findsOneWidget);
    expect(_selectedPrimaryDestination(tester), AppBranch.you.index);
  });

  testWidgets(
    'phone bottom navigation adapts to a safe-area tablet rail without '
    'losing branch state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(() {
        tester.view.resetPadding();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await _pumpApp(
        tester,
        repository: _repositoryFor([samplePaper]),
        restoration: const AppRestorationState(),
      );

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(2));
      expect(_selectedPrimaryDestination(tester), AppBranch.read.index);

      await _tapDestination(tester, 'You');
      expect(find.byType(GuestYouScreen), findsOneWidget);
      expect(_selectedPrimaryDestination(tester), AppBranch.you.index);

      tester.view.physicalSize = const Size(1024, 768);
      tester.view.padding = const FakeViewPadding(
        left: 12,
        top: 24,
        bottom: 20,
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(2));
      expect(
        rail.destinations.map(
          (destination) => (destination.label as Text).data,
        ),
        ['Read', 'You'],
      );
      expect(rail.labelType, NavigationRailLabelType.all);
      expect(_selectedPrimaryDestination(tester), AppBranch.you.index);
      expect(tester.getRect(find.byType(NavigationRail)).left, 12);
      expect(tester.getRect(find.byType(NavigationRail)).top, 24);
      expect(tester.getRect(find.byType(NavigationRail)).bottom, 768 - 20);

      await _tapDestination(tester, 'Read');
      expect(find.text(samplePaper.title), findsOneWidget);
      expect(_selectedPrimaryDestination(tester), AppBranch.read.index);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('primary destinations expose selected tab semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: const AppRestorationState(),
    );

    final readTab = find.bySemanticsLabel(
      RegExp(r'(Read.*Tab 1 of 2|Tab 1 of 2.*Read)', dotAll: true),
    );
    expect(readTab, findsOneWidget);
    expect(
      tester.getSemantics(readTab).flagsCollection.isSelected,
      Tristate.isTrue,
    );

    await _tapDestination(tester, 'You');
    final youTab = find.bySemanticsLabel(
      RegExp(r'(You.*Tab 2 of 2|Tab 2 of 2.*You)', dotAll: true),
    );
    expect(youTab, findsOneWidget);
    expect(
      tester.getSemantics(youTab).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('platform restoration returns to the You nested route', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: const AppRestorationState(),
    );
    await _tapDestination(tester, 'You');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PublicSettingsScreen), findsOneWidget);

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.byType(PublicSettingsScreen), findsOneWidget);
    expect(_selectedPrimaryDestination(tester), AppBranch.you.index);
  });

  testWidgets(
    'accounts-off auth and deletion links stay public and restore safely',
    (tester) async {
      await _pumpApp(
        tester,
        repository: _repositoryFor([samplePaper]),
        restoration: const AppRestorationState(),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );

      container.read(pakPerkRouterProvider).go(PakPerkRoutes.auth);
      await tester.pumpAndSettle();
      expect(find.text('Accounts are not enabled'), findsWidgets);
      expect(tester.takeException(), isNull);

      container.read(pakPerkRouterProvider).go(PakPerkRoutes.youAccountDelete);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-deletion-disabled')),
        findsOneWidget,
      );
      expect(find.text('Read the deletion policy'), findsOneWidget);
      expect(find.text('Use the web deletion request'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.restartAndRestore();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-deletion-disabled')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('validated public paper link opens Read on Abstract', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: AppRestorationState(
        activeBranchIndex: 1,
        readerStates: {
          routeReaderKey(
            'deep-link-${samplePaper.paperId}',
            samplePaper,
          ): const ReaderNavigationState(
            stageIndex: 2,
            prepareRequested: true,
          ),
        },
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container
        .read(pakPerkRouterProvider)
        .go(PakPerkRoutes.publicPaper(samplePaper.paperId));
    await tester.pumpAndSettle();

    _expectAbstractSelected();
    expect(_selectedPrimaryDestination(tester), AppBranch.read.index);
  });

  testWidgets('encoded legacy arXiv link resolves in the Read branch', (
    tester,
  ) async {
    final legacyPaper = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['arxiv_id'] = 'hep-th/9901001v3'
        ..['title'] = 'Legacy arXiv paper'
        ..['abs_url'] = 'https://arxiv.org/abs/hep-th/9901001v3'
        ..['pdf_url'] = 'https://arxiv.org/pdf/hep-th/9901001v3',
    );
    final repository = _repositoryFor([legacyPaper]);
    await _pumpApp(
      tester,
      repository: repository,
      restoration: AppRestorationState(
        activeBranchIndex: 1,
        readerStates: {
          routeReaderKey(
            'arxiv-link-hep-th-9901001v3',
            legacyPaper,
          ): const ReaderNavigationState(
            stageIndex: 2,
            prepareRequested: true,
          ),
        },
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    final route = PakPerkRoutes.arxiv(legacyPaper.arxivId);
    expect(route, '/arxiv/hep-th%2F9901001v3');

    container.read(pakPerkRouterProvider).go('https://pakperk.app$route');
    await tester.pumpAndSettle();

    // The exact legacy identifier is already in the cached feed, so routing
    // resolves locally without an unnecessary exact-lookup request.
    expect(repository.paperByArxivCalls, 0);
    expect(find.text('Legacy arXiv paper'), findsWidgets);
    _expectAbstractSelected();
    expect(_selectedPrimaryDestination(tester), AppBranch.read.index);
  });

  testWidgets('UUID direct route pushes a connection above its source', (
    tester,
  ) async {
    await _expectDirectConnectionRoundTrip(tester, useArxivRoute: false);
  });

  testWidgets('arXiv direct route pushes a connection above its source', (
    tester,
  ) async {
    await _expectDirectConnectionRoundTrip(tester, useArxivRoute: true);
  });

  testWidgets('malformed arXiv route is request-free and fails safely', (
    tester,
  ) async {
    final repository = _repositoryFor([samplePaper]);
    await _pumpApp(
      tester,
      repository: repository,
      restoration: const AppRestorationState(),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container.read(pakPerkRouterProvider).go('/arxiv/not-an-id');
    await tester.pumpAndSettle();

    expect(find.text('Invalid arXiv link'), findsWidgets);
    expect(repository.paperByArxivCalls, 0);
  });

  testWidgets('absolute link on a hostile host is rejected before matching', (
    tester,
  ) async {
    final repository = _repositoryFor([samplePaper]);
    await _pumpApp(
      tester,
      repository: repository,
      restoration: const AppRestorationState(activeBranchIndex: 1),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container
        .read(pakPerkRouterProvider)
        .go(
          'https://evil.example${PakPerkRoutes.publicPaper(samplePaper.paperId)}',
        );
    await tester.pumpAndSettle();

    expect(
      container.read(pakPerkRouterProvider).state.uri.path,
      PakPerkRoutes.read,
    );
    expect(find.text(samplePaper.title), findsOneWidget);
    expect(repository.paperByArxivCalls, 0);
  });

  testWidgets('leaving an unresolved arXiv route cancels its exact lookup', (
    tester,
  ) async {
    final repository = _repositoryFor([samplePaper])
      ..paperByArxivCompleter = Completer<RepositoryValue<PaperSummary>>();
    await _pumpApp(
      tester,
      repository: repository,
      restoration: const AppRestorationState(),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container
        .read(pakPerkRouterProvider)
        .go(PakPerkRoutes.arxiv(samplePaper.arxivId));
    await tester.pump();
    expect(repository.paperByArxivCalls, 1);

    container.read(pakPerkRouterProvider).go(PakPerkRoutes.read);
    await tester.pumpAndSettle();

    expect(repository.lastPaperByArxivCancellation?.isCancelled, isTrue);
    repository.paperByArxivCompleter!.complete(
      RepositoryValue(
        value: samplePaper,
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await tester.pump();
  });

  testWidgets('root comments route is truthful and has no composer', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      repository: _repositoryFor([samplePaper]),
      restoration: const AppRestorationState(),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container
        .read(pakPerkRouterProvider)
        .push(
          PakPerkRoutes.paperComments(samplePaper.paperId),
          extra: PaperCommentsRouteData(
            paperId: samplePaper.paperId,
            paperTitle: samplePaper.title,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('Paper discussions'), findsAtLeastNWidgets(1));
    expect(
      find.textContaining('are not enabled in this build'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Close paper discussions'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('primary-navigation')),
      findsOneWidget,
    );
  });

  testWidgets('disabled public comments link is request-free and truthful', (
    tester,
  ) async {
    final repository = _repositoryFor([samplePaper]);
    await _pumpApp(
      tester,
      repository: repository,
      restoration: const AppRestorationState(),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );

    container
        .read(pakPerkRouterProvider)
        .go(PakPerkRoutes.publicPaperComments(samplePaper.paperId));
    await tester.pumpAndSettle();

    expect(repository.paperCalls, 0);
    expect(find.text('Paper discussions'), findsAtLeastNWidgets(1));
    expect(
      find.textContaining('are not enabled in this build'),
      findsOneWidget,
    );
    expect(find.textContaining('incomplete or invalid'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  test('paper route builder rejects malformed and traversal identifiers', () {
    for (final value in [
      '',
      '../paper',
      '17060376-2000-4000-8000-000000000001/../../you',
      List.filled(1000, 'x').join(),
    ]) {
      expect(PakPerkRouteIdentifiers.isValidPaperId(value), isFalse);
      expect(() => PakPerkRoutes.paper(value), throwsArgumentError);
    }
  });

  test('custom paper links normalize narrowly and fail closed', () {
    final paperId = samplePaper.paperId;
    expect(
      PakPerkRoutes.normalizeCustomScheme(
        Uri.parse('pakperk://paper/$paperId'),
      ),
      PakPerkRoutes.paper(paperId),
    );
    expect(
      PakPerkRoutes.normalizeCustomScheme(
        Uri.parse('pakperk://paper/$paperId/comments'),
      ),
      PakPerkRoutes.paperComments(paperId),
    );
    for (final link in [
      'pakperk://unknown/$paperId',
      'pakperk:/paper/$paperId',
      'pakperk:paper/$paperId',
      'pakperk://paper/$paperId/extra',
      'pakperk://paper/$paperId?unexpected=true',
      'pakperk://paper/not-a-uuid',
    ]) {
      expect(
        PakPerkRoutes.normalizeCustomScheme(Uri.parse(link)),
        PakPerkRoutes.read,
      );
    }
    expect(
      PakPerkRoutes.normalizeCustomScheme(
        Uri.parse('https://example.test/p/$paperId'),
      ),
      isNull,
    );
  });

  test('HTTPS app links require the exact production origin', () {
    final paperId = samplePaper.paperId;
    expect(
      PakPerkRoutes.normalizeIncomingLink(
        Uri.parse('https://pakperk.app/p/$paperId'),
      ),
      PakPerkRoutes.paper(paperId),
    );
    expect(
      PakPerkRoutes.normalizeIncomingLink(
        Uri.parse('https://pakperk.app/p/$paperId/comments'),
      ),
      PakPerkRoutes.paperComments(paperId),
    );
    expect(
      PakPerkRoutes.normalizeIncomingLink(
        Uri.parse('https://pakperk.app/arxiv/math.GT%2F0309136v3'),
      ),
      PakPerkRoutes.arxiv('math.GT/0309136v3'),
    );
    for (final link in [
      'https://evil.example/p/$paperId',
      'https://pakperk.app.evil.example/p/$paperId',
      'http://pakperk.app/p/$paperId',
      'https://user@pakperk.app/p/$paperId',
      'https://pakperk.app:444/p/$paperId',
      'https://pakperk.app/p/$paperId?unexpected=true',
      'https://pakperk.app/p/$paperId#unexpected',
      'https://pakperk.app/you',
      '//evil.example/p/$paperId',
    ]) {
      expect(
        PakPerkRoutes.normalizeIncomingLink(Uri.parse(link)),
        PakPerkRoutes.read,
        reason: link,
      );
    }
  });
}

List<PaperSummary> _papers() => List.generate(3, (index) {
  final number = index + 1;
  final suffix = number.toString().padLeft(12, '0');
  return PaperSummary.fromJson(
    samplePaper.toJson()
      ..['paper_id'] = '17060376-2000-4000-8000-$suffix'
      ..['arxiv_id'] = '1706.0376${number}v1'
      ..['title'] = 'Shell paper $number'
      ..['abs_url'] = 'https://arxiv.org/abs/1706.0376${number}v1'
      ..['pdf_url'] = 'https://arxiv.org/pdf/1706.0376${number}v1',
  );
});

FakePaperDataSource _repositoryFor(List<PaperSummary> papers) =>
    FakePaperDataSource(
        paper: papers.first,
        processing: sampleProcessing,
        introduction: sampleIntroduction,
        connections: sampleConnections,
      )
      ..cachedFeed = FeedPage(items: papers)
      ..networkFeed = FeedPage(items: papers);

Future<void> _pumpApp(
  WidgetTester tester, {
  required FakePaperDataSource repository,
  required AppRestorationState restoration,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialRestorationProvider.overrideWithValue(restoration),
      ],
      child: const PakPerkApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapDestination(WidgetTester tester, String label) async {
  final navigation = find.byKey(const ValueKey<String>('primary-navigation'));
  await tester.tap(find.descendant(of: navigation, matching: find.text(label)));
  await tester.pumpAndSettle();
}

int _selectedPrimaryDestination(WidgetTester tester) {
  final navigation = tester.widget(
    find.byKey(const ValueKey<String>('primary-navigation')),
  );
  return switch (navigation) {
    NavigationBar value => value.selectedIndex,
    NavigationRail value => value.selectedIndex ?? -1,
    _ => throw StateError('Unexpected primary navigation widget.'),
  };
}

void _expectAbstractSelected() {
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Abstract view, selected' &&
          widget.properties.selected == true,
    ),
    findsOneWidget,
  );
}

Future<void> _expectDirectConnectionRoundTrip(
  WidgetTester tester, {
  required bool useArxivRoute,
}) async {
  final source = samplePaper.copyWith(
    capabilities: const PaperCapabilities(
      introduction: true,
      chat: true,
      connections: true,
    ),
  );
  final target = PaperSummary.fromJson(
    samplePaper.toJson()
      ..['paper_id'] = '17060376-2000-4000-8000-000000000002'
      ..['arxiv_id'] = '1810.04805v2'
      ..['title'] = 'Linked target paper'
      ..['abs_url'] = 'https://arxiv.org/abs/1810.04805v2'
      ..['pdf_url'] = 'https://arxiv.org/pdf/1810.04805v2',
  );
  final repository =
      FakePaperDataSource(
          paper: source,
          arxivPaper: source,
          processing: sampleProcessing,
          connections: PaperConnections(
            paperId: source.paperId,
            ready: true,
            keyConnections: [
              KeyConnection(
                referenceId: 'source-reference-1',
                paperId: target.paperId,
                arxivId: target.arxivId,
                title: target.title,
                authors: target.authors,
                year: target.publishedAt.year,
                relationType: 'builds_on',
                summary: 'A validated connection to the linked target.',
              ),
            ],
            references: const [],
          ),
        )
        ..cachedFeed = FeedPage(items: [source])
        ..networkFeed = FeedPage(items: [source])
        ..papersById[source.paperId] = source
        ..papersById[target.paperId] = target;
  await _pumpApp(
    tester,
    repository: repository,
    restoration: const AppRestorationState(),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(PakPerkApp)),
  );
  final sourceRoute = useArxivRoute
      ? PakPerkRoutes.arxiv(source.arxivId)
      : PakPerkRoutes.paper(source.paperId);

  container.read(pakPerkRouterProvider).go(sourceRoute);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('stage-connections')));
  await tester.pumpAndSettle();
  expect(find.text(target.title), findsOneWidget);

  await tester.tap(find.text(target.title));
  await tester.pumpAndSettle();

  expect(find.text(target.title), findsWidgets);
  expect(
    container.read(pakPerkRouterProvider).state.uri.path,
    PakPerkRoutes.paper(target.paperId),
  );
  expect(container.read(appRestorationControllerProvider).routeStack, isEmpty);

  await tester.tap(find.byTooltip('Back to previous paper'));
  await tester.pumpAndSettle();

  expect(find.text(source.title), findsWidgets);
  expect(container.read(pakPerkRouterProvider).state.uri.path, sourceRoute);
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Connections view, selected' &&
          widget.properties.selected == true,
    ),
    findsOneWidget,
  );
}
