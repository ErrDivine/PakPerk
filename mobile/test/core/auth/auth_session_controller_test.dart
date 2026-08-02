import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/comments/comment_cache_barrier.dart';
import 'package:pakperk/core/comments/comment_repository.dart';
import 'package:pakperk/core/comments/comments_api.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_repository.dart';

import 'auth_fakes.dart';
import '../../support/fakes.dart';

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
      clearAccountOwnedData: (_, __) async {},
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
      clearAccountOwnedData: (value, _) async {
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
        clearAccountOwnedData: (value, _) async {
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
        clearAccountOwnedData: (_, __) async {},
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
    'cross-account binding revokes old local and token scopes before cleanup',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      const accountB = '00000000-0000-4000-8000-000000000456';
      const paperId = '00000000-0000-4000-8000-000000000789';
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      var cleanupFinished = false;
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (accountId, _) async {
          expect(accountId, accountA);
          cleanupFinished = true;
        },
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;

      final bindGate = Completer<void>();
      store.writeGate = bindGate;
      final writesBeforeBind = store.writeCalls;
      final binding = controller.bindAccountId(accountB);
      while (store.writeCalls == writesBeforeBind) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(cleanupFinished, isTrue);
      expect(controller.state.accountId, isNull);
      expect(controller.isCurrentEpoch(epoch), isFalse);
      expect(await controller.accessTokenForRequest(), isNull);
      expect(
        await controller.refreshAfterUnauthorized(
          rejectedAccessToken: 'access-token',
          expectedAuthEpoch: epoch,
        ),
        isNull,
      );
      expect(controller.state.accountId, isNull);

      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final library = LibraryRepository(
        local: LibraryDao(database),
        remote: _UnusedLibraryRemote(),
        sessionScope: () => (
          accountId: controller.state.accountId,
          authEpoch: controller.state.epoch,
        ),
        verifiedScope: () => null,
        localMutationScope: () {
          final session = controller.state;
          final accountId = session.accountId;
          if (accountId == null || !session.mayHaveRecoverableCredentials) {
            return null;
          }
          return (accountId: accountId, authEpoch: session.epoch);
        },
      );
      expect(
        () => library.setSaved(
          accountId: accountA,
          authEpoch: epoch,
          paperId: paperId,
          saved: false,
        ),
        throwsA(isA<LibraryScopeChanged>()),
      );
      expect(await database.select(database.syncOutbox).get(), isEmpty);

      bindGate.complete();
      await binding;
      expect(controller.state.accountId, accountB);
      expect(controller.state.phase, AuthSessionPhase.authenticated);
      expect(controller.isCurrentEpoch(epoch), isTrue);
    },
  );

  test(
    'same-account binding preserves local drafts while remote auth is blocked',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final paperId = samplePaper.paperId;
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      final controller = AuthSessionController(
        repository: repository(oidc: FakeOidcClient(), store: store),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;

      final bindGate = Completer<void>();
      store.writeGate = bindGate;
      final writesBeforeBind = store.writeCalls;
      final binding = controller.bindAccountId(accountA);
      while (store.writeCalls == writesBeforeBind) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.state.phase, AuthSessionPhase.refreshing);
      expect(controller.state.accountId, accountA);
      expect(controller.isCurrentEpoch(epoch), isFalse);
      expect(await controller.accessTokenForRequest(), isNull);

      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await PaperCacheDao(database).save(samplePaper);
      final local = CommentsDao(database);
      final comments = CommentRepository(
        cache: CommentCacheDao(database),
        local: local,
        remote: _UnusedCommentsRemote(),
        accountWrites: AccountDataWriteBarrier(),
        commentCache: CommentCacheBarrier(),
        cachePolicy: const FeedPrefetchConfig(),
        sessionScope: () => (
          accountId: controller.state.accountId,
          authEpoch: controller.state.epoch,
        ),
        verifiedScope: () => null,
      );
      await comments.saveDraft(
        accountId: accountA,
        authEpoch: epoch,
        paperId: paperId,
        body: 'Latest text while the same identity is rebound.',
      );
      expect(
        (await local.loadDraft(accountA, paperId))?.body,
        'Latest text while the same identity is rebound.',
      );

      bindGate.complete();
      await binding;
      expect(controller.state.phase, AuthSessionPhase.authenticated);
      expect(controller.state.accountId, accountA);
    },
  );

  group('deletion reservation during identity binding', () {
    test('exact same-account deletion supersedes a preserved rebind', () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      final controller = AuthSessionController(
        repository: repository(oidc: FakeOidcClient(), store: store),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;

      final bindGate = Completer<void>();
      store.writeGate = bindGate;
      final writesBeforeBind = store.writeCalls;
      final binding = controller.bindAccountId(accountA);
      while (store.writeCalls == writesBeforeBind) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.state.accountId, accountA);
      expect(
        controller.reserveAccountDeletion(
          expectedAuthEpoch: epoch,
          expectedAccountId: accountA,
        ),
        isTrue,
      );
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.isCurrentEpoch(epoch), isFalse);
      expect(await controller.accessTokenForRequest(), isNull);

      final superseded = expectLater(binding, throwsA(isA<AuthFailure>()));
      bindGate.complete();
      await superseded;
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.state.accountId, isNull);
    });

    test('unbound request cannot cancel a bind to a new account', () async {
      const accountB = '00000000-0000-4000-8000-000000000456';
      final store = MemorySecureTokenStore(storedRecord());
      final controller = AuthSessionController(
        repository: repository(oidc: FakeOidcClient(), store: store),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;

      final bindGate = Completer<void>();
      store.writeGate = bindGate;
      final writesBeforeBind = store.writeCalls;
      final binding = controller.bindAccountId(accountB);
      while (store.writeCalls == writesBeforeBind) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.state.accountId, isNull);
      expect(
        controller.reserveAccountDeletion(
          expectedAuthEpoch: epoch,
          expectedAccountId: null,
        ),
        isFalse,
      );
      expect(controller.state.phase, AuthSessionPhase.refreshing);

      bindGate.complete();
      await binding;
      expect(controller.state.phase, AuthSessionPhase.authenticated);
      expect(controller.state.accountId, accountB);
      expect(store.record?.accountId, accountB);
    });
  });

  group('deletion reservation during auth completion', () {
    test('successful token refresh cannot reopen a reserved session', () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final refreshGate = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient();
      final controller = AuthSessionController(
        repository: repository(
          oidc: oidc,
          store: MemorySecureTokenStore(storedRecord(accountId: accountA)),
        ),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;
      oidc.refreshHandler = (_) => refreshGate.future;

      final refreshing = controller.refreshAfterUnauthorized(
        rejectedAccessToken: 'access-token',
        expectedAuthEpoch: epoch,
      );
      while (oidc.refreshCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        controller.reserveAccountDeletion(
          expectedAuthEpoch: epoch,
          expectedAccountId: accountA,
        ),
        isTrue,
      );
      refreshGate.complete(
        tokenSet(
          accessToken: 'late-access-token',
          refreshToken: 'late-refresh-token',
        ),
      );

      expect(await refreshing, isNull);
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.state.accountId, isNull);
      expect(controller.isCurrentEpoch(epoch), isFalse);
      expect(await controller.accessTokenForRequest(), isNull);
    });

    test('network failure cannot overwrite a reserved session', () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final refreshGate = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient();
      final controller = AuthSessionController(
        repository: repository(
          oidc: oidc,
          store: MemorySecureTokenStore(storedRecord(accountId: accountA)),
        ),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;
      oidc.refreshHandler = (_) => refreshGate.future;

      final refreshing = controller.refreshAfterUnauthorized(
        rejectedAccessToken: 'access-token',
        expectedAuthEpoch: epoch,
      );
      while (oidc.refreshCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final failureExpectation = expectLater(
        refreshing,
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.kind,
            'kind',
            AuthFailureKind.network,
          ),
        ),
      );
      expect(
        controller.reserveAccountDeletion(
          expectedAuthEpoch: epoch,
          expectedAccountId: accountA,
        ),
        isTrue,
      );
      refreshGate.completeError(const OidcClientException.network());

      await failureExpectation;
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.state.accountId, isNull);
      expect(controller.state.failure, isNull);
      expect(controller.isCurrentEpoch(epoch), isFalse);
    });

    test('restore completion cannot reopen a reserved session', () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final refreshGate = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient()..refreshHandler = (_) => refreshGate.future;
      final controller = AuthSessionController(
        repository: repository(
          oidc: oidc,
          store: MemorySecureTokenStore(storedRecord(accountId: accountA)),
        ),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);

      final restoring = controller.restoreSession();
      while (oidc.refreshCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final epoch = controller.state.epoch;
      expect(controller.state.phase, AuthSessionPhase.refreshing);
      expect(
        controller.reserveAccountDeletion(
          expectedAuthEpoch: epoch,
          expectedAccountId: accountA,
        ),
        isTrue,
      );
      refreshGate.complete(tokenSet(accessToken: 'late-access-token'));

      expect(await restoring, isFalse);
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.state.accountId, isNull);
      expect(controller.isCurrentEpoch(epoch), isFalse);
    });

    test(
      'stored-session inspection cannot reopen a reserved session',
      () async {
        const accountA = '00000000-0000-4000-8000-000000000123';
        final readGate = Completer<void>();
        final store = MemorySecureTokenStore(storedRecord(accountId: accountA))
          ..readGate = readGate;
        final controller = AuthSessionController(
          repository: repository(oidc: FakeOidcClient(), store: store),
          clearAccountOwnedData: (_, __) async {},
        );
        addTearDown(controller.dispose);

        final inspection = controller.inspectStoredSession();
        while (store.readCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final epoch = controller.state.epoch;
        expect(
          controller.reserveAccountDeletion(
            expectedAuthEpoch: epoch,
            expectedAccountId: null,
          ),
          isTrue,
        );
        readGate.complete();

        expect(await inspection, AuthStoredSessionStatus.guest);
        expect(controller.state.phase, AuthSessionPhase.deletionPending);
        expect(controller.state.accountId, isNull);
        expect(controller.isCurrentEpoch(epoch), isFalse);
      },
    );
  });

  test(
    'refresh racing account bind keeps controller and durable identity aligned',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      const accountB = '00000000-0000-4000-8000-000000000456';
      final refreshGate = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient()..refreshHandler = (_) => refreshGate.future;
      final store = MemorySecureTokenStore(
        storedRecord(refreshToken: 'account-a-refresh', accountId: accountA),
      );
      final auth = repository(oidc: oidc, store: store);
      final controller = AuthSessionController(
        repository: auth,
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(
        await controller.inspectStoredSession(),
        AuthStoredSessionStatus.refreshRequired,
      );

      final refreshing = controller.refreshAfterUnauthorized(
        rejectedAccessToken: 'expired-account-a-access',
      );
      while (oidc.refreshCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.bindAccountId(accountB);
      expect(controller.state.accountId, accountB);
      refreshGate.complete(
        tokenSet(
          accessToken: 'rotated-access',
          refreshToken: 'rotated-refresh',
          idToken: 'rotated-id-token',
        ),
      );

      expect(await refreshing, 'rotated-access');
      expect(controller.state.phase, AuthSessionPhase.authenticated);
      expect(controller.state.accountId, accountB);
      expect(auth.accountId, accountB);
      expect(store.record?.accountId, accountB);
      expect(store.record?.refreshToken, 'rotated-refresh');
      expect(store.record?.idTokenHint, 'rotated-id-token');
    },
  );

  test(
    'invalid grant racing identity bind clears all data and remains guest',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      const accountB = '00000000-0000-4000-8000-000000000456';
      final refreshGate = Completer<OidcTokenSet>();
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      final cleared = <String?>[];
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (accountId, _) async => cleared.add(accountId),
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      oidc.refreshHandler = (_) => refreshGate.future;

      final refresh = controller.refreshAfterUnauthorized(
        rejectedAccessToken: 'access-token',
      );
      while (oidc.refreshCalls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final binding = controller.bindAccountId(accountB);
      expect(controller.state.accountId, isNull);
      final refreshExpectation = expectLater(
        refresh,
        throwsA(isA<AuthFailure>()),
      );
      final bindingExpectation = expectLater(
        binding,
        throwsA(isA<AuthFailure>()),
      );
      refreshGate.completeError(const OidcClientException.invalidGrant());

      await refreshExpectation;
      await bindingExpectation;
      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(controller.state.accountId, isNull);
      expect(store.record, isNull);
      expect(cleared, contains(null));
    },
  );

  test('newer same-identity bind cannot republish a stale account', () async {
    const accountA = '00000000-0000-4000-8000-000000000123';
    const accountB = '00000000-0000-4000-8000-000000000456';
    final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
    final controller = AuthSessionController(
      repository: repository(oidc: FakeOidcClient(), store: store),
      clearAccountOwnedData: (_, __) async {},
    );
    addTearDown(controller.dispose);
    expect(await controller.restoreSession(), isTrue);
    final bindGate = Completer<void>();
    store.writeGate = bindGate;
    final writesBeforeBind = store.writeCalls;
    final staleBinding = controller.bindAccountId(accountB);
    while (store.writeCalls == writesBeforeBind) {
      await Future<void>.delayed(Duration.zero);
    }

    final newestBinding = controller.bindAccountId(accountA);
    final staleExpectation = expectLater(
      staleBinding,
      throwsA(isA<AuthFailure>()),
    );
    expect(controller.state.accountId, isNull);
    expect(await controller.accessTokenForRequest(), isNull);
    bindGate.complete();

    await staleExpectation;
    await newestBinding;
    expect(controller.state.phase, AuthSessionPhase.authenticated);
    expect(controller.state.accountId, accountA);
    expect(store.record?.accountId, accountA);
  });

  test(
    'failed cross-account bind cannot reopen the old comment draft scope',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      const accountB = '00000000-0000-4000-8000-000000000456';
      const paperId = '00000000-0000-4000-8000-000000000789';
      final oidc = FakeOidcClient();
      final store = MemorySecureTokenStore(storedRecord(accountId: accountA));
      final controller = AuthSessionController(
        repository: repository(oidc: oidc, store: store),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);
      final epoch = controller.state.epoch;
      store.writeError = StateError('injected binding write failure');

      await expectLater(
        controller.bindAccountId(accountB),
        throwsA(isA<AuthFailure>()),
      );
      expect(controller.state.phase, AuthSessionPhase.unavailable);
      expect(controller.state.accountId, accountA);

      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final comments = CommentRepository(
        cache: CommentCacheDao(database),
        local: CommentsDao(database),
        remote: _UnusedCommentsRemote(),
        accountWrites: AccountDataWriteBarrier(),
        commentCache: CommentCacheBarrier(),
        cachePolicy: const FeedPrefetchConfig(),
        sessionScope: () {
          final session = controller.state;
          return (
            accountId: session.mayHaveRecoverableCredentials
                ? session.accountId
                : null,
            authEpoch: session.epoch,
          );
        },
        verifiedScope: () => null,
      );
      expect(comments.localAccountGuard(accountA, epoch)(), isFalse);
      await expectLater(
        comments.saveDraft(
          accountId: accountA,
          authEpoch: epoch,
          paperId: paperId,
          body: 'Must not be resurrected.',
        ),
        throwsA(isA<CommentScopeChanged>()),
      );
      expect(await database.select(database.commentDrafts).get(), isEmpty);
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
        clearAccountOwnedData: (_, __) async {
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
    'deletion pending blocks sign-in until explicit continue as guest',
    () async {
      final oidc = FakeOidcClient();
      final controller = AuthSessionController(
        repository: repository(
          oidc: oidc,
          store: MemorySecureTokenStore(storedRecord()),
        ),
        clearAccountOwnedData: (_, __) async {},
      );
      addTearDown(controller.dispose);
      await controller.inspectStoredSession();
      expect(await controller.enterAccountDeletionPending(), isTrue);

      expect(await controller.signIn(), isFalse);
      expect(oidc.authorizeCalls, 0);
      expect(controller.state.phase, AuthSessionPhase.deletionPending);

      controller.continueAsGuestAfterDeletion();
      expect(controller.state.phase, AuthSessionPhase.guest);
      expect(await controller.signIn(), isTrue);
      expect(oidc.authorizeCalls, 1);
      expect(controller.state.phase, AuthSessionPhase.authenticated);
    },
  );

  test(
    'deletion pending is published before account cleanup completes',
    () async {
      const accountA = '00000000-0000-4000-8000-000000000123';
      final cleanupGate = Completer<void>();
      final controller = AuthSessionController(
        repository: repository(
          oidc: FakeOidcClient(),
          store: MemorySecureTokenStore(storedRecord(accountId: accountA)),
        ),
        clearAccountOwnedData: (accountId, _) {
          expect(accountId, accountA);
          return cleanupGate.future;
        },
      );
      addTearDown(controller.dispose);
      expect(await controller.restoreSession(), isTrue);

      final deletion = controller.enterAccountDeletionPending(
        accountId: accountA,
      );

      expect(controller.state.phase, AuthSessionPhase.deletionPending);
      expect(controller.state.accountId, isNull);
      expect(controller.isCurrentEpoch(controller.state.epoch), isFalse);
      expect(await controller.accessTokenForRequest(), isNull);

      cleanupGate.complete();
      expect(await deletion, isTrue);
      expect(controller.state.phase, AuthSessionPhase.deletionPending);
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
        clearAccountOwnedData: (accountId, _) async => cleared.add(accountId),
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
        clearAccountOwnedData: (accountId, _) async {
          expect(store.record?.accountId, accountA);
          expect(controller.state.accountId, isNull);
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
      clearAccountOwnedData: (_, __) async {
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
      clearAccountOwnedData: (_, __) async {
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
        clearAccountOwnedData: (value, _) async {
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
        clearAccountOwnedData: (_, __) async => accountRows.clear(),
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
        clearAccountOwnedData: (_, __) async => accountRows.clear(),
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
        clearAccountOwnedData: (_, __) async {},
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

final class _UnusedLibraryRemote implements LibraryRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The fail-closed test must not reach the network.');
}

final class _UnusedCommentsRemote implements CommentsRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The fail-closed test must not reach the network.');
}
