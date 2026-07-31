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

  test('cancelled system browser returns controller to guest', () async {
    final oidc = FakeOidcClient()
      ..authorizeHandler = () async =>
          throw const OidcClientException.cancelled();
    final controller = AuthSessionController(
      repository: repository(oidc: oidc, store: MemorySecureTokenStore()),
      clearAccountOwnedData: (_) async {},
    );
    addTearDown(controller.dispose);

    expect(await controller.signIn(), isFalse);
    expect(controller.state.phase, AuthSessionPhase.guest);
    expect(controller.state.failure, isNull);
  });

  test('invalid_grant becomes guest and removes secure credentials', () async {
    const accountId = '00000000-0000-4000-8000-000000000123';
    final oidc = FakeOidcClient()
      ..refreshHandler = (_) async =>
          throw const OidcClientException.invalidGrant();
    final store = MemorySecureTokenStore(storedRecord(accountId: accountId));
    final publicPaperIds = <String>{'public-paper'};
    final accountRows = <String>{'private-row'};
    String? clearedAccountId;
    final controller = AuthSessionController(
      repository: repository(oidc: oidc, store: store),
      clearAccountOwnedData: (value) async {
        clearedAccountId = value;
        accountRows.clear();
      },
    );
    addTearDown(controller.dispose);

    expect(await controller.restoreSession(), isFalse);
    expect(controller.state.phase, AuthSessionPhase.guest);
    expect(controller.state.failure?.kind, AuthFailureKind.invalidGrant);
    expect(store.record, isNull);
    expect(clearedAccountId, accountId);
    expect(accountRows, isEmpty);
    expect(publicPaperIds, {'public-paper'});
  });

  test(
    'invalid_grant still clears account data when secure invalidation fails',
    () async {
      const accountId = '00000000-0000-4000-8000-000000000123';
      final initial = storedRecord(accountId: accountId);
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.invalidGrant();
      final store = MemorySecureTokenStore(initial)
        ..clearError = StateError('injected secure-delete failure')
        ..writeError = StateError('injected secure-write failure');
      final accountRows = <String>{'private-row'};
      String? clearedAccountId;
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (value) async {
          clearedAccountId = value;
          accountRows.clear();
        },
      );
      addTearDown(controller.dispose);

      expect(await controller.restoreSession(), isFalse);

      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(controller.state.failure?.kind, AuthFailureKind.invalidGrant);
      expect(clearedAccountId, accountId);
      expect(accountRows, isEmpty);
      expect(store.record, same(initial));
      expect(await controller.accessTokenForRequest(), isNull);
      expect(oidc.refreshCalls, 1);
    },
  );

  test(
    'network restore failure is offlineAuthUnknown and remains durable',
    () async {
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.network();
      final initial = storedRecord(
        refreshToken: 'offline-refresh-secret',
        accountId: '00000000-0000-4000-8000-000000000123',
      );
      final store = MemorySecureTokenStore(initial);
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (_) async {},
      );
      addTearDown(controller.dispose);

      expect(await controller.restoreSession(), isFalse);
      expect(controller.state.phase, AuthSessionPhase.offlineAuthUnknown);
      expect(controller.state.accountId, initial.accountId);
      expect(store.record, same(initial));
      expect(
        controller.state.toString(),
        isNot(contains('offline-refresh-secret')),
      );
    },
  );

  test(
    'late sign-in completion cannot resurrect a signed-out session',
    () async {
      final authorization = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient()
        ..authorizeHandler = () => authorization.future;
      final store = MemorySecureTokenStore();
      var accountDataClearCount = 0;
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (_) async {
          accountDataClearCount += 1;
        },
      );
      addTearDown(controller.dispose);

      final signIn = controller.signIn();
      await Future<void>.delayed(Duration.zero);
      expect(oidc.authorizeCalls, 1);

      await controller.signOut();
      authorization.complete(tokenSet(accessToken: 'late-access'));

      expect(await signIn, isFalse);
      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(store.record, isNull);
      expect(accountDataClearCount, 2);
    },
  );

  test(
    'new sign-in clears the prior account before opening the browser',
    () async {
      const oldAccountId = '00000000-0000-4000-8000-000000000444';
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(
        storedRecord(accountId: oldAccountId),
      );
      final cleared = <String?>[];
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (accountId) async => cleared.add(accountId),
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();

      expect(await controller.signIn(), isTrue);

      expect(cleared, [oldAccountId]);
      expect(oidc.authorizeCalls, 1);
      expect(controller.state.phase, AuthSessionPhase.authenticated);
      expect(controller.state.accountId, isNull);
    },
  );

  test(
    'verified identity replacement clears stale account rows before binding',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000444';
      const accountB = '00000000-0000-4000-8000-000000000555';
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      final cleared = <String?>[];
      late final AuthSessionController controller;
      controller = AuthSessionController(
        repository: repository(oidc: FakeOidcClient(), store: store),
        clearAccountOwnedData: (accountId) async {
          expect(store.record?.accountId, accountA);
          expect(controller.state.accountId, accountA);
          cleared.add(accountId);
        },
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();

      await controller.bindAccountId(accountB);

      expect(cleared, [accountA]);
      expect(store.record?.accountId, accountB);
      expect(controller.state.accountId, accountB);
      expect(controller.state.phase, AuthSessionPhase.authenticated);
    },
  );

  test('stale identity cleanup failure prevents replacement binding', () async {
    const accountA = '00000000-0000-4000-8000-000000000444';
    const accountB = '00000000-0000-4000-8000-000000000555';
    final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
    final controller = AuthSessionController(
      repository: repository(oidc: FakeOidcClient(), store: store),
      clearAccountOwnedData: (_) async {
        throw StateError('private cleanup detail');
      },
    );
    addTearDown(controller.dispose);
    await controller.inspectStoredSession();

    await expectLater(
      controller.bindAccountId(accountB),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.kind,
          'kind',
          AuthFailureKind.accountDataCleanup,
        ),
      ),
    );

    expect(store.record?.accountId, accountA);
    expect(controller.state.accountId, accountA);
    expect(controller.state.phase, AuthSessionPhase.unavailable);
    expect(
      controller.state.failure?.toString(),
      isNot(contains('private cleanup detail')),
    );
  });

  test('account cleanup failure blocks a new browser sign-in', () async {
    final oidc = FakeOidcClient();
    final controller = AuthSessionController(
      repository: repository(oidc: oidc, store: MemorySecureTokenStore()),
      clearAccountOwnedData: (_) async {
        throw StateError('injected cleanup failure');
      },
    );
    addTearDown(controller.dispose);

    expect(await controller.signIn(), isFalse);

    expect(oidc.authorizeCalls, 0);
    expect(controller.state.phase, AuthSessionPhase.unavailable);
    expect(controller.state.failure?.kind, AuthFailureKind.accountDataCleanup);
  });

  test(
    'sign-out clears account data while a public cache remains intact',
    () async {
      const accountId = '00000000-0000-4000-8000-000000000321';
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(storedRecord(accountId: accountId));
      final auth = repository(oidc: oidc, store: store);
      final publicPaperIds = <String>{'public-paper'};
      final accountRows = <String>{'private-comment'};
      String? clearedAccountId;
      final controller = AuthSessionController(
        repository: auth,
        clearAccountOwnedData: (value) async {
          clearedAccountId = value;
          accountRows.clear();
        },
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();

      await controller.signOut();

      expect(clearedAccountId, accountId);
      expect(accountRows, isEmpty);
      expect(publicPaperIds, {'public-paper'});
      expect(store.record, isNull);
      expect(oidc.suppliedIdTokenHints, ['stored-id-token']);
    },
  );

  test(
    'sign-out clears local data when provider logout never completes',
    () async {
      const accountId = '00000000-0000-4000-8000-000000000321';
      final providerLogout = Completer<void>();
      final oidc = FakeOidcClient()
        ..endSessionHandler = (_) => providerLogout.future;
      final store = MemorySecureTokenStore(storedRecord(accountId: accountId));
      final accountRows = <String>{'private-comment'};
      final controller = AuthSessionController(
        repository: repository(
          oidc: oidc,
          store: store,
          providerLogoutTimeout: const Duration(milliseconds: 10),
        ),
        clearAccountOwnedData: (_) async => accountRows.clear(),
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();

      await controller.signOut().timeout(const Duration(seconds: 1));

      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(controller.state.failure, isNull);
      expect(accountRows, isEmpty);
      expect(store.record, isNull);
      expect(oidc.endSessionCalls, 1);
    },
  );

  test(
    'sign-out remains guest when secure delete and overwrite both fail',
    () async {
      const accountId = '00000000-0000-4000-8000-000000000321';
      final initial = storedRecord(accountId: accountId);
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(initial)
        ..clearError = StateError('injected secure-delete failure')
        ..writeError = StateError('injected secure-write failure');
      final accountRows = <String>{'private-comment'};
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (_) async => accountRows.clear(),
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();

      await controller.signOut();

      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(controller.state.failure?.kind, AuthFailureKind.secureStorage);
      expect(
        controller.state.failure?.code,
        AuthFailureCode.secureStorageClear,
      );
      expect(accountRows, isEmpty);
      expect(store.record, same(initial));
      expect(await controller.accessTokenForRequest(), isNull);
      expect(oidc.refreshCalls, 0);
    },
  );

  test(
    'sign-out clear is serialized after an already-started secure write',
    () async {
      final writeGate = Completer<void>();
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore()..writeGate = writeGate;
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (_) async {},
      );
      addTearDown(controller.dispose);

      final signIn = controller.signIn();
      while (store.writeCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final signOut = controller.signOut();
      writeGate.complete();

      await signOut;
      expect(await signIn, isFalse);
      expect(store.record, isNull);
      expect(controller.state.phase, AuthSessionPhase.guest);
    },
  );
}
