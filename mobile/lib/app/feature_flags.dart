enum AppEnvironment {
  development,
  staging,
  production;

  static AppEnvironment parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'development' || 'dev' => AppEnvironment.development,
      'staging' || 'stage' => AppEnvironment.staging,
      'production' || 'prod' => AppEnvironment.production,
      _ => throw BuildConfigurationException(
        'PAKPERK_ENV must be development, staging, or production.',
      ),
    };
  }

  bool get isProductionLike => this != AppEnvironment.development;
}

const bundledTermsDocumentVersion = '2026-07-31';
const bundledCommunityGuidelinesDocumentVersion = '2026-07-31';

class FeatureFlags {
  const FeatureFlags({
    required this.accounts,
    required this.library,
    required this.comments,
    required this.openingMotion,
  });

  const FeatureFlags.disabled()
    : accounts = false,
      library = false,
      comments = false,
      openingMotion = false;

  final bool accounts;
  final bool library;
  final bool comments;
  final bool openingMotion;

  @override
  bool operator ==(Object other) {
    return other is FeatureFlags &&
        other.accounts == accounts &&
        other.library == library &&
        other.comments == comments &&
        other.openingMotion == openingMotion;
  }

  @override
  int get hashCode => Object.hash(accounts, library, comments, openingMotion);
}

class AppBuildConfig {
  const AppBuildConfig._({
    required this.environment,
    required this.apiBaseUri,
    required this.fulltextPolicy,
    required this.termsDocumentVersion,
    required this.communityGuidelinesDocumentVersion,
    required this.features,
    required this.oidcIssuerUri,
    required this.oidcClientId,
    required this.oidcRedirectUri,
    required this.oidcPostLogoutRedirectUri,
    required this.oidcScopes,
    required this.commentSupportContactUri,
    required this.publicSiteOriginUri,
    required this.supportUri,
    required this.accountDeletionUri,
    required this.appLinkOriginUri,
    required this.telemetryEndpointUri,
  });

  static const _environmentKey = 'PAKPERK_ENV';
  static const _apiBaseUrlKey = 'PAKPERK_API_BASE_URL';
  static const _fulltextPolicyKey = 'PAKPERK_FULLTEXT_POLICY';
  static const _termsDocumentVersionKey = 'PAKPERK_TERMS_DOCUMENT_VERSION';
  static const _communityGuidelinesDocumentVersionKey =
      'PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION';
  static const _accountsEnabledKey = 'PAKPERK_ACCOUNTS_ENABLED';
  static const _libraryEnabledKey = 'PAKPERK_LIBRARY_ENABLED';
  static const _commentsEnabledKey = 'PAKPERK_COMMENTS_ENABLED';
  static const _openingMotionEnabledKey = 'PAKPERK_OPENING_MOTION_ENABLED';
  static const _oidcIssuerUrlKey = 'PAKPERK_OIDC_ISSUER_URL';
  static const _oidcClientIdKey = 'PAKPERK_OIDC_CLIENT_ID';
  static const _oidcRedirectUriKey = 'PAKPERK_OIDC_REDIRECT_URI';
  static const _oidcPostLogoutRedirectUriKey =
      'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI';
  static const _oidcScopesKey = 'PAKPERK_OIDC_SCOPES';
  static const _commentSupportContactUrlKey =
      'PAKPERK_COMMENT_SUPPORT_CONTACT_URL';
  static const _publicSiteOriginKey = 'PAKPERK_PUBLIC_SITE_ORIGIN';
  static const _supportUrlKey = 'PAKPERK_SUPPORT_URL';
  static const _accountDeletionUrlKey = 'PAKPERK_ACCOUNT_DELETION_URL';
  static const _appLinkOriginKey = 'PAKPERK_APP_LINK_ORIGIN';
  static const _telemetryEndpointKey = 'PAKPERK_TELEMETRY_ENDPOINT';

