import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/database/library_dao.dart';
import '../../core/database/library_v2_dao.dart';
import '../../core/library/paper_import_draft_store.dart';
import '../../core/library/library_models.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';
import '../../core/providers.dart';
import '../feed/reading_feed_controller.dart';
import 'add_paper_sheet.dart';
import 'paper_import_controller.dart';
import 'paper_import_drafts.dart';
import 'library_item_editor.dart';
import 'library_workspace_models.dart';

final paperImportAvailableProvider = Provider<bool>((ref) {
  final flags = ref.watch(featureFlagsProvider);
  if (!flags.libraryImportWrites) return false;
  final drafts = ref.watch(paperImportDraftAuthorityProvider);
  return ref.watch(verifiedLibraryScopeProvider) != null &&
      drafts.scopeReady &&
      drafts.pendingCount <
          SharedPreferencesPaperImportDraftStore.maximumDrafts;
});

/// Opens the account-scoped Add Paper task and joins its server result back to
/// the local queue authority without enqueueing a duplicate save mutation.
///
/// The import activity is deliberately published before the remote request is
/// dispatched. That synchronous signal makes a currently visible
/// recommendation disappear while the canonical paper is still being
/// resolved. It remains active across retryable failures and until the local
/// projection has either committed or begun a verified reconciliation.
Future<PaperImportResult?> showAccountAddPaperFlow({
  required BuildContext context,
  required WidgetRef ref,
  String initialInput = '',
  PaperImportDraft? resumeDraft,
}) async {
  final flags = ref.read(featureFlagsProvider);
  final verified = ref.read(verifiedLibraryScopeProvider);
  if (!flags.libraryImportWrites || verified == null) return null;
  final container = ProviderScope.containerOf(context, listen: false);
  final draftAuthority = container.read(paperImportDraftAuthorityProvider);
  final resumable =
      resumeDraft != null &&
      draftAuthority.scopeReady &&
      draftAuthority.drafts.any(
        (draft) =>
            draft.operationId == resumeDraft.operationId &&
            draft.source.kind == resumeDraft.source.kind &&
            draft.source.value == resumeDraft.source.value &&
            draft.saveSourceKind == resumeDraft.saveSourceKind,
      );
  if ((!draftAuthority.scopeReady ||
          draftAuthority.pendingCount >=
              SharedPreferencesPaperImportDraftStore.maximumDrafts) &&
      !resumable) {
    return null;
  }
  // Shadow rollout still computes queue authority while legacy discovery is
  // rendered, so imports must participate in that decision before enforcement.
  final protectsReadingFeed = flags.readingFeed;

  final feedScope = ReadingFeedAccountScope(
    accountId: verified.accountId,
    authEpoch: verified.authEpoch,
  );
  final importScope = PaperImportAccountScope(
    accountId: verified.accountId,
    authEpoch: verified.authEpoch,
    // Auth epochs advance whenever account-owned credentials are rebound. The
    // account ID completes the identity fence used by the sheet controller.
    accountGeneration: 0,
  );
  final importScopeListenable = ValueNotifier<PaperImportAccountScope?>(
    importScope,
  );
  final editorScope = LibraryEditorScope(
    accountId: verified.accountId,
    authEpoch: verified.authEpoch,
  );
  final editorScopeListenable = ValueNotifier<LibraryEditorScope?>(editorScope);
  var accountGeneration = 0;
  final scopeSubscription = container.listen<ActiveLibraryScope?>(
    verifiedLibraryScopeProvider,
    (_, next) {
      final remainsBound =
          next?.accountId == verified.accountId &&
          next?.authEpoch == verified.authEpoch;
      importScopeListenable.value = remainsBound
          ? PaperImportAccountScope(
              accountId: verified.accountId,
              authEpoch: verified.authEpoch,
              accountGeneration: ++accountGeneration,
            )
          : null;
      editorScopeListenable.value = remainsBound ? editorScope : null;
    },
  );
  String? activeOperationId;
  String? projectingOperationId;
  Future<void>? projection;
  var organizeRequested = false;
  Future<void> draftWriteTail = Future.value();

  void queueDraftWrite(Future<void> Function() write) {
    draftWriteTail = draftWriteTail.then((_) => write());
  }

  bool scopeIsCurrent() {
    final current = container.read(verifiedLibraryScopeProvider);
    return current?.accountId == verified.accountId &&
        current?.authEpoch == verified.authEpoch;
  }

  void endActivity(String? operationId) {
    if (operationId == null) return;
    container.read(readingFeedImportActivityProvider.notifier).end(operationId);
    if (activeOperationId == operationId) activeOperationId = null;
  }

  Future<void> projectResult(
    String operationId,
    PaperImportResult result,
  ) async {
    try {
      if (!scopeIsCurrent()) return;
      await container
          .read(libraryRepositoryProvider)
          .applyImportedPaper(
            accountId: verified.accountId,
            authEpoch: verified.authEpoch,
            item: result.item,
            paper: result.paper,
            syncRevision: result.syncRevision,
          );
    } on LibraryScopeChanged {
      // Account changes own the destination UI and deliberately discard this
      // account's late local projection.
    } on Object {
      // The server import already succeeded. Reconcile from the authoritative
      // library instead of manufacturing a second optimistic save operation.
      if (scopeIsCurrent()) {
        try {
          await container
              .read(librarySyncControllerProvider.notifier)
              .refresh(forceFull: true);
        } on Object {
          // The next foreground/network refresh retains the same canonical
          // recovery path. The reading feed still refreshes from the server
          // below, so this local failure cannot reveal a cached recommendation.
        }
      }
    } finally {
      await draftWriteTail;
      await container
          .read(paperImportDraftControllerProvider.notifier)
          .remove(operationId);
      endActivity(operationId);
      if (protectsReadingFeed && scopeIsCurrent()) {
        unawaited(
          container
              .read(readingFeedControllerProvider.notifier)
              .refresh(force: true),
        );
      }
    }
  }

  void handleLifecycle(PaperImportLifecycleEvent event) {
    final operationId = event.operationId;
    switch (event.phase) {
      case PaperImportLifecyclePhase.importing:
        if (operationId == null || event.placeholder == null) return;
        if (activeOperationId != null && activeOperationId != operationId) {
          endActivity(activeOperationId);
        }
        activeOperationId = operationId;
        container
            .read(readingFeedImportActivityProvider.notifier)
            .begin(
              scope: feedScope,
              operationId: operationId,
              label: event.placeholder!.label,
            );
        final now = DateTime.now().toUtc();
        PaperImportDraft? existing;
        for (final candidate
            in container.read(paperImportDraftControllerProvider).drafts) {
          if (candidate.operationId == operationId) {
            existing = candidate;
            break;
          }
        }
        final draft = PaperImportDraft(
          operationId: operationId,
          source: event.placeholder!.source,
          saveSourceKind: event.placeholder!.saveSourceKind,
          status: PaperImportDraftStatus.importing,
          createdAt: existing?.createdAt ?? now,
          expiresAt:
              existing?.expiresAt ?? now.add(PaperImportDraft.defaultRetention),
        );
        queueDraftWrite(
          () => container
              .read(paperImportDraftControllerProvider.notifier)
              .upsert(draft),
        );
      case PaperImportLifecyclePhase.failed:
        if (operationId == null) return;
        if (event.failure?.retryable ?? false) {
          queueDraftWrite(
            () => container
                .read(paperImportDraftControllerProvider.notifier)
                .markRetryable(operationId, event.failure!.code),
          );
        } else {
          queueDraftWrite(
            () => container
                .read(paperImportDraftControllerProvider.notifier)
                .remove(operationId),
          );
          endActivity(operationId);
        }
      case PaperImportLifecyclePhase.succeeded:
        final result = event.result;
        if (operationId == null || result == null) {
          endActivity(operationId);
          return;
        }
        if (projectingOperationId == operationId) return;
        projectingOperationId = operationId;
        projection = projectResult(operationId, result);
      case PaperImportLifecyclePhase.cancelled:
        if (operationId != null) {
          queueDraftWrite(
            () => container
                .read(paperImportDraftControllerProvider.notifier)
                .remove(operationId),
          );
        }
        endActivity(operationId);
      case PaperImportLifecyclePhase.closed:
        // A retryable/importing draft write is queued behind the synchronous
        // activity signal. Keep that signal alive until the flow's `finally`
        // block has awaited the ledger write, otherwise one microtask could
        // briefly expose recommendations between the two authority sources.
        if (operationId != projectingOperationId &&
            operationId != activeOperationId) {
          endActivity(operationId);
        }
    }
  }

  try {
    final result = await showAddPaperSheet(
      context: context,
      remote: container.read(paperResolutionApiProvider),
      scope: importScope,
      accountScopeListenable: importScopeListenable,
      initialInput: resumeDraft?.source.value ?? initialInput,
      initialSaveSourceKind: resumeDraft?.saveSourceKind,
      operationId: resumeDraft == null ? null : () => resumeDraft.operationId,
      titleSearchEnabled: flags.paperTitleSearch,
      remindersAvailable: flags.notificationsEnabled,
      onOrganize: flags.libraryV2Enabled
          ? (_) => organizeRequested = true
          : null,
      onLifecycle: handleLifecycle,
    );
    await projection;
    await draftWriteTail;
    if (result != null &&
        organizeRequested &&
        scopeIsCurrent() &&
        context.mounted) {
      LibraryListItem? item;
      try {
        final items = await container.read(
          libraryItemsProvider(verified).future,
        );
        for (final candidate in items) {
          if (candidate.paper.paperId == result.paper.paperId) {
            item = candidate;
            break;
          }
        }
      } on Object {
        // The canonical import response still provides a safe editor fallback.
      }
      item ??= LibraryListItem(
        paper: result.paper,
        savedAt: result.item.savedAt,
        savedState: const LibrarySavedState(saved: true, syncPending: false),
        state: result.item.state,
        privateNote: result.item.privateNote,
        saveSourceKind: result.item.saveSourceKind,
        reminderAt: result.item.reminderAt,
      );
      var revision = result.syncRevision;
      try {
        final checkpoint = await container.read(
          librarySyncCheckpointProvider(verified).future,
        );
        if (checkpoint.initialized) revision = checkpoint.lastRevision;
      } on Object {
        // The import revision remains a valid optimistic fence.
      }
      if (scopeIsCurrent() && context.mounted) {
        await showLibraryItemEditor(
          context: context,
          item: item,
          capabilities: LibraryEditorCapabilities.all(
            reminders: flags.notificationsEnabled,
          ),
          expectedLibraryRevision: revision,
          accountScopeListenable: editorScopeListenable,
          expectedAccountScope: editorScope,
          onSave: (selectedItem, draft, expectedRevision) async {
            if (!scopeIsCurrent() || expectedRevision == null) {
              throw const LibraryRevisionConflict();
            }
            await container
                .read(libraryRepositoryProvider)
                .editItemV2(
                  accountId: verified.accountId,
                  authEpoch: verified.authEpoch,
                  paperId: selectedItem.paper.paperId,
                  state: draft.state,
                  privateNote: draft.privateNote,
                  reminderAt: draft.reminderAt,
                  listNames: draft.listNames,
                  tagNames: draft.tagNames,
                  expectedRevision: expectedRevision,
                );
            unawaited(
              container.read(librarySyncControllerProvider.notifier).drain(),
            );
          },
        );
      }
    }
    return result;
  } finally {
    await projection;
    await draftWriteTail;
    endActivity(activeOperationId);
    scopeSubscription.close();
    importScopeListenable.dispose();
    editorScopeListenable.dispose();
  }
}
