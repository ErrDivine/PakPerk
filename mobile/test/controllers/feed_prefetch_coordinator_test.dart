import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/feed/feed_prefetch_config.dart';
import 'package:pakperk/features/feed/feed_prefetch_coordinator.dart';
import 'package:pakperk/features/feed/feed_prefetch_telemetry.dart';

import '../support/fakes.dart';

void main() {
  test('production defaults keep every prefetch and TTL knob centralized', () {
    const config = FeedPrefetchConfig();

    expect(config.remotePageSize, 30);
    expect(config.loadTrigger, 10);
    expect(config.memoryAhead, 6);
    expect(config.memoryBehind, 2);
    expect(config.durableAhead, 60);
    expect(config.maxCachedMetadataPapers, 500);
    expect(config.maxDatabaseBytes, 64 * 1024 * 1024);
    expect(config.metadataTtl, const Duration(days: 7));
    expect(config.firstCommentsPageTtl, const Duration(minutes: 5));
  });

  test('merge deduplicates IDs and never regresses an arXiv version', () {
    final old = _paper(0, version: 2, updatedDay: 2);
    final current = _paper(1, version: 4, updatedDay: 4);
    final merged = mergeFeedPapers(
      [old, current, _paper(1, version: 3, updatedDay: 3)],
      [
        _paper(0, version: 1, updatedDay: 9),
        _paper(1, version: 5, updatedDay: 5),
        _paper(2, version: 1, updatedDay: 1),
        _paper(2, version: 3, updatedDay: 3),
      ],
    );

    expect(merged.map((paper) => paper.paperId), [
      'paper-0',
      'paper-1',
      'paper-2',
    ]);
    expect(merged[0].arxivId, '2401.00000v2');
    expect(merged[1].arxivId, '2401.00001v5');
    expect(merged[2].arxivId, '2401.00002v3');
  });

  test(
    'normal sequential reading records at least 95 percent next hits',
    () async {
      final cache = _InMemoryFeedCache();
      final telemetry = _RecordingTelemetry();
      final coordinator = FeedPrefetchCoordinator(
        remote: _FakeRemote(),
        cache: cache,
        telemetry: telemetry,
        scheduler: _ManualScheduler(),
      );
      addTearDown(coordinator.dispose);
      final papers = List.generate(100, _paper);

      for (var index = 0; index < papers.length; index += 1) {
        await coordinator.onCommittedPage(
          index: index,
          items: papers,
          nextCursor: null,
        );
      }

      final hits = telemetry.count(FeedPrefetchMetric.nextPaperCacheHit);
      final misses = telemetry.count(FeedPrefetchMetric.nextPaperCacheMiss);
      expect(hits + misses, 99);
      expect(hits / (hits + misses), greaterThanOrEqualTo(0.95));
      expect(misses, 1);
    },
  );

  test(
    'committed page repairs exactly the default behind and ahead window',
    () async {
      final cache = _InMemoryFeedCache();
      final coordinator = FeedPrefetchCoordinator(
        remote: _FakeRemote(),
        cache: cache,
        scheduler: _ManualScheduler(),
      );
      addTearDown(coordinator.dispose);
      final papers = List.generate(20, _paper);

      await coordinator.onCommittedPage(
        index: 5,
        items: papers,
        nextCursor: null,
      );

      expect(
        cache.papers.keys,
        papers.sublist(3, 12).map((paper) => paper.paperId).toSet(),
      );
    },
  );

  test('rapid commits share one in-flight request for a query', () async {
    final response = Completer<RepositoryValue<FeedPage>>();
    final remote = _FakeRemote(handler: (_, __) => response.future);
    final cache = _InMemoryFeedCache();
    final telemetry = _RecordingTelemetry();
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: cache,
      telemetry: telemetry,
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);
    final papers = List.generate(12, _paper);

    final first = coordinator.onCommittedPage(
      index: 1,
      items: papers,
      nextCursor: 'cursor-1',
    );
    final second = coordinator.onCommittedPage(
      index: 1,
      items: papers,
      nextCursor: 'cursor-1',
    );
    await _flushMicrotasks();

    expect(remote.calls, hasLength(1));
    expect(remote.calls.single.limit, 30);
    expect(remote.calls.single.cursor, 'cursor-1');
    response.complete(
      RepositoryValue(
        value: FeedPage(items: [_paper(12)], nextCursor: null),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await Future.wait([first, second]);

    expect(remote.calls, hasLength(1));
    expect(telemetry.count(FeedPrefetchMetric.deduplicated), 1);
    expect(cache.persistedPages, hasLength(1));
    expect(cache.persistReplaceFlags, [false]);
  });

  test(
    'duplicate-heavy pages continue until durable target is truly met',
    () async {
      final initial = List.generate(11, _paper);
      final pages = <FeedPage>[
        FeedPage(
          items: [initial.first, initial.last, _paper(11)],
          nextCursor: 'cursor-2',
        ),
        FeedPage(
          items: [initial.first, _paper(11), _paper(12)],
          nextCursor: null,
        ),
      ];
      final remote = _FakeRemote(
        handler: (index, _) async => RepositoryValue(
          value: pages[index],
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      final coordinator = FeedPrefetchCoordinator(
        remote: remote,
        cache: _InMemoryFeedCache(),
        scheduler: _ManualScheduler(),
        config: const FeedPrefetchConfig(
          remotePageSize: 5,
          loadTrigger: 10,
          durableAhead: 12,
          maxCachedMetadataPapers: 50,
        ),
      );
      addTearDown(coordinator.dispose);
      final updates = <FeedPrefetchUpdate>[];
      final subscription = coordinator.updates.listen(updates.add);
      addTearDown(subscription.cancel);

      await coordinator.onCommittedPage(
        index: 0,
        items: initial,
        nextCursor: 'cursor-1',
      );

      expect(remote.calls, hasLength(2));
      expect(updates.last.items, hasLength(13));
      expect(updates.last.nextCursor, isNull);
    },
  );

  test('durable target does not assume a full page of unique papers', () async {
    final initial = List.generate(6, _paper);
    final remote = _FakeRemote(
      handler: (index, _) async => RepositoryValue(
        value: FeedPage(
          items: [initial.first, _paper(6 + index)],
          nextCursor: index == 2 ? null : 'cursor-${index + 2}',
        ),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: _InMemoryFeedCache(),
      scheduler: _ManualScheduler(),
      config: const FeedPrefetchConfig(
        remotePageSize: 30,
        loadTrigger: 10,
        durableAhead: 8,
        maxCachedMetadataPapers: 60,
      ),
    );
    addTearDown(coordinator.dispose);
    final updates = <FeedPrefetchUpdate>[];
    final subscription = coordinator.updates.listen(updates.add);
    addTearDown(subscription.cancel);

    await coordinator.onCommittedPage(
      index: 0,
      items: initial,
      nextCursor: 'cursor-1',
    );

    expect(remote.calls, hasLength(3));
    expect(updates.last.items, hasLength(9));
    expect(updates.last.nextCursor, isNull);
  });

  test('repository-owned atomic persistence is not written twice', () async {
    final cache = _InMemoryFeedCache();
    final coordinator = FeedPrefetchCoordinator(
      remote: _FakeRemote(
        handler: (_, __) async => RepositoryValue(
          value: FeedPage(items: [_paper(11)], nextCursor: null),
          origin: DataOrigin.network,
          offline: false,
          persisted: true,
        ),
      ),
      cache: cache,
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);

    await coordinator.onCommittedPage(
      index: 0,
      items: List.generate(11, _paper),
      nextCursor: 'cursor-1',
    );

    expect(cache.persistedPages, isEmpty);
  });

  test('cyclic cursors stop without requesting the same page twice', () async {
    final remote = _FakeRemote(
      handler: (index, __) async => RepositoryValue(
        value: FeedPage(
          items: [_paper(11 + index)],
          nextCursor: index == 0 ? 'cursor-2' : 'cursor-1',
        ),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: _InMemoryFeedCache(),
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);

    await coordinator.onCommittedPage(
      index: 0,
      items: List.generate(11, _paper),
      nextCursor: 'cursor-1',
    );

    expect(remote.calls.map((call) => call.cursor), ['cursor-1', 'cursor-2']);
  });

  test('query changes cancel and obsolete a late response', () async {
    final response = Completer<RepositoryValue<FeedPage>>();
    final remote = _FakeRemote(handler: (_, __) => response.future);
    final cache = _InMemoryFeedCache();
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: cache,
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);
    final updates = <FeedPrefetchUpdate>[];
    final subscription = coordinator.updates.listen(updates.add);
    addTearDown(subscription.cancel);
    final papers = List.generate(11, _paper);

    final pending = coordinator.onCommittedPage(
      index: 0,
      items: papers,
      nextCursor: 'old-cursor',
    );
    await _flushMicrotasks();
    final cancellation = remote.calls.single.cancellation;
    coordinator.activateQuery(category: 'cs.CV');

    expect(cancellation?.isCancelled, isTrue);
    response.complete(
      RepositoryValue(
        value: FeedPage(items: [_paper(99)], nextCursor: null),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await pending;

    expect(updates, isEmpty);
    expect(cache.persistedPages, isEmpty);
  });

  test('rapid A to B to A waits for the first A transport to unwind', () async {
    final firstResponse = Completer<RepositoryValue<FeedPage>>();
    final remote = _FakeRemote(
      handler: (index, _) {
        if (index == 0) return firstResponse.future;
        expect(firstResponse.isCompleted, isTrue);
        return Future.value(
          RepositoryValue(
            value: FeedPage(items: [_paper(12)], nextCursor: null),
            origin: DataOrigin.network,
            offline: false,
          ),
        );
      },
    );
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: _InMemoryFeedCache(),
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);
    final papers = List.generate(11, _paper);

    final first = coordinator.onCommittedPage(
      index: 0,
      items: papers,
      nextCursor: 'cursor-a-1',
      category: 'cs.AI',
    );
    await _flushMicrotasks();
    coordinator.activateQuery(category: 'cs.CL');
    coordinator.activateQuery(category: 'cs.AI');
    final second = coordinator.onCommittedPage(
      index: 0,
      items: papers,
      nextCursor: 'cursor-a-2',
      category: 'cs.AI',
    );
    await _flushMicrotasks();

    expect(remote.calls, hasLength(1));
    firstResponse.complete(
      RepositoryValue(
        value: FeedPage(items: [_paper(11)], nextCursor: null),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await Future.wait([first, second]);

    expect(remote.calls, hasLength(2));
    expect(remote.calls.map((call) => call.category), ['cs.AI', 'cs.AI']);
    expect(remote.calls.last.cursor, 'cursor-a-2');
  });

  test('a same-query snapshot replacement obsoletes its old cursor', () async {
    final response = Completer<RepositoryValue<FeedPage>>();
    final remote = _FakeRemote(handler: (_, __) => response.future);
    final cache = _InMemoryFeedCache();
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: cache,
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);
    final updates = <FeedPrefetchUpdate>[];
    final subscription = coordinator.updates.listen(updates.add);
    addTearDown(subscription.cancel);
    final original = List.generate(11, _paper);

    final pending = coordinator.onCommittedPage(
      index: 0,
      items: original,
      nextCursor: 'superseded-cursor',
    );
    await _flushMicrotasks();
    final cancellation = remote.calls.single.cancellation;
    final refreshed = [
      PaperSummary.fromJson(
        original.first.toJson()..['arxiv_id'] = '2401.00000v2',
      ),
      ...original.skip(1),
    ];

    coordinator.acceptAuthoritativeSnapshot(
      items: refreshed,
      nextCursor: 'fresh-cursor',
    );
    expect(cancellation?.isCancelled, isTrue);

    response.complete(
      RepositoryValue(
        value: FeedPage(items: [_paper(99)], nextCursor: null),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await pending;

    expect(updates, isEmpty);
    expect(cache.persistedPages, isEmpty);
  });

  test(
    'retry backoff is deterministic and resets on committed advance',
    () async {
      final remote = _FakeRemote(
        handler: (_, __) async => throw StateError('offline'),
      );
      final scheduler = _ManualScheduler();
      final telemetry = _RecordingTelemetry();
      final coordinator = FeedPrefetchCoordinator(
        remote: remote,
        cache: _InMemoryFeedCache(),
        telemetry: telemetry,
        scheduler: scheduler,
        nextJitter: () => 0.5,
        config: const FeedPrefetchConfig(evictionDelay: Duration(days: 1)),
      );
      addTearDown(coordinator.dispose);
      final papers = List.generate(12, _paper);

      await coordinator.onCommittedPage(
        index: 1,
        items: papers,
        nextCursor: 'cursor-1',
      );
      expect(scheduler.activeDelays, contains(const Duration(seconds: 1)));

      await scheduler.runFirst(const Duration(seconds: 1));
      expect(scheduler.activeDelays, contains(const Duration(seconds: 2)));

      await coordinator.onCommittedPage(
        index: 2,
        items: papers,
        nextCursor: 'cursor-1',
      );
      expect(
        scheduler.activeDelays,
        isNot(contains(const Duration(seconds: 2))),
      );
      expect(scheduler.activeDelays, contains(const Duration(seconds: 1)));
      expect(
        telemetry.events.where((event) => event.attempt == 1),
        hasLength(2),
      );
    },
  );

  test(
    'connectivity recovery cancels backoff and retries immediately',
    () async {
      var shouldFail = true;
      final remote = _FakeRemote(
        handler: (_, __) async {
          if (shouldFail) throw StateError('offline');
          return RepositoryValue(
            value: FeedPage(items: [_paper(12)], nextCursor: null),
            origin: DataOrigin.network,
            offline: false,
          );
        },
      );
      final scheduler = _ManualScheduler();
      final coordinator = FeedPrefetchCoordinator(
        remote: remote,
        cache: _InMemoryFeedCache(),
        scheduler: scheduler,
        config: const FeedPrefetchConfig(evictionDelay: Duration(days: 1)),
      );
      addTearDown(coordinator.dispose);

      await coordinator.onCommittedPage(
        index: 1,
        items: List.generate(12, _paper),
        nextCursor: 'cursor-1',
      );
      expect(remote.calls, hasLength(1));
      shouldFail = false;
      coordinator.connectivityRecovered();
      await _flushMicrotasks();

      expect(remote.calls, hasLength(2));
      expect(
        scheduler.activeDelays,
        isNot(contains(const Duration(seconds: 1))),
      );
    },
  );

  test('retry delay applies injected jitter deterministically', () async {
    final scheduler = _ManualScheduler();
    final coordinator = FeedPrefetchCoordinator(
      remote: _FakeRemote(
        handler: (_, __) async => throw StateError('offline'),
      ),
      cache: _InMemoryFeedCache(),
      scheduler: scheduler,
      nextJitter: () => 0,
      config: const FeedPrefetchConfig(
        retryInitialDelay: Duration(seconds: 10),
        retryMaximumDelay: Duration(seconds: 30),
        retryJitterFraction: 0.2,
        evictionDelay: Duration(days: 1),
      ),
    );
    addTearDown(coordinator.dispose);

    await coordinator.onCommittedPage(
      index: 0,
      items: List.generate(11, _paper),
      nextCursor: 'cursor-1',
    );

    expect(scheduler.activeDelays, contains(const Duration(seconds: 8)));
  });

  test(
    'eviction enforces row and byte caps without touching pins or window',
    () async {
      final now = DateTime.utc(2026, 7, 31, 12);
      final cache = _InMemoryFeedCache(bytesPerPaper: 100);
      final papers = List.generate(10, _paper);
      await cache.ensurePaperMetadata(
        papers,
        accessedAt: now.subtract(const Duration(days: 20)),
      );
      cache.pinnedPaperIds.add(papers.first.paperId);
      final scheduler = _ManualScheduler();
      final telemetry = _RecordingTelemetry();
      final coordinator = FeedPrefetchCoordinator(
        remote: _FakeRemote(),
        cache: cache,
        telemetry: telemetry,
        scheduler: scheduler,
        clock: () => now,
        config: const FeedPrefetchConfig(
          memoryBehind: 2,
          memoryAhead: 1,
          durableAhead: 6,
          maxCachedMetadataPapers: 6,
          maxDatabaseBytes: 500,
          evictionDelay: Duration.zero,
        ),
      );
      addTearDown(coordinator.dispose);

      await coordinator.onCommittedPage(
        index: 4,
        items: papers,
        nextCursor: null,
      );
      await scheduler.runFirst(Duration.zero);

      expect(cache.papers, hasLength(5));
      expect(cache.papers.keys, contains(papers.first.paperId));
      for (final protectedIndex in [2, 3, 4, 5]) {
        expect(cache.papers.keys, contains(papers[protectedIndex].paperId));
      }
      expect(cache.lastProtectedIds, {
        papers[2].paperId,
        papers[3].paperId,
        papers[4].paperId,
        papers[5].paperId,
      });
      expect(cache.lastMaxRows, 6);
      expect(cache.lastMaxBytes, 500);
      expect(cache.papers[papers[4].paperId]?.lastAccessedAt, now);
      expect(telemetry.value(FeedPrefetchMetric.cacheRows), 5);
      expect(telemetry.value(FeedPrefetchMetric.cacheBytes), 500);
    },
  );

  test('telemetry has a closed content-free shape', () async {
    final telemetry = _RecordingTelemetry();
    final coordinator = FeedPrefetchCoordinator(
      remote: _FakeRemote(),
      cache: _InMemoryFeedCache(),
      telemetry: telemetry,
      scheduler: _ManualScheduler(),
    );
    addTearDown(coordinator.dispose);

    await coordinator.onCommittedPage(
      index: 0,
      items: [_paper(0)],
      nextCursor: null,
    );

    expect(telemetry.events, isNotEmpty);
    for (final event in telemetry.events) {
      expect(
        event.metric.wireName.startsWith('feed_') ||
            event.metric.wireName.startsWith('next_'),
        isTrue,
      );
      expect(event.value, anyOf(isNull, isA<int>()));
      expect(event.attempt, anyOf(isNull, isA<int>()));
    }
  });

  test(
    'cache maintenance failure remains nonblocking and request-free',
    () async {
      final remote = _FakeRemote();
      final telemetry = _RecordingTelemetry();
      final coordinator = FeedPrefetchCoordinator(
        remote: remote,
        cache: _ThrowingFeedCache(),
        telemetry: telemetry,
        scheduler: _ManualScheduler(),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.onCommittedPage(
          index: 0,
          items: List.generate(11, _paper),
          nextCursor: 'cursor-1',
        ),
        completes,
      );

      expect(remote.calls, isEmpty);
      expect(telemetry.count(FeedPrefetchMetric.failed), 1);
    },
  );

  test(
    'paper data source adapter calls feed only and never deep endpoints',
    () async {
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeed = FeedPage(items: [_paper(11)], nextCursor: null);
      final coordinator = FeedPrefetchCoordinator(
        remote: PaperDataSourceFeedPrefetchRemoteSource(repository),
        cache: _InMemoryFeedCache(),
        scheduler: _ManualScheduler(),
      );
      addTearDown(coordinator.dispose);

      await coordinator.onCommittedPage(
        index: 0,
        items: List.generate(11, _paper),
        nextCursor: 'cursor-1',
      );

      expect(repository.feedCalls, 1);
      expect(repository.prepareCalls, 0);
      expect(repository.processingCalls, 0);
      expect(repository.introductionCalls, 0);
      expect(repository.connectionCalls, 0);
      expect(repository.paperCalls, 0);
      expect(repository.paperByArxivCalls, 0);
    },
  );
}

PaperSummary _paper(int index, {int version = 1, int updatedDay = 1}) =>
    PaperSummary(
      paperId: 'paper-$index',
      arxivId: '2401.${index.toString().padLeft(5, '0')}v$version',
      title: 'Private title $index must never enter telemetry',
      abstractText: 'Private abstract $index must never enter telemetry',
      authors: ['Private Author $index'],
      primaryCategory: 'cs.AI',
      categories: const ['cs.AI'],
      publishedAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, updatedDay),
      absUrl: 'https://arxiv.org/abs/2401.$index',
      pdfUrl: 'https://arxiv.org/pdf/2401.$index',
    );

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _RemoteCall {
  const _RemoteCall({
    required this.category,
    required this.cursor,
    required this.limit,
    required this.cancellation,
  });

  final String? category;
  final String cursor;
  final int limit;
  final RequestCancellation? cancellation;
}

class _FakeRemote implements FeedPrefetchRemoteSource {
  _FakeRemote({this.handler});

  final Future<RepositoryValue<FeedPage>> Function(
    int callIndex,
    RequestCancellation? cancellation,
  )?
  handler;
  final List<_RemoteCall> calls = [];

  @override
  Future<RepositoryValue<FeedPage>> fetchFeedPage({
    String? category,
    required String cursor,
    required int limit,
    RequestCancellation? cancellation,
  }) {
    final callIndex = calls.length;
    calls.add(
      _RemoteCall(
        category: category,
        cursor: cursor,
        limit: limit,
        cancellation: cancellation,
      ),
    );
    return handler?.call(callIndex, cancellation) ??
        Future.value(
          const RepositoryValue(
            value: FeedPage(items: []),
            origin: DataOrigin.network,
            offline: false,
          ),
        );
  }
}

class _RecordingTelemetry implements FeedPrefetchTelemetry {
  final List<FeedPrefetchEvent> events = [];

  @override
  void record(FeedPrefetchEvent event) => events.add(event);

  int count(FeedPrefetchMetric metric) =>
      events.where((event) => event.metric == metric).length;

  int? value(FeedPrefetchMetric metric) =>
      events.lastWhere((event) => event.metric == metric).value;
}

class _ManualTask implements FeedScheduledTask {
  _ManualTask(this.delay, this.callback);

  final Duration delay;
  final FutureOr<void> Function() callback;
  bool cancelled = false;
  bool executed = false;

  bool get active => !cancelled && !executed;

  @override
  void cancel() => cancelled = true;

  Future<void> run() async {
    if (!active) return;
    executed = true;
    await Future<void>.sync(callback);
  }
}

class _ManualScheduler implements FeedPrefetchScheduler {
  final List<_ManualTask> tasks = [];

  List<Duration> get activeDelays => tasks
      .where((task) => task.active)
      .map((task) => task.delay)
      .toList(growable: false);

  @override
  FeedScheduledTask schedule(
    Duration delay,
    FutureOr<void> Function() callback,
  ) {
    final task = _ManualTask(delay, callback);
    tasks.add(task);
    return task;
  }

  Future<void> runFirst(Duration delay) async {
    final task = tasks.firstWhere(
      (candidate) => candidate.active && candidate.delay == delay,
    );
    await task.run();
    await _flushMicrotasks();
  }
}

class _CachedPaper {
  _CachedPaper(this.paper, this.lastAccessedAt);

  PaperSummary paper;
  DateTime lastAccessedAt;
}

class _InMemoryFeedCache implements FeedCachePersistence {
  _InMemoryFeedCache({this.bytesPerPaper = 1024});

  final int bytesPerPaper;
  final Map<String, _CachedPaper> papers = {};
  final Map<String, FeedPage> queryPages = {};
  final Set<String> pinnedPaperIds = {};
  final List<FeedPage> persistedPages = [];
  final List<bool> persistReplaceFlags = [];
  Set<String> lastProtectedIds = {};
  int? lastMaxRows;
  int? lastMaxBytes;

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds) async =>
      paperIds.where(papers.containsKey).toSet();

  @override
  Future<void> recordPaperAccess(String paperId, {DateTime? accessedAt}) async {
    final cached = papers[paperId];
    if (cached != null) {
      cached.lastAccessedAt = accessedAt ?? DateTime.now();
    }
  }

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> values, {
    DateTime? accessedAt,
  }) async {
    final access = accessedAt ?? DateTime.now();
    for (final paper in values) {
      papers[paper.paperId] = _CachedPaper(paper, access);
    }
  }

  @override
  Future<FeedPage?> loadFeedPage(String queryKey) async => queryPages[queryKey];

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
    persistReplaceFlags.add(replace);
    final existing = queryPages[queryKey];
    queryPages[queryKey] = !replace && existing != null
        ? FeedPage(
            items: mergeFeedPapers(existing.items, page.items),
            nextCursor: page.nextCursor,
          )
        : page;
    await ensurePaperMetadata(page.items, accessedAt: refreshedAt);
  }

  @override
  Future<FeedCacheUsage> measureCache() async => FeedCacheUsage(
    metadataRows: papers.length,
    databaseBytes: papers.length * bytesPerPaper,
  );

  @override
  Future<CacheEvictionResult> evictCache({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    int maxMetadataPapers = 500,
    int maxDatabaseBytes = 64 * 1024 * 1024,
    Duration metadataTtl = const Duration(days: 7),
    DateTime? now,
  }) async {
    lastProtectedIds = Set.of(protectedPaperIds);
    lastMaxRows = maxMetadataPapers;
    lastMaxBytes = maxDatabaseBytes;
    final cutoff = (now ?? DateTime.now()).subtract(metadataTtl);
    final candidates =
        papers.entries
            .where(
              (entry) =>
                  !pinnedPaperIds.contains(entry.key) &&
                  !protectedPaperIds.contains(entry.key),
            )
            .toList()
          ..sort(
            (left, right) =>
                left.value.lastAccessedAt.compareTo(right.value.lastAccessedAt),
          );
    var expired = 0;
    var unpinned = 0;
    for (final entry in candidates) {
      final overRows = papers.length > maxMetadataPapers;
      final overBytes = papers.length * bytesPerPaper > maxDatabaseBytes;
      final isExpired = entry.value.lastAccessedAt.isBefore(cutoff);
      if (!overRows && !overBytes && !isExpired) continue;
      if (papers.remove(entry.key) != null) {
        if (isExpired) {
          expired += 1;
        } else {
          unpinned += 1;
        }
      }
    }
    return CacheEvictionResult(
      expiredCommentPages: 0,
      oldFeedEntries: expired,
      unpinnedPapers: unpinned,
      derivedRows: 0,
      usageAfter: await measureCache(),
    );
  }
}

class _ThrowingFeedCache extends _InMemoryFeedCache {
  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds) =>
      Future.error(StateError('cache unavailable'));
}
