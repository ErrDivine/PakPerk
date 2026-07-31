import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import 'account_profile.dart';
import 'account_repository.dart';

enum CurrentAccountPhase { idle, loading, ready, updating, failed }

final class CurrentAccountState {
  const CurrentAccountState({
    required this.phase,
    this.profile,
    this.verifiedAuthEpoch,
    this.error,
  });

  const CurrentAccountState.idle() : this(phase: CurrentAccountPhase.idle);

  final CurrentAccountPhase phase;
  final AccountProfile? profile;
  final int? verifiedAuthEpoch;
  final ApiException? error;

  bool get isBusy =>
      phase == CurrentAccountPhase.loading ||
      phase == CurrentAccountPhase.updating;
}

typedef SessionEpochReader = int Function();
typedef AccountIdBinder = Future<void> Function(String accountId);

final class CurrentAccountController
    extends StateNotifier<CurrentAccountState> {
  CurrentAccountController({
    required AccountRepository repository,
    required SessionEpochReader sessionEpoch,
    required AccountIdBinder bindAccountId,
  }) : _repository = repository,
       _sessionEpoch = sessionEpoch,
       _bindAccountId = bindAccountId,
       super(const CurrentAccountState.idle());

  final AccountRepository _repository;
  final SessionEpochReader _sessionEpoch;
  final AccountIdBinder _bindAccountId;
  int _generation = 0;

  Future<AccountProfile?> load() async {
    final generation = ++_generation;
    final epoch = _sessionEpoch();
    state = CurrentAccountState(
      phase: CurrentAccountPhase.loading,
      profile: state.profile,
      verifiedAuthEpoch: state.verifiedAuthEpoch,
    );
    try {
      final profile = await _repository.getCurrent(expectedAuthEpoch: epoch);
      if (!_isCurrent(generation, epoch)) return null;
      await _bindAccountId(profile.id);
      if (!_isCurrent(generation, epoch)) return null;
      state = CurrentAccountState(
        phase: CurrentAccountPhase.ready,
        profile: profile,
        verifiedAuthEpoch: epoch,
      );
      return profile;
    } on ApiException catch (error) {
      if (_isCurrent(generation, epoch)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: state.profile,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: error,
        );
      }
      return null;
    } on Object {
      if (_isCurrent(generation, epoch)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: state.profile,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: const ApiException(
            code: 'ACCOUNT_SESSION_UNAVAILABLE',
            message: 'The account session could not be saved securely.',
            retryable: true,
          ),
        );
      }
      return null;
    }
  }

  Future<AccountProfile?> update(AccountProfilePatch patch) async {
    final current = state.profile;
    if (current == null || patch.isEmpty) return null;
    final generation = ++_generation;
    final epoch = _sessionEpoch();
    state = CurrentAccountState(
      phase: CurrentAccountPhase.updating,
      profile: current,
      verifiedAuthEpoch: state.verifiedAuthEpoch,
    );
    try {
      final profile = await _repository.update(
        expectedAuthEpoch: epoch,
        expectedProfileVersion: current.profileVersion,
        patch: patch,
      );
      if (!_isCurrent(generation, epoch)) return null;
      state = CurrentAccountState(
        phase: CurrentAccountPhase.ready,
        profile: profile,
        verifiedAuthEpoch: epoch,
      );
      return profile;
    } on ApiException catch (error) {
      if (_isCurrent(generation, epoch)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: current,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: error,
        );
      }
      return null;
    } on Object {
      if (_isCurrent(generation, epoch)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: current,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: const ApiException(
            code: 'ACCOUNT_UPDATE_UNAVAILABLE',
            message: 'The account update could not be completed.',
            retryable: true,
          ),
        );
      }
      return null;
    }
  }

  void clear() {
    _generation += 1;
    state = const CurrentAccountState.idle();
  }

  bool _isCurrent(int generation, int epoch) =>
      mounted && generation == _generation && epoch == _sessionEpoch();
}
