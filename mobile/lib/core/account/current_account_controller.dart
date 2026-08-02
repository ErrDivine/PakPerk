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
    this.errorAuthEpoch,
    this.knownReadOnlyStatus,
    this.knownReadOnlyAuthEpoch,
  });

  const CurrentAccountState.idle() : this(phase: CurrentAccountPhase.idle);

  final CurrentAccountPhase phase;
  final AccountProfile? profile;
  final int? verifiedAuthEpoch;
  final ApiException? error;
  final int? errorAuthEpoch;
  final AccountStatus? knownReadOnlyStatus;
  final int? knownReadOnlyAuthEpoch;

  bool get isBusy =>
      phase == CurrentAccountPhase.loading ||
      phase == CurrentAccountPhase.updating;
}

typedef SessionEpochReader = int Function();
typedef SessionAccountIdReader = String? Function();
typedef AccountIdBinder = Future<void> Function(String accountId);

final class CurrentAccountController
    extends StateNotifier<CurrentAccountState> {
  CurrentAccountController({
    required AccountRepository repository,
    required SessionEpochReader sessionEpoch,
    required SessionAccountIdReader sessionAccountId,
    required AccountIdBinder bindAccountId,
  }) : _repository = repository,
       _sessionEpoch = sessionEpoch,
       _sessionAccountId = sessionAccountId,
       _bindAccountId = bindAccountId,
       super(const CurrentAccountState.idle());

  final AccountRepository _repository;
  final SessionEpochReader _sessionEpoch;
  final SessionAccountIdReader _sessionAccountId;
  final AccountIdBinder _bindAccountId;
  int _generation = 0;

  bool get isLoadingFirstVerifiedIdentity =>
      state.phase == CurrentAccountPhase.loading &&
      state.profile == null &&
      state.verifiedAuthEpoch == null &&
      state.errorAuthEpoch == null &&
      state.knownReadOnlyAuthEpoch == null;

  Future<AccountProfile?> load() async {
    final generation = ++_generation;
    final epoch = _sessionEpoch();
    final operationAccountId = _sessionAccountId();
    final verifiedOperationAccountId = state.verifiedAuthEpoch == epoch
        ? state.profile?.id
        : null;
    final retainedProfile = state.profile?.id == operationAccountId
        ? state.profile
        : null;
    state = CurrentAccountState(
      phase: CurrentAccountPhase.loading,
      profile: retainedProfile,
      verifiedAuthEpoch: retainedProfile == null
          ? null
          : state.verifiedAuthEpoch,
      knownReadOnlyStatus: state.knownReadOnlyAuthEpoch == epoch
          ? state.knownReadOnlyStatus
          : null,
      knownReadOnlyAuthEpoch: state.knownReadOnlyAuthEpoch == epoch
          ? state.knownReadOnlyAuthEpoch
          : null,
    );
    try {
      final profile = await _repository.getCurrent(expectedAuthEpoch: epoch);
      if (!_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        return null;
      }
      // The ID stored beside a refresh token is only an offline cache key. On
      // cold restore, the authenticated `/v1/me` response is authoritative and
      // may replace that stale key after the old account data is cleared. Once
      // this epoch has already verified an account, however, a different ID is
      // an inconsistent response and must fail closed.
      if (verifiedOperationAccountId != null &&
          profile.id != verifiedOperationAccountId) {
        throw StateError('The account response changed session identity.');
      }
      await _bindAccountId(profile.id);
      if (!_operationIdentityIsCurrent(generation, epoch, profile.id)) {
        return null;
      }
      state = CurrentAccountState(
        phase: CurrentAccountPhase.ready,
        profile: profile,
        verifiedAuthEpoch: epoch,
        knownReadOnlyStatus: profile.isActive ? null : profile.status,
        knownReadOnlyAuthEpoch: profile.isActive ? null : epoch,
      );
      return profile;
    } on ApiException catch (error) {
      if (_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        final learnedStatus = _readOnlyStatusForErrorCode(error.code);
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: state.profile,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: error,
          errorAuthEpoch: epoch,
          knownReadOnlyStatus:
              learnedStatus ??
              (state.knownReadOnlyAuthEpoch == epoch
                  ? state.knownReadOnlyStatus
                  : null),
          knownReadOnlyAuthEpoch:
              learnedStatus != null || state.knownReadOnlyAuthEpoch == epoch
              ? epoch
              : null,
        );
      }
      return null;
    } on Object {
      if (_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: state.profile,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: const ApiException(
            code: 'ACCOUNT_SESSION_UNAVAILABLE',
            message: 'The account session could not be saved securely.',
            retryable: true,
          ),
          errorAuthEpoch: epoch,
          knownReadOnlyStatus: state.knownReadOnlyAuthEpoch == epoch
              ? state.knownReadOnlyStatus
              : null,
          knownReadOnlyAuthEpoch: state.knownReadOnlyAuthEpoch == epoch
              ? epoch
              : null,
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
    final operationAccountId = _sessionAccountId();
    if (operationAccountId == null || current.id != operationAccountId) {
      clear();
      return null;
    }
    state = CurrentAccountState(
      phase: CurrentAccountPhase.updating,
      profile: current,
      verifiedAuthEpoch: state.verifiedAuthEpoch,
      knownReadOnlyStatus: state.knownReadOnlyAuthEpoch == epoch
          ? state.knownReadOnlyStatus
          : null,
      knownReadOnlyAuthEpoch: state.knownReadOnlyAuthEpoch == epoch
          ? epoch
          : null,
    );
    try {
      final profile = await _repository.update(
        expectedAuthEpoch: epoch,
        expectedProfileVersion: current.profileVersion,
        patch: patch,
      );
      if (!_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        return null;
      }
      if (profile.id != operationAccountId) {
        throw StateError('The account response changed session identity.');
      }
      state = CurrentAccountState(
        phase: CurrentAccountPhase.ready,
        profile: profile,
        verifiedAuthEpoch: epoch,
        knownReadOnlyStatus: profile.isActive ? null : profile.status,
        knownReadOnlyAuthEpoch: profile.isActive ? null : epoch,
      );
      return profile;
    } on ApiException catch (error) {
      if (_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        final learnedStatus = _readOnlyStatusForErrorCode(error.code);
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: current,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: error,
          errorAuthEpoch: epoch,
          knownReadOnlyStatus:
              learnedStatus ??
              (state.knownReadOnlyAuthEpoch == epoch
                  ? state.knownReadOnlyStatus
                  : null),
          knownReadOnlyAuthEpoch:
              learnedStatus != null || state.knownReadOnlyAuthEpoch == epoch
              ? epoch
              : null,
        );
      }
      return null;
    } on Object {
      if (_operationIdentityIsCurrent(generation, epoch, operationAccountId)) {
        state = CurrentAccountState(
          phase: CurrentAccountPhase.failed,
          profile: current,
          verifiedAuthEpoch: state.verifiedAuthEpoch,
          error: const ApiException(
            code: 'ACCOUNT_UPDATE_UNAVAILABLE',
            message: 'The account update could not be completed.',
            retryable: true,
          ),
          errorAuthEpoch: epoch,
          knownReadOnlyStatus: state.knownReadOnlyAuthEpoch == epoch
              ? state.knownReadOnlyStatus
              : null,
          knownReadOnlyAuthEpoch: state.knownReadOnlyAuthEpoch == epoch
              ? epoch
              : null,
        );
      }
      return null;
    }
  }

  /// Immediately revokes a profile's verified/mutation scopes when any
  /// authenticated endpoint reports an authoritative non-active status.
  void recordAuthoritativeReadOnlyStatus({
    required String errorCode,
    required int authEpoch,
  }) {
    final status = _readOnlyStatusForErrorCode(errorCode);
    if (!mounted || status == null || authEpoch != _sessionEpoch()) return;
    _generation += 1;
    state = CurrentAccountState(
      phase: CurrentAccountPhase.failed,
      profile: state.profile,
      verifiedAuthEpoch: state.verifiedAuthEpoch,
      error: ApiException(
        code: errorCode,
        message: switch (status) {
          AccountStatus.suspended => 'This account is suspended.',
          AccountStatus.deletionPending => 'Account deletion is pending.',
          AccountStatus.deleted => 'This account is deleted.',
          AccountStatus.active => 'This account is read-only.',
        },
        statusCode: 403,
      ),
      errorAuthEpoch: authEpoch,
      knownReadOnlyStatus: status,
      knownReadOnlyAuthEpoch: authEpoch,
    );
  }

  void clear() {
    _generation += 1;
    state = const CurrentAccountState.idle();
  }

  bool _isCurrent(int generation, int epoch) =>
      mounted && generation == _generation && epoch == _sessionEpoch();

  bool _operationIdentityIsCurrent(
    int generation,
    int epoch,
    String? accountId,
  ) {
    if (!_isCurrent(generation, epoch)) return false;
    if (_sessionAccountId() == accountId) return true;
    clear();
    return false;
  }
}

AccountStatus? _readOnlyStatusForErrorCode(String code) => switch (code) {
  'ACCOUNT_SUSPENDED' => AccountStatus.suspended,
  'ACCOUNT_DELETION_PENDING' => AccountStatus.deletionPending,
  'ACCOUNT_DELETED' => AccountStatus.deleted,
  _ => null,
};
