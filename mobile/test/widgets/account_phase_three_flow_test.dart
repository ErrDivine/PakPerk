import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/router.dart';
import 'package:pakperk/core/account/account.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/account/account_home_screen.dart';
import 'package:pakperk/features/account/auth_flow_screen.dart';

import '../core/auth/auth_fakes.dart';

void main() {
  testWidgets(
    'auth route clears pending intent and cannot sign in during deletion',
    (tester) async {
      final oidc = FakeOidcClient();
      final controllers = _controllers(
        oidc: oidc,
        secureStore: MemorySecureTokenStore(storedRecord()),
        adapter: _ProfileAdapter(),
      );
      await controllers.auth.inspectStoredSession();
      expect(await controllers.auth.enterAccountDeletionPending(), isTrue);
      final pending =
          PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
            ..replace(
              AppPendingAuthenticatedAction(
                kind: AppPendingActionKind.savePaper,
                targetId: '17060376-2000-4000-8000-000000000001',
              ),
            );
      final router = _authRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(_accountConfig()),
            authSessionProvider.overrideWith((ref) => controllers.auth),
            currentAccountProvider.overrideWith((ref) => controllers.account),
            pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Account deletion is pending'), findsOneWidget);
      expect(
        find.textContaining('Continue with public reading'),
        findsOneWidget,
      );
      expect(oidc.authorizeCalls, 0);
      expect(pending.state, isNull);
      expect(controllers.auth.state.phase, AuthSessionPhase.deletionPending);
    },
  );

  testWidgets(
    'Account You never renders a profile from a different bound identity',
    (tester) async {
      const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
      final controllers = _controllers(
        oidc: FakeOidcClient(),
        secureStore: MemorySecureTokenStore(
          storedRecord(accountId: _accountId),
        ),
        adapter: _ProfileAdapter(),
      );
      expect(await controllers.auth.restoreSession(), isTrue);
      final load = controllers.account.load();
      for (
        var attempt = 0;
        attempt < 100 &&
            controllers.account.state.phase == CurrentAccountPhase.loading;
        attempt += 1
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect((await load)?.id, _accountId);
      expect(controllers.account.state.profile?.displayName, 'Ada Reader');

      await controllers.auth.bindAccountId(accountB);
      expect(controllers.auth.state.accountId, accountB);
      expect(controllers.account.state.profile?.id, _accountId);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(_accountConfig()),
            authSessionProvider.overrideWith((ref) => controllers.auth),
            currentAccountProvider.overrideWith((ref) => controllers.account),
          ],
          child: MaterialApp(
            home: AccountYouScreen(
              onSignIn: () {},
              onCompleteProfile: () {},
              onOpenLibrary: () {},
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

      expect(find.text('Ada Reader'), findsNothing);
      expect(find.text('@ada_reader'), findsNothing);
      expect(
        find.textContaining('Account details do not match this session'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'system sign-in provisions profile, completes onboarding, resumes once',
    (tester) async {
      final oidc = FakeOidcClient();
      final secureStore = MemorySecureTokenStore();
      final adapter = _ProfileAdapter(completeOnGet: false);
      final controllers = _controllers(
        oidc: oidc,
        secureStore: secureStore,
        adapter: adapter,
      );
      final pending =
          PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
            ..replace(
              AppPendingAuthenticatedAction(
                kind: AppPendingActionKind.openComposer,
                targetId: '17060376-2000-4000-8000-000000000001',
              ),
            );
      var resumed = 0;
      final router = _authRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(_accountConfig()),
            authSessionProvider.overrideWith((ref) => controllers.auth),
            currentAccountProvider.overrideWith((ref) => controllers.account),
            pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
            pendingAuthenticatedActionExecutorProvider.overrideWithValue((
              action,
            ) async {
              resumed += 1;
              expect(action.actionType, 'openComposer');
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(oidc.authorizeCalls, 1);
      expect(adapter.requests.map((request) => request.method), ['GET']);
      expect(find.text('Finish account setup'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('account-handle-field')),
        'ada_reader',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-display-name-field')),
        'Ada Reader',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('account-terms-checkbox')),
          matching: find.byType(Checkbox),
        ),
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final onboardingScrollable = find
          .descendant(of: find.byType(Form), matching: find.byType(Scrollable))
          .first;
      final completeSetup = find.byKey(
        const ValueKey('account-complete-setup-button'),
      );
      await tester.scrollUntilVisible(
        completeSetup,
        240,
        scrollable: onboardingScrollable,
      );
      await tester.tap(completeSetup);
      await tester.pumpAndSettle();
      expect(
        find.text('Accept the current Community Guidelines to continue.'),
        findsOneWidget,
      );
      expect(adapter.requests.map((request) => request.method), ['GET']);
      expect(resumed, 0);

      final communityCheckbox = find.descendant(
        of: find.byKey(const ValueKey('account-community-checkbox')),
        matching: find.byType(Checkbox),
      );
      await tester.scrollUntilVisible(
        communityCheckbox,
        240,
        scrollable: onboardingScrollable,
      );
      expect(find.textContaining('Comments are public.'), findsOneWidget);
      expect(find.textContaining('sexual exploitation'), findsOneWidget);
      expect(find.textContaining('copyright abuse'), findsOneWidget);
      await tester.tap(communityCheckbox);
      await tester.pumpAndSettle();
      final support = find.byKey(const ValueKey('account-community-support'));
      await tester.scrollUntilVisible(
        support,
        240,
        scrollable: onboardingScrollable,
      );
      expect(
        find.text(
          'Support/moderation contact: https://support.test/moderation',
        ),
        findsOneWidget,
      );
      await tester.tap(support);
      await tester.pumpAndSettle();
      expect(find.text('Support and moderation route'), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        completeSetup,
        240,
        scrollable: onboardingScrollable,
      );
      await tester.tap(completeSetup);
      await tester.pumpAndSettle();

      expect(find.text('You destination'), findsOneWidget);
      expect(resumed, 1);
      expect(pending.state, isNull);
      expect(adapter.requests.map((request) => request.method), [
        'GET',
        'PATCH',
      ]);
      expect(adapter.requests.last.headers['If-Match'], '"profile-1"');
      expect(jsonDecode(adapter.bodies.last), {
        'handle': 'ada_reader',
        'display_name': 'Ada Reader',
        'accept_terms_version': '2026-07-31',
        'accept_community_guidelines_version': '2026-07-31',
      });
      expect(secureStore.record?.accountId, _accountId);
      expect(controllers.account.state.profile?.isProfileComplete, isTrue);
    },
  );

  testWidgets('outdated bundled policies cannot be accepted', (tester) async {
    final adapter = _ProfileAdapter(
      completeOnGet: false,
      policyVersion: '2026-08-01',
    );
    final controllers = _controllers(
      oidc: FakeOidcClient(),
      secureStore: MemorySecureTokenStore(),
      adapter: adapter,
    );
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
          ..replace(
            AppPendingAuthenticatedAction(
              kind: AppPendingActionKind.openComposer,
              targetId: '17060376-2000-4000-8000-000000000001',
            ),
          );
    final router = _authRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountConfig()),
          authSessionProvider.overrideWith((ref) => controllers.auth),
          currentAccountProvider.overrideWith((ref) => controllers.account),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final onboardingScrollable = find
        .descendant(of: find.byType(Form), matching: find.byType(Scrollable))
        .first;
    final termsFinder = find.descendant(
      of: find.byKey(const ValueKey('account-terms-checkbox')),
      matching: find.byType(Checkbox),
    );
    await tester.scrollUntilVisible(
      termsFinder,
      240,
      scrollable: onboardingScrollable,
    );
    final terms = tester.widget<Checkbox>(termsFinder);
    expect(terms.onChanged, isNull);
    expect(
      find.text('Update Pakperk before accepting the current terms.'),
      findsOneWidget,
    );

    final guidelinesFinder = find.descendant(
      of: find.byKey(const ValueKey('account-community-checkbox')),
      matching: find.byType(Checkbox),
    );
    await tester.scrollUntilVisible(
      guidelinesFinder,
      240,
      scrollable: onboardingScrollable,
    );
    final guidelines = tester.widget<Checkbox>(guidelinesFinder);
    expect(guidelines.onChanged, isNull);
    final guidelinesUpdateMessage = find.text(
      'Update Pakperk before accepting the current Community Guidelines.',
    );
    await tester.scrollUntilVisible(
      guidelinesUpdateMessage,
      120,
      scrollable: onboardingScrollable,
    );
    expect(guidelinesUpdateMessage, findsOneWidget);
    expect(adapter.requests.map((request) => request.method), ['GET']);
  });

  testWidgets(
    'pending save resumes after active account without profile onboarding',
    (tester) async {
      final oidc = FakeOidcClient();
      final adapter = _ProfileAdapter(completeOnGet: false);
      final controllers = _controllers(
        oidc: oidc,
        secureStore: MemorySecureTokenStore(),
        adapter: adapter,
      );
      final pending =
          PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
            ..replace(
              AppPendingAuthenticatedAction(
                kind: AppPendingActionKind.savePaper,
                targetId: '17060376-2000-4000-8000-000000000001',
              ),
            );
      var resumed = 0;
      final router = _authRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(_accountConfig()),
            authSessionProvider.overrideWith((ref) => controllers.auth),
            currentAccountProvider.overrideWith((ref) => controllers.account),
            pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
            pendingAuthenticatedActionExecutorProvider.overrideWithValue((
              action,
            ) async {
              resumed += 1;
              expect(action.kind, AppPendingActionKind.savePaper);
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('You destination'), findsOneWidget);
      expect(find.text('Finish account setup'), findsNothing);
      expect(resumed, 1);
      expect(pending.state, isNull);
      expect(adapter.requests.map((request) => request.method), ['GET']);
      expect(controllers.account.state.profile?.isProfileComplete, isFalse);
    },
  );

  testWidgets('pending save failure is visible and the action stays consumed', (
    tester,
  ) async {
    final controllers = _controllers(
      oidc: FakeOidcClient(),
      secureStore: MemorySecureTokenStore(),
      adapter: _ProfileAdapter(completeOnGet: false),
    );
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
          ..replace(
            AppPendingAuthenticatedAction(
              kind: AppPendingActionKind.savePaper,
              targetId: '17060376-2000-4000-8000-000000000001',
            ),
          );
    final router = _authRouter(initialLocation: '/you');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountConfig()),
          authSessionProvider.overrideWith((ref) => controllers.auth),
          currentAccountProvider.overrideWith((ref) => controllers.account),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
          pendingAuthenticatedActionExecutorProvider.overrideWithValue((
            action,
          ) async {
            throw StateError('simulated local write failure');
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push<void>('/auth'));
    await tester.pumpAndSettle();

    expect(find.text('Save could not be completed'), findsOneWidget);
    expect(
      find.text(
        'You are signed in, but this paper was not saved. Return and try '
        'again.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Return'), findsOneWidget);
    expect(pending.state, isNull);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('You destination'), findsOneWidget);
    expect(pending.state, isNull);
  });

  testWidgets('cancelled AppAuth clears pending action and returns in place', (
    tester,
  ) async {
    final oidc = FakeOidcClient()
      ..authorizeHandler = () async =>
          throw const OidcClientException.cancelled();
    final adapter = _ProfileAdapter(completeOnGet: false);
    final controllers = _controllers(
      oidc: oidc,
      secureStore: MemorySecureTokenStore(),
      adapter: adapter,
    );
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>()
          ..replace(
            AppPendingAuthenticatedAction(
              kind: AppPendingActionKind.openComposer,
              targetId: '17060376-2000-4000-8000-000000000001',
            ),
          );
    final router = _authRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountConfig()),
          authSessionProvider.overrideWith((ref) => controllers.auth),
          currentAccountProvider.overrideWith((ref) => controllers.account),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('You destination'), findsOneWidget);
    expect(controllers.auth.state.phase, AuthSessionPhase.guest);
    expect(pending.state, isNull);
    expect(adapter.requests, isEmpty);
  });

  testWidgets('offline saved session can open cached To Read from You', (
    tester,
  ) async {
    final oidc = FakeOidcClient()
      ..refreshHandler = (_) async => throw const OidcClientException.network();
    final controllers = _controllers(
      oidc: oidc,
      secureStore: MemorySecureTokenStore(storedRecord(accountId: _accountId)),
      adapter: _ProfileAdapter(),
    );
    expect(await controllers.auth.restoreSession(), isFalse);
    expect(controllers.auth.state.phase, AuthSessionPhase.offlineAuthUnknown);
    var libraryOpened = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const FeatureFlags(
              accounts: true,
              library: true,
              comments: true,
              openingMotion: false,
            ),
          ),
          authSessionProvider.overrideWith((ref) => controllers.auth),
        ],
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

    expect(find.text('Account status is offline'), findsOneWidget);
    expect(find.text('Open cached To Read'), findsOneWidget);
    final toRead = find.byKey(const ValueKey('offline-account-to-read'));
    await tester.ensureVisible(toRead);
    await tester.tap(toRead);
    expect(libraryOpened, isTrue);
  });

  testWidgets('offline unbound session does not offer an empty To Read hop', (
    tester,
  ) async {
    final oidc = FakeOidcClient()
      ..refreshHandler = (_) async => throw const OidcClientException.network();
    final controllers = _controllers(
      oidc: oidc,
      secureStore: MemorySecureTokenStore(storedRecord()),
      adapter: _ProfileAdapter(),
    );
    expect(await controllers.auth.restoreSession(), isFalse);
    expect(controllers.auth.state.phase, AuthSessionPhase.offlineAuthUnknown);
    expect(controllers.auth.state.accountId, isNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const FeatureFlags(
              accounts: true,
              library: true,
              comments: true,
              openingMotion: false,
            ),
          ),
          authSessionProvider.overrideWith((ref) => controllers.auth),
        ],
        child: MaterialApp(
          home: AccountYouScreen(
            onSignIn: () {},
            onCompleteProfile: () {},
            onOpenLibrary: () {},
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

    expect(find.text('Account status is offline'), findsOneWidget);
    expect(find.text('Open cached To Read'), findsNothing);
    expect(find.byKey(const ValueKey('offline-account-to-read')), findsNothing);
  });

  testWidgets(
    'suspended account keeps support, sign-out, and in-app deletion access',
    (tester) async {
      final controllers = _controllers(
        oidc: FakeOidcClient(),
        secureStore: MemorySecureTokenStore(
          storedRecord(accountId: _accountId),
        ),
        adapter: _ProfileAdapter(),
      );
      expect(await controllers.auth.restoreSession(), isTrue);
      final profileLoad = controllers.account.load();
      for (
        var attempt = 0;
        attempt < 100 &&
            controllers.account.state.phase == CurrentAccountPhase.loading;
        attempt += 1
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(await profileLoad, isNotNull);
      controllers.account.recordAuthoritativeReadOnlyStatus(
        errorCode: 'ACCOUNT_SUSPENDED',
        authEpoch: controllers.auth.state.epoch,
      );
      var supportOpened = false;
      var deletionOpened = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(_accountConfig()),
            authSessionProvider.overrideWith((ref) => controllers.auth),
            currentAccountProvider.overrideWith((ref) => controllers.account),
          ],
          child: MaterialApp(
            home: AccountYouScreen(
              onSignIn: () {},
              onCompleteProfile: () {},
              onOpenLibrary: () {},
              onOpenComments: () {},
              onOpenBlockedUsers: () {},
              onOpenSettings: () {},
              onOpenPrivacy: () {},
              onOpenTerms: () {},
              onOpenCommunityGuidelines: () {},
              onOpenSupport: () => supportOpened = true,
              onOpenDeleteAccount: () => deletionOpened = true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Account suspended'), findsOneWidget);
      final support = find.widgetWithText(TextButton, 'Support');
      expect(support, findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Sign out'), findsOneWidget);
      final deletion = find.byKey(const ValueKey('read-only-account-delete'));
      expect(deletion, findsOneWidget);

      await tester.ensureVisible(support);
      await tester.pump();
      await tester.tap(support);
      await tester.ensureVisible(deletion);
      await tester.pump();
      await tester.tap(deletion);
      expect(supportOpened, isTrue);
      expect(deletionOpened, isTrue);
      expect(controllers.auth.state.phase, AuthSessionPhase.authenticated);
    },
  );

  testWidgets('authenticated You signs out without clearing public reading', (
    tester,
  ) async {
    final publicCache = <String>{'public-paper'};
    final accountRows = <String>{'private-library-row', 'private-draft'};
    final oidc = FakeOidcClient();
    final secureStore = MemorySecureTokenStore();
    final adapter = _ProfileAdapter();
    final controllers = _controllers(
      oidc: oidc,
      secureStore: secureStore,
      adapter: adapter,
      clearAccountData: (_, __) async => accountRows.clear(),
    );
    expect(await controllers.auth.signIn(), isTrue);
    final profileLoad = controllers.account.load();
    for (
      var attempt = 0;
      attempt < 100 &&
          controllers.account.state.phase == CurrentAccountPhase.loading;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(controllers.account.state.phase, CurrentAccountPhase.ready);
    expect(await profileLoad, isNotNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountConfig()),
          authSessionProvider.overrideWith((ref) => controllers.auth),
          currentAccountProvider.overrideWith((ref) => controllers.account),
        ],
        child: MaterialApp(
          home: AccountYouScreen(
            onSignIn: () {},
            onCompleteProfile: () {},
            onOpenLibrary: () {},
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
    await tester.pumpAndSettle();

    expect(find.text('Ada Reader'), findsOneWidget);
    expect(find.text('@ada_reader'), findsOneWidget);
    expect(find.text('To Read'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Sign out'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    for (
      var attempt = 0;
      attempt < 100 && controllers.auth.state.phase != AuthSessionPhase.guest;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(controllers.auth.state.phase, AuthSessionPhase.guest);
    await tester.pump();

    expect(
      find.text('Sign in to manage your Pakperk account.'),
      findsOneWidget,
    );
    expect(accountRows, isEmpty);
    expect(publicCache, {'public-paper'});
    expect(secureStore.record, isNull);
    expect(oidc.endSessionCalls, 1);
  });

  testWidgets('authenticated You remains navigable at 200% text scaling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final profile = AccountProfile.fromJson(_profileJson(complete: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: AuthenticatedAccountHomeScreen(
              profile: profile,
              updating: false,
              onCompleteProfile: () {},
              onEditDisplayName: () {},
              onOpenLibrary: () {},
              onOpenComments: () {},
              onOpenBlockedUsers: () {},
              onOpenSettings: () {},
              onOpenPrivacy: () {},
              onOpenTerms: () {},
              onOpenCommunityGuidelines: () {},
              onOpenSupport: () {},
              onOpenDeleteAccount: () {},
              onSignOut: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Delete account'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Delete account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

({AuthSessionController auth, CurrentAccountController account}) _controllers({
  required FakeOidcClient oidc,
  required MemorySecureTokenStore secureStore,
  required HttpClientAdapter adapter,
  AccountOwnedDataClearer? clearAccountData,
}) {
  late final AuthSessionController auth;
  final repository = AuthRepository(
    configuration: testOidcConfiguration,
    oidcClient: oidc,
    secureTokenStore: secureStore,
    clock: () => DateTime.utc(2026, 7, 31),
  );
  auth = AuthSessionController(
    repository: repository,
    clearAccountOwnedData: clearAccountData ?? ((_, __) async {}),
  );
  final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
    ..httpClientAdapter = adapter;
  final account = CurrentAccountController(
    repository: AccountRepository(AccountApi(dio)),
    sessionEpoch: () => auth.state.epoch,
    sessionAccountId: () => auth.state.accountId,
    bindAccountId: auth.bindAccountId,
  );
  return (auth: auth, account: account);
}

GoRouter _authRouter({String initialLocation = '/auth'}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/auth', builder: (_, __) => const AuthFlowScreen()),
    GoRoute(
      path: '/you',
      builder: (_, __) => const Scaffold(body: Text('You destination')),
    ),
    GoRoute(
      path: PakPerkRoutes.communityGuidelines,
      builder: (_, __) => const Scaffold(body: Text('Community rules route')),
    ),
    GoRoute(
      path: PakPerkRoutes.support,
      builder: (_, __) =>
          const Scaffold(body: Text('Support and moderation route')),
    ),
  ],
);

AppBuildConfig _accountConfig() => AppBuildConfig.fromValues(const {
  'PAKPERK_ACCOUNTS_ENABLED': 'true',
  'PAKPERK_OIDC_ISSUER_URL': 'https://identity.example.test/realms/pakperk',
  'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile',
  'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
  'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI': 'pakperk-auth-dev://oauth/logout',
  'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://public.test',
  'PAKPERK_SUPPORT_URL': 'https://support.test/moderation',
});

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

final class _ProfileAdapter implements HttpClientAdapter {
  _ProfileAdapter({
    this.completeOnGet = true,
    this.policyVersion = bundledTermsDocumentVersion,
  });

  final bool completeOnGet;
  final String policyVersion;
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    final patched = options.method == 'PATCH';
    final complete = patched || completeOnGet;
    final version = patched ? 2 : 1;
    return ResponseBody.fromString(
      jsonEncode({
        'account': _profileJson(
          complete: complete,
          version: version,
          policyVersion: policyVersion,
        ),
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"profile-$version"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _profileJson({
  required bool complete,
  int version = 1,
  String policyVersion = bundledTermsDocumentVersion,
}) => {
  'id': _accountId,
  'handle': complete ? 'ada_reader' : null,
  'display_name': complete ? 'Ada Reader' : null,
  'status': 'active',
  'profile_version': version,
  'profile_complete': complete,
  'terms_version': complete ? policyVersion : null,
  'terms_accepted_at': complete ? '2026-07-30T12:00:00Z' : null,
  'current_terms_version': policyVersion,
  'terms_current': complete,
  'community_guidelines_version': complete ? policyVersion : null,
  'community_guidelines_accepted_at': complete ? '2026-07-30T12:00:00Z' : null,
  'current_community_guidelines_version': policyVersion,
  'community_guidelines_current': complete,
  'created_at': '2026-07-30T10:00:00Z',
  'updated_at': complete ? '2026-07-30T12:00:00Z' : '2026-07-30T11:00:00Z',
};
