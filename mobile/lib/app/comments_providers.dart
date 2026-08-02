import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/account/current_account_controller.dart';
import '../core/account/account_profile.dart';
import '../core/cache/drift_local_store.dart';
import '../core/comments/comment_controllers.dart';
import '../core/comments/comment_repository.dart';
import '../core/comments/comments_api.dart';
import '../core/database/comment_cache_dao.dart';
import '../core/database/comments_dao.dart';
import '../core/database/library_dao.dart';
import '../core/auth/auth_models.dart';
import '../core/providers.dart';
import '../features/feed/feed_prefetch_config.dart';
import 'account_providers.dart';
import 'library_providers.dart';

final commentCacheDaoProvider = Provider<CommentCacheDao>((ref) {
  final store = ref.watch(localStoreProvider);
  if (store is! DriftLocalStore) {
    throw StateError('Comments require the Drift store.');
  }
  return CommentCacheDao(store.database);
});

final commentsDaoProvider = Provider<CommentsDao>((ref) {
  final store = ref.watch(localStoreProvider);
  if (store is! DriftLocalStore) {
    throw StateError('Comments require the Drift store.');
  }
  return CommentsDao(store.database);
});

final commentsApiProvider = Provider<CommentsRemoteDataSource>(
  (ref) => CommentsApi(ref.watch(pakPerkDioProvider)),
);

final commentRepositoryProvider = Provider<CommentRepository>(
  (ref) => CommentRepository(
    cache: ref.watch(commentCacheDaoProvider),
    local: ref.watch(commentsDaoProvider),
    remote: ref.watch(commentsApiProvider),
    accountWrites: ref.watch(accountDataWriteBarrierProvider),
    commentCache: ref.watch(commentCacheBarrierProvider),
    cachePolicy: ref.watch(feedPrefetchConfigProvider),
    sessionScope: () {
      final session = ref.read(authSessionProvider);
      return (
        accountId: session.mayHaveRecoverableCredentials
            ? session.accountId
            : null,
        authEpoch: session.epoch,
      );
    },
    verifiedScope: () => ref.read(verifiedCommentScopeProvider),
  ),
);

