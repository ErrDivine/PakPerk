import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

import 'auth_fakes.dart';

void main() {
  final now = DateTime.utc(2030, 1, 1);

  AuthRepository repository({
    required FakeOidcClient oidc,
    required MemorySecureTokenStore store,
    Duration providerLogoutTimeout = const Duration(seconds: 5),
  }) => AuthRepository(
    configuration: testOidcConfiguration,
    oidcClient: oidc,
    secureTokenStore: store,
    clock: () => now,
    providerLogoutTimeout: providerLogoutTimeout,
  );

  test('interactive cancellation remains a clean guest session', () async {
    final oidc = FakeOidcClient()
      ..authorizeHandler = () async =>
          throw const OidcClientException.cancelled();
    final store = MemorySecureTokenStore(storedRecord());
    final auth = repository(oidc: oidc, store: store);

    await expectLater(
      auth.signIn(),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.kind,
          'kind',
          AuthFailureKind.cancelled,
        ),
      ),
    );

    expect(store.record, isNull);
    expect(auth.hasStoredSessionInMemory, isFalse);
  });

  test(
    'access bearer is memory-only while refresh metadata is durable',
    () async {
      const accessSecret = 'access-secret-never-persist';
      const refreshSecret = 'refresh-secret-durable';
      const idSecret = 'id-secret-hint';
      final oidc = FakeOidcClient()
        ..authorizeHandler = () async => tokenSet(
          accessToken: accessSecret,
          refreshToken: refreshSecret,
          idToken: idSecret,
        );
      final store = MemorySecureTokenStore();
      final auth = repository(oidc: oidc, store: store);

      await auth.signIn();

      expect(await auth.accessTokenForRequest(), accessSecret);
      expect(store.record?.refreshToken, refreshSecret);
      expect(store.record?.idTokenHint, idSecret);
      expect(
        const SecureAuthRecordCodec().encode(store.record!),
        isNot(contains(accessSecret)),
      );
    },
  );

  test(
    'proactive refresh is single-flight across concurrent requests',
    () async {
      final completer = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient()..refreshHandler = (_) => completer.future;
      final store = MemorySecureTokenStore(storedRecord());
      final auth = repository(oidc: oidc, store: store);
      await auth.inspectStoredSession();

      final first = auth.accessTokenForRequest();
      final second = auth.accessTokenForRequest();
      await Future<void>.delayed(Duration.zero);

      expect(oidc.refreshCalls, 1);
      completer.complete(
        tokenSet(accessToken: 'fresh-access', refreshToken: 'rotated-refresh'),
      );
      expect(await Future.wait([first, second]), [
        'fresh-access',
        'fresh-access',
      ]);
      expect(store.record?.refreshToken, 'rotated-refresh');
    },
  );

  test('401 challenge reuses a refresh won by another request', () async {
    final oidc = FakeOidcClient()
      ..authorizeHandler = (() async =>
          tokenSet(accessToken: 'rejected-access'))
      ..refreshHandler = ((_) async => tokenSet(accessToken: 'replacement'));
    final auth = repository(oidc: oidc, store: MemorySecureTokenStore());
    await auth.signIn();

    expect(
      await auth.refreshAfterUnauthorized(
        rejectedAccessToken: 'rejected-access',
      ),
      'replacement',
    );
    expect(
      await auth.refreshAfterUnauthorized(
        rejectedAccessToken: 'rejected-access',
      ),
      'replacement',
    );
    expect(oidc.refreshCalls, 1);
  });

  test('invalid_grant clears the durable session and advances epoch', () async {
    final oidc = FakeOidcClient()
      ..refreshHandler = (_) async =>
          throw const OidcClientException.invalidGrant();
    final store = MemorySecureTokenStore(storedRecord());
    final auth = repository(oidc: oidc, store: store);
    await auth.inspectStoredSession();
    final oldEpoch = auth.epoch;

    await expectLater(
      auth.accessTokenForRequest(),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.kind,
          'kind',
          AuthFailureKind.invalidGrant,
        ),
      ),
    );

    expect(auth.epoch, oldEpoch + 1);
    expect(auth.hasStoredSessionInMemory, isFalse);
    expect(store.record, isNull);
  });

  test(
    'invalid_grant overwrites a stale credential when secure delete fails',
    () async {
      const refreshSecret = 'revoked-refresh-must-not-survive';
      const accountId = '00000000-0000-4000-8000-000000000123';
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.invalidGrant();
      final store = MemorySecureTokenStore(
        storedRecord(refreshToken: refreshSecret, accountId: accountId),
      )..clearError = StateError('injected secure-delete failure');
      final auth = repository(oidc: oidc, store: store);
      await auth.inspectStoredSession();

      await expectLater(
        auth.accessTokenForRequest(),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.kind,
            'kind',
            AuthFailureKind.invalidGrant,
          ),
        ),
      );

      final invalidationMarker = store.record;
      expect(invalidationMarker, isNotNull);
      expect(invalidationMarker?.matches(testOidcConfiguration), isFalse);
      expect(invalidationMarker?.refreshToken, isNot(refreshSecret));
      expect(invalidationMarker?.idTokenHint, isNull);
      expect(invalidationMarker?.accountId, isNull);
      expect(
        const SecureAuthRecordCodec().encode(invalidationMarker!),
        isNot(anyOf(contains(refreshSecret), contains(accountId))),
      );

      // Simulate a process restart. The tombstone is recognized as guest and
      // is never sent to the identity provider, even while delete still fails.
      final restarted = repository(oidc: oidc, store: store);
      expect(
        (await restarted.inspectStoredSession()).status,
        AuthStoredSessionStatus.guest,
      );
      expect(await restarted.accessTokenForRequest(), isNull);
      expect(oidc.refreshCalls, 1);
    },
  );

  test(
    'invalid_grant blocks stale reuse when delete and overwrite both fail',
    () async {
      final initial = storedRecord(refreshToken: 'revoked-refresh');
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.invalidGrant();
      final store = MemorySecureTokenStore(initial)
        ..clearError = StateError('injected secure-delete failure')
        ..writeError = StateError('injected secure-write failure');
      final auth = repository(oidc: oidc, store: store);
      await auth.inspectStoredSession();

      await expectLater(
        auth.accessTokenForRequest(),
        throwsA(
          isA<AuthFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                AuthFailureKind.invalidGrant,
              )
              .having(
                (failure) => failure.code,
                'code',
                AuthFailureCode.oidcInvalidGrant,
              ),
        ),
      );

      expect(store.record, same(initial));
      expect(await auth.accessTokenForRequest(), isNull);
      expect(oidc.refreshCalls, 1);

      // Simulate a new process with the residual readable keychain record and
      // the independent non-secret guard. It must remain guest without ever
      // submitting the revoked refresh token again.
      final restartedStore =
          MemorySecureTokenStore(initial, store.invalidationStore)
            ..clearError = StateError('injected secure-delete failure')
            ..writeError = StateError('injected secure-write failure');
      final restarted = repository(oidc: oidc, store: restartedStore);
      expect(
        (await restarted.inspectStoredSession()).status,
        AuthStoredSessionStatus.guest,
      );
      expect(await restarted.accessTokenForRequest(), isNull);
      expect(restartedStore.record, same(initial));
      expect(store.invalidationStore.invalidated, isTrue);
      expect(oidc.refreshCalls, 1);
    },
  );

  test('network refresh failure retains the secure refresh record', () async {
    final oidc = FakeOidcClient()
      ..refreshHandler = (_) async => throw const OidcClientException.network();
    final initial = storedRecord(refreshToken: 'keep-me');
    final store = MemorySecureTokenStore(initial);
    final auth = repository(oidc: oidc, store: store);
    await auth.inspectStoredSession();

    await expectLater(
      auth.accessTokenForRequest(),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.kind,
          'kind',
          AuthFailureKind.network,
        ),
      ),
    );

    expect(store.record, same(initial));
    expect(auth.hasStoredSessionInMemory, isTrue);
  });

  test(
    'configuration binding mismatch fails closed and clears storage',
    () async {
      final store = MemorySecureTokenStore(
        storedRecord(clientId: 'different-client'),
      );
      final auth = repository(oidc: FakeOidcClient(), store: store);

      final inspection = await auth.inspectStoredSession();

      expect(inspection.status, AuthStoredSessionStatus.guest);
      expect(store.record, isNull);
      expect(store.clearCalls, 1);
    },
  );

  test('a newer interactive login wins an account-switch race', () async {
    final firstAuthorization = Completer<OidcTokenSet>();
    final secondAuthorization = Completer<OidcTokenSet>();
    var authorizationCall = 0;
    Future<OidcTokenSet> authorize() {
      authorizationCall += 1;
      return authorizationCall == 1
          ? firstAuthorization.future
          : secondAuthorization.future;
    }

    final oidc = FakeOidcClient()..authorizeHandler = authorize;
    final store = MemorySecureTokenStore();
    final auth = repository(oidc: oidc, store: store);

    final first = auth.signIn();
    await Future<void>.delayed(Duration.zero);
    final second = auth.signIn();
    await Future<void>.delayed(Duration.zero);
    secondAuthorization.complete(
      tokenSet(accessToken: 'second-access', refreshToken: 'second-refresh'),
    );
    expect((await second).epoch, auth.epoch);
    firstAuthorization.complete(
      tokenSet(accessToken: 'first-access', refreshToken: 'first-refresh'),
    );

    await expectLater(
      first,
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.kind,
          'kind',
          AuthFailureKind.superseded,
        ),
      ),
    );
    expect(store.record?.refreshToken, 'second-refresh');
    expect(await auth.accessTokenForRequest(), 'second-access');
  });

  test(
    'late refresh completion cannot rewrite credentials after sign-out',
    () async {
      final refresh = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient()..refreshHandler = (_) => refresh.future;
      final store = MemorySecureTokenStore(storedRecord());
      final auth = repository(oidc: oidc, store: store);
      await auth.inspectStoredSession();

      final refreshing = auth.accessTokenForRequest();
      await Future<void>.delayed(Duration.zero);
      expect(oidc.refreshCalls, 1);
      await auth.signOut();
      refresh.complete(
        tokenSet(accessToken: 'late-access', refreshToken: 'late-refresh'),
      );

      await expectLater(
        refreshing,
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.kind,
            'kind',
            AuthFailureKind.superseded,
          ),
        ),
      );
      expect(store.record, isNull);
      expect(await auth.accessTokenForRequest(), isNull);
    },
  );

  test('sign-out bounds a provider logout that never completes', () async {
    final providerLogout = Completer<void>();
    final oidc = FakeOidcClient()
      ..endSessionHandler = (_) => providerLogout.future;
    final store = MemorySecureTokenStore(storedRecord());
    final auth = repository(
      oidc: oidc,
      store: store,
      providerLogoutTimeout: const Duration(milliseconds: 10),
    );
    await auth.inspectStoredSession();

    await auth.signOut().timeout(const Duration(seconds: 1));

    expect(store.record, isNull);
    expect(auth.hasStoredSessionInMemory, isFalse);
    expect(await auth.accessTokenForRequest(), isNull);
    expect(oidc.endSessionCalls, 1);
  });

  test('provider logout timeout is positive and capped at 30 seconds', () {
    AuthRepository build(Duration timeout) => repository(
      oidc: FakeOidcClient(),
      store: MemorySecureTokenStore(),
      providerLogoutTimeout: timeout,
    );

    expect(() => build(Duration.zero), throwsArgumentError);
    expect(() => build(const Duration(microseconds: -1)), throwsArgumentError);
    expect(() => build(const Duration(seconds: 31)), throwsArgumentError);
    expect(() => build(const Duration(seconds: 30)), returnsNormally);
  });
}
