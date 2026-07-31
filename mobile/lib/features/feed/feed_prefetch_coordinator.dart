import 'dart:async';
import 'dart:math';

import '../../core/api/request_cancellation.dart';
import '../../core/cache/feed_cache_persistence.dart';
import '../../core/models/paper.dart';
import '../../core/repository/paper_repository.dart';
import 'feed_prefetch_config.dart';
import 'feed_prefetch_telemetry.dart';

/// The only remote capability visible to [FeedPrefetchCoordinator].
///
/// Keeping this surface feed-only is a compile-time guard against accidentally
/// invoking prepare, introduction, chat, connections, arXiv, PDF, or model
/// endpoints during speculative work.
abstract interface class FeedPrefetchRemoteSource {
  Future<RepositoryValue<FeedPage>> fetchFeedPage({
    String? category,
    required String cursor,
    required int limit,
    RequestCancellation? cancellation,
  });
}

class PaperDataSourceFeedPrefetchRemoteSource
    implements FeedPrefetchRemoteSource {
  const PaperDataSourceFeedPrefetchRemoteSource(this._source);

  final PaperDataSource _source;

  @override
  Future<RepositoryValue<FeedPage>> fetchFeedPage({
    String? category,
    required String cursor,
    required int limit,
    RequestCancellation? cancellation,
  }) => _source.getFeed(
    category: category,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );
}

abstract interface class FeedScheduledTask {
  void cancel();
}

abstract interface class FeedPrefetchScheduler {
  FeedScheduledTask schedule(
    Duration delay,
    FutureOr<void> Function() callback,
  );
}

class TimerFeedPrefetchScheduler implements FeedPrefetchScheduler {
  const TimerFeedPrefetchScheduler();

  @override
  FeedScheduledTask schedule(
    Duration delay,
    FutureOr<void> Function() callback,
  ) => _TimerFeedScheduledTask(delay, callback);
}

class _TimerFeedScheduledTask implements FeedScheduledTask {
  _TimerFeedScheduledTask(Duration delay, FutureOr<void> Function() callback)
    : _timer = Timer(delay, () => unawaited(Future<void>.sync(callback)));

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

class FeedPrefetchUpdate {
  const FeedPrefetchUpdate({
    required this.queryKey,
    required this.items,
    required this.nextCursor,
    required this.origin,
    required this.offline,
  });

  final String queryKey;
  final List<PaperSummary> items;
  final String? nextCursor;
  final DataOrigin origin;
  final bool offline;
}

class _FeedViewport {
  const _FeedViewport({
    required this.queryKey,
    required this.category,
    required this.index,
    required this.items,
    required this.nextCursor,
    required this.generation,
  });

  final String queryKey;
  final String? category;
  final int index;
  final List<PaperSummary> items;
  final String? nextCursor;
  final int generation;

  int get remaining => items.length - index - 1;

  bool hasSnapshot({
    required List<PaperSummary> items,
    required String? nextCursor,
  }) {
    if (this.nextCursor != nextCursor || this.items.length != items.length) {
      return false;
    }
    for (var index = 0; index < items.length; index += 1) {
      final current = this.items[index];
      final candidate = items[index];
      if (current.paperId != candidate.paperId ||
          current.arxivId != candidate.arxivId) {
        return false;
      }
    }
    return true;
  }

  _FeedViewport withPage(FeedPage page) => _FeedViewport(
    queryKey: queryKey,
    category: category,
    index: index,
    items: page.items,
    nextCursor: page.nextCursor,
    generation: generation,
  );
}

/// Coordinates cache-ahead work for committed vertical page transitions.
///
/// The coordinator never owns UI loading/error state. Failures remain
/// non-blocking while the feed controller continues to serve its current
/// items, and retries run through an injectable scheduler.
class FeedPrefetchCoordinator {
  FeedPrefetchCoordinator({
    required FeedPrefetchRemoteSource remote,
    required FeedCachePersistence cache,
    this.config = const FeedPrefetchConfig(),
    this.telemetry = const NoopFeedPrefetchTelemetry(),
    this.scheduler = const TimerFeedPrefetchScheduler(),
    DateTime Function()? clock,
    double Function()? nextJitter,
  }) : _remote = remote,
       _cache = cache,
       _clock = clock ?? DateTime.now,
       _nextJitter = nextJitter ?? Random().nextDouble;

