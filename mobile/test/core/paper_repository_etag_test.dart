import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/feed_http_result.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/demo_asset_store.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/repository/paper_repository.dart';

import '../support/fakes.dart';

void main() {
  test('feed query keys preserve category case', () {
    expect(
      feedQueryKey(category: 'cs.AI'),
      isNot(feedQueryKey(category: 'cs.ai')),
    );
  });

  test('cached category load uses the exact query and its cursor', () async {
    final categoryPaper = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = '00000000-0000-4000-8000-000000000031'
        ..['primary_category'] = 'cs.CL'
        ..['categories'] = ['cs.CL'],
    );
    final queryKey = feedQueryKey(category: 'cs.CL');
    final store = _ConditionalStore()
      ..feed = FeedPage(items: [samplePaper], nextCursor: 'all-cursor')
      ..pages[queryKey] = FeedPage(
        items: [categoryPaper],
        nextCursor: 'category-cursor',
      );
    final repository = PaperRepository(
      api: _ConditionalApiClient(const []),
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getCachedFeed(category: 'cs.CL');

    expect(result.origin, DataOrigin.deviceCache);
    expect(result.value.items.single.paperId, categoryPaper.paperId);
    expect(result.value.nextCursor, 'category-cursor');
  });

  test('304 publishes the exact cached query as freshly revalidated', () async {
    final queryKey = feedQueryKey(category: 'cs.CL', limit: 30);
    final store = _ConditionalStore()
      ..pages[queryKey] = FeedPage(items: [samplePaper])
      ..validators[queryKey] = FeedCacheValidator(
        etag: '"cached-tag"',
        refreshedAt: DateTime.utc(2026, 7, 1),
      );
    final api = _ConditionalApiClient([
      const FeedHttpResult.notModified(etag: '"cached-tag"'),
    ]);
    final repository = PaperRepository(
      api: api,
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(category: 'cs.CL', limit: 30);

    expect(result.value.items.single.paperId, samplePaper.paperId);
    expect(result.origin, DataOrigin.deviceCache);
    expect(result.revalidated, isTrue);
    expect(result.persisted, isTrue);
    expect(result.isStale, isFalse);
    expect(api.validators, ['"cached-tag"']);
    expect(store.persistCalls, 0);
    expect(store.validatorWrites, 1);
  });

  test('304 without an ETag retains the request validator', () async {
    final queryKey = feedQueryKey(limit: 30);
    final store = _ConditionalStore()
      ..pages[queryKey] = FeedPage(items: [samplePaper])
      ..validators[queryKey] = FeedCacheValidator(
        etag: '"retained-tag"',
        refreshedAt: DateTime.utc(2026, 7, 1),
      );
    final repository = PaperRepository(
      api: _ConditionalApiClient(const [FeedHttpResult.notModified()]),
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(limit: 30);

    expect(result.revalidated, isTrue);
    expect(store.validators[queryKey]?.etag, '"retained-tag"');
  });

  test(
    '200 persists the masked body and validator before publication',
    () async {
      final prepared = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['capabilities'] = {
            'metadata': true,
            'introduction': true,
            'chat': true,
            'connections': true,
          },
      );
      final store = _ConditionalStore();
      final api = _ConditionalApiClient([
        FeedHttpResult.modified(
          page: FeedPage(items: [prepared], nextCursor: 'opaque-next'),
          etag: '"network-tag"',
        ),
      ]);
      final repository = PaperRepository(
        api: api,
        localStore: store,
        demoContent: _NoDemoContent(),
        fulltextPolicy: ClientFulltextPolicy.strict,
      );
      addTearDown(repository.dispose);

      final result = await repository.getFeed(limit: 30);
      final queryKey = feedQueryKey(limit: 30);
      final persisted = store.pages[queryKey]!.items.single;

      expect(result.origin, DataOrigin.network);
      expect(result.persisted, isTrue);
      expect(result.revalidated, isFalse);
      expect(store.persistCalls, 1);
      expect(store.validators[queryKey]?.etag, '"network-tag"');
      expect(persisted.capabilities.introduction, isFalse);
      expect(persisted.capabilities.chat, isFalse);
      expect(persisted.capabilities.connections, isFalse);
    },
  );

  test(
    'orphan validator repairs itself with one unconditional request',
    () async {
      final queryKey = feedQueryKey(limit: 30);
      final store = _ConditionalStore()
        ..validators[queryKey] = FeedCacheValidator(
          etag: '"orphan"',
          refreshedAt: DateTime.utc(2026, 7, 1),
        );
      final api = _ConditionalApiClient([
        const FeedHttpResult.notModified(etag: '"orphan"'),
        FeedHttpResult.modified(
          page: FeedPage(items: [samplePaper]),
          etag: '"repaired"',
        ),
      ]);
      final repository = PaperRepository(
        api: api,
        localStore: store,
        demoContent: _NoDemoContent(),
      );
      addTearDown(repository.dispose);

      final result = await repository.getFeed(limit: 30);

      expect(api.validators, ['"orphan"', isNull]);
      expect(store.persistCalls, 1);
      expect(store.validators[queryKey]?.etag, '"repaired"');
      expect(result.value.items.single.paperId, samplePaper.paperId);
    },
  );

  test('304 repairs when eviction invalidates its ETag in flight', () async {
    final queryKey = feedQueryKey(limit: 30);
    final store = _ConditionalStore()
      ..pages[queryKey] = FeedPage(items: [samplePaper])
      ..validators[queryKey] = FeedCacheValidator(
        etag: '"superseded"',
        refreshedAt: DateTime.utc(2026, 7, 1),
      );
    store.afterPageLoad = () {
      store.validators[queryKey] = FeedCacheValidator(
        refreshedAt: DateTime.utc(2026, 7, 2),
      );
    };
    final api = _ConditionalApiClient([
      const FeedHttpResult.notModified(etag: '"superseded"'),
      FeedHttpResult.modified(
        page: FeedPage(items: [samplePaper]),
        etag: '"repaired"',
      ),
    ]);
    final repository = PaperRepository(
      api: api,
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(limit: 30);

    expect(api.validators, ['"superseded"', isNull]);
    expect(store.persistCalls, 1);
    expect(store.validators[queryKey]?.etag, '"repaired"');
    expect(result.revalidated, isFalse);
  });

  test('conditional network failure still serves cached public feed', () async {
    final queryKey = feedQueryKey(limit: 30);
    final store = _ConditionalStore()
      ..feed = FeedPage(items: [samplePaper])
      ..pages[queryKey] = FeedPage(items: [samplePaper])
      ..validators[queryKey] = FeedCacheValidator(
        etag: '"cached"',
        refreshedAt: DateTime.utc(2026, 7, 1),
      );
    final api = _ConditionalApiClient(const [], error: _offline());
    final repository = PaperRepository(
      api: api,
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(limit: 30);

    expect(result.origin, DataOrigin.deviceCache);
    expect(result.offline, isTrue);
    expect(result.isStale, isTrue);
    expect(result.value.items.single.paperId, samplePaper.paperId);
  });

  test('category failure never falls back to the all-feed query', () async {
    final categoryPaper = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = '00000000-0000-4000-8000-000000000032'
        ..['primary_category'] = 'cs.CL'
        ..['categories'] = ['cs.CL'],
    );
    final store = _ConditionalStore()
      ..feed = FeedPage(items: [samplePaper], nextCursor: 'all-cursor')
      ..pages[feedQueryKey(category: 'cs.CL', limit: 30)] = FeedPage(
        items: [categoryPaper],
        nextCursor: 'category-cursor',
      );
    final repository = PaperRepository(
      api: _ConditionalApiClient(const [], error: _offline()),
      localStore: store,
      demoContent: _NoDemoContent(),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(category: 'cs.CL', limit: 30);

    expect(result.origin, DataOrigin.deviceCache);
    expect(result.value.items.single.paperId, categoryPaper.paperId);
    expect(result.value.nextCursor, 'category-cursor');
  });

  test('an empty cached category remains authoritative offline', () async {
    final store = _ConditionalStore()
      ..pages[feedQueryKey(category: 'cs.CL', limit: 30)] = const FeedPage(
        items: [],
      );
    final repository = PaperRepository(
      api: _ConditionalApiClient(const [], error: _offline()),
      localStore: store,
      demoContent: _StaticDemoContent(FeedPage(items: [samplePaper])),
    );
    addTearDown(repository.dispose);

    final result = await repository.getFeed(category: 'cs.CL', limit: 30);

    expect(result.origin, DataOrigin.deviceCache);
    expect(result.value.items, isEmpty);
  });

  test(
    'conditional persistence publishes the newest stored arXiv version',
    () async {
      final older = PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '1706.03762v6',
      );
      final newer = PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '1706.03762v7',
      );
      final store = _ConditionalStore()..papers[newer.paperId] = newer;
      final repository = PaperRepository(
        api: _ConditionalApiClient([
          FeedHttpResult.modified(page: FeedPage(items: [older])),
        ]),
        localStore: store,
        demoContent: _NoDemoContent(),
      );
      addTearDown(repository.dispose);

      final result = await repository.getFeed(limit: 30);

      expect(result.value.items.single.arxivId, newer.arxivId);
      expect(store.papers[newer.paperId]?.arxivId, newer.arxivId);
    },
  );
}

ApiException _offline() => const ApiException(
  code: 'NETWORK_UNAVAILABLE',
  message: 'Offline',
  retryable: true,
  isOffline: true,
);

class _ConditionalApiClient extends ApiClient {
  _ConditionalApiClient(this.responses, {this.error})
    : super(
        baseUrl: 'http://localhost:8080',
        sessionId: '00000000-0000-4000-8000-000000000099',
      );

  final List<FeedHttpResult> responses;
  final ApiException? error;
  final List<String?> validators = [];
  int _index = 0;

  @override
  Future<FeedHttpResult> getFeedConditional({
    String? category,
    String? cursor,
    int limit = FeedPrefetchConfig.defaultRemotePageSize,
    String? ifNoneMatch,
    RequestCancellation? cancellation,
  }) async {
    validators.add(ifNoneMatch);
    if (error case final failure?) throw failure;
    return responses[_index++];
  }

  @override
  Future<FeedPage> getFeed({
    String? category,
    String? cursor,
    int limit = FeedPrefetchConfig.defaultRemotePageSize,
    RequestCancellation? cancellation,
  }) => throw StateError('Conditional cache must use conditional transport.');
}

class _ConditionalStore extends MemoryLocalStore
    implements FeedConditionalCache, FeedCachePersistence {
  final Map<String, FeedPage> pages = {};
  final Map<String, FeedCacheValidator> validators = {};
  int persistCalls = 0;
  int validatorWrites = 0;
  void Function()? afterPageLoad;

  @override
  Future<FeedPage?> loadFeedPage(String queryKey) async {
    final page = pages[queryKey];
    final callback = afterPageLoad;
    afterPageLoad = null;
    callback?.call();
    return page;
  }

  @override
  Future<FeedCacheValidator?> loadFeedValidator(String queryKey) async =>
      validators[queryKey];

  @override
  Future<void> storeFeedValidator(
    String queryKey, {
    required String? etag,
    required DateTime refreshedAt,
  }) async {
    validatorWrites += 1;
    validators[queryKey] = FeedCacheValidator(
      etag: etag,
      refreshedAt: refreshedAt,
    );
  }

  @override
  Future<void> touchFeedRefreshedAt(
    String queryKey,
    DateTime refreshedAt,
  ) async {
    final current = validators[queryKey];
    validators[queryKey] = FeedCacheValidator(
      etag: current?.etag,
      refreshedAt: refreshedAt,
    );
  }

  @override
  Future<void> persistFeedPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  }) async {
    persistCalls += 1;
    for (final paper in page.items) {
      await savePaper(paper);
    }
    pages[queryKey] = FeedPage(
      items: [
        for (final paper in page.items) await loadPaper(paper.paperId) ?? paper,
      ],
      nextCursor: page.nextCursor,
    );
    validators[queryKey] = FeedCacheValidator(
      etag: etag,
      refreshedAt: refreshedAt ?? DateTime.now().toUtc(),
    );
  }

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds) async =>
      paperIds.where(papers.containsKey).toSet();

  @override
  Future<void> recordPaperAccess(
    String paperId, {
    DateTime? accessedAt,
  }) async {}

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) async {
    for (final paper in papers) {
      this.papers[paper.paperId] = paper;
    }
  }

  @override
  Future<FeedCacheUsage> measureCache() async =>
      FeedCacheUsage(metadataRows: papers.length, databaseBytes: 0);

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

class _NoDemoContent implements DemoContentStore {
  @override
  Future<PaperSummary?> findFallbackPaper(String paperId) async => null;

  @override
  Future<PaperSummary?> findFallbackPaperByArxiv(String arxivBaseId) async =>
      null;

  @override
  Future<FeedPage> loadFallbackFeed() async => const FeedPage(items: []);

  @override
  Future<PaperConnections?> loadConnections(String paperId) async => null;

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async => null;
}

class _StaticDemoContent extends _NoDemoContent {
  _StaticDemoContent(this.feed);

  final FeedPage feed;

  @override
  Future<FeedPage> loadFallbackFeed() async => feed;
}
