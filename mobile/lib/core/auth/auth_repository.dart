import 'dart:async';

import 'auth_config.dart';
import 'auth_models.dart';
import 'oidc_client.dart';
import 'secure_token_store.dart';

typedef AuthClock = DateTime Function();

/// Owns the in-memory bearer token and serialized secure credential updates.
///
/// This type is intentionally independent of Dio, Riverpod, and account APIs.
/// Request middleware should access it through [AuthTokenSource].
final class AuthRepository implements AuthTokenSource {
  AuthRepository({
    required OidcClientConfiguration configuration,
    required OidcClient oidcClient,
    required SecureTokenStore secureTokenStore,
    AuthClock clock = _utcNow,
    Duration providerLogoutTimeout = const Duration(seconds: 5),
  }) : _configuration = configuration,
       _oidcClient = oidcClient,
       _secureTokenStore = secureTokenStore,
       _clock = clock,
       _providerLogoutTimeout = _validateProviderLogoutTimeout(
         providerLogoutTimeout,
       );

  final OidcClientConfiguration _configuration;
  final OidcClient _oidcClient;
  final SecureTokenStore _secureTokenStore;
  final AuthClock _clock;
  final Duration _providerLogoutTimeout;

  AuthAccessCredential? _accessCredential;
  SecureAuthRecord? _secureRecord;
  _RefreshFlight? _refreshFlight;
  Future<void> _storageTail = Future<void>.value();
  int _epoch = 0;
  int _accountIdentityVersion = 0;
  int _accountBindingsInProgress = 0;
  bool _durableSessionBlocked = false;

  int get epoch => _epoch;
  String? get accountId => _secureRecord?.accountId;
  int get accountIdentityVersion => _accountIdentityVersion;
  bool get hasAccountBindingInProgress => _accountBindingsInProgress > 0;
  bool get hasStoredSessionInMemory => _secureRecord != null;
  @override
  bool isCurrentEpoch(int value) => value >= 0 && value == _epoch;

  /// Reads secure metadata without performing network I/O or refreshing.
  Future<AuthStoredSessionInspection> inspectStoredSession() async {
    if (_durableSessionBlocked) {
      _accessCredential = null;
      _secureRecord = null;
      return const AuthStoredSessionInspection.guest();
    }
    final operationEpoch = _epoch;
    final record = await _readSecureRecord(operationEpoch);
    _ensureEpoch(operationEpoch);
    if (record == null) {
      _durableSessionBlocked = false;
      _accessCredential = null;
      _secureRecord = null;
      return const AuthStoredSessionInspection.guest();
    }
    if (_isInvalidationMarker(record) || !record.matches(_configuration)) {
      await _invalidateDurableSession(operationEpoch);
      _ensureEpoch(operationEpoch);
      _accessCredential = null;
      _secureRecord = null;
      return const AuthStoredSessionInspection.guest();
    }
    _durableSessionBlocked = false;
    _secureRecord = record;
    return AuthStoredSessionInspection.refreshRequired(
      accountId: record.accountId,
    );
  }

  /// Invalidates any previous session before opening the system auth browser.
  Future<AuthRepositorySession> signIn() async {
    final operationEpoch = _beginNewEpoch();
    await _invalidateDurableSession(operationEpoch);
    _ensureEpoch(operationEpoch);

    late final OidcTokenSet tokens;
    try {
      tokens = await _oidcClient.authorizeAndExchangeCode();
    } on OidcClientException catch (error) {
      throw _mapOidcFailure(error, operationEpoch);
    } on Object {
      throw AuthFailure(
        AuthFailureKind.provider,
        AuthFailureCode.oidcUnexpected,
        sessionEpoch: operationEpoch,
      );
    }
    _ensureEpoch(operationEpoch);
    _validateTokenSet(
      tokens,
      requireRefreshToken: true,
      operationEpoch: operationEpoch,
    );

    final record = SecureAuthRecord(
      issuer: _configuration.issuerBinding,
      clientId: _configuration.clientId,
      refreshToken: tokens.refreshToken!,
      idTokenHint: tokens.idToken,
    );
    await _writeSecureRecord(record, operationEpoch);
    _ensureEpoch(operationEpoch);
    _durableSessionBlocked = false;
    _secureRecord = record;
    _accessCredential = AuthAccessCredential(
      value: tokens.accessToken,
      expiresAt: tokens.accessTokenExpiresAt.toUtc(),
    );
    return AuthRepositorySession(accountId: null, epoch: operationEpoch);
  }

