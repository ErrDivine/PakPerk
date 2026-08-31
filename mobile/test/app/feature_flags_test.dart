import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';

void main() {
  group('AppBuildConfig', () {
    test(
      'development defaults preserve the current disabled feature surface',
      () {
        final config = AppBuildConfig.fromValues(const {});

        expect(config.environment, AppEnvironment.development);
        expect(config.apiBaseUri, Uri.parse('http://localhost:8080'));
        expect(config.publicSiteOriginUri, Uri.parse('http://localhost:3000'));
        expect(config.supportUri, Uri.parse('http://localhost:3000/support'));
        expect(
          config.accountDeletionUri,
          Uri.parse('http://localhost:3000/account-deletion'),
        );
        expect(config.appLinkOriginUri, Uri.parse('http://localhost:3000'));
        expect(
          {
            config.apiBaseUri.host,
            config.publicSiteOriginUri.host,
            config.supportUri.host,
            config.accountDeletionUri.host,
          },
          isNot(contains('pakperk.app')),
          reason: 'a zero-config debug build must not contact production',
        );
        expect(config.fulltextPolicy, 'prototype');
        expect(config.termsDocumentVersion, bundledTermsDocumentVersion);
        expect(
          config.communityGuidelinesDocumentVersion,
          bundledCommunityGuidelinesDocumentVersion,
        );
        expect(config.features, const FeatureFlags.disabled());
      },
    );

    test('policy versions are valid dates bound to bundled documents', () {
      for (final version in ['2026-02-30', '2026-7-31', 'release-latest']) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_TERMS_DOCUMENT_VERSION': version,
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: version,
        );
      }
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_TERMS_DOCUMENT_VERSION': '2026-08-01',
          'PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION': '2026-08-01',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
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
        'PAKPERK_PAPER_TITLE_SEARCH_ENABLED': 'true',
        'PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED': 'true',
        'PAKPERK_READING_FEED_ENABLED': 'true',
        'PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED': 'true',
        'PAKPERK_RECOMMENDATIONS_ENABLED': 'true',
        'PAKPERK_RECOMMENDATION_EVENTS_ENABLED': 'true',
        'PAKPERK_LIBRARY_V2_ENABLED': 'true',
        'PAKPERK_SEARCH_LOOKUP_ENABLED': 'true',
        'PAKPERK_SEARCH_EXPLORE_ENABLED': 'true',
        'PAKPERK_SAVED_QUERIES_ENABLED': 'true',
        'PAKPERK_RESEARCH_PROFILES_ENABLED': 'true',
        'PAKPERK_READING_BRIEFS_ENABLED': 'true',
        'PAKPERK_SUBSCRIPTIONS_ENABLED': 'true',
        'PAKPERK_NOTIFICATIONS_ENABLED': 'true',
        'PAKPERK_OIDC_ISSUER_URL': 'https://identity.pakperk.app/realms/app',
        'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-prod',
        'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth://oauth/callback',
        'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI': 'pakperk-auth://oauth/logout',
        'PAKPERK_COMMENT_SUPPORT_CONTACT_URL': 'https://pakperk.app/support',
        'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://pakperk.app',
        'PAKPERK_TELEMETRY_ENDPOINT': 'https://telemetry.pakperk.app/v1/logs',
      });

      expect(config.environment, AppEnvironment.production);
      expect(config.features.accounts, isTrue);
      expect(config.features.library, isTrue);
      expect(config.features.comments, isTrue);
      expect(config.features.openingMotion, isTrue);
      expect(config.features.paperTitleSearch, isTrue);
      expect(config.features.libraryImportWrites, isTrue);
      expect(config.features.readingFeed, isTrue);
      expect(config.features.toReadFirstEnforcement, isTrue);
      expect(config.features.recommendationsEnabled, isTrue);
      expect(config.features.recommendationEventsEnabled, isTrue);
      expect(config.features.libraryV2Enabled, isTrue);
      expect(config.features.searchLookupEnabled, isTrue);
      expect(config.features.searchExploreEnabled, isTrue);
      expect(config.features.savedQueriesEnabled, isTrue);
      expect(config.features.researchProfilesEnabled, isTrue);
      expect(config.features.readingBriefsEnabled, isTrue);
      expect(config.features.subscriptionsEnabled, isTrue);
      expect(config.features.notificationsEnabled, isTrue);
      expect(config.oidcClientId, 'pakperk-mobile-prod');
      expect(config.oidcScopes, ['openid', 'profile']);
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

    test('public HTTP endpoints are restricted to development loopback', () {
      for (final values in [
        const {'PAKPERK_PUBLIC_SITE_ORIGIN': 'http://pakperk.app'},
        const {'PAKPERK_SUPPORT_URL': 'http://192.168.1.20:3000/support'},
        const {
          'PAKPERK_ACCOUNT_DELETION_URL':
              'http://dev.internal/account-deletion',
        },
        const {'PAKPERK_APP_LINK_ORIGIN': 'http://dev.internal'},
      ]) {
        expect(
          () => AppBuildConfig.fromValues(values),
          throwsA(isA<BuildConfigurationException>()),
          reason: values.toString(),
        );
      }
    });

    test('staging uses staging public URLs and dedicated auth scheme', () {
      final config = AppBuildConfig.fromValues(const {
        'PAKPERK_ENV': 'staging',
        'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
        'PAKPERK_ACCOUNTS_ENABLED': 'true',
        'PAKPERK_OIDC_ISSUER_URL':
            'https://identity.staging.pakperk.app/realms/app',
        'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-staging',
        'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-staging://oauth/callback',
        'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
            'pakperk-auth-staging://oauth/logout',
        'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://staging.pakperk.app',
        'PAKPERK_TELEMETRY_ENDPOINT':
            'https://telemetry.staging.pakperk.app/v1/logs',
      });

      expect(
        config.publicSiteOriginUri,
        Uri.parse('https://staging.pakperk.app'),
      );
      expect(config.oidcRedirectUri!.scheme, 'pakperk-auth-staging');
    });

    test('native build flavor must exactly match the Dart environment', () {
      final configs = <({AppBuildConfig config, String flavor})>[
        (config: AppBuildConfig.fromValues(const {}), flavor: 'dev'),
        (
          config: AppBuildConfig.fromValues(const {
            'PAKPERK_ENV': 'staging',
            'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
            'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://staging.pakperk.app',
            'PAKPERK_TELEMETRY_ENDPOINT':
                'https://telemetry.staging.pakperk.app/v1/logs',
          }),
          flavor: 'staging',
        ),
        (
          config: AppBuildConfig.fromValues(const {
            'PAKPERK_ENV': 'production',
            'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
            'PAKPERK_FULLTEXT_POLICY': 'strict',
            'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://pakperk.app',
            'PAKPERK_TELEMETRY_ENDPOINT':
                'https://telemetry.pakperk.app/v1/logs',
          }),
          flavor: 'prod',
        ),
      ];

      for (final entry in configs) {
        expect(
          () => entry.config.requireMatchingNativeFlavor(entry.flavor),
          returnsNormally,
          reason: entry.flavor,
        );
        for (final wrongFlavor in <String?>{
          null,
          'development',
          'dev',
          'staging',
          'prod',
        }..remove(entry.flavor)) {
          expect(
            () => entry.config.requireMatchingNativeFlavor(wrongFlavor),
            throwsA(isA<BuildConfigurationException>()),
            reason: '${entry.flavor} must reject $wrongFlavor',
          );
        }
      }
    });

    test(
      'staging and production require deployment-owned public telemetry URLs',
      () {
        for (final values in [
          const {
            'PAKPERK_ENV': 'staging',
            'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
          },
          const {
            'PAKPERK_ENV': 'production',
            'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
            'PAKPERK_FULLTEXT_POLICY': 'strict',
            'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://pakperk.app',
          },
        ]) {
          expect(
            () => AppBuildConfig.fromValues(values),
            throwsA(isA<BuildConfigurationException>()),
            reason: values.toString(),
          );
        }
      },
    );

    test('telemetry requires the exact OTLP logs path', () {
      for (final endpoint in [
        'https://telemetry.pakperk.app',
        'https://telemetry.pakperk.app/v1/traces',
        'https://telemetry.pakperk.app/v1/logs/',
        'https://telemetry.pakperk.app/v1/logs?tenant=prod',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_ENV': 'production',
            'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
            'PAKPERK_FULLTEXT_POLICY': 'strict',
            'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://pakperk.app',
            'PAKPERK_TELEMETRY_ENDPOINT': endpoint,
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: endpoint,
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
      for (final key in <String>[
        'PAKPERK_PAPER_TITLE_SEARCH_ENABLED',
        'PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED',
        'PAKPERK_READING_FEED_ENABLED',
        'PAKPERK_RECOMMENDATIONS_ENABLED',
        'PAKPERK_LIBRARY_V2_ENABLED',
        'PAKPERK_SAVED_QUERIES_ENABLED',
        'PAKPERK_RESEARCH_PROFILES_ENABLED',
        'PAKPERK_READING_BRIEFS_ENABLED',
        'PAKPERK_SUBSCRIPTIONS_ENABLED',
        'PAKPERK_NOTIFICATIONS_ENABLED',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({key: 'true'}),
          throwsA(isA<BuildConfigurationException>()),
          reason: key,
        );
      }
    });

    test('To Read First feature dependencies fail closed', () {
      const accountValues = <String, String>{
        'PAKPERK_ACCOUNTS_ENABLED': 'true',
        'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
        'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
        'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
        'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
            'pakperk-auth-dev://oauth/logout',
      };
      final search = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_PAPER_TITLE_SEARCH_ENABLED': 'true',
      });
      expect(search.features.paperTitleSearch, isTrue);

      expect(
        () => AppBuildConfig.fromValues({
          ...accountValues,
          'PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues({
          ...accountValues,
          'PAKPERK_READING_FEED_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues({
          ...accountValues,
          'PAKPERK_LIBRARY_ENABLED': 'true',
          'PAKPERK_RECOMMENDATIONS_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );

      final recommendations = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_READING_FEED_ENABLED': 'true',
        'PAKPERK_RECOMMENDATIONS_ENABLED': 'true',
      });
      expect(recommendations.features.recommendationsEnabled, isTrue);
      expect(recommendations.features.recommendationEventsEnabled, isFalse);

      final independentEvents = AppBuildConfig.fromValues(const {
        'PAKPERK_RECOMMENDATION_EVENTS_ENABLED': 'true',
      });
      expect(independentEvents.features.recommendationEventsEnabled, isTrue);
      expect(independentEvents.features.recommendationsEnabled, isFalse);

      final recommendationEvents = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_READING_FEED_ENABLED': 'true',
        'PAKPERK_RECOMMENDATIONS_ENABLED': 'true',
        'PAKPERK_RECOMMENDATION_EVENTS_ENABLED': 'true',
      });
      expect(recommendationEvents.features.recommendationEventsEnabled, isTrue);

      final libraryV2 = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_LIBRARY_V2_ENABLED': 'true',
      });
      expect(libraryV2.features.libraryV2Enabled, isTrue);

      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_SEARCH_EXPLORE_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      final publicSearch = AppBuildConfig.fromValues(const {
        'PAKPERK_SEARCH_LOOKUP_ENABLED': 'true',
        'PAKPERK_SEARCH_EXPLORE_ENABLED': 'true',
      });
      expect(publicSearch.features.searchLookupEnabled, isTrue);
      expect(publicSearch.features.searchExploreEnabled, isTrue);
      expect(publicSearch.features.savedQueriesEnabled, isFalse);
      final savedQueries = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_SEARCH_LOOKUP_ENABLED': 'true',
        'PAKPERK_SEARCH_EXPLORE_ENABLED': 'true',
        'PAKPERK_SAVED_QUERIES_ENABLED': 'true',
        'PAKPERK_RESEARCH_PROFILES_ENABLED': 'true',
      });
      expect(savedQueries.features.savedQueriesEnabled, isTrue);
      expect(savedQueries.features.researchProfilesEnabled, isTrue);

      expect(
        () => AppBuildConfig.fromValues({
          ...accountValues,
          'PAKPERK_LIBRARY_ENABLED': 'true',
          'PAKPERK_READING_FEED_ENABLED': 'true',
          'PAKPERK_NOTIFICATIONS_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      final engagement = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_READING_FEED_ENABLED': 'true',
        'PAKPERK_READING_BRIEFS_ENABLED': 'true',
        'PAKPERK_SUBSCRIPTIONS_ENABLED': 'true',
        'PAKPERK_NOTIFICATIONS_ENABLED': 'true',
      });
      expect(engagement.features.readingBriefsEnabled, isTrue);
      expect(engagement.features.subscriptionsEnabled, isTrue);
      expect(engagement.features.notificationsEnabled, isTrue);
    });

    test('enabled accounts require the complete native OIDC configuration', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('native redirects reject unsafe or unowned schemes', () {
      for (final redirect in [
        'file:///tmp/callback',
        'data:text/plain,callback',
        'other-app://auth/callback',
        'pakperk://paper/callback',
        'pakperk-auth-dev://oauth/callback?forward=elsewhere',
        'pakperk-auth-dev://other/callback',
        'pakperk-auth-dev://oauth/wrong',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_ACCOUNTS_ENABLED': 'true',
            'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
            'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
            'PAKPERK_OIDC_REDIRECT_URI': redirect,
            'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
                'pakperk-auth-dev://oauth/logout',
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: redirect,
        );
      }
    });

    test('native auth redirects use the dedicated registered scheme', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ENV': 'staging',
          'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL':
              'https://identity.staging.pakperk.app/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-staging',
          'PAKPERK_OIDC_REDIRECT_URI': 'https://identity.pakperk.app/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth-staging://oauth/logout',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('development OIDC HTTP is restricted to loopback', () {
      for (final issuer in [
        'http://identity.internal/realms/app',
        'http://192.168.1.20:8081/realms/app',
        'http://keycloak:8080/realms/app',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({
            'PAKPERK_ACCOUNTS_ENABLED': 'true',
            'PAKPERK_OIDC_ISSUER_URL': issuer,
            'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
            'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
            'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
                'pakperk-auth-dev://oauth/logout',
          }),
          throwsA(isA<BuildConfigurationException>()),
          reason: issuer,
        );
      }
    });

    test('production-like OIDC issuers reject loopback even over HTTPS', () {
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_ENV': 'staging',
          'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'https://localhost:8081/realms/pakperk',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-staging',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-staging://oauth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth-staging://oauth/logout',
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
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth-dev://oauth/logout',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('rejects callback schemes owned by another flavor', () {
      for (final values in [
        const {
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth://oauth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth://oauth/logout',
        },
        const {
          'PAKPERK_ENV': 'staging',
          'PAKPERK_API_BASE_URL': 'https://api.staging.pakperk.app',
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL':
              'https://identity.staging.pakperk.app/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-staging',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth-dev://oauth/logout',
          'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://staging.pakperk.app',
          'PAKPERK_TELEMETRY_ENDPOINT':
              'https://telemetry.staging.pakperk.app/v1/logs',
        },
        const {
          'PAKPERK_ENV': 'production',
          'PAKPERK_API_BASE_URL': 'https://api.pakperk.app',
          'PAKPERK_FULLTEXT_POLICY': 'strict',
          'PAKPERK_ACCOUNTS_ENABLED': 'true',
          'PAKPERK_OIDC_ISSUER_URL': 'https://identity.pakperk.app/realms/app',
          'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-prod',
          'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-staging://oauth/callback',
          'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
              'pakperk-auth-staging://oauth/logout',
          'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://pakperk.app',
          'PAKPERK_TELEMETRY_ENDPOINT': 'https://telemetry.pakperk.app/v1/logs',
        },
      ]) {
        expect(
          () => AppBuildConfig.fromValues(values),
          throwsA(isA<BuildConfigurationException>()),
          reason: values['PAKPERK_ENV'] ?? 'development',
        );
      }
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
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_RECOMMENDATION_EVENTS_ENABLED': 'yes',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
    });

    test('feature equality includes the independent event rollout gate', () {
      const base = FeatureFlags(
        accounts: true,
        library: true,
        comments: false,
        openingMotion: false,
        recommendationsEnabled: true,
      );
      const events = FeatureFlags(
        accounts: true,
        library: true,
        comments: false,
        openingMotion: false,
        recommendationsEnabled: true,
        recommendationEventsEnabled: true,
      );
      expect(base, isNot(events));
    });

    test('Plan 03 flags default off and validate their dependency chain', () {
      const accountValues = <String, String>{
        'PAKPERK_ACCOUNTS_ENABLED': 'true',
        'PAKPERK_OIDC_ISSUER_URL': 'http://localhost:8081/realms/app',
        'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile-dev',
        'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
        'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI':
            'pakperk-auth-dev://oauth/logout',
      };
      final defaults = AppBuildConfig.fromValues(const {});
      expect(defaults.features.deepReader, isFalse);
      expect(defaults.features.paperPassport, isFalse);
      expect(defaults.features.semanticFacets, isFalse);
      expect(defaults.features.documentVisualObjects, isFalse);
      expect(defaults.features.readingCheckpoints, isFalse);
      expect(defaults.features.annotations, isFalse);
      expect(defaults.features.evidenceCards, isFalse);
      expect(defaults.features.researchMemory, isFalse);
      expect(defaults.features.versionDiff, isFalse);
      expect(defaults.features.assistantV2, isFalse);

      expect(
        () => AppBuildConfig.fromValues({
          ...accountValues,
          'PAKPERK_DEEP_READER_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      expect(
        () => AppBuildConfig.fromValues(const {
          'PAKPERK_PAPER_PASSPORT_ENABLED': 'true',
        }),
        throwsA(isA<BuildConfigurationException>()),
      );
      for (final key in const [
        'PAKPERK_SEMANTIC_FACETS_ENABLED',
        'PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED',
        'PAKPERK_READING_CHECKPOINTS_ENABLED',
        'PAKPERK_ANNOTATIONS_ENABLED',
        'PAKPERK_EVIDENCE_CARDS_ENABLED',
        'PAKPERK_RESEARCH_MEMORY_ENABLED',
        'PAKPERK_VERSION_DIFF_ENABLED',
        'PAKPERK_ASSISTANT_V2_ENABLED',
      ]) {
        expect(
          () => AppBuildConfig.fromValues({key: 'true'}),
          throwsA(isA<BuildConfigurationException>()),
          reason: key,
        );
      }

      final enabled = AppBuildConfig.fromValues({
        ...accountValues,
        'PAKPERK_LIBRARY_ENABLED': 'true',
        'PAKPERK_READING_FEED_ENABLED': 'true',
        'PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED': 'true',
        'PAKPERK_DEEP_READER_ENABLED': 'true',
        'PAKPERK_PAPER_PASSPORT_ENABLED': 'true',
        'PAKPERK_SEMANTIC_FACETS_ENABLED': 'true',
        'PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED': 'true',
        'PAKPERK_READING_CHECKPOINTS_ENABLED': 'true',
        'PAKPERK_ANNOTATIONS_ENABLED': 'true',
        'PAKPERK_EVIDENCE_CARDS_ENABLED': 'true',
        'PAKPERK_RESEARCH_MEMORY_ENABLED': 'true',
        'PAKPERK_VERSION_DIFF_ENABLED': 'true',
        'PAKPERK_ASSISTANT_V2_ENABLED': 'true',
      });
      expect(enabled.features.deepReader, isTrue);
      expect(enabled.features.paperPassport, isTrue);
      expect(enabled.features.semanticFacets, isTrue);
      expect(enabled.features.documentVisualObjects, isTrue);
      expect(enabled.features.readingCheckpoints, isTrue);
      expect(enabled.features.annotations, isTrue);
      expect(enabled.features.evidenceCards, isTrue);
      expect(enabled.features.researchMemory, isTrue);
      expect(enabled.features.versionDiff, isTrue);
      expect(enabled.features.assistantV2, isTrue);
    });

    test('OIDC scopes are exactly openid and profile', () {
      for (final scopes in ['profile', 'openid', 'openid profile email']) {
        expect(
          () => AppBuildConfig.fromValues({'PAKPERK_OIDC_SCOPES': scopes}),
          throwsA(isA<BuildConfigurationException>()),
          reason: scopes,
        );
      }
    });
  });
}
