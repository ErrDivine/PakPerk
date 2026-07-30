import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';

class PaperMetadataState {
  const PaperMetadataState({
    this.paper,
    this.refreshing = false,
    this.offline = false,
    this.errorMessage,
  });

  final PaperSummary? paper;
  final bool refreshing;
  final bool offline;
  final String? errorMessage;

  PaperMetadataState copyWith({
    PaperSummary? paper,
    bool? refreshing,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
  }) =>
      PaperMetadataState(
        paper: paper ?? this.paper,
        refreshing: refreshing ?? this.refreshing,
        offline: offline ?? this.offline,
        errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      );
}

final paperMetadataControllerProvider = StateNotifierProvider.autoDispose
    .family<PaperMetadataController, PaperMetadataState, PaperVersionKey>((
  ref,
  paperKey,
) {
  return PaperMetadataController(
    paperId: paperKey.paperId,
    repository: ref.watch(paperRepositoryProvider),
  );
});

class PaperMetadataController extends StateNotifier<PaperMetadataState> {
  PaperMetadataController({
    required this.paperId,
    required PaperDataSource repository,
  })  : _repository = repository,
        super(const PaperMetadataState());

  final String paperId;
  final PaperDataSource _repository;
  final RequestCancellation _requests = RequestCancellation();
  bool _loaded = false;

  Future<void> ensureLoaded(PaperSummary snapshot) async {
    if (state.paper == null) state = state.copyWith(paper: snapshot);
    if (_loaded) return;
    _loaded = true;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final result = await _repository.getPaper(
        paperId,
        cancellation: _requests,
      );
      if (!mounted) return;
      state = state.copyWith(
        paper: result.value,
        refreshing: false,
        offline: result.offline,
      );
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
      state = state.copyWith(
        refreshing: false,
        offline: error.isOffline,
        errorMessage: error.message,
      );
    }
  }

  @override
  void dispose() {
    _requests.cancel('The paper metadata view was disposed.');
    super.dispose();
  }
}
