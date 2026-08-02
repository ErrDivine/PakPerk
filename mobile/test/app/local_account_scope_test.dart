import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/comments_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/account/account.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/account/account_home_screen.dart';

import '../core/auth/auth_fakes.dart';

void main() {
  test(
    'offline restore retains local comment, draft, and library scope',
    () async {
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.network();
      final auth = _authController(
        oidc: oidc,
        store: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
      );
      expect(await auth.restoreSession(), isFalse);
      final account = _accountController(auth, _StatusAdapter('active'));
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(_features),
          authSessionProvider.overrideWith((ref) => auth),
          currentAccountProvider.overrideWith((ref) => account),
        ],
      );
      addTearDown(container.dispose);

      final viewer = container.read(commentViewerScopeProvider);
      expect(viewer.accountId, _accountId);
      expect(viewer.authenticated, isTrue);
      expect(viewer.remotelyVerified, isFalse);
      expect(container.read(verifiedCommentScopeProvider), isNull);
      expect(container.read(commentReadOnlyAccountStatusProvider), isNull);
      expect(
        container.read(libraryDisplayScopeProvider)?.accountId,
        _accountId,
      );
      expect(
        container.read(libraryMutationScopeProvider)?.accountId,
        _accountId,
      );
    },
  );

  test(
    'offline recovery is single-flight and waits for account verification',
    () async {
      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async =>
            throw const OidcClientException.network();
      final auth = _authController(
        oidc: oidc,
        store: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
      );
      expect(await auth.restoreSession(), isFalse);
      final accountGate = Completer<void>();
      final adapter = _StatusAdapter('active')..gate = accountGate;
      final account = _accountController(auth, adapter);
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(_features),
          authSessionProvider.overrideWith((ref) => auth),
          currentAccountProvider.overrideWith((ref) => account),
          networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(networkOfflineProvider.future), isFalse);
      expect(container.read(authSessionOfflineUnknownProvider), isTrue);

      oidc.refreshHandler = (_) async => tokenSet();
      final recovery = container.read(accountSessionRecoveryProvider);
      final first = recovery.recover();
      final second = recovery.recover();
      expect(identical(first, second), isTrue);
      while (adapter.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      var settled = false;
      unawaited(first.whenComplete(() => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      expect(container.read(verifiedLibraryScopeProvider), isNull);
      expect(container.read(verifiedCommentScopeProvider), isNull);

      accountGate.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(oidc.refreshCalls, 2);
      expect(container.read(authSessionOfflineUnknownProvider), isFalse);
      expect(account.state.phase, CurrentAccountPhase.ready);
      expect(
        container.read(verifiedLibraryScopeProvider)?.accountId,
        _accountId,
      );
      expect(
        container.read(verifiedCommentScopeProvider)?.accountId,
        _accountId,
      );
    },
  );

  test(
    'verified suspended profile keeps reads but removes mutation scopes',
    () async {
      final auth = _authController(
        oidc: FakeOidcClient(),
        store: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
      );
      expect(await auth.restoreSession(), isTrue);
      final account = _accountController(auth, _StatusAdapter('suspended'));
      expect(await account.load(), isNotNull);
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(_features),
          authSessionProvider.overrideWith((ref) => auth),
          currentAccountProvider.overrideWith((ref) => account),
        ],
      );
      addTearDown(container.dispose);

      final viewer = container.read(commentViewerScopeProvider);
      expect(viewer.accountId, _accountId);
      expect(viewer.remotelyVerified, isFalse);
      expect(viewer.allowsPublicRemoteRead, isTrue);
      expect(
        container.read(commentReadOnlyAccountStatusProvider),
        AccountStatus.suspended,
      );
      expect(container.read(verifiedCommentScopeProvider), isNull);
      expect(
        container.read(libraryDisplayScopeProvider)?.accountId,
        _accountId,
      );
      expect(container.read(libraryMutationScopeProvider), isNull);
      expect(
        container.read(libraryReadOnlyAccountStatusProvider),
        AccountStatus.suspended,
      );
    },
  );

  testWidgets('suspended error replaces retained active account UI', (
    tester,
  ) async {
    final auth = _authController(
      oidc: FakeOidcClient(),
      store: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
    );
    expect(await auth.restoreSession(), isTrue);
    final adapter = _StatusAdapter('active');
    final account = _accountController(auth, adapter);
    final initialLoad = account.load();
    await _pumpAccountLoad(tester, account);
    expect((await initialLoad)?.isActive, isTrue);
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWithValue(_features),
        authSessionProvider.overrideWith((ref) => auth),
        currentAccountProvider.overrideWith((ref) => account),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(libraryMutationScopeProvider), isNotNull);

    adapter.errorCode = 'ACCOUNT_SUSPENDED';
    final suspendedLoad = account.load();
    await _pumpAccountLoad(tester, account);
    expect(await suspendedLoad, isNull);
    expect(account.state.phase, CurrentAccountPhase.failed);
    expect(account.state.profile?.isActive, isTrue);
    expect(account.state.error?.code, 'ACCOUNT_SUSPENDED');
    expect(account.state.errorAuthEpoch, auth.state.epoch);
    expect(
      container.read(effectiveAccountReadOnlyStatusProvider),
      AccountStatus.suspended,
    );
    expect(container.read(libraryMutationScopeProvider), isNull);
    expect(
      container.read(libraryReadOnlyAccountStatusProvider),
      AccountStatus.suspended,
    );
    final viewer = container.read(commentViewerScopeProvider);
    expect(viewer.accountId, _accountId);
    expect(viewer.allowsPublicRemoteRead, isTrue);
    expect(viewer.remotelyVerified, isFalse);
    expect(
      container.read(commentReadOnlyAccountStatusProvider),
      AccountStatus.suspended,
    );

    final retryGate = Completer<void>();
    adapter
      ..errorCode = 'SERVICE_UNAVAILABLE'
      ..gate = retryGate;
    final callsBeforeRetry = adapter.calls;
    final retry = account.load();
    for (
      var attempt = 0;
      attempt < 100 && adapter.calls == callsBeforeRetry;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(adapter.calls, greaterThan(callsBeforeRetry));
    expect(account.state.phase, CurrentAccountPhase.loading);
    expect(
      container.read(effectiveAccountReadOnlyStatusProvider),
      AccountStatus.suspended,
    );
    expect(container.read(libraryMutationScopeProvider), isNull);
    retryGate.complete();
    await _pumpAccountLoad(tester, account);
    expect(await retry, isNull);
    expect(
      container.read(effectiveAccountReadOnlyStatusProvider),
      AccountStatus.suspended,
    );
    expect(container.read(libraryMutationScopeProvider), isNull);

    var libraryOpened = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: AccountYouScreen(
            onSignIn: () {},
            onCompleteProfile: () {},
            onOpenLibrary: () => libraryOpened = true,
            onOpenComments: () {},
            onOpenBlockedUsers: () {},
            onOpenSettings: () {},
            onOpenPrivacy: () {},
            onOpenTerms: () {},
            onOpenCommunityGuidelines: () {},
            onOpenSupport: () {},
            onOpenDeleteAccount: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.textContaining('This account is read-only'), findsOneWidget);
    expect(find.text('Edit display name'), findsNothing);
    expect(find.text('My comments'), findsNothing);
    expect(find.text('Blocked users'), findsNothing);
    final toRead = find.byKey(const ValueKey('read-only-account-to-read'));
    await tester.ensureVisible(toRead);
    await tester.pump();
    await tester.tap(toRead);
    expect(libraryOpened, isTrue);
  });

  test(
    'unavailable retained ID cannot expose local scopes or stale status',
    () async {
      final oidc = FakeOidcClient();
      final auth = _authController(
        oidc: oidc,
        store: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
      );
      expect(await auth.restoreSession(), isTrue);
      final account = _accountController(auth, _StatusAdapter('suspended'));
      expect(await account.load(), isNotNull);
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(_features),
          authSessionProvider.overrideWith((ref) => auth),
          currentAccountProvider.overrideWith((ref) => account),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container.read(commentReadOnlyAccountStatusProvider),
        AccountStatus.suspended,
      );

      oidc.refreshHandler = (_) async =>
          throw const OidcClientException.provider();
      await expectLater(
        auth.refreshAfterUnauthorized(rejectedAccessToken: 'access-token'),
        throwsA(isA<AuthFailure>()),
      );
      expect(auth.state.phase, AuthSessionPhase.unavailable);
      expect(auth.state.accountId, _accountId);
      expect(auth.state.mayHaveRecoverableCredentials, isFalse);

      expect(container.read(libraryDisplayScopeProvider), isNull);
      expect(container.read(libraryMutationScopeProvider), isNull);
      expect(container.read(libraryReadOnlyAccountStatusProvider), isNull);
      expect(container.read(commentViewerScopeProvider).authenticated, isFalse);
      expect(container.read(commentReadOnlyAccountStatusProvider), isNull);
      expect(container.read(authSessionOfflineUnknownProvider), isFalse);
    },
  );
}

