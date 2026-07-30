import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/connections.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';

class ConnectionsState {
  const ConnectionsState({
    this.value,
    this.loading = false,
    this.offline = false,
    this.notReady = false,
    this.origin,
    this.errorMessage,
  });

  final PaperConnections? value;
  final bool loading;
  final bool offline;
  final bool notReady;
  final DataOrigin? origin;
  final String? errorMessage;
  bool get bundledDemo => origin == DataOrigin.bundledDemo;

  ConnectionsState copyWith({
    PaperConnections? value,
    bool? loading,
    bool? offline,
    bool? notReady,
    DataOrigin? origin,
    String? errorMessage,
    bool clearError = false,
  }) =>
      ConnectionsState(
        value: value ?? this.value,
        loading: loading ?? this.loading,
        offline: offline ?? this.offline,
        notReady: notReady ?? this.notReady,
        origin: origin ?? this.origin,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );
}

final connectionsControllerProvider = StateNotifierProvider.autoDispose
    .family<ConnectionsController, ConnectionsState, PaperVersionKey>((
  ref,
  paperKey,
) {
  return ConnectionsController(
    paperId: paperKey.paperId,
    repository: ref.watch(paperRepositoryProvider),
  );
});

class ConnectionsController extends StateNotifier<ConnectionsState> {
  ConnectionsController({
    required this.paperId,
    required PaperDataSource repository,
  })  : _repository = repository,
        super(const ConnectionsState());

  final String paperId;
  final PaperDataSource _repository;
  final RequestCancellation _requests = RequestCancellation();

  Future<void> load({bool force = false}) async {
    if (state.loading || (!force && state.value != null)) return;
    state = state.copyWith(loading: true, notReady: false, clearError: true);
    try {
      final result = await _repository.getConnections(
        paperId,
        cancellation: _requests,
      );
      if (!mounted) return;
      state = state.copyWith(
        value: result.value,
        loading: false,
        offline: result.offline,
        notReady: false,
        origin: result.origin,
      );
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
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
    _requests.cancel('The connections view was disposed.');
    super.dispose();
  }
}
