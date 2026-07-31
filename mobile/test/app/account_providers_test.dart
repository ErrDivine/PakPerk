import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/providers.dart';

import '../core/auth/auth_fakes.dart';
import '../support/fakes.dart';

void main() {
  test('disabled accounts keep one anonymous transport without auth', () async {
    final delegate = _StartupDelegate();
    final store = MemoryLocalStore();
    final container = ProviderContainer(
      overrides: [
        appBuildConfigProvider.overrideWithValue(
          AppBuildConfig.fromValues(const {}),
        ),
        localStoreProvider.overrideWithValue(store),
        initialAnonymousSessionIdProvider.overrideWithValue(
          await store.getOrCreateSessionId(),
        ),
        ...accountApplicationOverrides(delegate),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(startupBootstrapperProvider), same(delegate));
    final dio = container.read(pakPerkDioProvider);
    final adapter = _AccountAdapter();
    dio.httpClientAdapter = adapter;
    expect(dio.interceptors.whereType<AuthInterceptor>(), isEmpty);

    final firstClient = container.read(apiClientProvider);
    await firstClient.ready();
    await container.read(anonymousSessionIdProvider.notifier).rotate();
    final secondClient = container.read(apiClientProvider);
    await secondClient.ready();

    expect(secondClient, isNot(same(firstClient)));
    expect(container.read(pakPerkDioProvider), same(dio));
    expect(adapter.paths, ['/health/ready', '/health/ready']);
  });

  test(
    'startup inspects locally then restores and loads account post-ready',
    () async {
      const accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
      final delegate = _StartupDelegate();
      final oidc = FakeOidcClient();
      final tokens = MemorySecureTokenStore(storedRecord(accountId: accountId));
      final store = MemoryLocalStore();
      final container = ProviderContainer(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountConfig()),
          localStoreProvider.overrideWithValue(store),
          initialAnonymousSessionIdProvider.overrideWithValue(
            await store.getOrCreateSessionId(),
          ),
          oidcClientProvider.overrideWithValue(oidc),
          secureTokenStoreProvider.overrideWithValue(tokens),
          ...accountApplicationOverrides(delegate),
        ],
      );
      addTearDown(container.dispose);
      final adapter = _AccountAdapter(accountId: accountId);
      final dio = container.read(pakPerkDioProvider)
        ..httpClientAdapter = adapter;
      expect(dio.interceptors.whereType<AuthInterceptor>(), hasLength(1));

      final startup = container.read(startupBootstrapperProvider);
      expect(
        await startup.checkAuthenticatedSession(),
        StartupSessionStatus.refreshRequired,
      );
      expect(oidc.refreshCalls, 0, reason: 'startup gate must remain local');
      expect(adapter.paths, isEmpty);

      await startup.runPostReadyWork();

      expect(delegate.postReadyCalls, 1);
      expect(oidc.refreshCalls, 1);
      expect(adapter.paths, ['/v1/me']);
      expect(container.read(authSessionProvider).isAuthenticated, isTrue);
      expect(container.read(currentAccountProvider).profile?.id, accountId);
      expect(tokens.record?.accountId, accountId);
    },
  );
}

AppBuildConfig _accountConfig() => AppBuildConfig.fromValues(const {
  'PAKPERK_ACCOUNTS_ENABLED': 'true',
  'PAKPERK_OIDC_ISSUER_URL': 'https://identity.example.test/realms/pakperk',
  'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile',
  'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth://oauth/callback',
  'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI': 'pakperk-auth://oauth/logout',
});

final class _StartupDelegate implements StartupBootstrapper {
  int postReadyCalls = 0;

  @override
  Future<void> hydrateLocalState() async {}

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() async =>
      StartupSessionStatus.anonymous;

  @override
  Future<void> repairLocalStatePreservingCredentials() async {}

  @override
  Future<void> runPostReadyWork() async {
    postReadyCalls += 1;
  }
}

final class _AccountAdapter implements HttpClientAdapter {
  _AccountAdapter({this.accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001'});

  final String accountId;
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (options.path == '/health/ready') {
      return ResponseBody.fromString('', 204);
    }
    return ResponseBody.fromString(
      jsonEncode({
        'account': {
          'id': accountId,
          'handle': 'ada_reader',
          'display_name': 'Ada',
          'status': 'active',
          'profile_version': 1,
          'profile_complete': true,
          'terms_version': '2026-07',
          'terms_accepted_at': '2026-07-30T12:00:00Z',
          'current_terms_version': '2026-07',
          'terms_current': true,
          'created_at': '2026-07-30T10:00:00Z',
          'updated_at': '2026-07-30T12:00:00Z',
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"profile-1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
