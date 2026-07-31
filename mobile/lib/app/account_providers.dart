import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/account/account.dart';
import '../core/api/api_client.dart';
import '../core/api/auth_interceptor.dart';
import '../core/auth/auth.dart';
import '../core/cache/drift_local_store.dart';
import '../core/database/account_cache_dao.dart';
import '../core/providers.dart';
import 'feature_flags.dart';
import 'startup_controller.dart';

/// The one application transport. It is owned by the root provider container,
/// not by an individual repository, so rotating the anonymous session cannot
/// close the transport used by account requests.
final pakPerkDioProvider = Provider<Dio>((ref) {
  final config = ref.watch(appBuildConfigProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: config.apiBaseUri.toString(),
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 10),
      followRedirects: false,
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );
  dio.interceptors.add(const _RequestIdInterceptor());
  if (config.features.accounts) {
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        apiBaseUri: config.apiBaseUri,
        tokenSource: ref.watch(authSessionProvider.notifier),
      ),
    );
  }
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

final oidcClientConfigurationProvider = Provider<OidcClientConfiguration>((
  ref,
) {
  final config = ref.watch(appBuildConfigProvider);
  if (!config.features.accounts) {
    throw StateError(
      'OIDC configuration is unavailable when accounts are off.',
    );
  }
  return OidcClientConfiguration(
    issuer: config.oidcIssuerUri!,
    clientId: config.oidcClientId!,
    redirectUri: config.oidcRedirectUri!,
    postLogoutRedirectUri: config.oidcPostLogoutRedirectUri!,
    scopes: config.oidcScopes,
    allowInsecureLocalhost: config.environment == AppEnvironment.development,
  );
});

final secureTokenStoreProvider = Provider<SecureTokenStore>(
  (ref) => FlutterSecureTokenStore(),
);

final oidcClientProvider = Provider<OidcClient>(
  (ref) => FlutterAppAuthOidcClient(
    configuration: ref.watch(oidcClientConfigurationProvider),
  ),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    configuration: ref.watch(oidcClientConfigurationProvider),
    oidcClient: ref.watch(oidcClientProvider),
    secureTokenStore: ref.watch(secureTokenStoreProvider),
  ),
);

/// Clears only local rows whose lifecycle belongs to an account. Public paper
/// metadata, feed windows, and reading restoration are deliberately untouched.
final accountOwnedDataClearerProvider = Provider<AccountOwnedDataClearer>((
  ref,
) {
  return (accountId) async {
    final store = ref.read(localStoreProvider);
    if (store is! DriftLocalStore) return;
    final accountCache = AccountCacheDao(store.database);
    if (accountId == null) {
      await accountCache.clearAllAccountData();
    } else {
      await accountCache.clearAccountData(accountId);
    }
  };
});

final authSessionProvider =
    StateNotifierProvider<AuthSessionController, AuthSessionState>((ref) {
      if (!ref.watch(featureFlagsProvider).accounts) {
        throw StateError(
          'authSessionProvider was read with accounts disabled.',
        );
      }
      return AuthSessionController(
        repository: ref.watch(authRepositoryProvider),
        clearAccountOwnedData: ref.watch(accountOwnedDataClearerProvider),
      );
    });

final accountApiProvider = Provider<AccountApi>(
  (ref) => AccountApi(ref.watch(pakPerkDioProvider)),
);

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(accountApiProvider)),
);

final currentAccountProvider =
    StateNotifierProvider<CurrentAccountController, CurrentAccountState>((ref) {
      if (!ref.watch(featureFlagsProvider).accounts) {
        throw StateError(
          'currentAccountProvider was read with accounts disabled.',
        );
      }
      final controller = CurrentAccountController(
        repository: ref.watch(accountRepositoryProvider),
        sessionEpoch: () => ref.read(authSessionProvider).epoch,
        bindAccountId: ref.read(authSessionProvider.notifier).bindAccountId,
      );
      ref.listen<AuthSessionState>(authSessionProvider, (previous, next) {
        if (previous != null && previous.epoch != next.epoch) {
          controller.clear();
        }
      });
      return controller;
    });

