import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';

class ProcessingUiState {
  const ProcessingUiState({
    this.processing,
    this.requestInFlight = false,
    this.visible = false,
    this.offline = false,
    this.errorMessage,
  });

  final PaperProcessingState? processing;
  final bool requestInFlight;
  final bool visible;
  final bool offline;
  final String? errorMessage;

  ProcessingUiState copyWith({
    PaperProcessingState? processing,
    bool? requestInFlight,
    bool? visible,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
  }) =>
      ProcessingUiState(
        processing: processing ?? this.processing,
        requestInFlight: requestInFlight ?? this.requestInFlight,
        visible: visible ?? this.visible,
        offline: offline ?? this.offline,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );
}

final paperProcessingControllerProvider = StateNotifierProvider.autoDispose
    .family<PaperProcessingController, ProcessingUiState, PaperVersionKey>((
  ref,
  paperKey,
) {
  return PaperProcessingController(
    paperId: paperKey.paperId,
    repository: ref.watch(paperRepositoryProvider),
  );
});

class PaperProcessingController extends StateNotifier<ProcessingUiState> {
  PaperProcessingController({
    required this.paperId,
    required PaperDataSource repository,
  })  : _repository = repository,
        super(const ProcessingUiState());

  final String paperId;
  final PaperDataSource _repository;
  Timer? _pollTimer;
  RequestCancellation? _requests;
  bool _refreshing = false;
  bool _restorationRecoveryChecked = false;

  void setVisible(bool visible) {
    if (state.visible == visible) {
      if (visible) _schedulePoll();
      return;
    }
    state = state.copyWith(visible: visible);
    if (!visible) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _cancelRequests('The paper processing view is no longer visible.');
      return;
    }
    if (state.processing?.stopsPolling == true) return;
    unawaited(refresh());
  }

  Future<void> prepare({bool retry = false}) async {
    if (state.requestInFlight) return;
    state = state.copyWith(requestInFlight: true, clearError: true);
    try {
      final result = await _repository.prepare(
        paperId,
        retry: retry,
        cancellation: _activeRequests,
      );
      if (!mounted) return;
      _apply(result);
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
      state = state.copyWith(
        requestInFlight: false,
        offline: error.isOffline,
        errorMessage: error.isOffline
            ? 'You’re offline. Cached prepared content is still available.'
            : error.message,
      );
    } finally {
      if (mounted) {
        state = state.copyWith(requestInFlight: false);
        _schedulePoll();
      }
    }
  }

  /// Reconciles a persisted committed-swipe guard with backend truth.
  ///
  /// The app may be terminated after persisting `prepareRequested` but before
  /// the POST reaches the server. On the next visible visit we inspect status
  /// once and reissue the idempotent POST only when the backend still reports
  /// `not_requested`.
  Future<void> recoverCommittedIntent() async {
    if (_restorationRecoveryChecked || state.requestInFlight) return;
    while (_refreshing && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!mounted || _restorationRecoveryChecked || state.requestInFlight) {
      return;
    }
    _restorationRecoveryChecked = true;

    final known = state.processing;
    if (known != null) {
      if (known.stage == ProcessingStage.notRequested) {
        await prepare();
      }
      return;
    }

    _refreshing = true;
    try {
      final result = await _repository.getProcessing(
        paperId,
        cancellation: _activeRequests,
      );
      if (!mounted) return;
      _apply(result);
      if (result.value.stage == ProcessingStage.notRequested) {
        _refreshing = false;
        await prepare();
      }
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
      state = state.copyWith(
        offline: error.isOffline,
        errorMessage: error.isOffline
            ? 'You’re offline. Connect to continue preparing this paper.'
            : error.message,
      );
    } finally {
      _refreshing = false;
      if (mounted) _schedulePoll();
    }
  }

  Future<void> refresh() async {
    if (_refreshing || !state.visible) return;
    _refreshing = true;
    try {
      final result = await _repository.getProcessing(
        paperId,
        cancellation: _activeRequests,
      );
      if (!mounted) return;
      _apply(result);
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
      state = state.copyWith(
        offline: error.isOffline,
        errorMessage: error.isOffline
            ? 'You’re offline. Connect to continue preparing this paper.'
            : error.message,
      );
    } finally {
      _refreshing = false;
      if (mounted) _schedulePoll();
    }
  }

  void _apply(RepositoryValue<PaperProcessingState> result) {
    state = state.copyWith(
      processing: result.value,
      requestInFlight: false,
      offline: result.offline,
      clearError: true,
    );
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final processing = state.processing;
    if (!state.visible || state.offline || processing?.stopsPolling == true) {
      return;
    }
    _pollTimer = Timer(const Duration(milliseconds: 1500), refresh);
  }

  RequestCancellation get _activeRequests {
    final current = _requests;
    if (current != null && !current.isCancelled) return current;
    return _requests = RequestCancellation();
  }

  void _cancelRequests(String reason) {
    _requests?.cancel(reason);
    _requests = null;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cancelRequests('The paper processing controller was disposed.');
    super.dispose();
  }
}
