import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/feed/feed_controller.dart';
import 'package:pakperk/features/feed/feed_prefetch_coordinator.dart';
import 'package:pakperk/features/feed/preloaded_feed_snapshot.dart';

import '../support/fakes.dart';

void main() {
  test(
    'preloaded feed is synchronous and waits for one explicit revalidation',
    () async {
      final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeedCompleter = pendingNetwork;
      final controller = FeedController(
        repository,
        preloadedSnapshot: PreloadedFeedSnapshot(
          page: FeedPage(items: [samplePaper], nextCursor: 'cached-cursor'),
          origin: DataOrigin.deviceCache,
        ),
      );

      expect(controller.state.loadingInitial, isFalse);
      expect(controller.state.items.single.paperId, samplePaper.paperId);
      expect(controller.state.nextCursor, 'cached-cursor');
      expect(controller.state.origin, DataOrigin.deviceCache);
      expect(repository.feedCalls, 0);
      expect(repository.lastFeedCancellation, isNull);

      final firstRefresh = controller.refreshPreloadedFirstPageOnce();
      final repeatedRefresh = controller.refreshPreloadedFirstPageOnce();
      expect(identical(firstRefresh, repeatedRefresh), isTrue);
      expect(repository.feedCalls, 1);
      expect(repository.lastFeedCancellation, isNotNull);

      pendingNetwork.complete(
        RepositoryValue(
          value: FeedPage(items: [samplePaper]),
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await firstRefresh;
      expect(repository.feedCalls, 1);
      controller.dispose();
    },
  );

  test(
    'cached feed is published before network revalidation completes',
    () async {
      final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeedCompleter = pendingNetwork;
      final controller = FeedController(repository);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(pendingNetwork.isCompleted, isFalse);
      expect(controller.state.loadingInitial, isFalse);
      expect(controller.state.items.single.paperId, samplePaper.paperId);
      expect(controller.state.origin, DataOrigin.deviceCache);
      expect(repository.cachedFeedWrites, isEmpty);

      pendingNetwork.complete(
        RepositoryValue(
          value: FeedPage(items: [samplePaper]),
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
    },
  );

  test('new version is cached before it is published to readers', () async {
    final newerPaper = PaperSummary.fromJson(
      samplePaper.toJson()..['arxiv_id'] = '1706.03762v8',
    );
    final cacheGate = Completer<void>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeed = FeedPage(items: [newerPaper])
      ..cacheFeedCompleter = cacheGate;
    final controller = FeedController(repository);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      repository.cachedFeedWrites.single.items.single.arxivId,
      '1706.03762v8',
    );
    expect(controller.state.items.single.arxivId, samplePaper.arxivId);

    cacheGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.items.single.arxivId, '1706.03762v8');
    controller.dispose();
  });

  test(
    'empty initial network refresh preserves a nonempty cached feed',
    () async {
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeed = const FeedPage(items: []);
      final controller = FeedController(repository);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.loadingInitial, isFalse);
      expect(controller.state.items.single.paperId, samplePaper.paperId);
      expect(controller.state.origin, DataOrigin.deviceCache);
      expect(controller.state.offline, isFalse);
      controller.dispose();
    },
  );

  test('empty category refresh remains an explicit empty state', () async {
    final repository = FakePaperDataSource(paper: samplePaper);
    final controller = FeedController(repository);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    repository.networkFeed = const FeedPage(items: []);
    repository.cachedFeedWrites.clear();
    repository.cachedFeedReplaceFlags.clear();
    await controller.loadInitial(category: 'cs.CV');

    expect(controller.state.loadingInitial, isFalse);
    expect(controller.state.category, 'cs.CV');
    expect(controller.state.items, isEmpty);
    expect(controller.state.origin, DataOrigin.network);
    expect(repository.cachedFeedWrites, hasLength(1));
    expect(repository.cachedFeedReplaceFlags.single, isFalse);
    controller.dispose();
  });

  test('disposing the feed cancels its in-flight network request', () async {
    final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeedCompleter = pendingNetwork;
    final controller = FeedController(repository);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final cancellation = repository.lastFeedCancellation;
    expect(cancellation, isNotNull);
    expect(cancellation!.isCancelled, isFalse);

    controller.dispose();
    expect(cancellation.isCancelled, isTrue);

    pendingNetwork.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('a late category response cannot replace the active query', () async {
    final firstResponse = Completer<RepositoryValue<FeedPage>>();
    final secondResponse = Completer<RepositoryValue<FeedPage>>();
    final firstPaper = _feedPaper(21);
    final secondPaper = _feedPaper(22);
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeedCompleter = firstResponse;
    final controller = FeedController(
      repository,
      preloadedSnapshot: PreloadedFeedSnapshot(
        page: FeedPage(items: [samplePaper]),
        origin: DataOrigin.deviceCache,
      ),
    );

    final firstLoad = controller.loadInitial(category: 'cs.AI');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final firstCancellation = repository.lastFeedCancellation!;

    repository.networkFeedCompleter = secondResponse;
    final secondLoad = controller.loadInitial(category: 'cs.CL');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(firstCancellation.isCancelled, isTrue);

    secondResponse.complete(
      RepositoryValue(
        value: FeedPage(items: [secondPaper], nextCursor: 'second-cursor'),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await secondLoad;

    firstResponse.complete(
      RepositoryValue(
        value: FeedPage(items: [firstPaper], nextCursor: 'first-cursor'),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await firstLoad;

    expect(controller.state.category, 'cs.CL');
    expect(controller.state.items.single.paperId, secondPaper.paperId);
    expect(controller.state.nextCursor, 'second-cursor');
    controller.dispose();
  });

  test(
    'committed page applies a coordinator update without deep preparation',
    () async {
      final initial = List.generate(11, _feedPaper);
      final repository = FakePaperDataSource(paper: initial.first)
        ..networkFeed = FeedPage(items: [_feedPaper(11)], nextCursor: null);
      final coordinator = FeedPrefetchCoordinator(
        remote: PaperDataSourceFeedPrefetchRemoteSource(repository),
        cache: _ControllerFeedCache(),
      );
      final controller = FeedController(
        repository,
        preloadedSnapshot: PreloadedFeedSnapshot(
          page: FeedPage(items: initial, nextCursor: 'cursor-1'),
          origin: DataOrigin.deviceCache,
        ),
        prefetchCoordinator: coordinator,
      );

      await controller.onCommittedPage(0);

      expect(controller.state.items, hasLength(12));
      expect(controller.state.items.last.paperId, 'prefetch-paper-11');
      expect(controller.state.nextCursor, isNull);
      expect(repository.feedCalls, 1);
      expect(repository.prepareCalls, 0);
      controller.dispose();
    },
  );

  test('non-default policy controls cached and network page sizes', () async {
    const config = FeedPrefetchConfig(remotePageSize: 7);
    final repository = FakePaperDataSource(paper: samplePaper);
    final controller = FeedController(repository, config: config);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(repository.cachedFeedLimits, [config.remotePageSize]);
    expect(repository.feedLimits, [config.remotePageSize]);
    controller.dispose();
  });

  test(
    'non-default load trigger applies without a prefetch coordinator',
    () async {
      const config = FeedPrefetchConfig(remotePageSize: 7, loadTrigger: 0);
      final papers = [_feedPaper(0), _feedPaper(1)];
      final repository = FakePaperDataSource(paper: papers.first)
        ..networkFeed = FeedPage(items: [_feedPaper(2)]);
      final controller = FeedController(
        repository,
        config: config,
        preloadedSnapshot: PreloadedFeedSnapshot(
          page: FeedPage(items: papers, nextCursor: 'cursor-1'),
          origin: DataOrigin.deviceCache,
        ),
      );

      await controller.onCommittedPage(0);
      expect(repository.feedCalls, 0);

      await controller.onCommittedPage(1);
      expect(repository.feedCalls, 1);
      expect(repository.feedLimits, [config.remotePageSize]);
      controller.dispose();
    },
  );
}

PaperSummary _feedPaper(int index) => PaperSummary.fromJson({
  ...samplePaper.toJson(),
  'paper_id': 'prefetch-paper-$index',
  'arxiv_id': '2501.${index.toString().padLeft(5, '0')}v1',
  'title': 'Paper $index',
});

class _ControllerFeedCache implements FeedCachePersistence {
  final Set<String> _ids = {};

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds) async =>
      paperIds.where(_ids.contains).toSet();

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) async {
    _ids.addAll(papers.map((paper) => paper.paperId));
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
    _ids.addAll(page.items.map((paper) => paper.paperId));
  }

  @override
  Future<FeedCacheUsage> measureCache() async => FeedCacheUsage(
    metadataRows: _ids.length,
    databaseBytes: _ids.length * 100,
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
