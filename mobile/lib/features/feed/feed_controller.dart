import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/cache/feed_cache_persistence.dart';
import '../../core/models/paper.dart';
import '../../core/repository/paper_repository.dart';
import '../../core/providers.dart';
import 'feed_prefetch_config.dart';
import 'feed_prefetch_coordinator.dart';
import 'feed_prefetch_telemetry.dart';
import 'preloaded_feed_snapshot.dart';

class FeedState {
  const FeedState({
    this.items = const [],
    this.nextCursor,
    this.category,
    this.loadingInitial = true,
    this.loadingMore = false,
    this.offline = false,
    this.origin,
    this.errorMessage,
  });

  final List<PaperSummary> items;
  final String? nextCursor;
  final String? category;
  final bool loadingInitial;
  final bool loadingMore;
  final bool offline;
  final DataOrigin? origin;
  final String? errorMessage;

  FeedState copyWith({
    List<PaperSummary>? items,
    String? nextCursor,
    bool clearNextCursor = false,
    String? category,
    bool clearCategory = false,
    bool? loadingInitial,
    bool? loadingMore,
    bool? offline,
    DataOrigin? origin,
    String? errorMessage,
    bool clearError = false,
  }) => FeedState(
    items: items ?? this.items,
    nextCursor: clearNextCursor ? null : nextCursor ?? this.nextCursor,
    category: clearCategory ? null : category ?? this.category,
    loadingInitial: loadingInitial ?? this.loadingInitial,
    loadingMore: loadingMore ?? this.loadingMore,
    offline: offline ?? this.offline,
    origin: origin ?? this.origin,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final feedControllerProvider = StateNotifierProvider<FeedController, FeedState>(
  (ref) {
    final repository = ref.watch(paperRepositoryProvider);
    final cache = ref.watch(feedCachePersistenceProvider);
    final config = ref.watch(feedPrefetchConfigProvider);
    return FeedController(
      repository,
      config: config,
      preloadedSnapshot: ref.watch(preloadedFeedSnapshotProvider),
      prefetchCoordinator: cache == null
          ? null
          : FeedPrefetchCoordinator(
              remote: PaperDataSourceFeedPrefetchRemoteSource(repository),
              cache: cache,
              config: config,
              telemetry: ref.watch(feedPrefetchTelemetryProvider),
            ),
    );
  },
);

final feedPrefetchTelemetryProvider = Provider<FeedPrefetchTelemetry>(
  (ref) => PakPerkFeedPrefetchTelemetry(sink: ref.watch(telemetrySinkProvider)),
);

class FeedController extends StateNotifier<FeedState> {
  FeedController(
    this._repository, {
    FeedPrefetchConfig? config,
    PreloadedFeedSnapshot? preloadedSnapshot,
    FeedPrefetchCoordinator? prefetchCoordinator,
  }) : _config =
           config ?? prefetchCoordinator?.config ?? const FeedPrefetchConfig(),
       _startedWithPreload = preloadedSnapshot != null,
       _prefetchCoordinator = prefetchCoordinator,
       super(
         preloadedSnapshot == null
             ? const FeedState()
             : FeedState(
                 items: preloadedSnapshot.page.items,
                 nextCursor: preloadedSnapshot.page.nextCursor,
                 loadingInitial: false,
                 offline: preloadedSnapshot.offline,
                 origin: preloadedSnapshot.origin,
               ),
       ) {
    _prefetchSubscription = _prefetchCoordinator?.updates.listen(
      _applyPrefetchUpdate,
    );
    var wasOffline = state.offline;
    _offlineSubscription = _repository.offlineChanges.listen((offline) {
      if (wasOffline && !offline) {
        _prefetchCoordinator?.connectivityRecovered();
      }
      wasOffline = offline;
      state = state.copyWith(offline: offline);
    });
    if (preloadedSnapshot == null) unawaited(loadInitial());
  }

  final PaperDataSource _repository;
  final FeedPrefetchConfig _config;
  final bool _startedWithPreload;
  final FeedPrefetchCoordinator? _prefetchCoordinator;
  StreamSubscription<bool>? _offlineSubscription;
  StreamSubscription<FeedPrefetchUpdate>? _prefetchSubscription;
  Future<void>? _preloadedRefresh;
  RequestCancellation? _initialRequest;
  RequestCancellation? _loadMoreRequest;
  int _queryGeneration = 0;

  /// Revalidates a production startup snapshot once, after the first usable
  /// frame. For direct tests and embeddings without a preload this is a no-op,
  /// because their constructor retains the original automatic load behavior.
  Future<void> refreshPreloadedFirstPageOnce() {
    if (!_startedWithPreload) return Future.value();
    return _preloadedRefresh ??= _startPreloadedRefresh();
  }

  Future<void> _startPreloadedRefresh() {
    final generation = _beginQueryRequest();
    final request = _initialRequest!;
    return _refreshFirstPage(
      category: state.category,
      generation: generation,
      cancellation: request,
    );
  }

  Future<void> loadInitial({String? category}) async {
    final generation = _beginQueryRequest();
    final request = _initialRequest!;
    _prefetchCoordinator?.activateQuery(category: category);
    state = state.copyWith(
      items: const [],
      clearNextCursor: true,
      loadingInitial: true,
      category: category,
      clearCategory: category == null,
      clearError: true,
    );
    try {
      final cached = await _repository.getCachedFeed(
        category: category,
        limit: _config.remotePageSize,
      );
      if (!_isCurrentQuery(generation)) return;
      state = state.copyWith(
        items: cached.value.items,
        nextCursor: cached.value.nextCursor,
        clearNextCursor: cached.value.nextCursor == null,
        loadingInitial: false,
        offline: cached.offline,
        origin: cached.origin,
        clearError: true,
      );
    } on Object catch (error) {
      if (!_isCurrentQuery(generation)) return;
      state = state.copyWith(
        loadingInitial: state.items.isEmpty,
        errorMessage: state.items.isEmpty ? _message(error) : null,
      );
    }

    await _refreshFirstPage(
      category: category,
      generation: generation,
      cancellation: request,
    );
  }

  Future<void> _refreshFirstPage({
    required String? category,
    required int generation,
    required RequestCancellation cancellation,
  }) async {
    try {
      final refreshed = await _repository.getFeed(
        category: category,
        limit: _config.remotePageSize,
        cancellation: cancellation,
      );
      if (!_isCurrentQuery(generation)) return;
      // A reachable but not-yet-seeded backend should not erase the bundled or
      // device-cached discovery feed. Category requests are different: an empty
      // response there is a meaningful result and must remain visible.
      if (category == null &&
          refreshed.value.items.isEmpty &&
          state.items.isNotEmpty) {
        state = state.copyWith(
          loadingInitial: false,
          offline: refreshed.offline,
          clearError: true,
        );
        return;
      }
      if (refreshed.origin == DataOrigin.network && !refreshed.persisted) {
        // Persist and invalidate the prior paper version before publishing a
        // new reader identity to the widget tree.
        await _repository.cacheFeed(
          refreshed.value,
          replaceFeed: category == null,
        );
        if (!_isCurrentQuery(generation)) return;
      }
      _prefetchCoordinator?.acceptAuthoritativeSnapshot(
        items: refreshed.value.items,
        nextCursor: refreshed.value.nextCursor,
        category: category,
      );
      state = state.copyWith(
        items: refreshed.value.items,
        nextCursor: refreshed.value.nextCursor,
        clearNextCursor: refreshed.value.nextCursor == null,
        loadingInitial: false,
        offline: refreshed.offline,
        origin: refreshed.origin,
        clearError: true,
      );
    } on Object catch (error) {
      if (!_isCurrentQuery(generation)) return;
      state = state.copyWith(
        loadingInitial: false,
        errorMessage: state.items.isEmpty ? _message(error) : null,
      );
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore || state.offline) return;
    final generation = _queryGeneration;
    final category = state.category;
    final request = RequestCancellation();
    _loadMoreRequest?.cancel('A newer feed page request replaced this one.');
    _loadMoreRequest = request;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final result = await _repository.getFeed(
        category: category,
        cursor: cursor,
        limit: _config.remotePageSize,
        cancellation: request,
      );
      if (!_isCurrentQuery(generation) || state.category != category) return;
      final combined = mergeFeedPapers(state.items, result.value.items);
      if (result.origin == DataOrigin.network && !result.persisted) {
        await _repository.cacheFeed(
          FeedPage(items: combined, nextCursor: result.value.nextCursor),
          replaceFeed: state.category == null,
        );
        if (!_isCurrentQuery(generation) || state.category != category) return;
      }
      _prefetchCoordinator?.acceptAuthoritativeSnapshot(
        items: combined,
        nextCursor: result.value.nextCursor,
        category: category,
      );
      state = state.copyWith(
        items: combined,
        nextCursor: result.value.nextCursor,
        clearNextCursor: result.value.nextCursor == null,
        loadingMore: false,
        offline: result.offline,
        origin: result.origin,
      );
    } on Object catch (error) {
      if (!_isCurrentQuery(generation) || state.category != category) return;
      state = state.copyWith(loadingMore: false, errorMessage: _message(error));
    } finally {
      if (identical(_loadMoreRequest, request)) _loadMoreRequest = null;
    }
  }

  /// Handles a settled vertical page without surfacing speculative failures
  /// as blocking feed errors.
  Future<void> onCommittedPage(int index) async {
    if (index < 0 || index >= state.items.length) {
      _prefetchCoordinator?.recordBlankCard();
      return;
    }
    final coordinator = _prefetchCoordinator;
    if (coordinator == null) {
      if (state.items.length - index - 1 <= _config.loadTrigger) {
        await loadMore();
      }
      return;
    }
    await coordinator.onCommittedPage(
      index: index,
      items: state.items,
      nextCursor: state.nextCursor,
      category: state.category,
    );
  }

  void _applyPrefetchUpdate(FeedPrefetchUpdate update) {
    if (!mounted) return;
    final coordinator = _prefetchCoordinator;
    if (coordinator == null ||
        update.queryKey !=
            feedQueryKey(
              category: state.category,
              limit: _config.remotePageSize,
            )) {
      return;
    }
    state = state.copyWith(
      items: update.items,
      nextCursor: update.nextCursor,
      clearNextCursor: update.nextCursor == null,
      loadingMore: false,
      offline: update.offline,
      origin: update.origin,
      clearError: true,
    );
  }

  @override
  void dispose() {
    _initialRequest?.cancel('The feed controller was disposed.');
    _loadMoreRequest?.cancel('The feed controller was disposed.');
    _offlineSubscription?.cancel();
    _prefetchSubscription?.cancel();
    final coordinator = _prefetchCoordinator;
    if (coordinator != null) unawaited(coordinator.dispose());
    super.dispose();
  }

  int _beginQueryRequest() {
    _queryGeneration += 1;
    _initialRequest?.cancel('The active feed query changed.');
    _loadMoreRequest?.cancel('The active feed query changed.');
    _loadMoreRequest = null;
    _initialRequest = RequestCancellation();
    return _queryGeneration;
  }

  bool _isCurrentQuery(int generation) =>
      mounted && generation == _queryGeneration;
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'The paper feed could not be loaded.';
}
