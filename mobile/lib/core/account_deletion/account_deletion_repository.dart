import '../api/api_exception.dart';
import '../auth/auth_models.dart';
import '../auth/auth_repository.dart';
import '../telemetry/telemetry.dart';
import 'account_deletion_api.dart';
import 'account_deletion_guard_store.dart';
import 'account_deletion_models.dart';

typedef AccountDeletionLocalFinalizer =
    Future<bool> Function(String? accountId);

final class AccountDeletionIdentityMismatch implements Exception {
  const AccountDeletionIdentityMismatch();

  @override
  String toString() => 'AccountDeletionIdentityMismatch(<redacted>)';
}

/// Coordinates recent authentication, same-account verification, server
/// acceptance, durable local guarding, and fail-closed cleanup.
final class AccountDeletionRepository {
  const AccountDeletionRepository({
    required AuthRepository auth,
    required AccountDeletionRemoteDataSource remote,
    required AccountDeletionGuardStore guardStore,
    required AccountDeletionLocalFinalizer finalizeLocalDeletion,
    required TelemetrySink telemetry,
    DateTime Function()? clock,
  }) : _auth = auth,
       _remote = remote,
       _guardStore = guardStore,
       _finalizeLocalDeletion = finalizeLocalDeletion,
       _telemetry = telemetry,
       _clock = clock ?? _utcNow;

  final AuthRepository _auth;
  final AccountDeletionRemoteDataSource _remote;
  final AccountDeletionGuardStore _guardStore;
  final AccountDeletionLocalFinalizer _finalizeLocalDeletion;
  final TelemetrySink _telemetry;
  final DateTime Function() _clock;

  Future<AccountDeletionRequestResult> request({
    required String? accountId,
    required int expectedAuthEpoch,
  }) async {
    if ((accountId != null && !isAccountDeletionUuid(accountId)) ||
        expectedAuthEpoch < 0) {
      throw ArgumentError('Invalid account deletion scope.');
    }
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.accountDeletionRequested);

    // Bind the session that initiated deletion using a normal credential first.
    // This covers process death before the app persisted its internal account
    // UUID, including accounts that were suspended before the next launch.
    // The API returns only its opaque internal ID; client JWT claims are never
    // parsed or trusted for this comparison.
    _requireCurrentEpoch(expectedAuthEpoch);
    final normalIdentity = await _remote.verifyCurrentSession(
      expectedAuthEpoch: expectedAuthEpoch,
    );
    _requireCurrentEpoch(expectedAuthEpoch);
    if (accountId != null && normalIdentity.accountId != accountId) {
      throw const AccountDeletionIdentityMismatch();
    }
    if (_alreadyDeleting(normalIdentity.status)) {
      return _acceptAlreadyPending(normalIdentity.accountId);
    }

