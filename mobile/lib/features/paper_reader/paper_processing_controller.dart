import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';

enum ProcessingEnrichmentStatus { disabled, waiting, ready, unavailable }

/// Optional, progressively published reader capabilities that this visible
/// reader is interested in. This is deliberately separate from preparation:
/// observing these capabilities never authorizes another prepare request.
final class ProcessingEnrichmentRequest {
  const ProcessingEnrichmentRequest({
    this.visualObjects = false,
    this.terms = false,
    this.semanticFacets = false,
    this.paperPassport = false,
  });

  final bool visualObjects;
  final bool terms;
  final bool semanticFacets;
  final bool paperPassport;

  bool get isEmpty =>
      !visualObjects && !terms && !semanticFacets && !paperPassport;

  bool isSatisfiedBy(PaperCapabilities capabilities) =>
      (!visualObjects || capabilities.visualObjects) &&
      (!terms || capabilities.terms) &&
      (!semanticFacets || capabilities.semanticFacets) &&
      (!paperPassport || capabilities.paperPassport);

  @override
  bool operator ==(Object other) =>
      other is ProcessingEnrichmentRequest &&
      other.visualObjects == visualObjects &&
      other.terms == terms &&
      other.semanticFacets == semanticFacets &&
      other.paperPassport == paperPassport;

  @override
  int get hashCode =>
      Object.hash(visualObjects, terms, semanticFacets, paperPassport);
}

final class ProcessingPollPolicy {
  const ProcessingPollPolicy({
    this.interval = const Duration(milliseconds: 1500),
    this.maximumEnrichmentAttempts = 40,
    this.maximumEnrichmentDuration = const Duration(minutes: 1),
  }) : assert(maximumEnrichmentAttempts > 0);

  final Duration interval;
  final int maximumEnrichmentAttempts;
  final Duration maximumEnrichmentDuration;
}

typedef ProcessingPollTimerFactory =
    Timer Function(Duration delay, void Function() callback);

Timer _createProcessingPollTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

class ProcessingUiState {
  const ProcessingUiState({
    this.processing,
    this.requestInFlight = false,
    this.visible = false,
    this.offline = false,
    this.errorMessage,
    this.enrichmentRequest = const ProcessingEnrichmentRequest(),
    this.enrichmentStatus = ProcessingEnrichmentStatus.disabled,
    this.enrichmentMessage,
  });

  final PaperProcessingState? processing;
  final bool requestInFlight;
  final bool visible;
  final bool offline;
  final String? errorMessage;
  final ProcessingEnrichmentRequest enrichmentRequest;
  final ProcessingEnrichmentStatus enrichmentStatus;
  final String? enrichmentMessage;

