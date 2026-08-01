import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import 'auth_config.dart';
import 'auth_models.dart';
import 'oidc_client.dart';

/// Native AppAuth implementation using the system authentication session.
///
/// `authorizeAndExchangeCode` uses AppAuth's Authorization Code flow. AppAuth
/// generates and verifies PKCE material internally; no verifier is persisted by
/// Pakperk.
final class FlutterAppAuthOidcClient implements OidcClient {
  FlutterAppAuthOidcClient({
    required OidcClientConfiguration configuration,
    FlutterAppAuth appAuth = const FlutterAppAuth(),
  }) : _configuration = configuration,
       _appAuth = appAuth;

  final OidcClientConfiguration _configuration;
  final FlutterAppAuth _appAuth;

  @override
  Future<OidcTokenSet> authorizeAndExchangeCode() async {
    try {
      final response = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          _configuration.clientId,
          _configuration.redirectUri.toString(),
          issuer: _configuration.issuer.toString(),
          scopes: _configuration.scopes,
          allowInsecureConnections: _configuration.allowInsecureLocalhost,
          externalUserAgent: ExternalUserAgent.asWebAuthenticationSession,
        ),
      );
      return _tokenSet(
        accessToken: response.accessToken,
        refreshToken: response.refreshToken,
        idToken: response.idToken,
        expiresAt: response.accessTokenExpirationDateTime,
      );
    } on FlutterAppAuthUserCancelledException {
      throw const OidcClientException.cancelled();
    } on FlutterAppAuthPlatformException catch (error) {
      throw _platformFailure(error.platformErrorDetails);
    } on PlatformException catch (error) {
      throw _legacyPlatformFailure(error);
    }
  }

  @override
  Future<OidcTokenSet> reauthenticateForSensitiveAction() async {
    try {
      final response = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          _configuration.clientId,
          _configuration.redirectUri.toString(),
          issuer: _configuration.issuer.toString(),
          scopes: _configuration.scopes,
          promptValues: const ['login'],
          additionalParameters: const {'max_age': '0'},
          allowInsecureConnections: _configuration.allowInsecureLocalhost,
          externalUserAgent: ExternalUserAgent.asWebAuthenticationSession,
        ),
      );
      return _tokenSet(
        accessToken: response.accessToken,
        refreshToken: null,
        idToken: null,
        expiresAt: response.accessTokenExpirationDateTime,
      );
    } on FlutterAppAuthUserCancelledException {
      throw const OidcClientException.cancelled();
    } on FlutterAppAuthPlatformException catch (error) {
      throw _platformFailure(error.platformErrorDetails);
    } on PlatformException catch (error) {
      throw _legacyPlatformFailure(error);
    }
  }

  @override
  Future<OidcTokenSet> refresh(String refreshToken) async {
    try {
      final response = await _appAuth.token(
        TokenRequest(
          _configuration.clientId,
          _configuration.redirectUri.toString(),
          issuer: _configuration.issuer.toString(),
          scopes: _configuration.scopes,
          refreshToken: refreshToken,
          allowInsecureConnections: _configuration.allowInsecureLocalhost,
        ),
      );
      return _tokenSet(
        accessToken: response.accessToken,
        refreshToken: response.refreshToken,
        idToken: response.idToken,
        expiresAt: response.accessTokenExpirationDateTime,
      );
    } on FlutterAppAuthUserCancelledException {
      throw const OidcClientException.cancelled();
    } on FlutterAppAuthPlatformException catch (error) {
      throw _platformFailure(error.platformErrorDetails);
    } on PlatformException catch (error) {
      throw _legacyPlatformFailure(error);
    }
  }

  @override
  Future<void> endSession({String? idTokenHint}) async {
    if (idTokenHint == null || idTokenHint.isEmpty) return;
    try {
      await _appAuth.endSession(
        EndSessionRequest(
          idTokenHint: idTokenHint,
          postLogoutRedirectUrl: _configuration.postLogoutRedirectUri
              ?.toString(),
          issuer: _configuration.issuer.toString(),
          allowInsecureConnections: _configuration.allowInsecureLocalhost,
          externalUserAgent: ExternalUserAgent.asWebAuthenticationSession,
        ),
      );
    } on FlutterAppAuthUserCancelledException {
      throw const OidcClientException.cancelled();
    } on FlutterAppAuthPlatformException catch (error) {
      throw _platformFailure(error.platformErrorDetails);
    } on PlatformException catch (error) {
      throw _legacyPlatformFailure(error);
    }
  }
}

OidcTokenSet _tokenSet({
  required String? accessToken,
  required String? refreshToken,
  required String? idToken,
  required DateTime? expiresAt,
}) {
  if (accessToken == null ||
      accessToken.isEmpty ||
      accessToken.length > 64 * 1024 ||
      expiresAt == null) {
    throw const OidcClientException.invalidResponse();
  }
  if ((refreshToken?.length ?? 0) > 64 * 1024 ||
      (idToken?.length ?? 0) > 64 * 1024) {
    throw const OidcClientException.invalidResponse();
  }
  return OidcTokenSet(
    accessToken: accessToken,
    accessTokenExpiresAt: expiresAt.toUtc(),
    refreshToken: _nonEmpty(refreshToken),
    idToken: _nonEmpty(idToken),
  );
}

OidcClientException _platformFailure(
  FlutterAppAuthPlatformErrorDetails details,
) {
  final normalizedError = _normalized(details.error);
  final normalizedCode = _normalized(details.code);
  final normalizedType = _normalized(details.type);
  final normalizedDomain = _normalized(details.domain);
  if (normalizedError == FlutterAppAuthOAuthError.invalidGrant ||
      normalizedCode == FlutterAppAuthOAuthError.invalidGrant ||
      // AppAuth-Android TokenRequestErrors.INVALID_GRANT.
      (normalizedType == '2' && normalizedCode == '2002') ||
      // AppAuth-iOS OIDErrorCodeOAuthTokenInvalidGrant.
      (normalizedType == 'org.openid.appauth.oauth_token' &&
          normalizedCode == '-10')) {
    return const OidcClientException.invalidGrant();
  }
  const networkCodes = {
    'network_error',
    'network',
    'connection_error',
    'io_error',
  };
  if (networkCodes.contains(normalizedError) ||
      networkCodes.contains(normalizedCode) ||
      // AppAuth-Android GeneralErrors.NETWORK_ERROR.
      (normalizedType == '0' && normalizedCode == '3') ||
      // AppAuth-iOS OIDErrorCodeNetworkError.
      (normalizedType == 'org.openid.appauth.general' &&
          normalizedCode == '-5') ||
      // AppAuth-iOS exposes the underlying Foundation transport domain here.
      normalizedDomain == 'nsurlerrordomain') {
    return const OidcClientException.network();
  }
  return const OidcClientException.provider();
}

OidcClientException _legacyPlatformFailure(PlatformException error) =>
    _platformFailure(
      FlutterAppAuthPlatformErrorDetails(error: error.code, code: error.code),
    );

String? _normalized(String? value) => value?.trim().toLowerCase();

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
