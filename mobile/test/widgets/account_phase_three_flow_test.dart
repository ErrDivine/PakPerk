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
      final completeSetup = find.widgetWithText(
        FilledButton,
        'Complete account setup',
      );
      await tester.ensureVisible(completeSetup);
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
      await tester.ensureVisible(communityCheckbox);
      expect(find.textContaining('Comments are public.'), findsOneWidget);
      expect(find.textContaining('sexual exploitation'), findsOneWidget);
      expect(find.textContaining('copyright abuse'), findsOneWidget);
      await tester.tap(communityCheckbox);
      await tester.pumpAndSettle();
      final support = find.byKey(const ValueKey('account-community-support'));
      await tester.ensureVisible(support);
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
      await tester.ensureVisible(completeSetup);
      await tester.pumpAndSettle();
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
        'accept_terms_version': '2026-07',
        'accept_community_guidelines_version': '2026-07',
      });
      expect(secureStore.record?.accountId, _accountId);
      expect(controllers.account.state.profile?.isProfileComplete, isTrue);
    },
  );

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

  testWidgets('pending save failure is visible after successful sign-in', (
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
      find.text('You are signed in, but this paper was not saved. Try again.'),
      findsOneWidget,
    );
    expect(pending.state?.kind, AppPendingActionKind.savePaper);

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
      find.text(
        'Sign in to sync your To Read list and join paper discussions.',
      ),
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
  _ProfileAdapter({this.completeOnGet = true});

  final bool completeOnGet;
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
        'account': _profileJson(complete: complete, version: version),
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
}) => {
  'id': _accountId,
  'handle': complete ? 'ada_reader' : null,
  'display_name': complete ? 'Ada Reader' : null,
  'status': 'active',
  'profile_version': version,
  'profile_complete': complete,
  'terms_version': complete ? '2026-07' : null,
  'terms_accepted_at': complete ? '2026-07-30T12:00:00Z' : null,
  'current_terms_version': '2026-07',
  'terms_current': complete,
  'community_guidelines_version': complete ? '2026-07' : null,
  'community_guidelines_accepted_at': complete ? '2026-07-30T12:00:00Z' : null,
  'current_community_guidelines_version': '2026-07',
  'community_guidelines_current': complete,
  'created_at': '2026-07-30T10:00:00Z',
  'updated_at': complete ? '2026-07-30T12:00:00Z' : '2026-07-30T11:00:00Z',
};
