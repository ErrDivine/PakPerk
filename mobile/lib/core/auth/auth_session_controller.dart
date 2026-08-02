import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_models.dart';
import 'auth_repository.dart';
import '../telemetry/telemetry.dart';

/// Deletes only account-owned local rows. Implementations must preserve the
/// public paper/feed cache so signing out never destroys guest reading data.
typedef AccountOwnedDataClearer =
    Future<void> Function(String? accountId, int invalidatedThroughEpoch);

final class AuthSessionController extends StateNotifier<AuthSessionState>
    implements AuthTokenSource {
  AuthSessionController({
    required AuthRepository repository,
    required AccountOwnedDataClearer clearAccountOwnedData,
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _repository = repository,
       _clearAccountOwnedData = clearAccountOwnedData,
       _telemetry = telemetry,
       super(AuthSessionState.checking(epoch: repository.epoch));

  final AuthRepository _repository;
  final AccountOwnedDataClearer _clearAccountOwnedData;
  final TelemetrySink _telemetry;
  _AccountCleanupFlight? _accountCleanupFlight;
  int _identityBindingGeneration = 0;
  int? _activeIdentityBindingGeneration;
  String? _activePreservedIdentityAccountId;
  Future<void> _identityBindingTail = Future<void>.value();
  bool _accountDeletionReserved = false;
  bool _disposed = false;

  /// Local-only startup check. This method never contacts the identity
  /// provider and is safe to use inside the first-frame startup budget.
  Future<AuthStoredSessionStatus> inspectStoredSession() async {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending) {
      return AuthStoredSessionStatus.guest;
    }
    if (_activeIdentityBindingGeneration != null) {
      return AuthStoredSessionStatus.guest;
    }
    final operationEpoch = _repository.epoch;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.checking(epoch: operationEpoch),
    );
    try {
      final inspection = await _repository.inspectStoredSession();
      if (!_isCurrent(operationEpoch) ||
          _activeIdentityBindingGeneration != null) {
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
      if (_activeIdentityBindingGeneration != null && !failure.isInvalidGrant) {
        return AuthStoredSessionStatus.guest;
      }
      await _applyFailure(failure, operationEpoch);
      return AuthStoredSessionStatus.guest;
    }
  }

  /// Restores a durable session and refreshes it after the app is usable.
  Future<bool> restoreSession() async {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending) {
      return false;
    }
    if (_activeIdentityBindingGeneration != null) return false;
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
      if (!_isCurrent(operationEpoch) ||
          _activeIdentityBindingGeneration != null ||
          token == null) {
        return false;
      }
      state = AuthSessionState.authenticated(
        epoch: operationEpoch,
        accountId: _repository.accountId,
      );
      return true;
    } on AuthFailure catch (failure) {
      if (_activeIdentityBindingGeneration != null && !failure.isInvalidGrant) {
        return false;
      }
      await _applyFailure(failure, operationEpoch);
      return false;
    }
  }

  /// Returns false for a user-cancelled browser flow without surfacing an
  /// error. All other failures are represented only by a safe failure code.
  Future<bool> signIn() async {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending) {
      return false;
    }
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.authStarted, {
      'purpose': 'session',
    });
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
      await _clearAccountOwnedData(previousAccountId, previousEpoch);
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
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.authCompleted, {
        'purpose': 'session',
      });
      return true;
    } on AuthFailure catch (failure) {
      if (_activeIdentityBindingGeneration != null && !failure.isInvalidGrant) {
        return false;
      }
      if (failure.isCancellation && _isCurrent(operationEpoch)) {
        state = AuthSessionState.guest(epoch: operationEpoch);
        emitTelemetry(_telemetry, PakPerkTelemetryEvent.authCancelled, {
          'purpose': 'session',
        });
      } else {
        await _applyFailure(failure, operationEpoch);
      }
      return false;
    }
  }

  Future<void> bindAccountId(String accountId) {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending) {
      return Future<void>.error(
        AuthFailure(
          AuthFailureKind.superseded,
          AuthFailureCode.operationSuperseded,
          sessionEpoch: _repository.epoch,
        ),
      );
    }
    final operationEpoch = _repository.epoch;
    final preservesExistingIdentity =
        _activeIdentityBindingGeneration == null &&
        _repository.accountId == accountId &&
        state.accountId == accountId;
    final bindingGeneration = ++_identityBindingGeneration;
    _activeIdentityBindingGeneration = bindingGeneration;
    _activePreservedIdentityAccountId = preservesExistingIdentity
        ? accountId
        : null;
    _setIfCurrent(
      operationEpoch,
      AuthSessionState.refreshing(
        epoch: operationEpoch,
        accountId: preservesExistingIdentity ? accountId : null,
      ),
    );
    final previous = _identityBindingTail;
    final operation = _runIdentityBinding(
      previous: previous,
      accountId: accountId,
      operationEpoch: operationEpoch,
      bindingGeneration: bindingGeneration,
    );
    _identityBindingTail = _ignoreBindingFailure(operation);
    return operation;
  }

  Future<void> _runIdentityBinding({
    required Future<void> previous,
    required String accountId,
    required int operationEpoch,
    required int bindingGeneration,
  }) async {
    await previous;
    try {
      if (!_isCurrentBinding(operationEpoch, bindingGeneration)) {
        throw AuthFailure(
          AuthFailureKind.superseded,
          AuthFailureCode.operationSuperseded,
          sessionEpoch: operationEpoch,
        );
      }
      final previousAccountId = _repository.accountId;
      final changesIdentity =
          previousAccountId != null && previousAccountId != accountId;
      if (changesIdentity) {
        try {
          await _clearAccountOwnedData(previousAccountId, operationEpoch);
        } on Object {
          throw AuthFailure(
            AuthFailureKind.accountDataCleanup,
            AuthFailureCode.accountDataCleanup,
            sessionEpoch: operationEpoch,
          );
        }
        if (!_isCurrentBinding(operationEpoch, bindingGeneration)) {
          throw AuthFailure(
            AuthFailureKind.superseded,
            AuthFailureCode.operationSuperseded,
            sessionEpoch: operationEpoch,
          );
        }
      }
      await _repository.bindAccountId(accountId);
      if (!_isCurrentBinding(operationEpoch, bindingGeneration)) {
        throw AuthFailure(
          AuthFailureKind.superseded,
          AuthFailureCode.operationSuperseded,
          sessionEpoch: operationEpoch,
        );
      }
      state = AuthSessionState.authenticated(
        epoch: operationEpoch,
        accountId: accountId,
      );
    } on AuthFailure catch (failure) {
      if (_isCurrentBinding(operationEpoch, bindingGeneration)) {
        await _applyFailure(failure, operationEpoch);
      }
      rethrow;
    } finally {
      if (_activeIdentityBindingGeneration == bindingGeneration) {
        _activeIdentityBindingGeneration = null;
        _activePreservedIdentityAccountId = null;
      }
    }
  }

  Future<void> _ignoreBindingFailure(Future<void> operation) async {
    try {
      await operation;
    } on Object {
      // The individual caller still observes the failure. This settled tail
      // only ensures the newest queued binding can run afterward.
    }
  }

  bool _isCurrentBinding(int epoch, int generation) =>
      _isCurrent(epoch) && _activeIdentityBindingGeneration == generation;

  Future<void> signOut() async {
    if (_accountDeletionReserved) return;
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
      accountDataClear = _clearAccountOwnedData(
        previousAccountId,
        signOutEpoch,
      );
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

  /// Enters a fail-closed deletion-pending session and removes all local
  /// account material. Unlike sign-out this never opens a provider logout
  /// browser: server-side deletion owns revocation and identity erasure.
  ///
  /// Returns true only when both secure credential invalidation and local
  /// account-data cleanup completed. Callers retain their independent durable
  /// guard until this succeeds, so process death cannot restore the session.
  Future<bool> enterAccountDeletionPending({String? accountId}) async {
    _accountDeletionReserved = true;
    final previousAccountId =
        accountId ?? _repository.accountId ?? state.accountId;
    final repositoryInvalidation = _repository.invalidateForAccountDeletion();
    final deletionEpoch = _repository.epoch;
    if (_isRepositoryEpochCurrent(deletionEpoch)) {
      state = AuthSessionState.deletionPending(epoch: deletionEpoch);
    }

    Future<void>? accountDataClear;
    AuthFailure? failure;
    try {
      accountDataClear = _clearAccountOwnedData(
        previousAccountId,
        deletionEpoch,
      );
    } on Object {
      failure = AuthFailure(
        AuthFailureKind.accountDeletionCleanup,
        AuthFailureCode.accountDeletionCleanup,
        sessionEpoch: deletionEpoch,
      );
    }
    try {
      await repositoryInvalidation;
    } on AuthFailure {
      failure ??= AuthFailure(
        AuthFailureKind.accountDeletionCleanup,
        AuthFailureCode.accountDeletionCleanup,
        sessionEpoch: deletionEpoch,
      );
    }
    try {
      await accountDataClear;
    } on Object {
      failure ??= AuthFailure(
        AuthFailureKind.accountDeletionCleanup,
        AuthFailureCode.accountDeletionCleanup,
        sessionEpoch: deletionEpoch,
      );
    }
    if (_isRepositoryEpochCurrent(deletionEpoch)) {
      state = AuthSessionState.deletionPending(
        epoch: deletionEpoch,
        failure: failure,
      );
    }
    return failure == null;
  }

  /// Changes only the post-cleanup presentation state. The caller must verify
  /// and clear the independent deletion guard before invoking this method.
  void continueAsGuestAfterDeletion() {
    if (state.phase != AuthSessionPhase.deletionPending) return;
    final currentEpoch = _repository.epoch;
    _accountDeletionReserved = false;
    _setIfCurrent(currentEpoch, AuthSessionState.guest(epoch: currentEpoch));
  }

  /// Reasserts the deletion gate after a cold start whose durable guard says
  /// local cleanup already completed. This does not repeat cleanup or inspect
  /// credentials; only an explicit guard dismissal may transition to guest.
  void holdAccountDeletionPending() {
    final currentEpoch = _repository.epoch;
    _accountDeletionReserved = true;
    if (_isRepositoryEpochCurrent(currentEpoch)) {
      state = AuthSessionState.deletionPending(epoch: currentEpoch);
    }
  }

  /// Atomically claims an exact account session for terminal deletion work.
  /// Once reserved, token access and identity replacement fail closed until
  /// the durable deletion guard is explicitly dismissed.
  bool reserveAccountDeletion({
    required int expectedAuthEpoch,
    required String? expectedAccountId,
  }) {
    if (_disposed ||
        _accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending ||
        !_repository.isCurrentEpoch(expectedAuthEpoch) ||
        state.epoch != expectedAuthEpoch ||
        state.accountId != expectedAccountId) {
      return false;
    }
    if (_activeIdentityBindingGeneration != null) {
      // A profile refresh can redundantly persist the already-bound account.
      // An exact deletion response for that identity must win and cancel the
      // write, while cross-account and unbound bindings remain unprovable and
      // are rejected even when nullable presentation IDs happen to match.
      if (expectedAccountId == null ||
          _activePreservedIdentityAccountId != expectedAccountId) {
        return false;
      }
      _activeIdentityBindingGeneration = null;
      _activePreservedIdentityAccountId = null;
    }
    _accountDeletionReserved = true;
    state = AuthSessionState.deletionPending(epoch: expectedAuthEpoch);
    return true;
  }

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) =>
      !_disposed &&
      !_accountDeletionReserved &&
      state.phase != AuthSessionPhase.deletionPending &&
      _activeIdentityBindingGeneration == null &&
      _repository.isCurrentEpoch(expectedAuthEpoch);

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending ||
        _activeIdentityBindingGeneration != null) {
      return null;
    }
    final operationEpoch = expectedAuthEpoch ?? _repository.epoch;
    try {
      final token = await _repository.accessTokenForRequest(
        expectedAuthEpoch: operationEpoch,
      );
      if (!_isCurrent(operationEpoch) ||
          _activeIdentityBindingGeneration != null) {
        return null;
      }
      if (token != null) {
        state = AuthSessionState.authenticated(
          epoch: operationEpoch,
          accountId: _repository.accountId,
        );
      }
      return token;
    } on AuthFailure catch (failure) {
      if (_activeIdentityBindingGeneration != null && !failure.isInvalidGrant) {
        return null;
      }
      await _applyFailure(failure, operationEpoch);
      rethrow;
    }
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    if (_accountDeletionReserved ||
        state.phase == AuthSessionPhase.deletionPending ||
        _activeIdentityBindingGeneration != null) {
      return null;
    }
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
      if (!_isCurrent(operationEpoch) ||
          _activeIdentityBindingGeneration != null) {
        return null;
      }
      state = token == null
          ? AuthSessionState.guest(epoch: operationEpoch)
          : AuthSessionState.authenticated(
              epoch: operationEpoch,
              accountId: _repository.accountId,
            );
      return token;
    } on AuthFailure catch (failure) {
      if (_activeIdentityBindingGeneration != null && !failure.isInvalidGrant) {
        return null;
      }
      await _applyFailure(failure, operationEpoch);
      rethrow;
    }
  }

  Future<void> _applyFailure(AuthFailure failure, int operationEpoch) async {
    if (_disposed || _accountDeletionReserved || failure.isSuperseded) return;
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
    operation =
        Future<void>.sync(
          () => _clearAccountOwnedData(accountId, epoch),
        ).whenComplete(() {
          if (identical(_accountCleanupFlight?.future, operation)) {
            _accountCleanupFlight = null;
          }
        });
    _accountCleanupFlight = _AccountCleanupFlight(epoch, operation);
    return operation;
  }

  bool _isRepositoryEpochCurrent(int epoch) =>
      !_disposed && _repository.epoch == epoch;

  bool _isCurrent(int epoch) =>
      !_accountDeletionReserved && _isRepositoryEpochCurrent(epoch);

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
