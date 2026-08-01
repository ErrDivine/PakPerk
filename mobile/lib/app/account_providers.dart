import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/account/account.dart';
import '../core/account/account_data_write_barrier.dart';
import '../core/account_deletion/account_deletion.dart';
import '../core/api/api_client.dart';
import '../core/api/auth_interceptor.dart';
import '../core/api/http_telemetry_interceptor.dart';
import '../core/api/safe_retry_interceptor.dart';
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
  dio.interceptors.add(const PakPerkRequestIdInterceptor());
  if (config.features.accounts) {
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        apiBaseUri: config.apiBaseUri,
        tokenSource: ref.watch(authSessionProvider.notifier),
        onAccountDeletionPending: (expectedAuthEpoch, requestId) async {
          final session = ref.read(authSessionProvider);
          if (session.epoch != expectedAuthEpoch) return;
          final accountId = session.accountId;
          final guard = AccountDeletionGuardRecord(
            acceptance: LocalAccountDeletionAcceptance.serviceUnavailable,
            accountId: accountId,
            requestId: requestId,
            acceptedAt: DateTime.now().toUtc(),
            localCleanupComplete: false,
          );
          final store = ref.read(accountDeletionGuardStoreProvider);
          Object? guardFailure;
          try {
            await store.write(guard);
          } on Object catch (error) {
            guardFailure = error;
          }
          final cleaned = await ref.read(accountDeletionLocalFinalizerProvider)(
            accountId,
          );
          if (cleaned) {
            try {
              await store.write(guard.cleanupCompleted());
            } on Object {
              guardFailure ??= StateError('Deletion guard update failed.');
            }
          }
          if (guardFailure != null) throw guardFailure;
        },
      ),
    );
  }
  dio.interceptors.add(
    SafeRetryInterceptor(dio: dio, apiBaseUri: config.apiBaseUri),
  );
  dio.interceptors.add(
    HttpTelemetryInterceptor(
      apiBaseUri: config.apiBaseUri,
      telemetry: ref.watch(telemetrySinkProvider),
    ),
  );
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
  final redirectUri = config.oidcRedirectUri!;
  return OidcClientConfiguration(
    issuer: config.oidcIssuerUri!,
    clientId: config.oidcClientId!,
    redirectUri: redirectUri,
    postLogoutRedirectUri: config.oidcPostLogoutRedirectUri!,
    scopes: config.oidcScopes,
    registeredRedirectScheme: redirectUri.scheme,
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
final accountDataWriteBarrierProvider = Provider<AccountDataWriteBarrier>(
  (ref) => AccountDataWriteBarrier(),
);

final accountOwnedDataClearerProvider = Provider<AccountOwnedDataClearer>((
  ref,
) {
  return (accountId, invalidatedThroughEpoch) async {
    final store = await ref.read(localStoreWhenReadyProvider)();
    if (store is! DriftLocalStore) return;
    final accountCache = AccountCacheDao(store.database);
    await ref
        .read(accountDataWriteBarrierProvider)
        .clear(
          accountId: accountId,
          invalidatedThroughEpoch: invalidatedThroughEpoch,
          clearAccount: accountCache.clearAccountData,
          clearAll: accountCache.clearAllAccountData,
        );
  };
});

typedef AccountDeletionLocalFinalizer =
    Future<bool> Function(String? accountId);

final accountDeletionCommentCachePurgerProvider =
    Provider<Future<void> Function()>((ref) {
      return () async {
        final store = await ref.read(localStoreWhenReadyProvider)();
        await store.purgeAccountDeletionCommentSnapshots();
      };
    });

/// Deletion is stronger than sign-out: it clears the authenticated scope and
/// every guest/authenticated comment snapshot that could retain the deleted
/// author's old public body or handle. Both operations are attempted, and the
/// durable deletion guard remains incomplete unless both succeed.
final accountDeletionLocalFinalizerProvider =
    Provider<AccountDeletionLocalFinalizer>((ref) {
      return (accountId) async {
        var sessionCleaned = false;
        var commentPagesPurged = false;
        try {
          sessionCleaned = await ref
              .read(authSessionProvider.notifier)
              .enterAccountDeletionPending(accountId: accountId);
        } on Object {
          // Continue to the independent comment-cache purge.
        }
        try {
          await ref.read(accountDeletionCommentCachePurgerProvider)();
          commentPagesPurged = true;
        } on Object {
          // The caller retains its durable guard for startup recovery.
        }
        return sessionCleaned && commentPagesPurged;
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
        telemetry: ref.watch(telemetrySinkProvider),
      );
    });

final accountDeletionGuardStoreProvider = Provider<AccountDeletionGuardStore>(
  (ref) => const SharedPreferencesAccountDeletionGuardStore(),
);

final accountApiProvider = Provider<AccountApi>(
  (ref) => AccountApi(ref.watch(pakPerkDioProvider)),
);

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(accountApiProvider)),
);