  final FeedPrefetchRemoteSource _remote;
  final FeedCachePersistence _cache;
  final FeedPrefetchConfig config;
  final FeedPrefetchTelemetry telemetry;
  final FeedPrefetchScheduler scheduler;
  final DateTime Function() _clock;
  final double Function() _nextJitter;
  final StreamController<FeedPrefetchUpdate> _updates =
      StreamController<FeedPrefetchUpdate>.broadcast(sync: true);
  final Map<String, Future<void>> _inFlight = {};
  final Map<String, RequestCancellation> _cancellations = {};
  final Map<String, int> _retryAttempts = {};
  final Map<String, FeedScheduledTask> _retryTasks = {};
  FeedScheduledTask? _evictionTask;
  _FeedViewport? _active;
  int _generation = 0;
  bool _disposed = false;

  Stream<FeedPrefetchUpdate> get updates => _updates.stream;

  bool get hasInFlightRequest => _inFlight.isNotEmpty;

  /// Obsoletes and cancels speculative work when the selected category
  /// changes, even before the replacement feed has rendered its first card.
  void activateQuery({String? category}) {
    if (_disposed) return;
    final queryKey = feedQueryKey(
      category: category,
      limit: config.remotePageSize,
    );
    if (_active?.queryKey == queryKey) return;
    _generation += 1;
    _active = null;
    for (final cancellation in _cancellations.values) {
      cancellation.cancel('The active feed query changed.');
    }
    _cancellations.clear();
    // Keep physical single-flight ownership until each canceled transport has
    // actually unwound. A rapid A -> B -> A switch must not overlap two A
    // requests merely because cancellation is slow to reach the socket.
    for (final task in _retryTasks.values) {
      task.cancel();
    }
    _retryTasks.clear();
    _retryAttempts.clear();
  }

  /// Immediately obsoletes speculative work when the controller publishes a
  /// materially different first-page snapshot for the same query. This closes
  /// the frame between a network refresh and the next widget page-commit.
  void acceptAuthoritativeSnapshot({
    required List<PaperSummary> items,
    required String? nextCursor,
    String? category,
  }) {
    if (_disposed) return;
    final active = _active;
    if (active == null) return;
    final queryKey = feedQueryKey(
      category: category,
      limit: config.remotePageSize,
    );
    if (active.queryKey != queryKey) {
      activateQuery(category: category);
      return;
    }
    if (active.hasSnapshot(items: items, nextCursor: nextCursor)) return;
    _obsoleteQueryWork(queryKey);
    _active = null;
  }

