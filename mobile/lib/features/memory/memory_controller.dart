import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/research_memory.dart';
import '../../core/research/research_repository.dart';
import '../research/research_controller.dart';

typedef MemoryReviewScope = ({String accountId, int authEpoch});

const maximumCustomMemoryReviewHorizon = Duration(days: 366 * 5);

bool isValidMemoryReviewInstant(DateTime value, DateTime now) {
  final instant = value.toUtc();
  final current = now.toUtc();
  return instant.isAfter(current) &&
      !instant.isAfter(current.add(maximumCustomMemoryReviewHorizon));
}

abstract interface class MemoryReviewDataSource {
  bool get isOffline;

  Stream<List<MemoryItem>> watch(String accountId);

  Future<void> refresh(
    ResearchAccountRequestScope scope, {
    RequestCancellation? cancellation,
  });

  Future<MemoryItem> review({
    required ResearchRequestScope scope,
    required MemoryItem item,
    required MemoryStatus status,
    DateTime? nextReviewAt,
  });
}

final class RepositoryMemoryReviewDataSource implements MemoryReviewDataSource {
  const RepositoryMemoryReviewDataSource(this._repository);

  final ResearchRepository _repository;

  @override
  bool get isOffline => _repository.isOffline;

  @override
  Stream<List<MemoryItem>> watch(String accountId) =>
      _repository.watchMemoryReview(accountId);

  @override
  Future<void> refresh(
    ResearchAccountRequestScope scope, {
    RequestCancellation? cancellation,
  }) => _repository.refreshMemoryForAccount(scope, cancellation: cancellation);

  @override
  Future<MemoryItem> review({
    required ResearchRequestScope scope,
    required MemoryItem item,
    required MemoryStatus status,
    DateTime? nextReviewAt,
  }) => _repository.reviewMemoryItem(
    scope: scope,
    item: item,
    status: status,
    nextReviewAt: nextReviewAt,
  );
}

final memoryReviewDataSourceProvider = Provider<MemoryReviewDataSource>((ref) {
  return RepositoryMemoryReviewDataSource(
    ref.watch(researchDataSourceProvider),
  );
});

final memoryReviewControllerProvider = StateNotifierProvider.autoDispose
    .family<MemoryReviewController, MemoryReviewState, MemoryReviewScope>((
      ref,
      scope,
    ) {
      return MemoryReviewController(
        scope: scope,
        source: ref.watch(memoryReviewDataSourceProvider),
        scopeIsCurrent: () => ref.read(verifiedLibraryScopeProvider) == scope,
      );
    });

final class MemoryReviewState {
  const MemoryReviewState({
    this.items = const [],
    this.loading = false,
    this.offline = false,
    this.busyItemId,
    this.errorMessage,
    this.statusMessage,
  });

  final List<MemoryItem> items;
  final bool loading;
  final bool offline;
  final String? busyItemId;
  final String? errorMessage;
  final String? statusMessage;

  List<MemoryItem> dueItems(DateTime now) {
    final instant = now.toUtc();
    final due = items
        .where((item) {
          if (!item.isReviewable) return false;
          final next = item.nextReviewAt;
          return next == null || !next.toUtc().isAfter(instant);
        })
        .toList(growable: false);
    due.sort((left, right) {
      final leftAt = left.nextReviewAt?.toUtc();
      final rightAt = right.nextReviewAt?.toUtc();
      if (leftAt == null && rightAt != null) return -1;
      if (leftAt != null && rightAt == null) return 1;
      final byDue = leftAt == null ? 0 : leftAt.compareTo(rightAt!);
      return byDue != 0 ? byDue : right.updatedAt.compareTo(left.updatedAt);
    });
    return List.unmodifiable(due);
  }

  MemoryReviewState copyWith({
    List<MemoryItem>? items,
    bool? loading,
    bool? offline,
    String? busyItemId,
    bool clearBusyItem = false,
    String? errorMessage,
    bool clearError = false,
    String? statusMessage,
    bool clearStatus = false,
  }) => MemoryReviewState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    offline: offline ?? this.offline,
    busyItemId: clearBusyItem ? null : busyItemId ?? this.busyItemId,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    statusMessage: clearStatus ? null : statusMessage ?? this.statusMessage,
  );
}

