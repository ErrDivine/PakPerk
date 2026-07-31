enum AuthFailureKind {
  cancelled,
  invalidGrant,
  network,
  provider,
  invalidResponse,
  secureStorage,
  accountDataCleanup,
  superseded,
}

enum AuthFailureCode {
  oidcCancelled('oidc_cancelled'),
  oidcInvalidGrant('oidc_invalid_grant'),
  oidcNetwork('oidc_network'),
  oidcProvider('oidc_provider'),
  oidcInvalidResponse('oidc_invalid_response'),
  oidcUnexpected('oidc_unexpected'),
  authSessionMissing('auth_session_missing'),
  accountIdInvalid('account_id_invalid'),
  secureStorageRead('secure_storage_read'),
  secureStorageWrite('secure_storage_write'),
  secureStorageClear('secure_storage_clear'),
  accountDataCleanup('account_data_cleanup'),
  operationSuperseded('auth_operation_superseded');

  const AuthFailureCode(this.value);

  final String value;
}

/// A deliberately sanitized auth failure suitable for state and diagnostics.
///
/// Raw provider errors can contain tokens or identity information and are
/// therefore never retained here.
final class AuthFailure implements Exception {
  const AuthFailure(this.kind, this.code, {this.sessionEpoch});

  final AuthFailureKind kind;
  final AuthFailureCode code;
  final int? sessionEpoch;

  String get safeCode => code.value;

  bool get isCancellation => kind == AuthFailureKind.cancelled;
  bool get isInvalidGrant => kind == AuthFailureKind.invalidGrant;
  bool get isNetwork => kind == AuthFailureKind.network;
  bool get isSuperseded => kind == AuthFailureKind.superseded;

  @override
  String toString() => 'AuthFailure($safeCode)';
}

/// Tokens returned by an OIDC adapter. All secret fields are redacted from
/// string representations. Access tokens are never serialized by this layer.
final class OidcTokenSet {
  const OidcTokenSet({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    this.refreshToken,
    this.idToken,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String? refreshToken;
  final String? idToken;

  @override
  String toString() =>
      'OidcTokenSet(accessToken: <redacted>, refreshToken: '
      '${refreshToken == null ? '<absent>' : '<redacted>'}, idToken: '
      '${idToken == null ? '<absent>' : '<redacted>'}, '
      'accessTokenExpiresAt: $accessTokenExpiresAt)';
}

final class AuthAccessCredential {
  const AuthAccessCredential({required this.value, required this.expiresAt});

  final String value;
  final DateTime expiresAt;

  bool isUsableAt(DateTime now, Duration leeway) =>
      expiresAt.isAfter(now.add(leeway));

  @override
  String toString() =>
      'AuthAccessCredential(value: <redacted>, expiresAt: $expiresAt)';
}

enum AuthStoredSessionStatus { guest, refreshRequired }

final class AuthStoredSessionInspection {
  const AuthStoredSessionInspection._(this.status, this.accountId);

  const AuthStoredSessionInspection.guest()
    : this._(AuthStoredSessionStatus.guest, null);

  const AuthStoredSessionInspection.refreshRequired({String? accountId})
    : this._(AuthStoredSessionStatus.refreshRequired, accountId);

  final AuthStoredSessionStatus status;
  final String? accountId;

  @override
  String toString() =>
      'AuthStoredSessionInspection(status: $status, accountId: '
      '${accountId == null ? '<absent>' : '<present>'})';
}

final class AuthRepositorySession {
  const AuthRepositorySession({required this.accountId, required this.epoch});

  final String? accountId;
  final int epoch;

  @override
  String toString() =>
      'AuthRepositorySession(accountId: '
      '${accountId == null ? '<absent>' : '<present>'}, epoch: $epoch)';
}

enum AuthSessionPhase {
  checkingStoredSession,
  guest,
  authenticating,
  refreshRequired,
  refreshing,
  authenticated,
  offlineAuthUnknown,
  signingOut,
  unavailable,
}

/// UI-safe immutable session state. It never contains a bearer, refresh, or ID
/// token and never retains raw exceptions from an identity provider.
final class AuthSessionState {
  const AuthSessionState._({
    required this.phase,
    required this.epoch,
    this.accountId,
    this.failure,
  });

  const AuthSessionState.checking({required int epoch})
    : this._(phase: AuthSessionPhase.checkingStoredSession, epoch: epoch);

  const AuthSessionState.guest({required int epoch, AuthFailure? failure})
    : this._(phase: AuthSessionPhase.guest, epoch: epoch, failure: failure);

  const AuthSessionState.authenticating({required int epoch})
    : this._(phase: AuthSessionPhase.authenticating, epoch: epoch);

  const AuthSessionState.refreshRequired({
    required int epoch,
    String? accountId,
  }) : this._(
         phase: AuthSessionPhase.refreshRequired,
         epoch: epoch,
         accountId: accountId,
       );

  const AuthSessionState.refreshing({required int epoch, String? accountId})
    : this._(
        phase: AuthSessionPhase.refreshing,
        epoch: epoch,
        accountId: accountId,
      );

  const AuthSessionState.authenticated({required int epoch, String? accountId})
    : this._(
        phase: AuthSessionPhase.authenticated,
        epoch: epoch,
        accountId: accountId,
      );

  const AuthSessionState.offlineAuthUnknown({
    required int epoch,
    String? accountId,
    required AuthFailure failure,
  }) : this._(
         phase: AuthSessionPhase.offlineAuthUnknown,
         epoch: epoch,
         accountId: accountId,
         failure: failure,
       );

  const AuthSessionState.signingOut({required int epoch, String? accountId})
    : this._(
        phase: AuthSessionPhase.signingOut,
        epoch: epoch,
        accountId: accountId,
      );

  const AuthSessionState.unavailable({
    required int epoch,
    String? accountId,
    required AuthFailure failure,
  }) : this._(
         phase: AuthSessionPhase.unavailable,
         epoch: epoch,
         accountId: accountId,
         failure: failure,
       );

  final AuthSessionPhase phase;
  final int epoch;
  final String? accountId;
  final AuthFailure? failure;

  bool get isAuthenticated => phase == AuthSessionPhase.authenticated;
  bool get mayHaveRecoverableCredentials =>
      phase == AuthSessionPhase.refreshRequired ||
      phase == AuthSessionPhase.refreshing ||
      phase == AuthSessionPhase.offlineAuthUnknown ||
      phase == AuthSessionPhase.authenticated;

  @override
  String toString() =>
      'AuthSessionState(phase: $phase, epoch: $epoch, accountId: '
      '${accountId == null ? '<absent>' : '<present>'}, '
      'failure: ${failure?.safeCode})';
}