  /// Returns a current bearer, proactively refreshing inside the configured
  /// leeway. Concurrent callers share one refresh exchange.
  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    final operationEpoch = expectedAuthEpoch ?? _epoch;
    _ensureEpoch(operationEpoch);
    final current = _accessCredential;
    if (current != null &&
        current.isUsableAt(_clock().toUtc(), _configuration.refreshLeeway)) {
      _ensureEpoch(operationEpoch);
      return current.value;
    }
    if (_secureRecord == null) {
      final inspection = await inspectStoredSession();
      _ensureEpoch(operationEpoch);
      if (inspection.status == AuthStoredSessionStatus.guest) return null;
    }
    final token = (await _refreshSingleFlight())?.value;
    _ensureEpoch(operationEpoch);
    return token;
  }

  /// Contract for one 401 challenge retry.
  ///
  /// If another request already replaced [rejectedAccessToken], its new token
  /// is returned without a second refresh. Callers must still enforce their
  /// own at-most-one-retry and write-idempotency policy.
  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    final operationEpoch = expectedAuthEpoch ?? _epoch;
    _ensureEpoch(operationEpoch);
    final current = _accessCredential;
    if (current != null &&
        current.value != rejectedAccessToken &&
        current.expiresAt.isAfter(_clock().toUtc())) {
      _ensureEpoch(operationEpoch);
      return current.value;
    }
    if (_secureRecord == null) {
      final inspection = await inspectStoredSession();
      _ensureEpoch(operationEpoch);
      if (inspection.status == AuthStoredSessionStatus.guest) return null;
    }
    final token = (await _refreshSingleFlight())?.value;
    _ensureEpoch(operationEpoch);
    return token;
  }

  /// Persists the non-secret Pakperk account UUID alongside the refresh token.
  Future<void> bindAccountId(String accountId) async {
    final operationEpoch = _epoch;
    // Account binding is a second identity coordinate within one credential
    // epoch. Advance it for every intent before the first await: while a B write
    // is pending, a queued A intent must not disappear into an A -> B -> A ABA.
    _accountIdentityVersion += 1;
    _accountBindingsInProgress += 1;
    try {
      await _mutateSecureRecord(
        operationEpoch,
        (current) => current.copyWith(accountId: accountId),
      );
    } on ArgumentError {
      throw AuthFailure(
        AuthFailureKind.invalidResponse,
        AuthFailureCode.accountIdInvalid,
        sessionEpoch: operationEpoch,
      );
    } finally {
      _accountBindingsInProgress -= 1;
    }
  }

  /// Obtains a fresh, one-use bearer without mutating the normal session.
  ///
  /// The optional account identifier is only the locally bound Pakperk ID.
  /// It can be absent after process death between token persistence and first
  /// profile binding. The deletion repository independently calls the
  /// deletion-verification endpoint with both the normal and ephemeral
  /// bearers and compares the server-returned internal IDs before DELETE.
  Future<RecentAuthCredential> reauthenticateForAccountDeletion({
    required int expectedAuthEpoch,
  }) async {
    _ensureEpoch(expectedAuthEpoch);
    final record = _secureRecord;
    if (record == null) {
      throw AuthFailure(
        AuthFailureKind.invalidGrant,
        AuthFailureCode.authSessionMissing,
        sessionEpoch: expectedAuthEpoch,
      );
    }

    late final OidcTokenSet tokens;
    try {
      tokens = await _oidcClient.reauthenticateForSensitiveAction();
    } on OidcClientException catch (error) {
      throw _mapOidcFailure(error, expectedAuthEpoch);
    } on Object {
      throw AuthFailure(
        AuthFailureKind.provider,
        AuthFailureCode.oidcUnexpected,
        sessionEpoch: expectedAuthEpoch,
      );
    }
    _ensureEpoch(expectedAuthEpoch);
    _validateTokenSet(
      tokens,
      requireRefreshToken: false,
      operationEpoch: expectedAuthEpoch,
    );
    return RecentAuthCredential(
      bearer: tokens.accessToken,
      expiresAt: tokens.accessTokenExpiresAt.toUtc(),
      accountId: record.accountId,
      sessionEpoch: expectedAuthEpoch,
    );
  }

  /// Invalidates the local session after deletion acceptance without opening
  /// a provider logout browser. The API has already disabled the account and
  /// its worker owns provider-session revocation and identity erasure.
  Future<int> invalidateForAccountDeletion() async {
    final deletionEpoch = _beginNewEpoch();
    await _invalidateDurableSession(deletionEpoch);
    _ensureEpoch(deletionEpoch);
    return deletionEpoch;
  }

  /// Immediately invalidates in-flight operations, clears memory, then removes
  /// durable credentials. Provider logout is best effort, bounded by the
  /// configured timeout, and cannot prevent local sign-out.
  Future<void> signOut() async {
    final idTokenHint = _secureRecord?.idTokenHint;
    final signOutEpoch = _beginNewEpoch();
    AuthFailure? localFailure;
    try {
      await _invalidateDurableSession(signOutEpoch);
    } on AuthFailure catch (error) {
      localFailure = error;
    }

    try {
      await _oidcClient
          .endSession(idTokenHint: idTokenHint)
          .timeout(_providerLogoutTimeout);
    } on Object {
      // RP-initiated logout is advisory. The local credential was invalidated
      // synchronously above and must remain signed out when the IdP is offline.
    }
    if (localFailure != null) throw localFailure;
  }

  Future<AuthAccessCredential?> _refreshSingleFlight() {
    final operationEpoch = _epoch;
    final record = _secureRecord;
    if (record == null) return Future<AuthAccessCredential?>.value();

    final active = _refreshFlight;
    if (active != null && active.epoch == operationEpoch) {
      return active.future;
    }

    late final Future<AuthAccessCredential?> operation;
    operation = _performRefresh(record, operationEpoch).whenComplete(() {
      if (identical(_refreshFlight?.future, operation)) {
        _refreshFlight = null;
      }
    });
    _refreshFlight = _RefreshFlight(operationEpoch, operation);
    return operation;
  }

  Future<AuthAccessCredential> _performRefresh(
    SecureAuthRecord record,
    int operationEpoch,
  ) async {
    late final OidcTokenSet tokens;
    try {
      tokens = await _oidcClient.refresh(record.refreshToken);
    } on OidcClientException catch (error) {
      if (error.kind == OidcClientFailureKind.invalidGrant) {
        final invalidatedEpoch = await _invalidateInvalidGrant(operationEpoch);
        throw AuthFailure(
          AuthFailureKind.invalidGrant,
          AuthFailureCode.oidcInvalidGrant,
          sessionEpoch: invalidatedEpoch,
        );
      }
      throw _mapOidcFailure(error, operationEpoch);
    } on Object {
      throw AuthFailure(
        AuthFailureKind.provider,
        AuthFailureCode.oidcUnexpected,
        sessionEpoch: operationEpoch,
      );
    }
    _ensureEpoch(operationEpoch);
    _validateTokenSet(
      tokens,
      requireRefreshToken: false,
      operationEpoch: operationEpoch,
    );

    await _mutateSecureRecord(
      operationEpoch,
      (current) => current.copyWith(
        refreshToken: tokens.refreshToken,
        idTokenHint: tokens.idToken,
      ),
    );
    _ensureEpoch(operationEpoch);
    final credential = AuthAccessCredential(
      value: tokens.accessToken,
      expiresAt: tokens.accessTokenExpiresAt.toUtc(),
    );
    _accessCredential = credential;
    return credential;
  }

  int _beginNewEpoch() {
    final next = ++_epoch;
    _accessCredential = null;
    _secureRecord = null;
    return next;
  }

  Future<int> _invalidateInvalidGrant(int operationEpoch) async {
    _ensureEpoch(operationEpoch);
    final invalidatedEpoch = _beginNewEpoch();
    try {
      await _invalidateDurableSession(invalidatedEpoch);
    } on AuthFailure catch (failure) {
      if (failure.isSuperseded) rethrow;
      // Preserve invalid_grant as the controlling failure. This lets the
      // session controller enter guest state and erase account-owned rows even
      // when the secure store is temporarily unable to delete or overwrite.
      // _invalidateDurableSession has already blocked this repository from
      // reading the stale record again.
    }
    _ensureEpoch(invalidatedEpoch);
    return invalidatedEpoch;
  }

  void _validateTokenSet(
    OidcTokenSet tokens, {
    required bool requireRefreshToken,
    required int operationEpoch,
  }) {
    final refreshToken = tokens.refreshToken;
    if (tokens.accessToken.isEmpty ||
        tokens.accessToken.length > 64 * 1024 ||
        !tokens.accessTokenExpiresAt.toUtc().isAfter(_clock().toUtc()) ||
        (requireRefreshToken &&
            (refreshToken == null || refreshToken.isEmpty)) ||
        (refreshToken?.length ?? 0) > 64 * 1024 ||
        (tokens.idToken?.length ?? 0) > 64 * 1024) {
      throw AuthFailure(
        AuthFailureKind.invalidResponse,
        AuthFailureCode.oidcInvalidResponse,
        sessionEpoch: operationEpoch,
      );
    }
  }

  Future<SecureAuthRecord?> _readSecureRecord(int operationEpoch) async {
    try {
      final record = await _withSerializedStorage(_secureTokenStore.read);
      _ensureEpoch(operationEpoch);
      return record;
    } on AuthFailure {
      rethrow;
    } on Object {
      throw AuthFailure(
        AuthFailureKind.secureStorage,
        AuthFailureCode.secureStorageRead,
        sessionEpoch: operationEpoch,
      );
    }
  }

  Future<void> _writeSecureRecord(
    SecureAuthRecord record,
    int operationEpoch,
  ) async {
    try {
      await _withSerializedStorage(() async {
        _ensureEpoch(operationEpoch);
        await _secureTokenStore.write(record);
      });
      _ensureEpoch(operationEpoch);
    } on AuthFailure {
      rethrow;
    } on Object {
      throw AuthFailure(
        AuthFailureKind.secureStorage,
        AuthFailureCode.secureStorageWrite,
        sessionEpoch: operationEpoch,
      );
    }
  }

  /// Serializes read-modify-write updates against the latest in-memory record.
  ///
  /// Refresh and account binding deliberately update disjoint fields. Reading
  /// the record inside the same storage critical section prevents either one
  /// from restoring the other's stale snapshot when their asynchronous work
  /// completes in the opposite order.
  Future<SecureAuthRecord> _mutateSecureRecord(
    int operationEpoch,
    SecureAuthRecord Function(SecureAuthRecord current) mutate,
  ) async {
    try {
      final updated = await _withSerializedStorage(() async {
        _ensureEpoch(operationEpoch);
        final current = _secureRecord;
        if (current == null) {
          throw AuthFailure(
            AuthFailureKind.invalidGrant,
            AuthFailureCode.authSessionMissing,
            sessionEpoch: operationEpoch,
          );
        }
        final next = mutate(current);
        await _secureTokenStore.write(next);
        _ensureEpoch(operationEpoch);
        _secureRecord = next;
        return next;
      });
      _ensureEpoch(operationEpoch);
      return updated;
    } on AuthFailure {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on Object {
      throw AuthFailure(
        AuthFailureKind.secureStorage,
        AuthFailureCode.secureStorageWrite,
        sessionEpoch: operationEpoch,
      );
    }
  }

  Future<void> _clearSecureRecord(int operationEpoch) async {
    try {
      await _withSerializedStorage(() async {
        _ensureEpoch(operationEpoch);
        await _secureTokenStore.clear();
      });
      _ensureEpoch(operationEpoch);
    } on AuthFailure {
      rethrow;
    } on Object {
      throw AuthFailure(
        AuthFailureKind.secureStorage,
        AuthFailureCode.secureStorageClear,
        sessionEpoch: operationEpoch,
      );
    }
  }

  /// Makes a durable credential unusable even on stores where deleting an
  /// existing key can fail while replacing its value still succeeds.
  ///
  /// The replacement contains no credential or identity data and is
  /// recognized before configuration matching, so a later repository instance
  /// cannot submit it to the identity provider. If both operations fail, this
  /// repository remains fail-closed for its lifetime and reports the original
  /// secure-storage failure to explicit sign-out callers.
  Future<void> _invalidateDurableSession(int operationEpoch) async {
    try {
      await _clearSecureRecord(operationEpoch);
      _ensureEpoch(operationEpoch);
      _durableSessionBlocked = false;
      return;
    } on AuthFailure catch (clearFailure) {
      if (clearFailure.isSuperseded) rethrow;
      try {
        await _writeSecureRecord(_secureInvalidationMarker, operationEpoch);
        _ensureEpoch(operationEpoch);
        _durableSessionBlocked = false;
        return;
      } on AuthFailure catch (writeFailure) {
        if (writeFailure.isSuperseded) rethrow;
        _ensureEpoch(operationEpoch);
        _durableSessionBlocked = true;
        throw clearFailure;
      }
    }
  }

  Future<T> _withSerializedStorage<T>(Future<T> Function() operation) {
    final previous = _storageTail;
    final release = Completer<void>();
    _storageTail = release.future;
    return () async {
      try {
        await previous;
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  void _ensureEpoch(int expected) {
    if (_epoch != expected) {
      throw AuthFailure(
        AuthFailureKind.superseded,
        AuthFailureCode.operationSuperseded,
        sessionEpoch: expected,
      );
    }
  }
}

/// Narrow interface consumed by authenticated HTTP middleware.
abstract interface class AuthTokenSource {
  bool isCurrentEpoch(int expectedAuthEpoch);

  Future<String?> accessTokenForRequest({int? expectedAuthEpoch});

  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  });
}

final class _RefreshFlight {
  const _RefreshFlight(this.epoch, this.future);

  final int epoch;
  final Future<AuthAccessCredential?> future;
}

// `.invalid` is reserved for names that can never resolve. The marker is a
// valid record only so every SecureTokenStore can atomically replace an old
// credential through its existing write contract.
final _secureInvalidationMarker = SecureAuthRecord(
  issuer: 'https://local-session-invalidated.invalid/pakperk',
  clientId: 'pakperk-local-session-invalidated-v1',
  refreshToken: 'pakperk-local-session-invalidated-v1',
);

bool _isInvalidationMarker(SecureAuthRecord record) =>
    record.issuer == _secureInvalidationMarker.issuer &&
    record.clientId == _secureInvalidationMarker.clientId &&
    record.refreshToken == _secureInvalidationMarker.refreshToken &&
    record.idTokenHint == null &&
    record.accountId == null;

AuthFailure _mapOidcFailure(OidcClientException error, int epoch) {
  final kind = switch (error.kind) {
    OidcClientFailureKind.cancelled => AuthFailureKind.cancelled,
    OidcClientFailureKind.invalidGrant => AuthFailureKind.invalidGrant,
    OidcClientFailureKind.network => AuthFailureKind.network,
    OidcClientFailureKind.provider => AuthFailureKind.provider,
    OidcClientFailureKind.invalidResponse => AuthFailureKind.invalidResponse,
  };
  final code = switch (error.kind) {
    OidcClientFailureKind.cancelled => AuthFailureCode.oidcCancelled,
    OidcClientFailureKind.invalidGrant => AuthFailureCode.oidcInvalidGrant,
    OidcClientFailureKind.network => AuthFailureCode.oidcNetwork,
    OidcClientFailureKind.provider => AuthFailureCode.oidcProvider,
    OidcClientFailureKind.invalidResponse =>
      AuthFailureCode.oidcInvalidResponse,
  };
  return AuthFailure(kind, code, sessionEpoch: epoch);
}

DateTime _utcNow() => DateTime.now().toUtc();

Duration _validateProviderLogoutTimeout(Duration value) {
  const maximum = Duration(seconds: 30);
  if (value <= Duration.zero || value > maximum) {
    throw ArgumentError.value(
      value,
      'providerLogoutTimeout',
      'Must be greater than zero and no more than 30 seconds.',
    );
  }
  return value;
}
