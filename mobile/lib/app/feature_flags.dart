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
    required this.features,
    required this.oidcIssuerUri,
    required this.oidcClientId,
    required this.oidcRedirectUri,
    required this.oidcPostLogoutRedirectUri,
    required this.commentSupportContactUri,
  });

  static const _environmentKey = 'PAKPERK_ENV';
  static const _apiBaseUrlKey = 'PAKPERK_API_BASE_URL';
  static const _fulltextPolicyKey = 'PAKPERK_FULLTEXT_POLICY';
  static const _accountsEnabledKey = 'PAKPERK_ACCOUNTS_ENABLED';
  static const _libraryEnabledKey = 'PAKPERK_LIBRARY_ENABLED';
  static const _commentsEnabledKey = 'PAKPERK_COMMENTS_ENABLED';
  static const _openingMotionEnabledKey = 'PAKPERK_OPENING_MOTION_ENABLED';
  static const _oidcIssuerUrlKey = 'PAKPERK_OIDC_ISSUER_URL';
  static const _oidcClientIdKey = 'PAKPERK_OIDC_CLIENT_ID';
  static const _oidcRedirectUriKey = 'PAKPERK_OIDC_REDIRECT_URI';
  static const _oidcPostLogoutRedirectUriKey =
      'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI';
  static const _commentSupportContactUrlKey =
      'PAKPERK_COMMENT_SUPPORT_CONTACT_URL';

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
    _commentSupportContactUrlKey: const String.fromEnvironment(
      _commentSupportContactUrlKey,
    ),
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

    final commentSupportContactUri = _optionalUri(
      values[_commentSupportContactUrlKey],
      key: _commentSupportContactUrlKey,
      requireHttps: environment.isProductionLike,
      allowCustomScheme: false,
    );
    if (features.comments) {
      if (commentSupportContactUri == null) {
        throw BuildConfigurationException(
          'Comments require $_commentSupportContactUrlKey.',
        );
      }
      _rejectPlaceholder(
        commentSupportContactUri.host,
        _commentSupportContactUrlKey,
      );
    }

    return AppBuildConfig._(
      environment: environment,
      apiBaseUri: apiBaseUri,
      fulltextPolicy: fulltextPolicy,
      features: features,
      oidcIssuerUri: oidcIssuerUri,
      oidcClientId: oidcClientId?.isEmpty == true ? null : oidcClientId,
      oidcRedirectUri: oidcRedirectUri,
      oidcPostLogoutRedirectUri: oidcPostLogoutRedirectUri,
      commentSupportContactUri: commentSupportContactUri,
    );
  }

  final AppEnvironment environment;
  final Uri apiBaseUri;
  final String fulltextPolicy;
  final FeatureFlags features;
  final Uri? oidcIssuerUri;
  final String? oidcClientId;
  final Uri? oidcRedirectUri;
  final Uri? oidcPostLogoutRedirectUri;
  final Uri? commentSupportContactUri;

  static String _value(
    Map<String, String> values,
    String key, {
    required String fallback,
  }) {
    final value = values[key]?.trim();
    return value == null || value.isEmpty ? fallback : value;
  }

  static bool _parseBool(Map<String, String> values, String key) {
    return switch (values[key]?.trim().toLowerCase() ?? 'false') {
      'true' => true,
      'false' || '' => false,
      _ => throw BuildConfigurationException('$key must be true or false.'),
    };
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

  static void _validateNativeRedirectUri(
    Uri uri, {
    required String key,
    required AppEnvironment environment,
  }) {
    final scheme = uri.scheme.toLowerCase();
    final isPakPerkScheme =
        scheme == 'pakperk' || scheme.startsWith('pakperk-');
    final isUniversalLink = scheme == 'https';
    if (!isPakPerkScheme && !isUniversalLink) {
      throw BuildConfigurationException(
        '$key must use an app-owned pakperk scheme or HTTPS universal link.',
      );
    }
    if (!uri.hasAuthority || uri.host.isEmpty) {
      throw BuildConfigurationException('$key must include a callback host.');
    }
    if (uri.query.isNotEmpty) {
      throw BuildConfigurationException(
        '$key must not include a query string.',
      );
    }
    if (environment.isProductionLike && isUniversalLink) {
      _rejectPlaceholder(uri.host, key);
      final host = uri.host.toLowerCase();
      if (host == 'localhost' ||
          host.endsWith('.localhost') ||
          host == '127.0.0.1' ||
          host == '::1') {
        throw BuildConfigurationException(
          '$key cannot use a loopback universal-link host outside development.',
        );
      }
    }
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
