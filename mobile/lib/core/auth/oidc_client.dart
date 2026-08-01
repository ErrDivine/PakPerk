import 'auth_models.dart';

/// Testable boundary around a native system-browser OpenID Connect client.
abstract interface class OidcClient {
  /// Starts Authorization Code + PKCE in the system authentication browser and
  /// immediately exchanges the returned code.
  Future<OidcTokenSet> authorizeAndExchangeCode();

  /// Performs a fresh Authorization Code + PKCE ceremony for a sensitive
  /// action. Implementations must force provider login (`prompt=login`) and
  /// require an authentication age of zero (`max_age=0`). The returned token
  /// set is ephemeral and must not replace the normal refresh session.
  Future<OidcTokenSet> reauthenticateForSensitiveAction();

  Future<OidcTokenSet> refresh(String refreshToken);

  /// Best-effort RP-initiated logout. Local sign-out must never depend on it.
  Future<void> endSession({String? idTokenHint});
}

enum OidcClientFailureKind {
  cancelled,
  invalidGrant,
  network,
  provider,
  invalidResponse,
}

/// Sanitized adapter error. Raw platform/OAuth exception text is intentionally
/// discarded because it may contain provider-controlled identity data.
final class OidcClientException implements Exception {
  const OidcClientException.cancelled()
    : kind = OidcClientFailureKind.cancelled;

  const OidcClientException.invalidGrant()
    : kind = OidcClientFailureKind.invalidGrant;

  const OidcClientException.network() : kind = OidcClientFailureKind.network;

  const OidcClientException.provider() : kind = OidcClientFailureKind.provider;

  const OidcClientException.invalidResponse()
    : kind = OidcClientFailureKind.invalidResponse;

  final OidcClientFailureKind kind;

  String get safeCode => switch (kind) {
    OidcClientFailureKind.cancelled => 'oidc_cancelled',
    OidcClientFailureKind.invalidGrant => 'oidc_invalid_grant',
    OidcClientFailureKind.network => 'oidc_network',
    OidcClientFailureKind.provider => 'oidc_provider',
    OidcClientFailureKind.invalidResponse => 'oidc_invalid_response',
  };

  @override
  String toString() => 'OidcClientException($safeCode)';
}