/// A required comment request may use credentials only after `/v1/me` has
/// independently rebound this exact account and auth epoch.
final verifiedCommentScopeProvider = Provider<VerifiedCommentScope?>((ref) {
  if (!ref.watch(featureFlagsProvider).comments) return null;
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

final commentViewerScopeProvider = Provider<CommentViewerScope>((ref) {
  final verified = ref.watch(verifiedCommentScopeProvider);
  if (verified != null) {
    return CommentViewerScope.authenticated(
      accountId: verified.accountId,
      authEpoch: verified.authEpoch,
    );
  }
  if (!ref.watch(featureFlagsProvider).comments) {
    return const CommentViewerScope.guest();
  }
  final session = ref.watch(authSessionProvider);
  final accountId = session.accountId;
  if (accountId == null || !session.mayHaveRecoverableCredentials) {
    return const CommentViewerScope.guest();
  }
  if (ref.watch(effectiveAccountReadOnlyStatusProvider) != null) {
    return CommentViewerScope.readOnly(
      accountId: accountId,
      authEpoch: session.epoch,
    );
  }
  return CommentViewerScope.retained(
    accountId: accountId,
    authEpoch: session.epoch,
  );
});

/// A non-active status already verified for this exact auth epoch is a durable
/// read-only boundary. It must not be mistaken for a guest or for a temporary
/// inability to reach `/v1/me`.
final commentReadOnlyAccountStatusProvider = Provider<AccountStatus?>((ref) {
  if (!ref.watch(featureFlagsProvider).comments) return null;
  return ref.watch(effectiveAccountReadOnlyStatusProvider);
});

final commentComposerEligibleProvider = Provider<bool>((ref) {
  final verified = ref.watch(verifiedCommentScopeProvider);
  final account = ref.watch(currentAccountProvider);
  return verified != null && account.profile?.canParticipateInComments == true;
});

final commentThreadProvider = StateNotifierProvider.autoDispose
    .family<CommentThreadController, CommentThreadState, String>((
      ref,
      paperId,
    ) {
      final controller = CommentThreadController(
        repository: ref.watch(commentRepositoryProvider),
        paperId: paperId,
        viewer: ref.watch(commentViewerScopeProvider),
      );
      scheduleMicrotask(controller.load);
      return controller;
    });

final blockedUsersProvider = StreamProvider.autoDispose
    .family<List<BlockedUserValue>, VerifiedCommentScope>((ref, scope) {
      return ref
          .watch(commentRepositoryProvider)
          .watchBlockedUsers(scope.accountId);
    });

final myCommentsControllerProvider =
    StateNotifierProvider.autoDispose<MyCommentsController, MyCommentsState>((
      ref,
    ) {
      final scope = ref.watch(verifiedCommentScopeProvider);
      if (scope == null) {
        throw StateError('My Comments requires a verified account scope.');
      }
      final controller = MyCommentsController(
        repository: ref.watch(commentRepositoryProvider),
        scope: scope,
      );
      scheduleMicrotask(controller.load);
      return controller;
    });

enum CommentUiIntentKind { openComposer, reportComment, reportUser, blockUser }

final class CommentUiIntent {
  const CommentUiIntent({required this.kind, required this.targetId});

  final CommentUiIntentKind kind;
  final String targetId;
}

final class CommentUiIntentController extends StateNotifier<CommentUiIntent?> {
  CommentUiIntentController() : super(null);

  static const maximumResumePageLoads = 3;

  int _remainingPageLoads = 0;

  void show(CommentUiIntent value) {
    _remainingPageLoads = maximumResumePageLoads;
    state = value;
  }

  CommentUiIntent? take() {
    final value = state;
    clear();
    return value;
  }

  void clear() {
    _remainingPageLoads = 0;
    state = null;
  }

  CommentUiIntent? takeIfCurrent(CommentUiIntent expected) {
    if (!identical(state, expected)) return null;
    return take();
  }

  bool claimTargetPageLoad(CommentUiIntent expected) {
    if (!identical(state, expected) || _remainingPageLoads <= 0) return false;
    _remainingPageLoads -= 1;
    return true;
  }
}

final commentUiIntentProvider =
    StateNotifierProvider<CommentUiIntentController, CommentUiIntent?>(
      (ref) => CommentUiIntentController(),
    );

final commentBlockReconcilerProvider = Provider<CommentBlockReconciler>(
  (ref) => CommentBlockReconciler(
    reconcile: (scope) => ref
        .read(commentRepositoryProvider)
        .reconcileBlocks(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
        ),
  ),
);

final commentsRuntimeProvider = Provider<void>((ref) {
  if (!ref.watch(featureFlagsProvider).comments) return;
  final reconciler = ref.watch(commentBlockReconcilerProvider);
  ref.listen<AuthSessionState>(authSessionProvider, (previous, next) {
    if (previous == null) return;
    final departedBoundAccount =
        previous.accountId != null && previous.accountId != next.accountId;
    if (previous.epoch != next.epoch || departedBoundAccount) {
      ref.read(commentUiIntentProvider.notifier).clear();
    }
  });
  ref.listen<VerifiedCommentScope?>(verifiedCommentScopeProvider, (
    previous,
    next,
  ) {
    if (next != null && next != previous) {
      unawaited(
        ref
            .read(accountDataWriteBarrierProvider)
            .activate(
              accountId: next.accountId,
              authEpoch: next.authEpoch,
              isCurrent: () => ref.read(verifiedCommentScopeProvider) == next,
            ),
      );
      unawaited(reconciler.run(next));
    }
  }, fireImmediately: true);
  ref.listen<AsyncValue<bool>>(networkOfflineProvider, (previous, next) {
    if (previous?.value == true && next.value == false) {
      final scope = ref.read(verifiedCommentScopeProvider);
      if (scope != null) unawaited(reconciler.run(scope));
    }
  });
});

/// Installed after the Phase 4 executor, extending its exhaustive handoff
/// while preserving the verified save boundary.
List<Override> commentsApplicationOverrides() => [
  pendingAuthenticatedActionExecutorProvider.overrideWith((ref) {
    return (action) async {
      switch (action.kind) {
        case AppPendingActionKind.savePaper:
          if (!ref.read(featureFlagsProvider).library ||
              !_uuid.hasMatch(action.targetId)) {
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
          if (!ref.read(featureFlagsProvider).comments ||
              !_uuid.hasMatch(action.targetId) ||
              !ref.read(commentComposerEligibleProvider)) {
            throw StateError('The comment composer is not available.');
          }
          ref
              .read(commentUiIntentProvider.notifier)
              .show(
                CommentUiIntent(
                  kind: CommentUiIntentKind.openComposer,
                  targetId: action.targetId,
                ),
              );
          return;
        case AppPendingActionKind.reportComment:
          if (!ref.read(featureFlagsProvider).comments ||
              !_uuid.hasMatch(action.targetId) ||
              ref.read(verifiedCommentScopeProvider) == null) {
            throw StateError('Reporting is not available.');
          }
          ref
              .read(commentUiIntentProvider.notifier)
              .show(
                CommentUiIntent(
                  kind: CommentUiIntentKind.reportComment,
                  targetId: action.targetId,
                ),
              );
          return;
        case AppPendingActionKind.reportUser:
          if (!ref.read(featureFlagsProvider).comments ||
              !_uuid.hasMatch(action.targetId) ||
              ref.read(verifiedCommentScopeProvider) == null) {
            throw StateError('User reporting is not available.');
          }
          ref
              .read(commentUiIntentProvider.notifier)
              .show(
                CommentUiIntent(
                  kind: CommentUiIntentKind.reportUser,
                  targetId: action.targetId,
                ),
              );
          return;
        case AppPendingActionKind.blockUser:
          if (!ref.read(featureFlagsProvider).comments ||
              !_uuid.hasMatch(action.targetId) ||
              ref.read(verifiedCommentScopeProvider) == null) {
            throw StateError('Blocking is not available.');
          }
          ref
              .read(commentUiIntentProvider.notifier)
              .show(
                CommentUiIntent(
                  kind: CommentUiIntentKind.blockUser,
                  targetId: action.targetId,
                ),
              );
          return;
      }
    };
  }),
];

typedef ReconcileCommentBlocks =
    Future<void> Function(VerifiedCommentScope scope);

/// Serializes block reconciliation while retaining the newest requested
/// account/epoch. An account switch during an in-flight request therefore
/// drains the new scope automatically instead of borrowing the old future.
final class CommentBlockReconciler {
  CommentBlockReconciler({required ReconcileCommentBlocks reconcile})
    : _reconcile = reconcile;

  final ReconcileCommentBlocks _reconcile;
  Future<void>? _running;
  VerifiedCommentScope? _queued;

  Future<void> run(VerifiedCommentScope scope) {
    _queued = scope;
    return _running ??= _drain();
  }

  Future<void> _drain() async {
    while (_queued != null) {
      final scope = _queued!;
      _queued = null;
      try {
        await _reconcile(scope);
      } on Object {
        // Persisted unconfirmed rows remain locally effective and retry on
        // the next verified scope, foreground view, or network recovery.
      }
    }
    _running = null;
  }
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
