import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/account/current_account_controller.dart';
import '../core/account/account_profile.dart';
import '../core/cache/drift_local_store.dart';
import '../core/database/library_dao.dart';
import '../core/library/library_api.dart';
import '../core/library/library_models.dart';
import '../core/library/library_repository.dart';
import '../core/providers.dart';
import '../core/sync/library_sync_controller.dart';
import '../core/sync/outbox_controller.dart';
import 'account_providers.dart';

final libraryDaoProvider = Provider<LibraryDao>((ref) {
  final store = ref.watch(localStoreProvider);
  if (store is! DriftLocalStore) {
    throw StateError('The synchronized library requires the Drift store.');
  }
  return LibraryDao(store.database);
});

final libraryApiProvider = Provider<LibraryRemoteDataSource>(
  (ref) => LibraryApi(ref.watch(pakPerkDioProvider)),
);

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    local: ref.watch(libraryDaoProvider),
    remote: ref.watch(libraryApiProvider),
    sessionScope: () {
      final session = ref.read(authSessionProvider);
      return (accountId: session.accountId, authEpoch: session.epoch);
    },
    verifiedScope: () => ref.read(verifiedLibraryScopeProvider),
    localMutationScope: () => ref.read(libraryMutationScopeProvider),
  ),
);

typedef ActiveLibraryScope = ({String accountId, int authEpoch});
typedef LibraryPaperViewScope = ({
  String? accountId,
  int? authEpoch,
  String paperId,
});

/// The credential-store account is sufficient for offline display. It must
/// never authorize remote synchronization until `/v1/me` independently
/// verifies the identity for this auth epoch.
final libraryDisplayScopeProvider = Provider<ActiveLibraryScope?>((ref) {
  if (!ref.watch(featureFlagsProvider).library) return null;
  final session = ref.watch(authSessionProvider);
  final accountId = session.accountId;
  if (accountId == null || !session.mayHaveRecoverableCredentials) {
    return null;
  }
  return (accountId: accountId, authEpoch: session.epoch);
});

/// A status learned from `/v1/me` remains authoritative for this auth epoch.
/// Suspended/deleting/deleted accounts may inspect retained local saves, but
/// must not add more durable outbox work.
final libraryReadOnlyAccountStatusProvider = Provider<AccountStatus?>((ref) {
  if (!ref.watch(featureFlagsProvider).library) return null;
  return ref.watch(effectiveAccountReadOnlyStatusProvider);
});

/// Local optimistic writes remain available while identity verification is
/// temporarily unavailable, but stop once this exact session is known to be
/// non-active.
final libraryMutationScopeProvider = Provider<ActiveLibraryScope?>((ref) {
  final scope = ref.watch(libraryDisplayScopeProvider);
  if (scope == null ||
      ref.watch(libraryReadOnlyAccountStatusProvider) != null) {
    return null;
  }
  return scope;
});

/// Remote library work is authorized only by a profile loaded from `/v1/me`
/// for the current epoch and bound back to the same active account identity.
final verifiedLibraryScopeProvider = Provider<ActiveLibraryScope?>((ref) {
  if (!ref.watch(featureFlagsProvider).library) return null;
  final session = ref.watch(authSessionProvider);
  final account = ref.watch(currentAccountProvider);
  final profile = account.profile;
  if (!session.mayHaveRecoverableCredentials ||
      account.phase != CurrentAccountPhase.ready ||
      account.verifiedAuthEpoch != session.epoch ||
      profile == null ||
      !profile.isActive ||
      profile.id != session.accountId) {
    return null;
  }
  return (accountId: profile.id, authEpoch: session.epoch);
});

final paperSavedStateProvider = StreamProvider.autoDispose
    .family<LibrarySavedState, LibraryPaperViewScope>((ref, view) {
      final accountId = view.accountId;
      if (accountId == null) {
        return Stream.value(const LibrarySavedState.notSaved());
      }
      return ref
          .watch(libraryRepositoryProvider)
          .watchSavedState(accountId, view.paperId);
    });

final toReadItemsProvider = StreamProvider.autoDispose
    .family<List<LibraryListItem>, ActiveLibraryScope>((ref, scope) {
      return ref.watch(libraryRepositoryProvider).watchToRead(scope.accountId);
    });

final libraryPendingCountProvider = StreamProvider.autoDispose
    .family<int, ActiveLibraryScope>((ref, scope) {
      return ref
          .watch(libraryRepositoryProvider)
          .watchPendingCount(scope.accountId);
    });

final libraryOutboxControllerProvider = Provider<LibraryOutboxController>(
  (ref) =>
      LibraryOutboxController(repository: ref.watch(libraryRepositoryProvider)),
);

final librarySyncControllerProvider =
    StateNotifierProvider<LibrarySyncController, LibrarySyncStatus>((ref) {
      return LibrarySyncController(
        repository: ref.watch(libraryRepositoryProvider),
        outbox: ref.watch(libraryOutboxControllerProvider),
        telemetry: ref.watch(telemetrySinkProvider),
      );
    });

/// Long-lived binding between auth scope/network recovery and the durable
/// sync engine. Merely creating it never delays the first readable frame.
final libraryRuntimeProvider = Provider<void>((ref) {
  if (!ref.watch(featureFlagsProvider).library) return;
  final controller = ref.watch(librarySyncControllerProvider.notifier);
  ref.listen<ActiveLibraryScope?>(verifiedLibraryScopeProvider, (
    previous,
    next,
  ) {
    if (next == null) {
      controller.stop();
    } else if (next != previous) {
      unawaited(
        controller.start(accountId: next.accountId, authEpoch: next.authEpoch),
      );
    }
  }, fireImmediately: true);
  ref.listen<AsyncValue<bool>>(networkOfflineProvider, (previous, next) {
    final wasOffline = previous?.value ?? false;
    if (wasOffline && next.value == false) {
      unawaited(controller.onNetworkRecovered());
    }
  });
  ref.onDispose(controller.stop);
});

/// Installs the first real pending-action dispatcher. Future comment phases
/// extend the exhaustive switch; unsupported actions fail explicitly instead
/// of being silently discarded.
List<Override> libraryApplicationOverrides() => [
  pendingAuthenticatedActionExecutorProvider.overrideWith((ref) {
    return (action) async {
      switch (action.kind) {
        case AppPendingActionKind.savePaper:
          if (!ref.read(featureFlagsProvider).library ||
              !_paperId.hasMatch(action.targetId)) {
            throw StateError('The pending save is not available.');
          }
          final scope = ref.read(verifiedLibraryScopeProvider);
          if (scope == null) throw const LibraryScopeChanged();
          final paper = await ref
              .read(localStoreProvider)
              .loadPaper(action.targetId);
          await ref
              .read(libraryRepositoryProvider)
              .setSaved(
                accountId: scope.accountId,
                authEpoch: scope.authEpoch,
                paperId: action.targetId,
                saved: true,
                paper: paper,
              );
          unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
          return;
        case AppPendingActionKind.openComposer:
        case AppPendingActionKind.reportComment:
        case AppPendingActionKind.reportUser:
        case AppPendingActionKind.blockUser:
          throw StateError(
            'The pending ${action.kind.name} feature is not enabled.',
          );
      }
    };
  }),
];

final _paperId = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
