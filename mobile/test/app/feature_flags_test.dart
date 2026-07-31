import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';

void main() {
  group('AppBuildConfig', () {
    test('development defaults preserve the current disabled feature surface',
        () {
      final config = AppBuildConfig.fromValues(const {});

      expect(config.environment, AppEnvironment.development);
      expect(config.apiBaseUri, Uri.parse('http://localhost:8080'));
      expect(config.fulltextPolicy, 'prototype');
      expect(config.features, const FeatureFlags.disabled());
    });

    test('accepts a complete strict production configuration', () {
      final config = AppBuildConfig.fromValues(const {
        'PAKPERK_ENV': 'production',
        'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
        'PAKPERK_FULLTEXT_POLICY': 'strict',
        'PAKPERK_ACCOUNTS_ENABLED': 'true',
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_COMMENTS_ENABLED': 'true',
        'PAKPERK_OPENING_MOTION_ENABLED': 'true',
        'PAKPERK_OIDC_ISSUER_URL': 'https://identity.pakperk.app/realms/app',
        'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-prod',
        'PAKPERK_OIDC_REDIRECT_URI': 'pakperk://auth/callback',
        'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
            'pakperk://auth/logout-callback',
        'PAKPERK_COMMENT_SUPPORT_CONTACT_URL': 'https://pakperk.app/support',
      });

      expect(config.environment, AppEnvironment.production);
      expect(config.features.accounts, isTrue);
      expect(config.features.library, isTrue);
      expect(config.features.comments, isTrue);
      expect(config.features.openingMotion, isTrue);
      expect(config.oidcClientId, 'pakperk-mobile-prod');
    });

    test('production requires HTTPS and strict full-text policy', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ENV': 'production',
          'PAKPERK_API_BASE_URL': 'http://api.pakperk.app',
          'PAKPERK_FULLTEXT_POLICY': 'strict',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ENV': 'production',
          'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
          'PAKPERK_FULLTEXT_POLICY': 'prototype',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('production-like builds reject loopback and placeholder hosts', () {
      for (final url in [
        'https://localhost:8080',
        'https://api.example.com',
        'https://replace-me.invalid',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_ENV': 'staging',
            'PAKPERK_API_BASE_URL': url,
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: url,
        );
      }
    });

    test('account-owned features cannot be enabled without accounts', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_LIBRARY_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_COMMENTS_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('enabled accounts require the complete native OIDC configuration', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk://auth/callback',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('native redirects reject unsafe or unowned schemes', () {
      for (final redirect in [
        'file:///tmp/callback',
        'data:text/plain,callback',
        'other-app://auth/callback',
        'pakperk://auth/callback?forward=elsewhere',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_ACCOUNTS_ENABLED': 'true',
            'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
            'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
            'PAKPERK_OIDC_REDIRECT_URI': redirect,
            'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
                'pakperk://auth/logout-callback',
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: redirect,
        );
      }
    });

    test('staging universal-link redirects reject loopback hosts', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ENV': 'staging',
          'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL':
              'https://identity.staging.pakperk.app/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-staging',
          'PAKPERK_OIDC_REDIRECT_URI': 'https://localhost/auth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-staging://auth/logout-callback',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('enabled comments require a real support contact', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_COMMENTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk://auth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk://auth/logout-callback',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('rejects values that would bundle a secret in the app', () {
      for (final key in [
        'PAKPERK_OIDC_CLIENT_SECRET',
        'PAKPERK_API_SECRET',
        'PAKPERK_LLM_API_KEY',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({key: 'do-not-bundle'}),
          throwsA(isA<BuildConfigurationException>()),
          reason: key,
        );
      }
    });

    test('boolean flags reject ambiguous values', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ACCOUNTS_ENABLED': 'yes',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });
  });
}