final accountDeletionApiProvider = Provider<AccountDeletionRemoteDataSource>(
  (ref) => AccountDeletionApi(ref.watch(pakPerkDioProvider)),
);

final accountDeletionRepositoryProvider = Provider<AccountDeletionRepository>(
  (ref) => AccountDeletionRepository(
    auth: ref.watch(authRepositoryProvider),
    remote: ref.watch(accountDeletionApiProvider),
    guardStore: ref.watch(accountDeletionGuardStoreProvider),
    finalizeLocalDeletion: ref.watch(accountDeletionLocalFinalizerProvider),
    telemetry: ref.watch(telemetrySinkProvider),
  ),
);

final accountDeletionControllerProvider =
    StateNotifierProvider<AccountDeletionController, AccountDeletionState>((
      ref,
    ) {
      if (!ref.watch(featureFlagsProvider).accounts) {
        throw StateError(
          'accountDeletionControllerProvider was read with accounts disabled.',
        );
      }
      return AccountDeletionController(
        repository: ref.watch(accountDeletionRepositoryProvider),
      );
    });

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

enum AppPendingActionKind {
  savePaper,
  openComposer,
  reportComment,
  reportUser,
  blockUser,
}

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
  AccountAwareStartupBootstrapper({
    required StartupBootstrapper delegate,
    required AuthSessionController authSession,
    required CurrentAccountController currentAccount,
    required AccountDeletionController accountDeletion,
  }) : _delegate = delegate,
       _authSession = authSession,
       _currentAccount = currentAccount,
       _accountDeletion = accountDeletion;

  final StartupBootstrapper _delegate;
  final AuthSessionController _authSession;
  final CurrentAccountController _currentAccount;
  final AccountDeletionController _accountDeletion;
  bool _deletionPending = false;
  Future<StartupSessionStatus>? _sessionInspection;

  @override
  Future<void> hydrateLocalState() => _delegate.hydrateLocalState();

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() {
    final active = _sessionInspection;
    if (active != null) return active;
    final operation = _checkAuthenticatedSession();
    late final Future<StartupSessionStatus> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_sessionInspection, tracked)) {
        _sessionInspection = null;
      }
    });
    _sessionInspection = tracked;
    return tracked;
  }

  Future<StartupSessionStatus> _checkAuthenticatedSession() {
    final delegate = _delegate;
    if (delegate is StartupLocalStoreLeaseCoordinator) {
      return (delegate as StartupLocalStoreLeaseCoordinator)
          .withStartupLocalStoreLease(_inspectAuthenticatedSession);
    }
    return _inspectAuthenticatedSession();
  }

  Future<StartupSessionStatus> _inspectAuthenticatedSession() async {
    _deletionPending = await _accountDeletion.recoverAtStartup();
    if (_deletionPending) return StartupSessionStatus.anonymous;
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
    if (_deletionPending) return;
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
      accountDeletion: ref.watch(accountDeletionControllerProvider.notifier),
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

final class PakPerkRequestIdInterceptor extends Interceptor {
  const PakPerkRequestIdInterceptor();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.putIfAbsent('X-Request-Id', () => const Uuid().v4());
    handler.next(options);
  }
}
