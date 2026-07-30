import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/repository/paper_repository.dart';
import '../../core/providers.dart';

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
  }) =>
      FeedState(
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
    return FeedController(ref.watch(paperRepositoryProvider));
  },
);

class FeedController extends StateNotifier<FeedState> {
  FeedController(this._repository) : super(const FeedState()) {
    _offlineSubscription = _repository.offlineChanges.listen(
      (offline) => state = state.copyWith(offline: offline),
    );
    unawaited(loadInitial());
  }

  final PaperDataSource _repository;
  final RequestCancellation _requests = RequestCancellation();
  StreamSubscription<bool>? _offlineSubscription;

  Future<void> loadInitial({String? category}) async {
    state = state.copyWith(
      loadingInitial: true,
      category: category,
      clearCategory: category == null,
      clearError: true,
    );
    try {
      final cached = await _repository.getCachedFeed(category: category);
      if (!mounted) return;
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
      if (!mounted) return;
      state = state.copyWith(
        loadingInitial: state.items.isEmpty,
        errorMessage: state.items.isEmpty ? _message(error) : null,
      );
    }

    try {
      final refreshed = await _repository.getFeed(
        category: category,
        cancellation: _requests,
      );
      if (!mounted) return;
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
      if (refreshed.origin == DataOrigin.network) {
        // Persist and invalidate the prior paper version before publishing a
        // new reader identity to the widget tree.
        await _repository.cacheFeed(
          refreshed.value,
          replaceFeed: category == null,
        );
        if (!mounted) return;
      }
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
      if (!mounted) return;
      state = state.copyWith(
        loadingInitial: false,
        errorMessage: state.items.isEmpty ? _message(error) : null,
      );
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore || state.offline) return;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final result = await _repository.getFeed(
        category: state.category,
        cursor: cursor,
        cancellation: _requests,
      );
      if (!mounted) return;
      final seen = state.items.map((paper) => paper.paperId).toSet();
      final newItems = result.value.items.where(
        (paper) => seen.add(paper.paperId),
      );
      final combined = [...state.items, ...newItems];
      if (result.origin == DataOrigin.network) {
        await _repository.cacheFeed(
          FeedPage(items: combined, nextCursor: result.value.nextCursor),
          replaceFeed: state.category == null,
        );
        if (!mounted) return;
      }
      state = state.copyWith(
        items: combined,
        nextCursor: result.value.nextCursor,
        clearNextCursor: result.value.nextCursor == null,
        loadingMore: false,
        offline: result.offline,
        origin: result.origin,
      );
    } on Object catch (error) {
      if (!mounted) return;
      state = state.copyWith(loadingMore: false, errorMessage: _message(error));
    }
  }

  @override
  void dispose() {
    _requests.cancel('The feed controller was disposed.');
    _offlineSubscription?.cancel();
    super.dispose();
  }
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'The paper feed could not be loaded.';
}