  ProcessingUiState copyWith({
    PaperProcessingState? processing,
    bool? requestInFlight,
    bool? visible,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
    ProcessingEnrichmentRequest? enrichmentRequest,
    ProcessingEnrichmentStatus? enrichmentStatus,
    String? enrichmentMessage,
    bool clearEnrichmentMessage = false,
  }) => ProcessingUiState(
    processing: processing ?? this.processing,
    requestInFlight: requestInFlight ?? this.requestInFlight,
    visible: visible ?? this.visible,
    offline: offline ?? this.offline,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    enrichmentRequest: enrichmentRequest ?? this.enrichmentRequest,
    enrichmentStatus: enrichmentStatus ?? this.enrichmentStatus,
    enrichmentMessage: clearEnrichmentMessage
        ? null
        : enrichmentMessage ?? this.enrichmentMessage,
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
    ProcessingPollPolicy pollPolicy = const ProcessingPollPolicy(),
    DateTime Function()? now,
    ProcessingPollTimerFactory timerFactory = _createProcessingPollTimer,
  }) : assert(
         pollPolicy.maximumEnrichmentDuration.compareTo(Duration.zero) > 0,
       ),
       _repository = repository,
       _pollPolicy = pollPolicy,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory,
       super(const ProcessingUiState());

  final String paperId;
  final PaperDataSource _repository;
  final ProcessingPollPolicy _pollPolicy;
  final DateTime Function() _now;
  final ProcessingPollTimerFactory _timerFactory;
  Timer? _pollTimer;
  RequestCancellation? _requests;
  bool _refreshing = false;
  bool _restorationRecoveryChecked = false;
  DateTime? _enrichmentPollingStartedAt;
  int _enrichmentPollAttempts = 0;

  void setEnrichmentRequest(ProcessingEnrichmentRequest request) {
    if (state.enrichmentRequest == request) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _resetEnrichmentBudget();
    state = state.copyWith(
      enrichmentRequest: request,
      enrichmentStatus: request.isEmpty
          ? ProcessingEnrichmentStatus.disabled
          : ProcessingEnrichmentStatus.waiting,
      clearEnrichmentMessage: true,
    );
    _reconcileEnrichmentStatus();
    if (state.visible && !state.offline) {
      if (_needsEnrichmentPolling) {
        unawaited(refresh());
      } else {
        _schedulePoll();
      }
    }
  }

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
      _resetEnrichmentBudget();
      return;
    }
    _reconcileEnrichmentStatus();
    if (!_shouldPoll) return;
    unawaited(refresh());
  }

  Future<void> prepare({
    bool retry = false,
    PreparationTrigger trigger = PreparationTrigger.introductionTransition,
  }) async {
    if (state.requestInFlight) return;
    state = state.copyWith(requestInFlight: true, clearError: true);
    final request = _activeRequests;
    try {
      final result = await _repository.prepare(
        paperId,
        retry: retry,
        trigger: trigger,
        cancellation: request,
      );
      if (!mounted || request.isCancelled) return;
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
    final request = _activeRequests;
    try {
      final result = await _repository.getProcessing(
        paperId,
        cancellation: request,
      );
      if (!mounted || request.isCancelled) return;
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
    if (_needsEnrichmentPolling && _enrichmentBudgetExhausted) {
      _markEnrichmentUnavailable();
      return;
    }
    if (!_shouldPoll) return;
    if (_needsEnrichmentPolling && !_beginEnrichmentPollAttempt()) return;
    _refreshing = true;
    final request = _activeRequests;
    try {
      final result = await _repository.getProcessing(
        paperId,
        cancellation: request,
      );
      if (!mounted || request.isCancelled || !state.visible) return;
      _apply(result);
    } on ApiException catch (error) {
      if (error.cancelled || request.isCancelled) return;
      if (!mounted || !state.visible) return;
      state = state.copyWith(
        offline: error.isOffline,
        errorMessage: error.isOffline
            ? 'You’re offline. Connect to continue preparing this paper.'
            : error.message,
        enrichmentStatus: _needsEnrichmentPolling && error.isOffline
            ? ProcessingEnrichmentStatus.unavailable
            : state.enrichmentStatus,
        enrichmentMessage: _needsEnrichmentPolling && error.isOffline
            ? _enrichmentUnavailableMessage
            : state.enrichmentMessage,
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
    _reconcileEnrichmentStatus();
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_shouldPoll) {
      return;
    }
    if (_needsEnrichmentPolling && _enrichmentBudgetExhausted) {
      _markEnrichmentUnavailable();
      return;
    }
    _pollTimer = _timerFactory(_pollPolicy.interval, refresh);
  }

  bool get _shouldPoll {
    if (!state.visible || state.offline) return false;
    final processing = state.processing;
    if (processing == null) return true;
    if (!processing.stopsPolling) return true;
    return _needsEnrichmentPolling && !_enrichmentBudgetExhausted;
  }

  bool get _needsEnrichmentPolling {
    final processing = state.processing;
    final request = state.enrichmentRequest;
    if (processing == null || request.isEmpty) return false;
    if (!processing.stopsPolling) return false;
    if (processing.stage == ProcessingStage.failedRetryable ||
        processing.stage == ProcessingStage.failedTerminal) {
      return false;
    }
    return !request.isSatisfiedBy(processing.capabilities);
  }

  bool _beginEnrichmentPollAttempt() {
    _enrichmentPollingStartedAt ??= _now();
    if (_enrichmentBudgetExhausted) {
      _markEnrichmentUnavailable();
      return false;
    }
    _enrichmentPollAttempts += 1;
    return true;
  }

  bool get _enrichmentBudgetExhausted {
    if (_enrichmentPollAttempts >= _pollPolicy.maximumEnrichmentAttempts) {
      return true;
    }
    final startedAt = _enrichmentPollingStartedAt;
    return startedAt != null &&
        !_now().isBefore(startedAt.add(_pollPolicy.maximumEnrichmentDuration));
  }

  void _reconcileEnrichmentStatus() {
    final request = state.enrichmentRequest;
    if (request.isEmpty) {
      _resetEnrichmentBudget();
      state = state.copyWith(
        enrichmentStatus: ProcessingEnrichmentStatus.disabled,
        clearEnrichmentMessage: true,
      );
      return;
    }
    final processing = state.processing;
    if (processing != null && request.isSatisfiedBy(processing.capabilities)) {
      _resetEnrichmentBudget();
      state = state.copyWith(
        enrichmentStatus: ProcessingEnrichmentStatus.ready,
        clearEnrichmentMessage: true,
      );
      return;
    }
    if (state.offline ||
        processing?.stage == ProcessingStage.failedRetryable ||
        processing?.stage == ProcessingStage.failedTerminal ||
        _enrichmentBudgetExhausted) {
      _markEnrichmentUnavailable();
      return;
    }
    state = state.copyWith(
      enrichmentStatus: ProcessingEnrichmentStatus.waiting,
      enrichmentMessage: processing?.capabilities.introduction == true
          ? 'Optional reader details are still being prepared. You can keep reading.'
          : null,
      clearEnrichmentMessage: processing?.capabilities.introduction != true,
    );
  }

  void _markEnrichmentUnavailable() {
    state = state.copyWith(
      enrichmentStatus: ProcessingEnrichmentStatus.unavailable,
      enrichmentMessage: _enrichmentUnavailableMessage,
    );
  }

  String get _enrichmentUnavailableMessage =>
      'Some optional reader details are unavailable. The prepared text remains available.';

  void _resetEnrichmentBudget() {
    _enrichmentPollingStartedAt = null;
    _enrichmentPollAttempts = 0;
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