  /// Reads only compile-time values supplied with `--dart-define`.
  ///
  /// Secrets are intentionally included only in the rejected-value checks so
  /// an accidental client-side secret fails startup instead of being ignored.
  factory AppBuildConfig.fromCompileTime() => AppBuildConfig.fromValues({
    _environmentKey: const String.fromEnvironment(
      _environmentKey,
      defaultValue: 'development',
    ),
    _apiBaseUrlKey: const String.fromEnvironment(
      _apiBaseUrlKey,
      defaultValue: 'http://localhost:8080',
    ),
    _fulltextPolicyKey: const String.fromEnvironment(
      _fulltextPolicyKey,
      defaultValue: 'prototype',
    ),
    _termsDocumentVersionKey: const String.fromEnvironment(
      _termsDocumentVersionKey,
      defaultValue: bundledTermsDocumentVersion,
    ),
    _communityGuidelinesDocumentVersionKey: const String.fromEnvironment(
      _communityGuidelinesDocumentVersionKey,
      defaultValue: bundledCommunityGuidelinesDocumentVersion,
    ),
    _accountsEnabledKey: const String.fromEnvironment(
      _accountsEnabledKey,
      defaultValue: 'false',
    ),
    _libraryEnabledKey: const String.fromEnvironment(
      _libraryEnabledKey,
      defaultValue: 'false',
    ),
    _commentsEnabledKey: const String.fromEnvironment(
      _commentsEnabledKey,
      defaultValue: 'false',
    ),
    _openingMotionEnabledKey: const String.fromEnvironment(
      _openingMotionEnabledKey,
      defaultValue: 'false',
    ),
    _oidcIssuerUrlKey: const String.fromEnvironment(_oidcIssuerUrlKey),
    _oidcClientIdKey: const String.fromEnvironment(_oidcClientIdKey),
    _oidcRedirectUriKey: const String.fromEnvironment(_oidcRedirectUriKey),
    _oidcPostLogoutRedirectUriKey: const String.fromEnvironment(
      _oidcPostLogoutRedirectUriKey,
    ),
    _oidcScopesKey: const String.fromEnvironment(
      _oidcScopesKey,
      defaultValue: 'openid profile',
    ),
    _commentSupportContactUrlKey: const String.fromEnvironment(
      _commentSupportContactUrlKey,
    ),
    _publicSiteOriginKey: const String.fromEnvironment(_publicSiteOriginKey),
    _supportUrlKey: const String.fromEnvironment(_supportUrlKey),
    _accountDeletionUrlKey: const String.fromEnvironment(
      _accountDeletionUrlKey,
    ),
    _appLinkOriginKey: const String.fromEnvironment(_appLinkOriginKey),
    _telemetryEndpointKey: const String.fromEnvironment(_telemetryEndpointKey),
    'PAKPERK_OIDC_CLIENT_SECRET': const String.fromEnvironment(
      'PAKPERK_OIDC_CLIENT_SECRET',
    ),
    'PAKPERK_API_SECRET': const String.fromEnvironment('PAKPERK_API_SECRET'),
    'PAKPERK_LLM_API_KEY': const String.fromEnvironment('PAKPERK_LLM_API_KEY'),
  });