  /// Records a settled vertical page and launches only low-priority work.
  Future<void> onCommittedPage({
    required int index,
    required List<PaperSummary> items,
    required String? nextCursor,
    String? category,
  }) async {
    if (_disposed) return;
    if (items.isEmpty || index < 0 || index >= items.length) {
      telemetry.record(const FeedPrefetchEvent(FeedPrefetchMetric.blankCard));
      return;
    }

    final queryKey = feedQueryKey(
      category: category,
      limit: config.remotePageSize,
    );
    var previous = _active;
    if (previous != null && previous.queryKey != queryKey) {
      activateQuery(category: category);
      previous = null;
    } else if (previous != null &&
        !previous.hasSnapshot(items: items, nextCursor: nextCursor)) {
      // A same-query refresh, reorder, version advance, or cursor replacement
      // must not accept a tail fetched for the superseded snapshot.
      _obsoleteQueryWork(queryKey);
      previous = null;
    }
    final pageAdvanced =
        previous != null &&
        previous.queryKey == queryKey &&
        previous.index != index;
    if (pageAdvanced) _resetRetry(queryKey);

    final viewport = _FeedViewport(
      queryKey: queryKey,
      category: category,
      index: index,
      items: List<PaperSummary>.unmodifiable(items),
      nextCursor: nextCursor,
      generation: _generation,
    );
    _active = viewport;

    final readableStartedAt = _clock();
    final window = _windowFor(viewport);
    final current = items[index];
    try {
      final readableIds = await _cache.cachedPaperIds(
        window.map((paper) => paper.paperId),
      );
      if (!_isCurrent(viewport)) return;

      await _cache.recordPaperAccess(
        current.paperId,
        accessedAt: readableStartedAt,
      );
      if (!_isCurrent(viewport)) return;

      if (index + 1 < items.length) {
        final nextId = items[index + 1].paperId;
        telemetry.record(
          FeedPrefetchEvent(
            readableIds.contains(nextId)
                ? FeedPrefetchMetric.nextPaperCacheHit
                : FeedPrefetchMetric.nextPaperCacheMiss,
          ),
        );
      }

      final unreadable = window
          .where((paper) => !readableIds.contains(paper.paperId))
          .toList(growable: false);
      if (unreadable.isNotEmpty) {
        await _cache.ensurePaperMetadata(
          unreadable,
          accessedAt: readableStartedAt,
        );
        if (!_isCurrent(viewport)) return;
      }
      telemetry.record(
        FeedPrefetchEvent(
          FeedPrefetchMetric.timeToReadable,
          value: _clock().difference(readableStartedAt).inMilliseconds,
        ),
      );
    } on Object {
      // A corrupt or temporarily unavailable cache must not surface an
      // unhandled asynchronous error from a page gesture.
      telemetry.record(const FeedPrefetchEvent(FeedPrefetchMetric.failed));
      return;
    }

    _scheduleEviction();
    final latest = _active;
    if (latest != null &&
        _isCurrent(latest) &&
        latest.remaining <= config.loadTrigger &&
        latest.nextCursor != null &&
        latest.nextCursor!.isNotEmpty) {
      await _startPrefetch(latest);
    }
  }

  /// Resets retry state and immediately rechecks the latest viewport.
  void connectivityRecovered() {
    if (_disposed) return;
    final active = _active;
    if (active == null) return;
    _resetRetry(active.queryKey);
    if (active.remaining <= config.loadTrigger &&
        active.nextCursor != null &&
        active.nextCursor!.isNotEmpty) {
      unawaited(_startPrefetch(active));
    }
  }

  void recordBlankCard() {
    telemetry.record(const FeedPrefetchEvent(FeedPrefetchMetric.blankCard));
  }