enum AppPendingActionKind { savePaper, openComposer, reportComment, blockUser }

/// One credential-free, in-memory action marker that can cross an AppAuth
/// round trip. Feature phases install an executor for the action they own.
final class AppPendingAuthenticatedAction
    implements PendingAuthenticatedAction {
  AppPendingAuthenticatedAction({required this.kind, required this.targetId}) {
    if (targetId.trim().isEmpty || targetId.length > 256) {
      throw ArgumentError.value(targetId, 'targetId', 'Must be 1-256 chars.');
    }
  }

  final AppPendingActionKind kind;
  final String targetId;

  @override
  String get actionType => kind.name;
}

final pendingAuthenticatedActionProvider =
    StateNotifierProvider<
      PendingAuthenticatedActionController<AppPendingAuthenticatedAction>,
      AppPendingAuthenticatedAction?
    >((ref) => PendingAuthenticatedActionController());

typedef PendingAuthenticatedActionExecutor =
    Future<void> Function(AppPendingAuthenticatedAction action);

final pendingAuthenticatedActionExecutorProvider =
    Provider<PendingAuthenticatedActionExecutor>((ref) {
      return (action) async {
        throw StateError(
          'No executor is registered for pending ${action.kind.name}.',
        );
      };
    });

/// Adds account work to the existing startup machine without making OIDC or
/// `/v1/me` part of the first-readable-frame gate.
final class AccountAwareStartupBootstrapper implements StartupBootstrapper {
  const AccountAwareStartupBootstrapper({
    required StartupBootstrapper delegate,
    required AuthSessionController authSession,
    required CurrentAccountController currentAccount,
  }) : _delegate = delegate,
       _authSession = authSession,
       _currentAccount = currentAccount;

  final StartupBootstrapper _delegate;
  final AuthSessionController _authSession;
  final CurrentAccountController _currentAccount;

  @override
  Future<void> hydrateLocalState() => _delegate.hydrateLocalState();

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() async {
    final status = await _authSession.inspectStoredSession();
    return switch (status) {
      AuthStoredSessionStatus.guest => StartupSessionStatus.anonymous,
      AuthStoredSessionStatus.refreshRequired =>
        StartupSessionStatus.refreshRequired,
    };
  }

  @override
  Future<void> repairLocalStatePreservingCredentials() =>
      _delegate.repairLocalStatePreservingCredentials();

  @override
  Future<void> runPostReadyWork() async {
    await Future.wait<void>([
      _delegate.runPostReadyWork(),
      _restoreAccount(),
    ], eagerError: false);
  }

  Future<void> _restoreAccount() async {
    if (await _authSession.restoreSession()) await _currentAccount.load();
  }
}

/// Production root overrides. Focused tests can keep using the original
/// independent API provider or override individual account seams.
List<Override> accountApplicationOverrides(
  StartupBootstrapper bootstrapper,
) => [
  startupBootstrapperProvider.overrideWith((ref) {
    if (!ref.watch(featureFlagsProvider).accounts) return bootstrapper;
    return AccountAwareStartupBootstrapper(
      delegate: bootstrapper,
      authSession: ref.watch(authSessionProvider.notifier),
      currentAccount: ref.watch(currentAccountProvider.notifier),
    );
  }),
  apiClientProvider.overrideWith((ref) {
    final client = ApiClient(
      baseUrl: ref.watch(appBuildConfigProvider).apiBaseUri.toString(),
      sessionId: ref.watch(anonymousSessionIdProvider),
      dio: ref.watch(pakPerkDioProvider),
    );
    // Injected transports are non-owned by ApiClient; this releases only the
    // facade while [pakPerkDioProvider] remains the sole transport owner.
    ref.onDispose(client.dispose);
    return client;
  }),
];

final class _RequestIdInterceptor extends Interceptor {
  const _RequestIdInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.putIfAbsent('X-Request-Id', () => const Uuid().v4());
    handler.next(options);
  }
}
