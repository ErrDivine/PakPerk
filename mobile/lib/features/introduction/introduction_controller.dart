import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/introduction.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';

class IntroductionState {
  const IntroductionState({
    this.value,
    this.loading = false,
    this.offline = false,
    this.notReady = false,
    this.origin,
    this.errorMessage,
  });

  final PaperIntroduction? value;
  final bool loading;
  final bool offline;
  final bool notReady;
  final DataOrigin? origin;
  final String? errorMessage;
  bool get bundledDemo => origin == DataOrigin.bundledDemo;

  IntroductionState copyWith({
    PaperIntroduction? value,
    bool clearValue = false,
    bool? loading,
    bool? offline,
    bool? notReady,
    DataOrigin? origin,
    String? errorMessage,
    bool clearError = false,
  }) => IntroductionState(
    value: clearValue ? null : value ?? this.value,
    loading: loading ?? this.loading,
    offline: offline ?? this.offline,
    notReady: notReady ?? this.notReady,
    origin: origin ?? this.origin,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final introductionControllerProvider = StateNotifierProvider.autoDispose
    .family<IntroductionController, IntroductionState, PaperVersionKey>((
      ref,
      paperKey,
    ) {
      return IntroductionController(
        paperId: paperKey.paperId,
        repository: ref.watch(paperRepositoryProvider),
      );
    });

class IntroductionController extends StateNotifier<IntroductionState> {
  IntroductionController({
    required this.paperId,
    required PaperDataSource repository,
  }) : _repository = repository,
       super(const IntroductionState());

  final String paperId;
  final PaperDataSource _repository;
  RequestCancellation? _requests;
  int? _expectedGeneration;
  int _scopeRevision = 0;

  /// Invalidates in-memory derived content as soon as processing advances.
  void acceptGeneration(int generation) {
    if (generation <= 0 || _expectedGeneration == generation) return;
    _expectedGeneration = generation;
    _scopeRevision += 1;
    if (state.value?.generation == generation) return;
    _requests?.cancel('The paper processing generation changed.');
    _requests = null;
    state = const IntroductionState();
  }

  Future<void> load({bool force = false}) async {
    if (state.loading || (!force && state.value != null)) return;
    final scopeRevision = _scopeRevision;
    final request = _activeRequests;
    state = state.copyWith(loading: true, notReady: false, clearError: true);
    try {
      final result = await _repository.getIntroduction(
        paperId,
        cancellation: request,
      );
      if (!_isCurrentScope(scopeRevision, request)) return;
      final expectedGeneration = _expectedGeneration;
      if (expectedGeneration != null &&
          result.value.generation != expectedGeneration) {
        state = state.copyWith(
          clearValue: true,
          loading: false,
          notReady: true,
        );
        return;
      }
      _expectedGeneration ??= result.value.generation;
      state = state.copyWith(
        value: result.value,
        loading: false,
        offline: result.offline,
        notReady: false,
        origin: result.origin,
      );
    } on ApiException catch (error) {
      if (error.cancelled || !_isCurrentScope(scopeRevision, request)) return;
      state = state.copyWith(
        loading: false,
        offline: error.isOffline,
        notReady: error.capabilityNotReady,
        errorMessage: error.capabilityNotReady ? null : error.message,
      );
    }
  }

  @override
  void dispose() {
    _requests?.cancel('The introduction view was disposed.');
    super.dispose();
  }

  RequestCancellation get _activeRequests {
    final current = _requests;
    if (current != null && !current.isCancelled) return current;
    return _requests = RequestCancellation();
  }

  bool _isCurrentScope(int revision, RequestCancellation request) =>
      mounted &&
      revision == _scopeRevision &&
      identical(_requests, request) &&
      !request.isCancelled;
}