Future<void> _pumpAccountLoad(
  WidgetTester tester,
  CurrentAccountController account,
) async {
  for (
    var attempt = 0;
    attempt < 100 && account.state.phase == CurrentAccountPhase.loading;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(account.state.phase, isNot(CurrentAccountPhase.loading));
}

AuthSessionController _authController({
  required FakeOidcClient oidc,
  required MemorySecureTokenStore store,
}) => AuthSessionController(
  repository: AuthRepository(
    configuration: testOidcConfiguration,
    oidcClient: oidc,
    secureTokenStore: store,
    clock: () => DateTime.utc(2026, 8, 1),
  ),
  clearAccountOwnedData: (_, __) async {},
);

CurrentAccountController _accountController(
  AuthSessionController auth,
  HttpClientAdapter adapter,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
    ..httpClientAdapter = adapter;
  return CurrentAccountController(
    repository: AccountRepository(AccountApi(dio)),
    sessionEpoch: () => auth.state.epoch,
    sessionAccountId: () => auth.state.accountId,
    bindAccountId: auth.bindAccountId,
  );
}

final class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);

  String status;
  String? errorCode;
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    await gate?.future;
    if (errorCode case final code?) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': code,
            'message': 'The account is not active.',
            'retryable': false,
            'request_id': '018f47a6-4b56-7f4c-8c7a-e2656e820099',
          },
        }),
        403,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'cache-control': ['private, no-store'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'account': {
          'id': _accountId,
          'handle': null,
          'display_name': null,
          'status': status,
          'profile_version': 1,
          'profile_complete': false,
          'terms_version': null,
          'terms_accepted_at': null,
          'current_terms_version': '2026-07-31',
          'terms_current': false,
          'community_guidelines_version': null,
          'community_guidelines_accepted_at': null,
          'current_community_guidelines_version': '2026-07-31',
          'community_guidelines_current': false,
          'created_at': '2026-07-30T10:00:00Z',
          'updated_at': '2026-07-30T11:00:00Z',
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

const _features = FeatureFlags(
  accounts: true,
  library: true,
  comments: true,
  openingMotion: false,
);

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
