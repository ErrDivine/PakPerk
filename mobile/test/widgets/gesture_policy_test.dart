import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/feed/feed_screen.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'horizontal fling changes stage without changing the current paper',
    (tester) async {
      final papers = _papers();
      final repository = _repositoryFor(papers);
      await _pumpFeed(tester, repository);

      final firstReaderKey = feedReaderKey(papers.first);
      await tester.fling(
        find.byKey(ValueKey('feed-paper-$firstReaderKey')),
        const Offset(-520, 0),
        1200,
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      expect(container.read(appRestorationControllerProvider).feedIndex, 0);
      expect(
        container
            .read(appRestorationControllerProvider)
            .readerState(firstReaderKey)
            .stageIndex,
        PaperStage.introduction.index,
      );
      expect(repository.prepareCalls, 1);
    },
  );

  testWidgets(
    'vertical fling changes paper without changing horizontal stage',
    (tester) async {
      final papers = _papers();
      final repository = _repositoryFor(papers);
      await _pumpFeed(tester, repository);

      await tester.fling(
        find.byKey(const ValueKey('stage-abstractView')),
        const Offset(0, -520),
        1200,
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      final restoration = container.read(appRestorationControllerProvider);
      expect(restoration.feedIndex, 1);
      expect(
        restoration.readerState(feedReaderKey(papers[1])).stageIndex,
        PaperStage.abstractView.index,
      );
      expect(repository.prepareCalls, 0);
      expect(find.text(papers[1].title), findsOneWidget);
    },
  );

  testWidgets('reader stays bounded and overflow-free on a large screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final papers = _papers();
    final repository = _repositoryFor(papers);
    await _pumpFeed(tester, repository);

    final reader = find.byKey(
      ValueKey('feed-paper-${feedReaderKey(papers.first)}'),
    );
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    expect(find.text('1 Introduction'), findsOneWidget);
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('stage-connections')));
    await tester.pumpAndSettle();
    expect(find.text('KEY CONNECTIONS'), findsOneWidget);
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);
  });

  testWidgets('committed vertical page triggers predictive feed prefetch', (
    tester,
  ) async {
    final papers = _papers(13);
    final repository = _repositoryFor(papers)
      ..cachedFeed = FeedPage(items: papers, nextCursor: 'cursor-1')
      ..networkFeed = FeedPage(items: papers, nextCursor: 'cursor-1');
    final cache = _WidgetFeedCache();
    await _pumpFeed(tester, repository, cache: cache);
    expect(repository.feedCalls, 1);

    await tester.fling(
      find.byKey(ValueKey('feed-paper-${feedReaderKey(papers[0])}')),
      const Offset(0, -520),
      1200,
    );
    await tester.pumpAndSettle();
    expect(repository.feedCalls, 1);

    final appended = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = 'prefetched-paper'
        ..['arxiv_id'] = '2601.99999v1'
        ..['title'] = 'Prefetched paper',
    );
    repository.networkFeed = FeedPage(items: [appended], nextCursor: null);
    await tester.fling(
      find.byKey(ValueKey('feed-paper-${feedReaderKey(papers[1])}')),
      const Offset(0, -520),
      1200,
    );
    await tester.pumpAndSettle();

    expect(repository.feedCalls, 2);
    expect(repository.prepareCalls, 0);
    expect(cache.persistedPages.single.items.last.paperId, 'prefetched-paper');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 2);
  });

  testWidgets('settled vertical commit emits one haptic, never during drag', (
    tester,
  ) async {
    final papers = _papers();
    var hapticCalls = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') hapticCalls += 1;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpDirectFeed(tester, _repositoryFor(papers));
    expect(hapticCalls, 0, reason: 'initial positioning is not a commit');

    final stage = find.byKey(const ValueKey('stage-abstractView'));
    final stageBounds = tester.getRect(stage);
    final gesture = await tester.startGesture(
      Offset(stageBounds.center.dx, stageBounds.bottom - 40),
    );
    for (var movement = 0; movement < 4; movement += 1) {
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(hapticCalls, 0, reason: 'drag updates must remain silent');

    await gesture.up();
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(hapticCalls, 1);
  });

  testWidgets('reduced-motion explicit paper jump is instant and silent', (
    tester,
  ) async {
    final papers = _papers();
    var hapticCalls = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') hapticCalls += 1;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpDirectFeed(tester, _repositoryFor(papers), reducedMotion: true);
    final firstReader = find.byKey(
      ValueKey('feed-paper-${feedReaderKey(papers.first)}'),
    );
    final abstractScroll = find.descendant(
      of: firstReader,
      matching: find.byKey(const PageStorageKey('abstract-scroll')),
    );
    final nextPaper = find.descendant(
      of: firstReader,
      matching: find.text('Next paper'),
    );
    await tester.dragUntilVisible(
      nextPaper,
      abstractScroll,
      const Offset(0, -240),
    );
    await tester.tap(nextPaper);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(hapticCalls, 0);
  });

  testWidgets('unavailable haptics never fail a settled page commit', (
    tester,
  ) async {
    final papers = _papers();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        throw PlatformException(code: 'feedback-unavailable');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpDirectFeed(tester, _repositoryFor(papers));
    await tester.fling(
      find.byKey(const ValueKey('stage-abstractView')),
      const Offset(0, -520),
      1200,
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(tester.takeException(), isNull);
  });
}

List<PaperSummary> _papers([int count = 3]) => List.generate(count, (index) {
  final number = index + 1;
  final arxivId = '1706.${(3760 + number).toString().padLeft(5, '0')}v1';
  final json = samplePaper.toJson()
    ..['paper_id'] =
        '17060376-2000-4000-8000-${number.toString().padLeft(12, '0')}'
    ..['arxiv_id'] = arxivId
    ..['title'] = 'Gesture paper $number'
    ..['abs_url'] = 'https://arxiv.org/abs/$arxivId'
    ..['pdf_url'] = 'https://arxiv.org/pdf/$arxivId';
  return PaperSummary.fromJson(json);
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

Future<void> _pumpFeed(
  WidgetTester tester,
  FakePaperDataSource repository, {
  FeedCachePersistence? cache,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        if (cache != null)
          feedCachePersistenceProvider.overrideWithValue(cache),
        initialRestorationProvider.overrideWithValue(
          const AppRestorationState(),
        ),
      ],
      child: const PakPerkApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpDirectFeed(
  WidgetTester tester,
  FakePaperDataSource repository, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialRestorationProvider.overrideWithValue(
          const AppRestorationState(),
        ),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: const FeedScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _WidgetFeedCache implements FeedCachePersistence {
  final Set<String> paperIds = {};
  final List<FeedPage> persistedPages = [];

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> ids) async =>
      ids.where(paperIds.contains).toSet();

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) async {
    paperIds.addAll(papers.map((paper) => paper.paperId));
  }

  @override
  Future<void> recordPaperAccess(
    String paperId, {
    DateTime? accessedAt,
  }) async {}

  @override
  Future<FeedPage?> loadFeedPage(String queryKey) async => null;

  @override
  Future<void> persistFeedPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  }) async {
    persistedPages.add(page);
    paperIds.addAll(page.items.map((paper) => paper.paperId));
  }

  @override
  Future<FeedCacheUsage> measureCache() async => FeedCacheUsage(
    metadataRows: paperIds.length,
    databaseBytes: paperIds.length * 100,
  );

  @override
  Future<CacheEvictionResult> evictCache({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    int maxMetadataPapers = 500,
    int maxDatabaseBytes = 64 * 1024 * 1024,
    Duration metadataTtl = const Duration(days: 7),
    DateTime? now,
  }) async => CacheEvictionResult(
    expiredCommentPages: 0,
    oldFeedEntries: 0,
    unpinnedPapers: 0,
    derivedRows: 0,
    usageAfter: await measureCache(),
  );
}