  factory AppBuildConfig.fromValues(Map<String, String> values) {
    _rejectBundledSecrets(values);

    final environment = AppEnvironment.parse(
      _value(values, _environmentKey, fallback: 'development'),
    );
    final apiBaseUri = _parseUri(
      _value(values, _apiBaseUrlKey, fallback: 'http://localhost:8080'),
      key: _apiBaseUrlKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    _validateApiUri(apiBaseUri, environment);

    final fulltextPolicy = _value(
      values,
      _fulltextPolicyKey,
      fallback: 'prototype',
    ).toLowerCase();
    if (fulltextPolicy != 'prototype' && fulltextPolicy != 'strict') {
      throw BuildConfigurationException(
        '$_fulltextPolicyKey must be prototype or strict.',
      );
    }
    if (environment == AppEnvironment.production &&
        fulltextPolicy != 'strict') {
      throw BuildConfigurationException(
        'Production builds require PAKPERK_FULLTEXT_POLICY=strict.',
      );
    }
    final termsDocumentVersion = _parseDocumentVersion(
      _value(
        values,
        _termsDocumentVersionKey,
        fallback: bundledTermsDocumentVersion,
      ),
      _termsDocumentVersionKey,
    );
    final communityGuidelinesDocumentVersion = _parseDocumentVersion(
      _value(
        values,
        _communityGuidelinesDocumentVersionKey,
        fallback: bundledCommunityGuidelinesDocumentVersion,
      ),
      _communityGuidelinesDocumentVersionKey,
    );
    if (termsDocumentVersion != bundledTermsDocumentVersion ||
        communityGuidelinesDocumentVersion !=
            bundledCommunityGuidelinesDocumentVersion) {
      throw BuildConfigurationException(
        'Configured policy versions must match the documents bundled in this '
        'application build.',
      );
    }

    final features = FeatureFlags(
      accounts: _parseBool(values, _accountsEnabledKey),
      library: _parseBool(values, _libraryEnabledKey),
      comments: _parseBool(values, _commentsEnabledKey),
      openingMotion: _parseBool(values, _openingMotionEnabledKey),
    );
    if (features.library && !features.accounts) {
      throw BuildConfigurationException(
        'Library requires the accounts feature.',
      );
    }
    if (features.comments && !features.accounts) {
      throw BuildConfigurationException(
        'Comments require the accounts feature.',
      );
    }

    final oidcIssuerUri = _optionalUri(
      values[_oidcIssuerUrlKey],
      key: _oidcIssuerUrlKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    final oidcClientId = values[_oidcClientIdKey]?.trim();
    final oidcRedirectUri = _optionalUri(
      values[_oidcRedirectUriKey],
      key: _oidcRedirectUriKey,
      requireHttps: false,
      allowCustomScheme: true,
    );
    final oidcPostLogoutRedirectUri = _optionalUri(
      values[_oidcPostLogoutRedirectUriKey],
      key: _oidcPostLogoutRedirectUriKey,
      requireHttps: false,
      allowCustomScheme: true,
    );
    final oidcScopes = _parseOidcScopes(
      _value(values, _oidcScopesKey, fallback: 'openid profile'),
    );
    if (features.accounts) {
      if (oidcIssuerUri == null ||
          oidcClientId == null ||
          oidcClientId.isEmpty ||
          oidcRedirectUri == null ||
          oidcPostLogoutRedirectUri == null) {
        throw BuildConfigurationException(
          'Accounts require issuer, client ID, redirect URI, and post-logout '
          'redirect URI configuration.',
        );
      }
      _rejectPlaceholder(oidcIssuerUri.host, _oidcIssuerUrlKey);
      _rejectPlaceholder(oidcClientId, _oidcClientIdKey);
      _validateOidcIssuerUri(oidcIssuerUri, environment);
      _validateNativeRedirectUri(
        oidcRedirectUri,
        key: _oidcRedirectUriKey,
        environment: environment,
      );
      _validateNativeRedirectUri(
        oidcPostLogoutRedirectUri,
        key: _oidcPostLogoutRedirectUriKey,
        environment: environment,
      );
    }

    final publicSiteOriginValue = environment == AppEnvironment.development
        ? _value(
            values,
            _publicSiteOriginKey,
            fallback: 'http://localhost:3000',
          )
        : _requiredValue(values, _publicSiteOriginKey);
    final publicSiteOriginUri = _parseUri(
      publicSiteOriginValue,
      key: _publicSiteOriginKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    _validateOrigin(
      publicSiteOriginUri,
      _publicSiteOriginKey,
      environment: environment,
    );
    if (environment.isProductionLike) {
      _rejectPlaceholder(publicSiteOriginUri.host, _publicSiteOriginKey);
    }
    final supportUri = _parseUri(
      _value(
        values,
        _supportUrlKey,
        fallback:
            values[_commentSupportContactUrlKey]?.trim().isNotEmpty == true
            ? values[_commentSupportContactUrlKey]!.trim()
            : publicSiteOriginUri.resolve('/support').toString(),
      ),
      key: _supportUrlKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    if (features.comments &&
        values[_supportUrlKey]?.trim().isNotEmpty != true &&
        values[_commentSupportContactUrlKey]?.trim().isNotEmpty != true) {
      throw BuildConfigurationException('Comments require $_supportUrlKey.');
    }
    final accountDeletionUri = _parseUri(
      _value(
        values,
        _accountDeletionUrlKey,
        fallback: publicSiteOriginUri.resolve('/account-deletion').toString(),
      ),
      key: _accountDeletionUrlKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    final appLinkOriginUri = _parseUri(
      _value(
        values,
        _appLinkOriginKey,
        fallback: publicSiteOriginUri.toString(),
      ),
      key: _appLinkOriginKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    _validateOrigin(
      appLinkOriginUri,
      _appLinkOriginKey,
      environment: environment,
    );
    final telemetryEndpointValue = environment.isProductionLike
        ? _requiredValue(values, _telemetryEndpointKey)
        : values[_telemetryEndpointKey];
    final telemetryEndpointUri = _optionalUri(
      telemetryEndpointValue,
      key: _telemetryEndpointKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    for (final entry in {
      _supportUrlKey: supportUri,
      _accountDeletionUrlKey: accountDeletionUri,
    }.entries) {
      _validatePublicPageUri(entry.value, entry.key, environment: environment);
      if (environment.isProductionLike || features.comments) {
        _rejectPlaceholder(entry.value.host, entry.key);
      }
    }
    if (environment.isProductionLike) {
      _rejectPlaceholder(appLinkOriginUri.host, _appLinkOriginKey);
    }
    if (telemetryEndpointUri != null) {
      _validateTelemetryEndpointUri(
        telemetryEndpointUri,
        _telemetryEndpointKey,
        environment: environment,
      );
      if (environment.isProductionLike) {
        _rejectPlaceholder(telemetryEndpointUri.host, _telemetryEndpointKey);
      }
    }

    return AppBuildConfig._(
      environment: environment,
      apiBaseUri: apiBaseUri,
      fulltextPolicy: fulltextPolicy,
      termsDocumentVersion: termsDocumentVersion,
      communityGuidelinesDocumentVersion: communityGuidelinesDocumentVersion,
      features: features,
      oidcIssuerUri: oidcIssuerUri,
      oidcClientId: oidcClientId?.isEmpty == true ? null : oidcClientId,
      oidcRedirectUri: oidcRedirectUri,
      oidcPostLogoutRedirectUri: oidcPostLogoutRedirectUri,
      oidcScopes: oidcScopes,
      commentSupportContactUri: supportUri,
      publicSiteOriginUri: publicSiteOriginUri,
      supportUri: supportUri,
      accountDeletionUri: accountDeletionUri,
      appLinkOriginUri: appLinkOriginUri,
      telemetryEndpointUri: telemetryEndpointUri,
    );
  }

  final AppEnvironment environment;
  final Uri apiBaseUri;
  final String fulltextPolicy;
  final String termsDocumentVersion;
  final String communityGuidelinesDocumentVersion;
  final FeatureFlags features;
  final Uri? oidcIssuerUri;
  final String? oidcClientId;
  final Uri? oidcRedirectUri;
  final Uri? oidcPostLogoutRedirectUri;
  final List<String> oidcScopes;
  final Uri? commentSupportContactUri;
  final Uri publicSiteOriginUri;
  final Uri supportUri;
  final Uri accountDeletionUri;
  final Uri appLinkOriginUri;
  final Uri? telemetryEndpointUri;

  Uri legalUri(String path) => publicSiteOriginUri.resolve(path);

  /// Fails closed when Flutter's native build flavor and the Dart environment
  /// file do not describe the same deployable application.
  ///
  /// Native bundle IDs, callback registrations, and transport policy come from
  /// `--flavor`, while API/OIDC endpoints and feature flags come from Dart
  /// defines. Accepting a missing or mismatched flavor would allow a correctly
  /// signed production identity to run the wrong environment configuration.
  void requireMatchingNativeFlavor(String? nativeFlavor) {
    final expected = switch (environment) {
      AppEnvironment.development => 'dev',
      AppEnvironment.staging => 'staging',
      AppEnvironment.production => 'prod',
    };
    if (nativeFlavor != expected) {
      throw BuildConfigurationException(
        'Native flavor must be $expected for the configured environment.',
      );
    }
  }

  static String _value(
    Map<String, String> values,
    String key, {
    required String fallback,
  }) {
    final value = values[key]?.trim();
    return value == null || value.isEmpty ? fallback : value;
  }

  static String _requiredValue(Map<String, String> values, String key) {
    final value = values[key]?.trim();
    if (value == null || value.isEmpty) {
      throw BuildConfigurationException('$key is required for this build.');
    }
    return value;
  }

  static bool _parseBool(Map<String, String> values, String key) {
    return switch (values[key]?.trim().toLowerCase() ?? 'false') {
      'true' => true,
      'false' || '' => false,
      _ => throw BuildConfigurationException('$key must be true or false.'),
    };
  }

  static String _parseDocumentVersion(String value, String key) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) {
      throw BuildConfigurationException('$key must be an ISO calendar date.');
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime.utc(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      throw BuildConfigurationException('$key must be an ISO calendar date.');
    }
    return value;
  }

  static Uri? _optionalUri(
    String? value, {
    required String key,
    required bool requireHttps,
    required bool allowCustomScheme,
  }) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return _parseUri(
      trimmed,
      key: key,
      requireHttps: requireHttps,
      allowCustomScheme: allowCustomScheme,
    );
  }

  static Uri _parseUri(
    String value, {
    required String key,
    required bool requireHttps,
    required bool allowCustomScheme,
  }) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme.isEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw BuildConfigurationException('$key must be an absolute safe URI.');
    }
    if (!allowCustomScheme && !uri.hasAuthority) {
      throw BuildConfigurationException('$key must include a host.');
    }
    if (requireHttps && uri.scheme.toLowerCase() != 'https') {
      throw BuildConfigurationException('$key must use HTTPS.');
    }
    if (!allowCustomScheme &&
        uri.scheme.toLowerCase() != 'http' &&
        uri.scheme.toLowerCase() != 'https') {
      throw BuildConfigurationException('$key must use HTTP or HTTPS.');
    }
    return uri;
  }

  static void _validateApiUri(Uri uri, AppEnvironment environment) {
    if (uri.query.isNotEmpty) {
      throw BuildConfigurationException(
        '$_apiBaseUrlKey must not include a query string.',
      );
    }
    if (environment.isProductionLike) {
      _rejectPlaceholder(uri.host, _apiBaseUrlKey);
      final host = uri.host.toLowerCase();
      if (host == 'localhost' ||
          host.endsWith('.localhost') ||
          host == '127.0.0.1' ||
          host == '::1') {
        throw BuildConfigurationException(
          'Staging and production API URLs cannot use a loopback host.',
        );
      }
    }
  }

  static void _validateOidcIssuerUri(Uri uri, AppEnvironment environment) {
    if (uri.query.isNotEmpty) {
      throw BuildConfigurationException(
        '$_oidcIssuerUrlKey must not include a query string.',
      );
    }
    final host = uri.host.toLowerCase();
    final loopback =
        host == 'localhost' || host == '127.0.0.1' || host == '::1';
    if (environment.isProductionLike && loopback) {
      throw BuildConfigurationException(
        '$_oidcIssuerUrlKey cannot use loopback outside development.',
      );
    }
    if (uri.scheme.toLowerCase() == 'https') return;
    if (environment != AppEnvironment.development ||
        uri.scheme.toLowerCase() != 'http' ||
        !loopback) {
      throw BuildConfigurationException(
        '$_oidcIssuerUrlKey may use HTTP only on development loopback.',
      );
    }
  }

  static void _validateNativeRedirectUri(
    Uri uri, {
    required String key,
    required AppEnvironment environment,
  }) {
    final scheme = uri.scheme.toLowerCase();
    final allowedSchemes = switch (environment) {
      AppEnvironment.development => const {'pakperk-auth-dev'},
      AppEnvironment.staging => const {'pakperk-auth-staging'},
      AppEnvironment.production => const {'pakperk-auth'},
    };
    if (!allowedSchemes.contains(scheme)) {
      throw BuildConfigurationException(
        '$key must use this flavor\'s dedicated auth callback scheme.',
      );
    }
    if (!uri.hasAuthority || uri.authority != 'oauth' || uri.hasPort) {
      throw BuildConfigurationException(
        '$key must use the oauth callback host.',
      );
    }
    if (uri.query.isNotEmpty) {
      throw BuildConfigurationException(
        '$key must not include a query string.',
      );
    }
    final expectedPath = key == _oidcRedirectUriKey ? '/callback' : '/logout';
    if (uri.path != expectedPath) {
      throw BuildConfigurationException('$key must end in $expectedPath.');
    }
  }

  static void _validateOrigin(
    Uri uri,
    String key, {
    required AppEnvironment environment,
  }) {
    if (uri.path.isNotEmpty && uri.path != '/' ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw BuildConfigurationException(
        '$key must be an origin without a path.',
      );
    }
    _validatePublicScheme(uri, key, environment);
  }

  static void _validatePublicPageUri(
    Uri uri,
    String key, {
    required AppEnvironment environment,
  }) {
    _validatePublicScheme(uri, key, environment);
    if (uri.query.isNotEmpty || uri.path.isEmpty) {
      throw BuildConfigurationException(
        '$key must be an absolute page URL without a query.',
      );
    }
  }

  static void _validateTelemetryEndpointUri(
    Uri uri,
    String key, {
    required AppEnvironment environment,
  }) {
    _validatePublicScheme(uri, key, environment);
    if (uri.path != '/v1/logs' ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw BuildConfigurationException(
        '$key must use the exact OTLP/HTTP logs path /v1/logs.',
      );
    }
  }

  static void _validatePublicScheme(
    Uri uri,
    String key,
    AppEnvironment environment,
  ) {
    if (uri.scheme.toLowerCase() == 'https') return;
    final host = uri.host.toLowerCase();
    final loopback =
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '127.0.0.1' ||
        host == '::1';
    if (environment != AppEnvironment.development ||
        uri.scheme.toLowerCase() != 'http' ||
        !loopback) {
      throw BuildConfigurationException(
        '$key may use HTTP only on development loopback.',
      );
    }
  }

  static List<String> _parseOidcScopes(String value) {
    final scopes = value
        .split(RegExp(r'[\s,]+'))
        .map((scope) => scope.trim().toLowerCase())
        .where((scope) => scope.isNotEmpty)
        .toSet();
    if (scopes.length != 2 ||
        !scopes.contains('openid') ||
        !scopes.contains('profile')) {
      throw const BuildConfigurationException(
        'PAKPERK_OIDC_SCOPES must be openid profile.',
      );
    }
    return List.unmodifiable(scopes);
  }

  static void _rejectBundledSecrets(Map<String, String> values) {
    const forbidden = {
      'PAKPERK_OIDC_CLIENT_SECRET',
      'PAKPERK_API_SECRET',
      'PAKPERK_LLM_API_KEY',
    };
    for (final key in forbidden) {
      if (values[key]?.trim().isNotEmpty == true) {
        throw BuildConfigurationException(
          '$key must never be compiled into the mobile application.',
        );
      }
    }
  }

  static void _rejectPlaceholder(String value, String key) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized.contains('changeme') ||
        normalized.contains('placeholder') ||
        normalized == 'example.com' ||
        normalized.endsWith('.example.com') ||
        normalized.endsWith('.example') ||
        normalized.endsWith('.invalid')) {
      throw BuildConfigurationException('$key contains a placeholder value.');
    }
  }
}

class BuildConfigurationException implements Exception {
  const BuildConfigurationException(this.message);

  final String message;

  @override
  String toString() => 'BuildConfigurationException: $message';
}
