import 'dart:async';

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
import '../core/api/transport_network_status.dart';
import '../core/auth/auth.dart';
import '../core/cache/drift_local_store.dart';
import '../core/comments/comment_cache_barrier.dart';
import '../core/database/account_cache_dao.dart';
import '../core/discovery_search/search_privacy_store.dart';
import '../core/library/library_history_store.dart';
import '../core/library/paper_import_draft_store.dart';
import '../core/providers.dart';
import '../core/reading_feed/reading_feed_page_cache.dart';
import '../features/paper_reader/reader_navigation_controller.dart';
import 'feature_flags.dart';
import 'startup_controller.dart';

/// The one application transport. It is owned by the root provider container,
/// not by an individual repository, so rotating the anonymous session cannot
/// close the transport used by account requests.
final Provider<Dio> pakPerkDioProvider = Provider<Dio>((ref) {
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
        accountIdForRequest: (expectedAuthEpoch) {
          final session = ref.read(authSessionProvider);
          if (session.epoch != expectedAuthEpoch ||
              !session.mayHaveRecoverableCredentials) {
            return null;
          }
          return session.accountId;
        },
        onAccountDeletionPending:
            (expectedAuthEpoch, requestAccountId, requestId) async {
              final auth = ref.read(authSessionProvider.notifier);
              if (!auth.reserveAccountDeletion(
                expectedAuthEpoch: expectedAuthEpoch,
                expectedAccountId: requestAccountId,
              )) {
                return;
              }
              final guard = AccountDeletionGuardRecord(
                acceptance: LocalAccountDeletionAcceptance.serviceUnavailable,
                accountId: requestAccountId,
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
              final cleaned = await ref.read(
                accountDeletionLocalFinalizerProvider,
              )(requestAccountId);
              if (cleaned) {
                try {
                  await store.write(guard.cleanupCompleted());
                } on Object {
                  guardFailure ??= StateError('Deletion guard update failed.');
                }
              }
              if (guardFailure != null) throw guardFailure;
            },
        onAccountReadOnly:
            (expectedAuthEpoch, requestAccountId, errorCode) async {
              final session = ref.read(authSessionProvider);
              if (session.epoch != expectedAuthEpoch ||
                  session.accountId != requestAccountId ||
                  !session.mayHaveRecoverableCredentials) {
                return;
              }
              ref
                  .read(currentAccountProvider.notifier)
                  .recordAuthoritativeReadOnlyStatus(
                    errorCode: errorCode,
                    authEpoch: expectedAuthEpoch,
                  );
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
  dio.interceptors.add(
    TransportNetworkStatusInterceptor(
      ref.watch(transportNetworkStatusProvider),
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

/// Clears local state whose lifecycle belongs to an account. Public paper
/// metadata, feed windows, and safe route references remain available, while
/// per-reader mode/progress is cleared because the unscoped restoration record
/// cannot prove which account owns it.
final accountDataWriteBarrierProvider = Provider<AccountDataWriteBarrier>(
  (ref) => AccountDataWriteBarrier(),
);

/// Coordinates every cached-comment write with the stronger all-snapshot
/// purge required by account deletion.
final commentCacheBarrierProvider = Provider<CommentCacheBarrier>(
  (ref) => CommentCacheBarrier(),
);

final accountOwnedDataClearerProvider = Provider<AccountOwnedDataClearer>((
  ref,
) {
  return (accountId, invalidatedThroughEpoch) async {
    final store = await ref.read(localStoreWhenReadyProvider)();
    final accountCache = store is DriftLocalStore
        ? AccountCacheDao(store.database)
        : null;
    final history = SharedPreferencesLibraryHistoryStore();
    final importDrafts = SharedPreferencesPaperImportDraftStore();
    final readingFeedPages = SharedPreferencesReadingFeedPageCache();
    final privateSearch = SharedPreferencesSearchPrivacyStore();
    final visualAssets = ref.read(visualAssetCacheProvider);
    final restoration = ref.read(appRestorationControllerProvider.notifier);
    await ref
        .read(accountDataWriteBarrierProvider)
        .clear(
          accountId: accountId,
          invalidatedThroughEpoch: invalidatedThroughEpoch,
          clearAccount: (accountId) async {
            await Future.wait<void>([
              if (accountCache != null)
                accountCache.clearAccountData(accountId),
              history.clear(accountId),
              importDrafts.clear(accountId),
              readingFeedPages.clear(accountId),
              privateSearch.clear(accountId),
              visualAssets.clearAccount(accountId),
              restoration.clearReaderStatesForAccountTransition(),
            ]);
          },
          clearAll: () async {
            await Future.wait<void>([
              if (accountCache != null) accountCache.clearAllAccountData(),
              history.clearAll(),
              importDrafts.clearAll(),
              readingFeedPages.clearAll(),
              privateSearch.clearAll(),
              visualAssets.clearAll(),
              restoration.clearReaderStatesForAccountTransition(),
            ]);
          },
        );
  };
});

typedef AccountDeletionLocalFinalizer =
    Future<bool> Function(String? accountId);

final accountDeletionCommentCachePurgerProvider =
    Provider<Future<void> Function()>((ref) {
      return () {
        final barrier = ref.read(commentCacheBarrierProvider);
        return barrier.invalidateAndPurge(() async {
          final store = await ref.read(localStoreWhenReadyProvider)();
          await store.purgeAccountDeletionCommentSnapshots();
        });
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

/// Identity-provider refresh failures do not necessarily pass through the
/// shared Dio transport, so authenticated surfaces need this independent
/// offline signal in addition to [networkOfflineProvider].
final authSessionOfflineUnknownProvider = Provider<bool>((ref) {
  if (!ref.watch(featureFlagsProvider).accounts) return false;
  return ref.watch(
    authSessionProvider.select(
      (session) => session.phase == AuthSessionPhase.offlineAuthUnknown,
    ),
  );
});

/// Serializes recovery of a retained offline identity. A successful OIDC
/// refresh is not enough by itself: `/v1/me` must rebind the same auth epoch
/// before account-owned remote reads or writes become available again.
final accountSessionRecoveryProvider = Provider<AccountSessionRecovery>((ref) {
  return AccountSessionRecovery(() async {
    if (!ref.read(featureFlagsProvider).accounts) return false;
    var session = ref.read(authSessionProvider);
    final wasOfflineUnknown =
        session.phase == AuthSessionPhase.offlineAuthUnknown;
    if (wasOfflineUnknown) {
      final restored = await ref
          .read(authSessionProvider.notifier)
          .restoreSession();
      if (!restored) return false;
      session = ref.read(authSessionProvider);
    }
    if (session.phase != AuthSessionPhase.authenticated) return false;

    final account = ref.read(currentAccountProvider);
    final alreadyVerified =
        !wasOfflineUnknown &&
        account.phase == CurrentAccountPhase.ready &&
        account.verifiedAuthEpoch == session.epoch &&
        account.profile?.id == session.accountId;
    if (alreadyVerified) return true;
    return await ref.read(currentAccountProvider.notifier).load() != null;
  });
});

/// One application-level recovery listener shared by library and comments.
/// Their individual runtimes react to the resulting verified scopes and do
/// not perform additional identity refreshes.
final accountSessionRecoveryRuntimeProvider = Provider<void>((ref) {
  if (!ref.watch(featureFlagsProvider).accounts) return;
  final recovery = ref.watch(accountSessionRecoveryProvider);
  ref.listen<AsyncValue<bool>>(networkOfflineProvider, (previous, next) {
    if (previous?.value == true && next.value == false) {
      unawaited(recovery.recover());
    }
  });
});

final class AccountSessionRecovery {
  AccountSessionRecovery(Future<bool> Function() recover) : _recover = recover;

  final Future<bool> Function() _recover;
  Future<bool>? _flight;

  Future<bool> recover() {
    final active = _flight;
    if (active != null) return active;
    late final Future<bool> flight;
    flight = _recover().whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
    });
    _flight = flight;
    return flight;
  }
}

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
        sessionAccountId: () => ref.read(authSessionProvider).accountId,
        bindAccountId: ref.read(authSessionProvider.notifier).bindAccountId,
      );
      ref.listen<AuthSessionState>(authSessionProvider, (previous, next) {
        if (previous == null) return;
        final epochChanged = previous.epoch != next.epoch;
        final accountDeparted =
            previous.accountId != null && previous.accountId != next.accountId;
        final loadingFirstVerifiedIdentity =
            controller.isLoadingFirstVerifiedIdentity;
        // A cold `/v1/me` load can deliberately rebind a stale offline cache
        // key. Its own captured-account guard still rejects an unrelated
        // same-epoch identity change; avoid invalidating only the unverified
        // load while its binder briefly publishes a null account scope.
        if (epochChanged ||
            (accountDeparted && !loadingFirstVerifiedIdentity)) {
          controller.clear();
        }
      });
      return controller;
    });

/// Effective non-active status for the current auth epoch. `/v1/me` itself is
/// protected by backend account-status middleware, so suspended/deleting
/// accounts can be represented by a stable 403 code rather than a profile
/// payload. A retained older active profile must not hide that boundary.
final effectiveAccountReadOnlyStatusProvider = Provider<AccountStatus?>((ref) {
  if (!ref.watch(featureFlagsProvider).accounts) return null;
  final session = ref.watch(authSessionProvider);
  if (session.phase == AuthSessionPhase.deletionPending) {
    return AccountStatus.deletionPending;
  }
  final accountId = session.accountId;
  if (accountId == null || !session.mayHaveRecoverableCredentials) return null;
  final account = ref.watch(currentAccountProvider);
  final knownStatus = account.knownReadOnlyStatus;
  if (account.knownReadOnlyAuthEpoch == session.epoch && knownStatus != null) {
    return knownStatus;
  }
  if (account.errorAuthEpoch == session.epoch) {
    final status = switch (account.error?.code) {
      'ACCOUNT_SUSPENDED' => AccountStatus.suspended,
      'ACCOUNT_DELETION_PENDING' => AccountStatus.deletionPending,
      'ACCOUNT_DELETED' => AccountStatus.deleted,
      _ => null,
    };
    if (status != null) return status;
  }
  final profile = account.profile;
  if (account.verifiedAuthEpoch != session.epoch ||
      profile == null ||
      profile.id != accountId ||
      profile.isActive) {
    return null;
  }
  return profile.status;
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
    if (_deletionPending) {
      _authSession.holdAccountDeletionPending();
      return StartupSessionStatus.anonymous;
    }
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
      networkStatus: ref.watch(transportNetworkStatusProvider),
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
