import 'dart:async';

import 'package:pakperk/core/auth/auth.dart';

final testOidcConfiguration = OidcClientConfiguration(
  issuer: Uri.parse('https://identity.example.test/realms/pakperk'),
  clientId: 'pakperk-mobile',
  redirectUri: Uri.parse('pakperk-auth://oauth/callback'),
  postLogoutRedirectUri: Uri.parse('pakperk-auth://oauth/logout'),
  scopes: const ['openid', 'profile'],
);

OidcTokenSet tokenSet({
  String accessToken = 'access-token',
  String? refreshToken = 'refresh-token',
  String? idToken = 'id-token',
  DateTime? expiresAt,
}) => OidcTokenSet(
  accessToken: accessToken,
  refreshToken: refreshToken,
  idToken: idToken,
  accessTokenExpiresAt: expiresAt ?? DateTime.utc(2030, 1, 1, 0, 30),
);

final class FakeOidcClient implements OidcClient {
  Future<OidcTokenSet> Function()? authorizeHandler;
  Future<OidcTokenSet> Function()? reauthenticateHandler;
  Future<OidcTokenSet> Function(String refreshToken)? refreshHandler;
  Future<void> Function(String? idTokenHint)? endSessionHandler;

  int authorizeCalls = 0;
  int reauthenticateCalls = 0;
  int refreshCalls = 0;
  int endSessionCalls = 0;
  final List<String> suppliedRefreshTokens = [];
  final List<String?> suppliedIdTokenHints = [];

  @override
  Future<OidcTokenSet> authorizeAndExchangeCode() {
    authorizeCalls += 1;
    return authorizeHandler?.call() ?? Future.value(tokenSet());
  }

  @override
  Future<OidcTokenSet> reauthenticateForSensitiveAction() {
    reauthenticateCalls += 1;
    return reauthenticateHandler?.call() ??
        Future.value(tokenSet(refreshToken: null, idToken: null));
  }

  @override
  Future<OidcTokenSet> refresh(String refreshToken) {
    refreshCalls += 1;
    suppliedRefreshTokens.add(refreshToken);
    return refreshHandler?.call(refreshToken) ?? Future.value(tokenSet());
  }

  @override
  Future<void> endSession({String? idTokenHint}) {
    endSessionCalls += 1;
    suppliedIdTokenHints.add(idTokenHint);
    return endSessionHandler?.call(idTokenHint) ?? Future.value();
  }
}

final class MemoryAuthInvalidationStore implements AuthInvalidationStore {
  bool invalidated = false;
  int readCalls = 0;
  int markCalls = 0;
  int clearCalls = 0;

  @override
  Future<bool> isInvalidated() async {
    readCalls += 1;
    return invalidated;
  }

  @override
  Future<void> markInvalidated() async {
    markCalls += 1;
    invalidated = true;
  }

  @override
  Future<void> clearInvalidation() async {
    clearCalls += 1;
    invalidated = false;
  }
}

final class MemorySecureTokenStore implements SecureTokenStore {
  MemorySecureTokenStore([
    this.record,
    MemoryAuthInvalidationStore? invalidationStore,
  ]) : invalidationStore = invalidationStore ?? MemoryAuthInvalidationStore();

  SecureAuthRecord? record;
  final MemoryAuthInvalidationStore invalidationStore;
  int readCalls = 0;
  int writeCalls = 0;
  int clearCalls = 0;
  Completer<void>? writeGate;
  Object? readError;
  Object? writeError;
  Object? clearError;

  @override
  Future<SecureAuthRecord?> read() async {
    readCalls += 1;
    if (await invalidationStore.isInvalidated()) return null;
    final error = readError;
    if (error != null) throw error;
    return record;
  }

  @override
  Future<void> write(SecureAuthRecord value) async {
    writeCalls += 1;
    await writeGate?.future;
    final error = writeError;
    if (error != null) throw error;
    record = value;
    await invalidationStore.clearInvalidation();
  }

  @override
  Future<void> clear() async {
    clearCalls += 1;
    await invalidationStore.markInvalidated();
    final error = clearError;
    if (error != null) throw error;
    record = null;
  }
}

SecureAuthRecord storedRecord({
  String refreshToken = 'stored-refresh-token',
  String? idTokenHint = 'stored-id-token',
  String? accountId,
  String? issuer,
  String? clientId,
}) => SecureAuthRecord(
  issuer: issuer ?? testOidcConfiguration.issuerBinding,
  clientId: clientId ?? testOidcConfiguration.clientId,
  refreshToken: refreshToken,
  idTokenHint: idTokenHint,
  accountId: accountId,
);
