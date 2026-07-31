/// Public-client OpenID Connect settings used by the native AppAuth adapter.
///
/// The mobile app never accepts a client secret. Authorization Code + PKCE is
/// the only interactive flow exposed by [OidcClientConfiguration].
final class OidcClientConfiguration {
  OidcClientConfiguration({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    required Iterable<String> scopes,
    this.postLogoutRedirectUri,
    this.registeredRedirectScheme = 'pakperk-auth',
    this.registeredRedirectHost = 'oauth',
    this.registeredAuthorizationPath = '/callback',
    this.registeredLogoutPath = '/logout',
    this.refreshLeeway = const Duration(minutes: 2),
    this.allowInsecureLocalhost = false,
  }) : scopes = List.unmodifiable(scopes.toSet()) {
    _validate();
  }

  final Uri issuer;
  final String clientId;
  final Uri redirectUri;
  final List<String> scopes;
  final Uri? postLogoutRedirectUri;
  final String registeredRedirectScheme;
  final String registeredRedirectHost;
  final String registeredAuthorizationPath;
  final String registeredLogoutPath;
  final Duration refreshLeeway;

  /// Allows an HTTP issuer only for an explicit loopback development setup.
  final bool allowInsecureLocalhost;

  String get issuerBinding => issuer.toString();

  void _validate() {
    if (!issuer.isAbsolute || issuer.hasQuery || issuer.hasFragment) {
      throw ArgumentError.value(issuer, 'issuer', 'Must be an absolute URL.');
    }
    final secureIssuer = issuer.scheme == 'https';
    final insecureLoopback =
        allowInsecureLocalhost &&
        issuer.scheme == 'http' &&
        _isLoopbackHost(issuer.host);
    if (!secureIssuer && !insecureLoopback) {
      throw ArgumentError.value(
        issuer,
        'issuer',
        'Must use HTTPS outside an explicitly enabled loopback setup.',
      );
    }
    if (clientId.trim().isEmpty || clientId.length > 256) {
      throw ArgumentError.value(clientId, 'clientId', 'Must be 1-256 chars.');
    }
    if (!_isRegisteredRedirect(
      redirectUri,
      scheme: registeredRedirectScheme,
      host: registeredRedirectHost,
      path: registeredAuthorizationPath,
    )) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Must be an absolute private-use URI.',
      );
    }
    if (postLogoutRedirectUri case final uri?) {
      if (!_isRegisteredRedirect(
        uri,
        scheme: registeredRedirectScheme,
        host: registeredRedirectHost,
        path: registeredLogoutPath,
      )) {
        throw ArgumentError.value(
          uri,
          'postLogoutRedirectUri',
          'Must be an absolute private-use URI.',
        );
      }
    }
    if (!scopes.contains('openid') || !scopes.contains('profile')) {
      throw ArgumentError.value(
        scopes,
        'scopes',
        'Must include openid and profile.',
      );
    }
    if (scopes.any((scope) => scope.isEmpty || scope.length > 128)) {
      throw ArgumentError.value(scopes, 'scopes', 'Contains an invalid scope.');
    }
    if (refreshLeeway < Duration.zero) {
      throw ArgumentError.value(
        refreshLeeway,
        'refreshLeeway',
        'Must not be negative.',
      );
    }
  }

  @override
  String toString() =>
      'OidcClientConfiguration(issuer: $issuer, clientId: $clientId, '
      'redirectUri: $redirectUri, scopes: $scopes)';
}

bool _isLoopbackHost(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

bool _isRegisteredRedirect(
  Uri uri, {
  required String scheme,
  required String host,
  required String path,
}) =>
    uri.isAbsolute &&
    scheme.isNotEmpty &&
    host.isNotEmpty &&
    uri.scheme == scheme &&
    uri.host == host &&
    path.startsWith('/') &&
    uri.path == path &&
    !uri.hasPort &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment;