final class MemoryReviewController extends StateNotifier<MemoryReviewState> {
  MemoryReviewController({
    required this.scope,
    required MemoryReviewDataSource source,
    required bool Function() scopeIsCurrent,
    DateTime Function()? now,
  }) : _source = source,
       _scopeIsCurrent = scopeIsCurrent,
       _now = now ?? DateTime.now,
       super(MemoryReviewState(offline: source.isOffline)) {
    _subscription = source.watch(scope.accountId).listen((items) {
      if (!mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(items: List.unmodifiable(items));
    });
  }

  final MemoryReviewScope scope;
  final MemoryReviewDataSource _source;
  final bool Function() _scopeIsCurrent;
  final DateTime Function() _now;
  late final StreamSubscription<List<MemoryItem>> _subscription;
  RequestCancellation? _request;
  Future<void>? _loadFlight;

  Future<void> load() {
    final active = _loadFlight;
    if (active != null) return active;
    late final Future<void> flight;
    flight = _load().whenComplete(() {
      if (identical(_loadFlight, flight)) _loadFlight = null;
    });
    _loadFlight = flight;
    return flight;
  }

  Future<void> _load() async {
    if (!_scopeIsCurrent()) return;
    _request?.cancel('The memory review was refreshed.');
    final request = RequestCancellation();
    _request = request;
    state = state.copyWith(
      loading: true,
      offline: _source.isOffline,
      clearError: true,
      clearStatus: true,
    );
    try {
      if (!_source.isOffline) {
        await _source.refresh(
          ResearchAccountRequestScope(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            isCurrent: _scopeIsCurrent,
          ),
          cancellation: request,
        );
      }
      if (!mounted || request.isCancelled || !_scopeIsCurrent()) return;
      state = state.copyWith(
        loading: false,
        offline: _source.isOffline,
        clearError: true,
      );
    } on ApiException catch (error) {
      if (error.cancelled || !mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(
        loading: false,
        offline: error.isOffline || _source.isOffline,
        errorMessage: error.isOffline
            ? 'Offline: cached memory remains available on this device.'
            : error.message,
      );
    } on Object {
      if (!mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(
        loading: false,
        offline: _source.isOffline,
        errorMessage: 'Research memory could not be verified.',
      );
    }
  }

  Future<void> markReviewed(
    MemoryItem item, {
    required DateTime nextReviewAt,
  }) => _schedule(
    item: item,
    // The server contract uses `active` only for due-now items with no date.
    // Any chosen future review time is represented as `snoozed` while the
    // review endpoint still increments review_count.
    status: MemoryStatus.snoozed,
    nextReviewAt: nextReviewAt,
    successMessage: 'Review recorded with your next review time.',
  );

  Future<void> snooze(MemoryItem item, {required DateTime nextReviewAt}) =>
      _schedule(
        item: item,
        status: MemoryStatus.snoozed,
        nextReviewAt: nextReviewAt,
        successMessage: 'Memory item snoozed until your chosen time.',
      );

  Future<void> retire(MemoryItem item) => _commit(
    item: item,
    status: MemoryStatus.retired,
    successMessage: 'Memory item retired. The paper was not changed.',
  );

  Future<void> _schedule({
    required MemoryItem item,
    required MemoryStatus status,
    required DateTime nextReviewAt,
    required String successMessage,
  }) {
    if (!isValidMemoryReviewInstant(nextReviewAt, _now())) {
      state = state.copyWith(
        errorMessage: 'Choose a future review time within the next five years.',
        clearStatus: true,
      );
      return Future.value();
    }
    return _commit(
      item: item,
      status: status,
      nextReviewAt: nextReviewAt.toUtc(),
      successMessage: successMessage,
    );
  }

  Future<void> _commit({
    required MemoryItem item,
    required MemoryStatus status,
    required String successMessage,
    DateTime? nextReviewAt,
  }) async {
    if (!_scopeIsCurrent() || state.busyItemId != null) return;
    final current = state.items
        .where((value) => value.id == item.id)
        .firstOrNull;
    if (current == null ||
        current.paperId != item.paperId ||
        current.generation != item.generation ||
        current.revision != item.revision ||
        !current.isReviewable) {
      state = state.copyWith(
        errorMessage: 'This memory item changed. Refresh before reviewing it.',
        clearStatus: true,
      );
      return;
    }
    state = state.copyWith(
      busyItemId: item.id,
      clearError: true,
      clearStatus: true,
    );
    try {
      final canonical = await _source.review(
        scope: ResearchRequestScope(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          paperId: current.paperId,
          generation: current.generation,
          isCurrent: _scopeIsCurrent,
        ),
        item: current,
        status: status,
        nextReviewAt: nextReviewAt,
      );
      if (!mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(
        items: List.unmodifiable([
          for (final value in state.items)
            if (value.id == canonical.id) canonical else value,
        ]),
        clearBusyItem: true,
        clearError: true,
        statusMessage: successMessage,
      );
    } on ApiException catch (error) {
      if (error.cancelled || !mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(
        clearBusyItem: true,
        offline: error.isOffline || _source.isOffline,
        errorMessage: error.isOffline
            ? 'Saved on this device. It will sync after reconnecting.'
            : error.message,
      );
    } on Object {
      if (!mounted || !_scopeIsCurrent()) return;
      state = state.copyWith(
        clearBusyItem: true,
        errorMessage: 'The memory review could not be saved.',
      );
    }
  }

  @override
  void dispose() {
    _request?.cancel('The memory review closed.');
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
