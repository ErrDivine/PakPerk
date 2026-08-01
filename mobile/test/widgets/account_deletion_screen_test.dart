import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/account_deletion/account_deletion.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/account/account_deletion_screen.dart';

import '../core/auth/auth_fakes.dart';

const _accountId = '00000000-0000-4000-8000-000000000123';
const _operationId = '00000000-0000-4000-8000-000000000789';
const _requestId = '00000000-0000-4000-8000-000000000999';

void main() {
  testWidgets(
    'unbound suspended session can delete with comments disabled at 200% text',
    (tester) async {
      final harness = await _Harness.create(boundAccountId: null);
      await _pumpScreen(tester, harness, textScale: 2, dark: true);

      expect(find.text('Permanently delete your Pakperk account?'), findsOne);
      final checkbox = find.descendant(
        of: find.byKey(const ValueKey('account-deletion-understand')),
        matching: find.byType(Checkbox),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-deletion-understand')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 120));
      await tester.pump();
      await tester.tap(checkbox);
      await tester.pump();
      final submit = find.byKey(const ValueKey('account-deletion-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('account-deletion-pending')), findsOne);
      expect(find.text('Deletion requested'), findsOne);
      expect(harness.remote.normalVerifyCalls, 1);
      expect(harness.remote.recentVerifyCalls, 1);
      expect(harness.remote.deleteCalls, 1);
      expect(harness.cleanupScopes, [_accountId]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('support link carries only a validated request_id', (
    tester,
  ) async {
    final harness = await _Harness.create();
    harness.remote.deleteError = const ApiException(
      code: 'ACCOUNT_DELETION_UNAVAILABLE',
      message: 'cleanup queued',
      retryable: true,
      statusCode: 503,
      requestId: _requestId,
    );
    await _pumpScreen(tester, harness);
    final understand = find.byKey(
      const ValueKey('account-deletion-understand'),
    );
    await tester.scrollUntilVisible(
      understand,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(understand);
    await tester.pump();
    final submit = find.byKey(const ValueKey('account-deletion-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final support = find.byKey(const ValueKey('account-deletion-support'));
    await tester.ensureVisible(support);
    await tester.tap(support);
    await tester.pump();

    expect(harness.links.opened, hasLength(1));
    final uri = harness.links.opened.single;
    expect(
      uri,
      Uri.parse('https://support.test/deletion?request_id=$_requestId'),
    );
    expect(uri.queryParameters.keys, ['request_id']);
  });

  testWidgets('terminal server failure requires operator review', (
    tester,
  ) async {
    final harness = await _Harness.create();
    harness.remote.serverState = AccountDeletionServerState.failedTerminal;
    await _pumpScreen(tester, harness);
    final understand = find.byKey(
      const ValueKey('account-deletion-understand'),
    );
    await tester.scrollUntilVisible(
      understand,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(understand);
    await tester.pump();
    final submit = find.byKey(const ValueKey('account-deletion-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('Deletion needs operator review'), findsOneWidget);
    expect(
      find.textContaining('will not continue automatically'),
      findsOneWidget,
    );
    expect(find.textContaining('account remains disabled'), findsOneWidget);
    expect(
      find.textContaining('server cleanup is still in progress'),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('account-deletion-support')),
      findsOneWidget,
    );
  });

  testWidgets('generic 503 renders an honest outcome-unknown state', (
    tester,
  ) async {
    final harness = await _Harness.create();
    harness.remote.deleteError = const ApiException(
      code: 'SERVICE_UNAVAILABLE',
      message: 'commit boundary unknown',
      retryable: true,
      statusCode: 503,
    );
    await _pumpScreen(tester, harness);
    final understand = find.byKey(
      const ValueKey('account-deletion-understand'),
    );
    await tester.scrollUntilVisible(
      understand,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(understand);
    await tester.pump();
    final submit = find.byKey(const ValueKey('account-deletion-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('Deletion outcome unknown'), findsOneWidget);
    expect(find.textContaining('could not confirm'), findsOneWidget);
    expect(find.textContaining('server worker'), findsNothing);
    expect(find.textContaining('Your account is disabled'), findsNothing);
    final web = find.byKey(const ValueKey('account-deletion-confirm-web'));
    await tester.tap(web);
    await tester.pump();
    expect(harness.links.opened, [
      Uri.parse('https://public.test/account-deletion'),
    ]);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _Harness harness, {
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBuildConfigProvider.overrideWithValue(_config()),
        authSessionProvider.overrideWith((ref) => harness.authSession),
        accountDeletionControllerProvider.overrideWith(
          (ref) => harness.deletionController,
        ),
        externalLinkOpenerProvider.overrideWithValue(harness.links),
      ],
      child: MaterialApp(
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        darkTheme: ThemeData.dark(useMaterial3: true),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const AccountDeletionScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AppBuildConfig _config() => AppBuildConfig.fromValues(const {
  'PAKPERK_ACCOUNTS_ENABLED': 'true',
  'PAKPERK_OIDC_ISSUER_URL': 'https://identity.example.test/realms/pakperk',
  'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile',
  'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth-dev://oauth/callback',
  'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI': 'pakperk-auth-dev://oauth/logout',
  'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://public.test',
  'PAKPERK_SUPPORT_URL': 'https://support.test/deletion',
});

final class _Harness {
  _Harness({
    required this.authSession,
    required this.deletionController,
    required this.remote,
    required this.cleanupScopes,
    required this.links,
  });

  static Future<_Harness> create({String? boundAccountId = _accountId}) async {
    final oidc = FakeOidcClient()
      ..reauthenticateHandler = () async => tokenSet(
        accessToken: 'recent-access',
        refreshToken: null,
        idToken: null,
      );
    final authRepository = AuthRepository(
      configuration: testOidcConfiguration,
      oidcClient: oidc,
      secureTokenStore: MemorySecureTokenStore(
        storedRecord(accountId: boundAccountId),
      ),
      clock: () => DateTime.utc(2029, 1, 1),
    );
    final cleanupScopes = <String?>[];
    final authSession = AuthSessionController(
      repository: authRepository,
      clearAccountOwnedData: (scope, _) async {
        cleanupScopes.add(scope);
      },
    );
    await authSession.restoreSession();
    final remote = _Remote();
    final repository = AccountDeletionRepository(
      auth: authRepository,
      remote: remote,
      guardStore: MemoryAccountDeletionGuardStore(),
      finalizeLocalDeletion: (scope) =>
          authSession.enterAccountDeletionPending(accountId: scope),
      telemetry: const NoopTelemetrySink(),
      clock: () => DateTime.utc(2029, 1, 1),
    );
    return _Harness(
      authSession: authSession,
      deletionController: AccountDeletionController(repository: repository),
      remote: remote,
      cleanupScopes: cleanupScopes,
      links: _Links(),
    );
  }

  final AuthSessionController authSession;
  final AccountDeletionController deletionController;
  final _Remote remote;
  final List<String?> cleanupScopes;
  final _Links links;
}

final class _Remote implements AccountDeletionRemoteDataSource {
  int normalVerifyCalls = 0;
  int recentVerifyCalls = 0;
  int deleteCalls = 0;
  ApiException? deleteError;
  AccountDeletionServerState serverState = AccountDeletionServerState.requested;

  @override
  Future<AccountDeletionVerification> verifyCurrentSession({
    required int expectedAuthEpoch,
  }) async {
    normalVerifyCalls += 1;
    return _verification();
  }

  @override
  Future<AccountDeletionVerification> verifyRecentSession({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) async {
    recentVerifyCalls += 1;
    return _verification();
  }

  @override
  Future<AccountDeletionOperation> deleteCurrentAccount({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) async {
    deleteCalls += 1;
    if (deleteError case final error?) throw error;
    return AccountDeletionOperation(
      operationId: _operationId,
      state: serverState,
      requestedAt: DateTime.utc(2029, 1, 1),
      updatedAt: DateTime.utc(2029, 1, 1),
    );
  }

  AccountDeletionVerification _verification() => AccountDeletionVerification(
    accountId: _accountId,
    status: AccountDeletionVerificationStatus.suspended,
    deletionOperationId: null,
  );
}

final class _Links implements ExternalLinkOpener {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}
