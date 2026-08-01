import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import '../auth/auth_models.dart';
import 'account_deletion_guard_store.dart';
import 'account_deletion_models.dart';
import 'account_deletion_repository.dart';

enum AccountDeletionPhase { idle, requestingRecentAuth, pending, failed }

final class AccountDeletionState {
  const AccountDeletionState({
    required this.phase,
    this.result,
    this.guard,
    this.errorCode,
    this.errorMessage,
  });

  const AccountDeletionState.idle() : this(phase: AccountDeletionPhase.idle);

  final AccountDeletionPhase phase;
  final AccountDeletionRequestResult? result;
  final AccountDeletionGuardRecord? guard;
  final String? errorCode;
  final String? errorMessage;

  bool get busy => phase == AccountDeletionPhase.requestingRecentAuth;
  bool get deletionPending => phase == AccountDeletionPhase.pending;
  bool get localCleanupComplete => guard?.localCleanupComplete == true;
}

final class AccountDeletionController
    extends StateNotifier<AccountDeletionState> {
  AccountDeletionController({required AccountDeletionRepository repository})
    : _repository = repository,
      super(const AccountDeletionState.idle());

  final AccountDeletionRepository _repository;
  int _generation = 0;

  Future<AccountDeletionRequestResult?> request({
    required String? accountId,
    required int expectedAuthEpoch,
  }) async {
    if (state.busy || state.deletionPending) return state.result;
    final generation = ++_generation;
    state = const AccountDeletionState(
      phase: AccountDeletionPhase.requestingRecentAuth,
    );
    try {
      final result = await _repository.request(
        accountId: accountId,
        expectedAuthEpoch: expectedAuthEpoch,
      );
      if (!_current(generation)) return null;
      final guard = await _repository.recoverLocalCleanup();
      if (!_current(generation)) return null;
      state = AccountDeletionState(
        phase: AccountDeletionPhase.pending,
        result: result,
        guard: guard,
      );
      return result;
    } on AuthFailure catch (error) {
      if (!_current(generation)) return null;
      if (error.isCancellation) {
        state = const AccountDeletionState.idle();
      } else {
        state = AccountDeletionState(
          phase: AccountDeletionPhase.failed,
          errorCode: error.safeCode,
          errorMessage: error.isNetwork
              ? 'Recent sign in could not reach the identity provider.'
              : 'Recent sign in could not be completed.',
        );
      }
      return null;
    } on AccountDeletionIdentityMismatch {
      if (_current(generation)) {
        state = const AccountDeletionState(
          phase: AccountDeletionPhase.failed,
          errorCode: 'ACCOUNT_DELETION_IDENTITY_MISMATCH',
          errorMessage:
              'That sign-in belongs to a different Pakperk account. No '
              'account was deleted.',
        );
      }
      return null;
    } on ApiException catch (error) {
      if (!_current(generation)) return null;
      if (error.code == 'ACCOUNT_DELETION_LOCAL_GUARD_FAILED') {
        final guard = await _repository.recoverLocalCleanup();
        if (!_current(generation)) return null;
        state = AccountDeletionState(
          phase: AccountDeletionPhase.pending,
          guard: guard,
          errorCode: error.code,
          errorMessage: error.message,
        );
      } else {
        state = AccountDeletionState(
          phase: AccountDeletionPhase.failed,
          errorCode: error.code,
          errorMessage: error.message,
        );
      }
      return null;
    } on Object {
      if (_current(generation)) {
        state = const AccountDeletionState(
          phase: AccountDeletionPhase.failed,
          errorCode: 'ACCOUNT_DELETION_FAILED',
          errorMessage:
              'Pakperk could not start the deletion request. If a request '
              'crossed the network boundary, this device will show deletion '
              'pending and remove local credentials instead of offering a '
              'retry.',
        );
      }
      return null;
    }
  }

  Future<bool> recoverAtStartup() async {
    final generation = ++_generation;
    try {
      final guard = await _repository.recoverLocalCleanup();
      if (!_current(generation) || guard == null) return false;
      state = AccountDeletionState(
        phase: AccountDeletionPhase.pending,
        guard: guard,
      );
      return true;
    } on Object {
      if (_current(generation)) {
        state = const AccountDeletionState(
          phase: AccountDeletionPhase.pending,
          errorCode: 'ACCOUNT_DELETION_LOCAL_CLEANUP_FAILED',
          errorMessage:
              'Account deletion is pending. This device will retry private '
              'data cleanup on the next start.',
        );
      }
      return true;
    }
  }

  Future<void> handleServerDeletionPending({
    required String? accountId,
    required String? requestId,
  }) async {
    final generation = ++_generation;
    try {
      final guard = await _repository.handleServerDeletionPending(
        accountId: accountId,
        requestId: requestId,
      );
      if (_current(generation)) {
        state = AccountDeletionState(
          phase: AccountDeletionPhase.pending,
          guard: guard,
        );
      }
    } on Object {
      if (_current(generation)) {
        state = const AccountDeletionState(
          phase: AccountDeletionPhase.pending,
          errorCode: 'ACCOUNT_DELETION_LOCAL_CLEANUP_FAILED',
          errorMessage:
              'Account deletion is pending. Local private data cleanup will '
              'be retried when Pakperk starts again.',
        );
      }
    }
  }

  Future<bool> continueAsGuest() async {
    if (!state.localCleanupComplete) return false;
    await _repository.dismissCompletedGuard();
    if (mounted) state = const AccountDeletionState.idle();
    return true;
  }

  bool _current(int generation) => mounted && generation == _generation;
}
