import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_models.dart';
import 'auth_repository.dart';

/// Deletes only account-owned local rows. Implementations must preserve the
/// public paper/feed cache so signing out never destroys guest reading data.
typedef AccountOwnedDataClearer = Future<void> Function(String? accountId);

final class AuthSessionController extends StateNotifier<AuthSessionState>
    implements AuthTokenSource {
  AuthSessionController({
    required AuthRepository repository,
    required AccountOwnedDataClearer clearAccountOwnedData,
  }) : _repository = repository,
       _clearAccountOwnedData = clearAccountOwnedData,
       super(AuthSessionState.checking(epoch: repository.epoch));

  final AuthRepository _repository;
  final AccountOwnedDataClearer _clearAccountOwnedData;
  _AccountCleanupFlight? _accountCleanupFlight;
  bool _disposed = false;

  /// Local-only startup check. This method never contacts the identity
  /// provider and is safe to use inside the first-frame startup budget.
  Future<AuthStoredSessionStatus> inspectStoredSession() async {
    final operationEpoch = _repository.epoch;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.checking(epoch: operationEpoch),
    );
    try {
      final inspection = await _repository.inspectStoredSession();
      if (!_isCurrent(operationEpoch)) {
        return AuthStoredSessionStatus.guest;
      }
      state = switch (inspection.status) {
        AuthStoredSessionStatus.guest => AuthSessionState.guest(
          epoch: operationEpoch,
        ),
        AuthStoredSessionStatus.refreshRequired =>
          AuthSessionState.refreshRequired(
            epoch: operationEpoch,
            accountId: inspection.accountId,
          ),
      };
      return inspection.status;
    } on AuthFailure catch (failure) {
      await _applyFailure(failure, operationEpoch);
      return AuthStoredSessionStatus.guest;
    }
  }

  /// Restores a durable session and refreshes it after the app is usable.
  Future<bool> restoreSession() async {
    final status = await inspectStoredSession();
    if (status == AuthStoredSessionStatus.guest) return false;
    final operationEpoch = _repository.epoch;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.refreshing(
        epoch: operationEpoch,
        accountId: _repository.accountId,
      ),
    );
    try {
      final token = await _repository.accessTokenForRequest();
      if (!_isCurrent(operationEpoch) || token == null) return false;
      state = AuthSessionState.authenticated(
        epoch: operationEpoch,
        accountId: _repository.accountId,
      );
      return true;
    } on AuthFailure catch (failure) {
      await _applyFailure(failure, operationEpoch);
      return false;
    }
  }

  /// Returns false for a user-cancelled browser flow without surfacing an
  /// error. All other failures are represented only by a safe failure code.
  Future<bool> signIn() async {
    // A new interactive identity must never inherit another account's local
    // library, drafts, or outbox. A null ID deliberately asks the application
    // clearer to remove all account-owned rows left by an unbound session.
    final previousEpoch = _repository.epoch;
    final previousAccountId = _repository.accountId ?? state.accountId;
    _setIfCurrent(
      previousEpoch,
      AuthSessionState.authenticating(epoch: previousEpoch),
    );
    try {
      await _clearAccountOwnedData(previousAccountId);
    } on Object {
      if (_isCurrent(previousEpoch)) {
        state = AuthSessionState.unavailable(
          epoch: previousEpoch,
          accountId: previousAccountId,
          failure: AuthFailure(
            AuthFailureKind.accountDataCleanup,
            AuthFailureCode.accountDataCleanup,
            sessionEpoch: previousEpoch,
          ),
        );
      }
      return false;
    }
    if (!_isCurrent(previousEpoch)) return false;

    final operation = _repository.signIn();
    final operationEpoch = _repository.epoch;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.authenticating(epoch: operationEpoch),
    );
    try {
      final session = await operation;
      if (!_isCurrent(session.epoch)) return false;
      state = AuthSessionState.authenticated(
        epoch: session.epoch,
        accountId: session.accountId,
      );
      return true;
    } on AuthFailure catch (failure) {
      if (failure.isCancellation && _isCurrent(operationEpoch)) {
        state = AuthSessionState.guest(epoch: operationEpoch);
      } else {
        await _applyFailure(failure, operationEpoch);
      }
      return false;
    }
  }

  Future<void> bindAccountId(String accountId) async {
    final operationEpoch = _repository.epoch;
    final previousAccountId = _repository.accountId ?? state.accountId;
    try {
      if (previousAccountId != null && previousAccountId != accountId) {
        try {
          await _clearAccountOwnedData(previousAccountId);
        } on Object {
          throw AuthFailure(
            AuthFailureKind.accountDataCleanup,
            AuthFailureCode.accountDataCleanup,
            sessionEpoch: operationEpoch,
          );
        }
        if (!_isCurrent(operationEpoch)) {
          throw AuthFailure(
            AuthFailureKind.superseded,
            AuthFailureCode.operationSuperseded,
            sessionEpoch: operationEpoch,
          );
        }
      }
      await _repository.bindAccountId(accountId);
      if (_isCurrent(operationEpoch)) {
        state = AuthSessionState.authenticated(
          epoch: operationEpoch,
          accountId: accountId,
        );
      }
    } on AuthFailure catch (failure) {
      await _applyFailure(failure, operationEpoch);
      rethrow;
    }
  }

  Future<void> signOut() async {
    final previousAccountId = _repository.accountId ?? state.accountId;
    final repositorySignOut = _repository.signOut();
    final signOutEpoch = _repository.epoch;
    _setIfCurrent(
      signOutEpoch,
      AuthSessionState.signingOut(
        epoch: signOutEpoch,
        accountId: previousAccountId,
      ),
    );

    // Start account-data deletion immediately; provider logout may require a
    // slow or cancelled system-browser round trip.
    Future<void>? accountDataClear;
    AuthFailure? failure;
    try {
      accountDataClear = _clearAccountOwnedData(previousAccountId);
    } on Object {
      failure = AuthFailure(
        AuthFailureKind.accountDataCleanup,
        AuthFailureCode.accountDataCleanup,
        sessionEpoch: signOutEpoch,
      );
    }
    try {
      await repositorySignOut;
    } on AuthFailure catch (error) {
      failure ??= error;
    }
    try {
      await accountDataClear;
    } on Object {
      failure ??= AuthFailure(
        AuthFailureKind.accountDataCleanup,
        AuthFailureCode.accountDataCleanup,
        sessionEpoch: signOutEpoch,
      );
    }
    if (_isCurrent(signOutEpoch)) {
      state = AuthSessionState.guest(epoch: signOutEpoch, failure: failure);
    }
  }

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    final operationEpoch = expectedAuthEpoch ?? _repository.epoch;
    try {
      final token = await _repository.accessTokenForRequest(
        expectedAuthEpoch: operationEpoch,
      );
      if (!_isCurrent(operationEpoch)) return null;
      if (token != null) {
        state = AuthSessionState.authenticated(
          epoch: operationEpoch,
          accountId: _repository.accountId,
        );
      }
      return token;
    } on AuthFailure catch (failure) {
      await _applyFailure(failure, operationEpoch);
      rethrow;
    }
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    final operationEpoch = expectedAuthEpoch ?? _repository.epoch;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.refreshing(
        epoch: operationEpoch,
        accountId: _repository.accountId,
      ),
    );
    try {
      final token = await _repository.refreshAfterUnauthorized(
        rejectedAccessToken: rejectedAccessToken,
        expectedAuthEpoch: operationEpoch,
      );
      if (!_isCurrent(operationEpoch)) return null;
      state = token == null
          ? AuthSessionState.guest(epoch: operationEpoch)
          : AuthSessionState.authenticated(
              epoch: operationEpoch,
              accountId: _repository.accountId,
            );
      return token;
    } on AuthFailure catch (failure) {
      await _applyFailure(failure, operationEpoch);
      rethrow;
    }
  }

  Future<void> _applyFailure(AuthFailure failure, int operationEpoch) async {
    if (_disposed || failure.isSuperseded) return;
    final failureEpoch = failure.sessionEpoch ?? operationEpoch;
    if (_repository.epoch != failureEpoch) return;
    if (failure.isInvalidGrant) {
      final accountId = state.accountId;
      var reportedFailure = failure;
      try {
        await _clearInvalidSessionData(failureEpoch, accountId);
      } on Object {
        reportedFailure = AuthFailure(
          AuthFailureKind.accountDataCleanup,
          AuthFailureCode.accountDataCleanup,
          sessionEpoch: failureEpoch,
        );
      }
      if (_isCurrent(failureEpoch)) {
        state = AuthSessionState.guest(
          epoch: failureEpoch,
          failure: reportedFailure,
        );
      }
      return;
    }
    if (failure.isNetwork && _repository.hasStoredSessionInMemory) {
      state = AuthSessionState.offlineAuthUnknown(
        epoch: failureEpoch,
        accountId: _repository.accountId,
        failure: failure,
      );
      return;
    }
    if (failure.isCancellation) {
      state = AuthSessionState.guest(epoch: failureEpoch);
      return;
    }
    state = AuthSessionState.unavailable(
      epoch: failureEpoch,
      accountId: _repository.accountId,
      failure: failure,
    );
  }

  Future<void> _clearInvalidSessionData(int epoch, String? accountId) {
    final active = _accountCleanupFlight;
    if (active != null && active.epoch == epoch) return active.future;

    late final Future<void> operation;
    operation = Future<void>.sync(() => _clearAccountOwnedData(accountId))
        .whenComplete(() {
          if (identical(_accountCleanupFlight?.future, operation)) {
            _accountCleanupFlight = null;
          }
        });
    _accountCleanupFlight = _AccountCleanupFlight(epoch, operation);
    return operation;
  }

  bool _isCurrent(int epoch) => !_disposed && _repository.epoch == epoch;

  void _setIfCurrent(int epoch, AuthSessionState value) {
    if (_isCurrent(epoch)) state = value;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final class _AccountCleanupFlight {
  const _AccountCleanupFlight(this.epoch, this.future);

  final int epoch;
  final Future<void> future;
}