  Future<void> _startPrefetch(_FeedViewport viewport) {
    final activeRequest = _inFlight[viewport.queryKey];
    if (activeRequest != null) {
      telemetry.record(
        const FeedPrefetchEvent(FeedPrefetchMetric.deduplicated),
      );
      return activeRequest.then((_) async {
        final latest = _active;
        if (latest != null &&
            latest.queryKey == viewport.queryKey &&
            _isCurrent(latest) &&
            latest.remaining <= config.loadTrigger &&
            latest.nextCursor != null &&
            latest.nextCursor!.isNotEmpty) {
          await _startPrefetch(latest);
        }
      });
    }

    final operation = _prefetchToDurableTarget(viewport);
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_inFlight[viewport.queryKey], tracked)) {
        _inFlight.remove(viewport.queryKey);
      }
    });
    _inFlight[viewport.queryKey] = tracked;
    return tracked;
  }

  Future<void> _prefetchToDurableTarget(_FeedViewport initial) async {
    var viewport = initial;
    final requestedCursors = <String>{};
    // A duplicate-heavy server page can add fewer than [remotePageSize]
    // papers. Continue until the durable target is genuinely reached. One
    // page per desired unique paper is sufficient even when each response
    // contributes only one new row; repeated/cyclic cursors and no-progress
    // responses still terminate the loop below.
    final maximumPages = max(1, config.durableAhead);

    for (var pageNumber = 0; pageNumber < maximumPages; pageNumber += 1) {
      if (!_isCurrent(viewport)) return;
      final cursor = viewport.nextCursor;
      if (cursor == null || cursor.isEmpty) return;
      if (!requestedCursors.add(cursor)) return;

      final cancellation = RequestCancellation();
      _cancellations[viewport.queryKey] = cancellation;
      telemetry.record(const FeedPrefetchEvent(FeedPrefetchMetric.requested));
      try {
        final result = await _remote.fetchFeedPage(
          category: viewport.category,
          cursor: cursor,
          limit: config.remotePageSize,
          cancellation: cancellation,
        );
        if (!_isCurrent(viewport) || cancellation.isCancelled) return;

        final currentViewport = _active;
        if (currentViewport == null || !_isCurrent(currentViewport)) return;
        final mergedItems = mergeFeedPapers(
          currentViewport.items,
          result.value.items,
        );
        final merged = FeedPage(
          items: mergedItems,
          nextCursor: result.value.nextCursor,
        );
        final madeProgress =
            mergedItems.length > currentViewport.items.length ||
            merged.nextCursor != cursor;
        if (!result.persisted) {
          await _cache.persistFeedPage(
            queryKey: viewport.queryKey,
            // Cursor pages append to the first-page representation. Appending
            // preserves its validator; replacing with a null ETag would make
            // every successful prefetch disable later 304 revalidation.
            page: result.value,
            replace: false,
            category: viewport.category,
            refreshedAt: _clock(),
          );
        }
        if (!_isCurrent(viewport)) return;
        final latestViewport = _active;
        if (latestViewport == null || !_isCurrent(latestViewport)) return;

        _resetRetry(viewport.queryKey);
        telemetry.record(const FeedPrefetchEvent(FeedPrefetchMetric.succeeded));
        final update = FeedPrefetchUpdate(
          queryKey: viewport.queryKey,
          items: mergedItems,
          nextCursor: merged.nextCursor,
          origin: result.origin,
          offline: result.offline,
        );
        _updates.add(update);
        viewport = latestViewport.withPage(merged);
        _active = viewport;

        if (!madeProgress ||
            viewport.remaining >= config.durableAhead ||
            viewport.nextCursor == null ||
            viewport.nextCursor!.isEmpty) {
          return;
        }
      } on Object {
        if (!_isCurrent(viewport) || cancellation.isCancelled) return;
        final attempt = (_retryAttempts[viewport.queryKey] ?? 0) + 1;
        _retryAttempts[viewport.queryKey] = attempt;
        telemetry.record(
          FeedPrefetchEvent(FeedPrefetchMetric.failed, attempt: attempt),
        );
        _scheduleRetry(viewport, attempt);
        return;
      } finally {
        if (identical(_cancellations[viewport.queryKey], cancellation)) {
          _cancellations.remove(viewport.queryKey);
        }
      }
    }
  }

  void _scheduleRetry(_FeedViewport viewport, int attempt) {
    _retryTasks.remove(viewport.queryKey)?.cancel();
    final task = scheduler.schedule(_retryDelay(attempt), () async {
      _retryTasks.remove(viewport.queryKey);
      final active = _active;
      if (active == null ||
          active.queryKey != viewport.queryKey ||
          !_isCurrent(active)) {
        return;
      }
      await _startPrefetch(active);
    });
    _retryTasks[viewport.queryKey] = task;
  }

  Duration _retryDelay(int attempt) {
    final exponent = min(attempt - 1, 30);
    final baseMilliseconds = min(
      config.retryMaximumDelay.inMilliseconds,
      config.retryInitialDelay.inMilliseconds * pow(2, exponent),
    ).toDouble();
    final boundedRandom = _nextJitter().clamp(0.0, 1.0);
    final factor = 1 + ((boundedRandom * 2) - 1) * config.retryJitterFraction;
    return Duration(
      milliseconds: (baseMilliseconds * factor)
          .round()
          .clamp(1, config.retryMaximumDelay.inMilliseconds)
          .toInt(),
    );
  }

  List<PaperSummary> _windowFor(_FeedViewport viewport) {
    final start = max(0, viewport.index - config.memoryBehind);
    final end = min(
      viewport.items.length,
      viewport.index + config.memoryAhead + 1,
    );
    return viewport.items.sublist(start, end);
  }

  void _scheduleEviction() {
    _evictionTask?.cancel();
    _evictionTask = scheduler.schedule(config.evictionDelay, () async {
      _evictionTask = null;
      final active = _active;
      if (active == null || !_isCurrent(active)) return;
      final protectedIds = _windowFor(
        active,
      ).map((paper) => paper.paperId).toSet();
      try {
        final result = await _cache.evictCache(
          activeQueryKey: active.queryKey,
          protectedPaperIds: protectedIds,
          maxMetadataPapers: config.maxCachedMetadataPapers,
          maxDatabaseBytes: config.maxDatabaseBytes,
          metadataTtl: config.metadataTtl,
          now: _clock(),
        );
        telemetry
          ..record(
            FeedPrefetchEvent(
              FeedPrefetchMetric.cacheRows,
              value: result.usageAfter.metadataRows,
            ),
          )
          ..record(
            FeedPrefetchEvent(
              FeedPrefetchMetric.cacheBytes,
              value: result.usageAfter.physicalDatabaseBytes,
            ),
          );
      } on Object {
        // Cache maintenance is opportunistic and must never interrupt reading.
      }
    });
  }

  bool _isCurrent(_FeedViewport viewport) =>
      !_disposed &&
      viewport.generation == _generation &&
      _active?.queryKey == viewport.queryKey;

  void _resetRetry(String queryKey) {
    _retryAttempts.remove(queryKey);
    _retryTasks.remove(queryKey)?.cancel();
  }

  void _obsoleteQueryWork(String queryKey) {
    _generation += 1;
    _cancellations.remove(queryKey)?.cancel('The feed snapshot was replaced.');
    _resetRetry(queryKey);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final cancellation in _cancellations.values) {
      cancellation.cancel('The feed prefetch coordinator was disposed.');
    }
    _cancellations.clear();
    for (final task in _retryTasks.values) {
      task.cancel();
    }
    _retryTasks.clear();
    _evictionTask?.cancel();
    _evictionTask = null;
    await _updates.close();
  }
}