    emitTelemetry(_telemetry, PakPerkTelemetryEvent.authStarted, {
      'purpose': 'account_deletion',
    });
    late final RecentAuthCredential recent;
    try {
      recent = await _auth.reauthenticateForAccountDeletion(
        expectedAuthEpoch: expectedAuthEpoch,
      );
    } on AuthFailure catch (error) {
      if (error.isCancellation) {
        emitTelemetry(_telemetry, PakPerkTelemetryEvent.authCancelled, {
          'purpose': 'account_deletion',
        });
      }
      rethrow;
    }
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.authCompleted, {
      'purpose': 'account_deletion',
    });
    if (recent.sessionEpoch != expectedAuthEpoch) {
      throw const AccountDeletionIdentityMismatch();
    }
    _requireCurrentEpoch(expectedAuthEpoch);
    final recentIdentity = await _remote.verifyRecentSession(
      recentBearer: recent.bearer,
      expectedAuthEpoch: expectedAuthEpoch,
    );
    _requireCurrentEpoch(expectedAuthEpoch);
    if (recentIdentity.accountId != normalIdentity.accountId) {
      throw const AccountDeletionIdentityMismatch();
    }
    if (_alreadyDeleting(recentIdentity.status)) {
      return _acceptAlreadyPending(normalIdentity.accountId);
    }

    // Close the server-accept/process-death window before dispatch. Once this
    // marker is durable, every ambiguous outcome is deletion-pending and
    // startup will clear credentials and all account-owned rows.
    final inFlight = AccountDeletionGuardRecord(
      acceptance: LocalAccountDeletionAcceptance.inFlight,
      accountId: normalIdentity.accountId,
      acceptedAt: _clock().toUtc(),
      localCleanupComplete: false,
    );
    try {
      await _guardStore.write(inFlight);
    } on Object {
      throw const ApiException(
        code: 'ACCOUNT_DELETION_LOCAL_GUARD_FAILED',
        message:
            'Pakperk could not prepare safe local cleanup. The deletion '
            'request was not sent.',
        retryable: true,
      );
    }
    try {
      _requireCurrentEpoch(expectedAuthEpoch);
    } on AuthFailure {
      await _guardStore.clearInFlight();
      rethrow;
    }

    try {
      final operation = await _remote.deleteCurrentAccount(
        recentBearer: recent.bearer,
        expectedAuthEpoch: expectedAuthEpoch,
      );
      final record = AccountDeletionGuardRecord(
        acceptance: LocalAccountDeletionAcceptance.accepted,
        accountId: normalIdentity.accountId,
        operationId: operation.operationId,
        serverState: operation.state,
        acceptedAt: _clock().toUtc(),
        localCleanupComplete: false,
      );
      await _updateThenFinalize(record, fallback: inFlight);
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.accountDeletionAccepted, {
        'server_state': operation.state.wireValue,
      });
      return AccountDeletionRequestResult.accepted(operation);
    } on ApiException catch (error) {
      if (error.statusCode == 503 &&
          error.code == 'ACCOUNT_DELETION_UNAVAILABLE') {
        final record = AccountDeletionGuardRecord(
          acceptance: LocalAccountDeletionAcceptance.serviceUnavailable,
          accountId: normalIdentity.accountId,
          requestId: error.requestId,
          acceptedAt: inFlight.acceptedAt,
          localCleanupComplete: false,
        );
        await _updateThenFinalize(record, fallback: inFlight);
        emitTelemetry(
          _telemetry,
          PakPerkTelemetryEvent.accountDeletionUnavailable,
          {'retryable': true},
        );
        return AccountDeletionRequestResult.serviceUnavailable(
          requestId: error.requestId,
        );
      }
      if (_provablyNotAccepted(error)) {
        await _guardStore.clearInFlight();
        rethrow;
      }
      await _finalizeRecord(inFlight);
      emitTelemetry(
        _telemetry,
        PakPerkTelemetryEvent.accountDeletionUnavailable,
        {'retryable': true},
      );
      return const AccountDeletionRequestResult.ambiguous();
    } on AuthFailure {
      // A session switch after dispatch is ambiguous: the request may already
      // have crossed the transport boundary, so the preflight guard wins.
      await _finalizeRecord(inFlight);
      return const AccountDeletionRequestResult.ambiguous();
    } on Object {
      await _finalizeRecord(inFlight);
      return const AccountDeletionRequestResult.ambiguous();
    }
  }

  /// Replays only local cleanup. It never retries the server DELETE and never
  /// needs credentials. The deletion worker/operator owns server-side retry.
  Future<AccountDeletionGuardRecord?> recoverLocalCleanup() async {
    final record = await _guardStore.read();
    if (record == null) return null;
    if (record.localCleanupComplete) return record;
    await _finalizeRecord(record);
    return await _guardStore.read();
  }

  Future<AccountDeletionGuardRecord?> handleServerDeletionPending({
    required String? accountId,
    required String? requestId,
  }) async {
    final record = AccountDeletionGuardRecord(
      acceptance: LocalAccountDeletionAcceptance.serviceUnavailable,
      accountId: accountId,
      requestId: requestId,
      acceptedAt: _clock().toUtc(),
      localCleanupComplete: false,
    );
    await _persistThenFinalize(record);
    return _guardStore.read();
  }

  Future<void> dismissCompletedGuard() async {
    await _guardStore.clearAfterCompletedCleanup();
  }

  Future<AccountDeletionRequestResult> _acceptAlreadyPending(
    String? verifiedAccountId,
  ) async {
    await handleServerDeletionPending(
      accountId: verifiedAccountId,
      requestId: null,
    );
    emitTelemetry(
      _telemetry,
      PakPerkTelemetryEvent.accountDeletionUnavailable,
      {'retryable': true},
    );
    return const AccountDeletionRequestResult.serviceUnavailable();
  }

  Future<void> _persistThenFinalize(AccountDeletionGuardRecord record) async {
    Object? guardFailure;
    try {
      await _guardStore.write(record);
    } on Object catch (error) {
      guardFailure = error;
    }
    await _finalizeRecord(record);
    if (guardFailure != null) {
      throw const ApiException(
        code: 'ACCOUNT_DELETION_LOCAL_GUARD_FAILED',
        message:
            'Deletion was requested, but this device could not save its '
            'cleanup marker. Keep the app open and contact support.',
        retryable: false,
      );
    }
  }

  Future<void> _updateThenFinalize(
    AccountDeletionGuardRecord record, {
    required AccountDeletionGuardRecord fallback,
  }) async {
    Object? updateFailure;
    try {
      await _guardStore.write(record);
    } on Object catch (error) {
      updateFailure = error;
    }
    await _finalizeRecord(updateFailure == null ? record : fallback);
    if (updateFailure != null) {
      throw const ApiException(
        code: 'ACCOUNT_DELETION_LOCAL_GUARD_FAILED',
        message:
            'Deletion was requested and local cleanup began. Pakperk will '
            'retry cleanup from its durable preflight marker.',
        retryable: false,
      );
    }
  }

  Future<void> _finalizeRecord(AccountDeletionGuardRecord record) async {
    final completed = await _finalizeLocalDeletion(record.accountId);
    if (!completed) {
      emitTelemetry(
        _telemetry,
        PakPerkTelemetryEvent.accountDeletionLocalCleanupFailed,
        {'failure_code': 'local_cleanup'},
      );
      return;
    }
    await _guardStore.write(record.cleanupCompleted());
  }

  void _requireCurrentEpoch(int expectedAuthEpoch) {
    if (!_auth.isCurrentEpoch(expectedAuthEpoch)) {
      throw AuthFailure(
        AuthFailureKind.superseded,
        AuthFailureCode.operationSuperseded,
        sessionEpoch: expectedAuthEpoch,
      );
    }
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

bool _provablyNotAccepted(ApiException error) {
  if (error.isOffline || error.requestId == null) return false;
  return switch ((error.statusCode, error.code, error.retryable)) {
    (400, 'INVALID_REQUEST', false) ||
    (401, 'UNAUTHENTICATED', false) ||
    (401, 'TOKEN_EXPIRED', false) ||
    (401, 'REAUTHENTICATION_REQUIRED', false) ||
    (404, 'FEATURE_DISABLED', false) ||
    (404, 'ROUTE_NOT_FOUND', false) ||
    (405, 'METHOD_NOT_ALLOWED', false) ||
    (413, 'REQUEST_BODY_TOO_LARGE', false) => true,
    (429, 'RATE_LIMITED', true) ||
    (503, 'AUTHENTICATION_UNAVAILABLE', true) => error.retryAfter != null,
    _ => false,
  };
}

bool _alreadyDeleting(AccountDeletionVerificationStatus status) =>
    status == AccountDeletionVerificationStatus.deletionPending ||
    status == AccountDeletionVerificationStatus.deleted;