/// Merges feed pages by stable paper identity without allowing an older arXiv
/// version to replace a newer one already visible to the reader.
List<PaperSummary> mergeFeedPapers(
  Iterable<PaperSummary> existing,
  Iterable<PaperSummary> incoming,
) {
  final merged = <PaperSummary>[];
  final positions = <String, int>{};

  void add(PaperSummary candidate) {
    final position = positions[candidate.paperId];
    if (position == null) {
      positions[candidate.paperId] = merged.length;
      merged.add(candidate);
      return;
    }
    if (_preferCandidate(candidate, merged[position])) {
      merged[position] = candidate;
    }
  }

  existing.forEach(add);
  incoming.forEach(add);
  return List<PaperSummary>.unmodifiable(merged);
}

bool _preferCandidate(PaperSummary candidate, PaperSummary current) {
  if (candidate.arxivBaseId.toLowerCase() !=
      current.arxivBaseId.toLowerCase()) {
    return false;
  }
  final candidateVersion = _arxivVersion(candidate.arxivId);
  final currentVersion = _arxivVersion(current.arxivId);
  if (candidateVersion != currentVersion) {
    return candidateVersion > currentVersion;
  }
  return !candidate.updatedAt.isBefore(current.updatedAt);
}

int _arxivVersion(String arxivId) =>
    int.tryParse(RegExp(r'v(\d+)$').firstMatch(arxivId)?.group(1) ?? '') ?? 0;
