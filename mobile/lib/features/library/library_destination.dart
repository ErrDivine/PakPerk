import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/account/account_profile.dart';
import '../../core/database/library_dao.dart';
import '../../core/database/library_v2_dao.dart';
import '../../core/library/library_action_failure.dart';
import '../../core/library/library_models.dart';
import '../../core/library/library_v2_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../design_system/motion.dart';
import '../placeholders/phase_one_placeholder_screens.dart';
import 'library_action_failure_card.dart';
import 'library_collections_view.dart';
import 'library_history_controller.dart';
import 'library_history_view.dart';
import 'library_item_editor.dart';
import 'library_workspace_models.dart';
import 'paper_import_flow.dart';

final libraryEditorCapabilitiesProvider = Provider<LibraryEditorCapabilities>((
  ref,
) {
  final flags = ref.watch(featureFlagsProvider);
  return flags.libraryV2Enabled
      ? LibraryEditorCapabilities.all(reminders: flags.notificationsEnabled)
      : const LibraryEditorCapabilities.none();
});

final libraryItemEditCallbackProvider = Provider<LibraryItemEditCallback?>((
  ref,
) {
  if (!ref.watch(featureFlagsProvider).libraryV2Enabled) return null;
  return (item, draft, expectedLibraryRevision) async {
    final scope = ref.read(libraryMutationScopeProvider);
    if (scope == null || expectedLibraryRevision == null) {
      throw const LibraryRevisionConflict();
    }
    await ref
        .read(libraryRepositoryProvider)
        .editItemV2(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          paperId: item.paper.paperId,
          state: draft.state,
          privateNote: draft.privateNote,
          reminderAt: draft.reminderAt,
          listNames: draft.listNames,
          tagNames: draft.tagNames,
          expectedRevision: expectedLibraryRevision,
        );
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  };
});

class LibraryDestination extends ConsumerStatefulWidget {
  const LibraryDestination({required this.onOpenPaper, super.key});

  final ValueChanged<PaperSummary> onOpenPaper;

  @override
  ConsumerState<LibraryDestination> createState() => _LibraryDestinationState();
}

class _LibraryDestinationState extends ConsumerState<LibraryDestination> {
  late final ValueNotifier<LibraryEditorScope?> _accountScopeListenable;

  @override
  void initState() {
    super.initState();
    _accountScopeListenable = ValueNotifier(
      _editorScope(ref.read(libraryDisplayScopeProvider)),
    );
  }

  @override
  void dispose() {
    _accountScopeListenable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ActiveLibraryScope?>(libraryDisplayScopeProvider, (_, next) {
      _accountScopeListenable.value = _editorScope(next);
    });
    if (!ref.watch(featureFlagsProvider).library) {
      return const PhaseOnePlaceholderScreen(
        title: 'Library is not enabled',
        message:
            'Synchronized saves are disabled in this build. Reading and '
            'cached papers remain available.',
        icon: Icons.local_library_outlined,
      );
    }
    final readOnlyStatus = ref.watch(libraryReadOnlyAccountStatusProvider);
    final scope = ref.watch(libraryDisplayScopeProvider);
    if (scope == null) {
      return readOnlyStatus == null
          ? const _SignedOutLibraryDestination()
          : _UnavailableLibraryDestination(status: readOnlyStatus);
    }
    final items = ref.watch(libraryItemsProvider(scope));
    final actionFailures = ref.watch(libraryActionFailureAlertsProvider(scope));
    final pending = ref.watch(libraryPendingIntentsProvider(scope));
    final checkpoint = ref.watch(librarySyncCheckpointProvider(scope));
    final sync = ref.watch(librarySyncControllerProvider);
    final cachedItems = items.value;
    final cachedActionFailures = actionFailures.value ?? const [];
    final cachedPending = pending.value;
    final cachedCheckpoint = checkpoint.value;
    final loading =
        cachedItems == null ||
        cachedPending == null ||
        cachedCheckpoint == null;
    final mutationScope = ref.watch(libraryMutationScopeProvider);
    final libraryV2Enabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.libraryV2Enabled),
    );
    final lists = ref.watch(libraryListsV2Provider(scope));
    final tags = ref.watch(libraryTagsV2Provider(scope));
    final history = libraryV2Enabled
        ? ref.watch(libraryHistoryControllerProvider(scope))
        : const LibraryHistoryState(loading: false);
    final canOrganize =
        libraryV2Enabled &&
        mutationScope != null &&
        cachedCheckpoint?.initialized == true &&
        cachedCheckpoint?.resetting == false;
    final canImport = ref.watch(paperImportAvailableProvider);
    final offline =
        ref.watch(authSessionOfflineUnknownProvider) ||
        ref
            .watch(networkOfflineProvider)
            .when(
              data: (value) => value,
              loading: () => true,
              error: (_, __) => true,
            );

    return LibraryDestinationView(
      key: PageStorageKey<ActiveLibraryScope>(scope),
      items: cachedItems ?? const [],
      authority: LibraryWorkspaceAuthority.from(
        items: cachedItems ?? const [],
        pendingIntents:
            cachedPending ?? const LibraryPendingIntentCounts.empty(),
        checkpoint: cachedCheckpoint ?? const LibrarySyncCheckpoint.unknown(),
      ),
      loading: loading,
      offline: offline,
      syncIssue:
          items.hasError ||
              actionFailures.hasError ||
              pending.hasError ||
              checkpoint.hasError
          ? LibrarySyncIssue.fromCode('LOCAL_SYNC_UNAVAILABLE')
          : cachedActionFailures.isEmpty
          ? sync.issue
          : null,
      actionFailures: cachedActionFailures,
      readOnlyMessage: readOnlyStatus == null
          ? null
          : _readOnlyMessage(readOnlyStatus),
      canAddPaper: canImport,
      onAddPaper: canImport
          ? () => unawaited(showAccountAddPaperFlow(context: context, ref: ref))
          : null,
      onRefresh: mutationScope == null
          ? null
          : () async {
              if (ref.read(authSessionOfflineUnknownProvider)) {
                await ref.read(accountSessionRecoveryProvider).recover();
              }
              await ref.read(librarySyncControllerProvider.notifier).refresh();
            },
      onOpenPaper: (item) => widget.onOpenPaper(item.paper),
      onOpenActionFailurePaper: widget.onOpenPaper,
      onSignIn: () => context.push<void>('/auth'),
      onDismissActionFailure: (failure) =>
          unawaited(_dismissActionFailure(scope, failure)),
      editorCapabilities: ref.watch(libraryEditorCapabilitiesProvider),
      onEdit: ref.watch(libraryItemEditCallbackProvider),
      accountScopeListenable: _accountScopeListenable,
      expectedAccountScope: _editorScope(scope),
      libraryV2Enabled: libraryV2Enabled,
      lists: lists.value ?? const [],
      tags: tags.value ?? const [],
      collectionsLoading:
          libraryV2Enabled && (lists.value == null || tags.value == null),
      history: history,
      onHistoryEnabledChanged: libraryV2Enabled
          ? (enabled) => unawaited(
              ref
                  .read(libraryHistoryControllerProvider(scope).notifier)
                  .setEnabled(enabled),
            )
          : null,
      onClearHistory: libraryV2Enabled
          ? () => unawaited(_clearHistory(scope))
          : null,
      onOpenHistoryPaper: widget.onOpenPaper,
      onSaveList: canOrganize
          ? (existing, name, description, sortOrder) => _saveList(
              scope: scope,
              existing: existing,
              name: name,
              description: description,
              sortOrder: sortOrder,
            )
          : null,
      onDeleteList: canOrganize
          ? (list) => _deleteList(scope: scope, list: list)
          : null,
      onReorderLists: canOrganize
          ? (orderedIds) => _reorderLists(
              scope: scope,
              lists: lists.value ?? const [],
              orderedIds: orderedIds,
            )
          : null,
      onSaveTag: canOrganize
          ? (existing, name) =>
                _saveTag(scope: scope, existing: existing, name: name)
          : null,
      onDeleteTag: canOrganize
          ? (tag) => _deleteTag(scope: scope, tag: tag)
          : null,
    );
  }

  Future<void> _dismissActionFailure(
    ActiveLibraryScope scope,
    LibraryActionFailure failure,
  ) async {
    try {
      final dismissed = await ref
          .read(libraryRepositoryProvider)
          .dismissActionFailure(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            operationId: failure.operationId,
          );
      if (dismissed) {
        await ref
            .read(librarySyncControllerProvider.notifier)
            .acknowledgeActionFailureDismissal(
              accountId: scope.accountId,
              authEpoch: scope.authEpoch,
            );
      }
    } on LibraryScopeChanged {
      return;
    } on Object {
      if (!mounted || ref.read(libraryDisplayScopeProvider) != scope) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This notice could not be dismissed. Try again.'),
        ),
      );
    }
  }

  Future<void> _saveList({
    required ActiveLibraryScope scope,
    required LibraryV2LocalList? existing,
    required String name,
    required String description,
    required int sortOrder,
  }) async {
    final checkpoint = _currentCheckpoint(scope);
    await ref
        .read(libraryRepositoryProvider)
        .upsertListV2(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          listId: existing?.id,
          name: name,
          description: description,
          sortOrder: sortOrder,
          expectedRevision: checkpoint,
        );
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  }

  Future<void> _deleteList({
    required ActiveLibraryScope scope,
    required LibraryV2LocalList list,
  }) async {
    final checkpoint = _currentCheckpoint(scope);
    await ref
        .read(libraryRepositoryProvider)
        .deleteListV2(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          listId: list.id,
          expectedRevision: checkpoint,
        );
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  }

  Future<void> _reorderLists({
    required ActiveLibraryScope scope,
    required List<LibraryV2LocalList> lists,
    required List<String> orderedIds,
  }) async {
    if (orderedIds.length != lists.length ||
        orderedIds.toSet().length != lists.length) {
      throw const LibraryRevisionConflict();
    }
    final byId = {for (final list in lists) list.id: list};
    if (!orderedIds.every(byId.containsKey)) {
      throw const LibraryRevisionConflict();
    }
    final checkpoint = _currentCheckpoint(scope);
    for (var index = 0; index < orderedIds.length; index += 1) {
      final list = byId[orderedIds[index]]!;
      final sortOrder = index * 1000;
      if (list.sortOrder == sortOrder) continue;
      await ref
          .read(libraryRepositoryProvider)
          .upsertListV2(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            listId: list.id,
            name: list.name,
            description: list.description ?? '',
            sortOrder: sortOrder,
            expectedRevision: checkpoint,
          );
    }
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  }

  Future<void> _saveTag({
    required ActiveLibraryScope scope,
    required LibraryV2LocalTag? existing,
    required String name,
  }) async {
    final checkpoint = _currentCheckpoint(scope);
    await ref
        .read(libraryRepositoryProvider)
        .upsertTagV2(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          tagId: existing?.id,
          name: name,
          expectedRevision: checkpoint,
        );
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  }

  Future<void> _deleteTag({
    required ActiveLibraryScope scope,
    required LibraryV2LocalTag tag,
  }) async {
    final checkpoint = _currentCheckpoint(scope);
    await ref
        .read(libraryRepositoryProvider)
        .deleteTagV2(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          tagId: tag.id,
          expectedRevision: checkpoint,
        );
    unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
  }

  int _currentCheckpoint(ActiveLibraryScope expected) {
    if (ref.read(libraryMutationScopeProvider) != expected) {
      throw const LibraryScopeChanged();
    }
    final checkpoint = ref.read(librarySyncCheckpointProvider(expected)).value;
    if (checkpoint == null || !checkpoint.initialized || checkpoint.resetting) {
      throw const LibraryRevisionConflict();
    }
    return checkpoint.lastRevision;
  }

  Future<void> _clearHistory(ActiveLibraryScope scope) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Clear private paper history?'),
        content: const Text(
          'This removes the explicitly opened-paper history on this device. Library and To Read are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (ref.read(libraryDisplayScopeProvider) != scope) return;
    await ref.read(libraryHistoryControllerProvider(scope).notifier).clear();
  }
}

class LibraryDestinationView extends StatefulWidget {
  const LibraryDestinationView({
    required this.items,
    required this.authority,
    required this.onOpenPaper,
    required this.editorCapabilities,
    this.onEdit,
    this.onAddPaper,
    this.onRefresh,
    this.loading = false,
    this.offline = false,
    this.canAddPaper = false,
    this.syncIssue,
    this.actionFailures = const [],
    this.readOnlyMessage,
    this.accountScopeListenable,
    this.expectedAccountScope,
    this.libraryV2Enabled = false,
    this.lists = const [],
    this.tags = const [],
    this.collectionsLoading = false,
    this.history = const LibraryHistoryState(loading: false),
    this.onHistoryEnabledChanged,
    this.onClearHistory,
    this.onOpenHistoryPaper,
    this.onOpenActionFailurePaper,
    this.onSignIn,
    this.onDismissActionFailure,
    this.onSaveList,
    this.onDeleteList,
    this.onReorderLists,
    this.onSaveTag,
    this.onDeleteTag,
    super.key,
  });

  final List<LibraryListItem> items;
  final LibraryWorkspaceAuthority authority;
  final ValueChanged<LibraryListItem> onOpenPaper;
  final LibraryEditorCapabilities editorCapabilities;
  final LibraryItemEditCallback? onEdit;
  final VoidCallback? onAddPaper;
  final Future<void> Function()? onRefresh;
  final bool loading;
  final bool offline;
  final bool canAddPaper;
  final LibrarySyncIssue? syncIssue;
  final List<LibraryActionFailure> actionFailures;
  final String? readOnlyMessage;
  final ValueListenable<LibraryEditorScope?>? accountScopeListenable;
  final LibraryEditorScope? expectedAccountScope;
  final bool libraryV2Enabled;
  final List<LibraryV2LocalList> lists;
  final List<LibraryV2LocalTag> tags;
  final bool collectionsLoading;
  final LibraryHistoryState history;
  final ValueChanged<bool>? onHistoryEnabledChanged;
  final VoidCallback? onClearHistory;
  final ValueChanged<PaperSummary>? onOpenHistoryPaper;
  final ValueChanged<PaperSummary>? onOpenActionFailurePaper;
  final VoidCallback? onSignIn;
  final ValueChanged<LibraryActionFailure>? onDismissActionFailure;
  final LibraryListSaveCallback? onSaveList;
  final LibraryListDeleteCallback? onDeleteList;
  final LibraryListReorderCallback? onReorderLists;
  final LibraryTagSaveCallback? onSaveTag;
  final LibraryTagDeleteCallback? onDeleteTag;

  @override
  State<LibraryDestinationView> createState() => _LibraryDestinationViewState();
}

class _LibraryDestinationViewState extends State<LibraryDestinationView> {
  LibraryItemState _selectedState = LibraryItemState.inbox;
  _LibrarySupplementalView? _supplementalView;

  @override
  Widget build(BuildContext context) {
    final selectedItems = widget.items
        .where((item) => item.state == _selectedState)
        .toList(growable: false);
    final reducedMotion = platformPrefersReducedMotion(context);
    Widget body = CustomScrollView(
      key: PageStorageKey<String>('library-${_selectedState.storageValue}'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _QueueAuthorityBanner(
                  authority: widget.authority,
                  offline: widget.offline,
                  syncIssue: widget.syncIssue,
                  readOnlyMessage: widget.readOnlyMessage,
                ),
                for (final failure in widget.actionFailures) ...[
                  const SizedBox(height: 12),
                  LibraryActionFailureCard(
                    failure: failure,
                    collectionsAvailable: widget.libraryV2Enabled,
                    onReview: () => _reviewActionFailure(failure),
                    onDismiss: () =>
                        widget.onDismissActionFailure?.call(failure),
                  ),
                ],
                const SizedBox(height: 12),
                _StatePicker(
                  selected: _supplementalView == null ? _selectedState : null,
                  items: widget.items,
                  onSelected: (state) => setState(() {
                    _selectedState = state;
                    _supplementalView = null;
                  }),
                ),
                if (widget.libraryV2Enabled) ...[
                  const SizedBox(height: 8),
                  _SupplementalPicker(
                    selected: _supplementalView,
                    onSelected: (value) =>
                        setState(() => _supplementalView = value),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_supplementalView == _LibrarySupplementalView.history)
          SliverToBoxAdapter(
            child: LibraryHistoryView(
              enabled: widget.history.enabled,
              entries: widget.history.entries,
              loading: widget.history.loading,
              saving: widget.history.saving,
              errorMessage: widget.history.errorMessage,
              onEnabledChanged: (enabled) =>
                  widget.onHistoryEnabledChanged?.call(enabled),
              onClear: () => widget.onClearHistory?.call(),
              onOpenPaper: (paper) => widget.onOpenHistoryPaper?.call(paper),
            ),
          )
        else if (_supplementalView == _LibrarySupplementalView.collections)
          SliverToBoxAdapter(
            child: LibraryCollectionsView(
              lists: widget.lists,
              tags: widget.tags,
              loading: widget.collectionsLoading,
              onSaveList: widget.onSaveList,
              onDeleteList: widget.onDeleteList,
              onReorderLists: widget.onReorderLists,
              onSaveTag: widget.onSaveTag,
              onDeleteTag: widget.onDeleteTag,
              accountScopeListenable: widget.accountScopeListenable,
              expectedAccountScope: widget.expectedAccountScope,
            ),
          )
        else if (widget.loading && widget.items.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (selectedItems.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LibraryEmptyState(
              state: _selectedState,
              canAddPaper: widget.canAddPaper,
              onAddPaper: widget.onAddPaper,
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList.separated(
              itemCount: selectedItems.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = selectedItems[index];
                return _LibraryPaperCard(
                  key: ValueKey('library-${item.paper.paperId}'),
                  item: item,
                  onOpen: () => widget.onOpenPaper(item),
                  onEdit: () => _openEditor(item),
                );
              },
            ),
          ),
      ],
    );
    if (widget.onRefresh != null) {
      body = RefreshIndicator(onRefresh: widget.onRefresh!, child: body);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (widget.canAddPaper)
            IconButton(
              key: const ValueKey('library-add-paper'),
              tooltip: 'Add a paper',
              onPressed: widget.onAddPaper,
              icon: const Icon(Icons.add_rounded),
            ),
          if (widget.authority.pendingCount > 0)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: Semantics(
                  label:
                      '${widget.authority.pendingCount} library changes '
                      'waiting to sync',
                  child: Badge(
                    label: Text('${widget.authority.pendingCount}'),
                    child: const Icon(Icons.cloud_upload_outlined),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: reducedMotion
              ? PakPerkMotion.instant
              : PakPerkMotion.crossFade,
          child: body,
        ),
      ),
    );
  }

  Future<void> _openEditor(LibraryListItem item) async {
    await showLibraryItemEditor(
      context: context,
      item: item,
      capabilities: widget.editorCapabilities,
      expectedLibraryRevision: widget.authority.checkpoint.initialized
          ? widget.authority.checkpoint.lastRevision
          : null,
      onSave: widget.onEdit,
      accountScopeListenable: widget.accountScopeListenable,
      expectedAccountScope: widget.expectedAccountScope,
    );
  }

  void _reviewActionFailure(LibraryActionFailure failure) {
    switch (failure.action) {
      case LibraryActionFailureAction.reviewPaper:
        final paper = failure.paper;
        if (paper != null) widget.onOpenActionFailurePaper?.call(paper);
        return;
      case LibraryActionFailureAction.reviewItem:
        final paper = failure.paper;
        if (paper == null) return;
        for (final item in widget.items) {
          if (item.paper.paperId == paper.paperId) {
            if (widget.libraryV2Enabled) {
              unawaited(_openEditor(item));
            } else {
              setState(() {
                _selectedState = item.state;
                _supplementalView = null;
              });
            }
            return;
          }
        }
        widget.onOpenActionFailurePaper?.call(paper);
        return;
      case LibraryActionFailureAction.reviewCollections:
        setState(() {
          _selectedState = LibraryItemState.inbox;
          _supplementalView = widget.libraryV2Enabled
              ? _LibrarySupplementalView.collections
              : null;
        });
        return;
      case LibraryActionFailureAction.signIn:
        widget.onSignIn?.call();
        return;
      case LibraryActionFailureAction.reviewLibrary:
        setState(() {
          _selectedState = LibraryItemState.inbox;
          _supplementalView = null;
        });
        return;
    }
  }
}

enum _LibrarySupplementalView { history, collections }

class _StatePicker extends StatelessWidget {
  const _StatePicker({
    required this.selected,
    required this.items,
    required this.onSelected,
  });

  final LibraryItemState? selected;
  final List<LibraryListItem> items;
  final ValueChanged<LibraryItemState> onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Library states',
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final state in LibraryItemState.values) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ChoiceChip(
                key: ValueKey('library-state-${state.storageValue}'),
                selected: state == selected,
                onSelected: (_) => onSelected(state),
                label: Text('${state.label} ${_count(items, state)}'),
              ),
            ),
            if (state != LibraryItemState.values.last) const SizedBox(width: 8),
          ],
        ],
      ),
    ),
  );
}

final class _SupplementalPicker extends StatelessWidget {
  const _SupplementalPicker({required this.selected, required this.onSelected});

  final _LibrarySupplementalView? selected;
  final ValueChanged<_LibrarySupplementalView> onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Additional Library views',
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: ChoiceChip(
            key: const ValueKey('library-view-history'),
            selected: selected == _LibrarySupplementalView.history,
            onSelected: (_) => onSelected(_LibrarySupplementalView.history),
            avatar: const Icon(Icons.history_rounded),
            label: const Text('History'),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: ChoiceChip(
            key: const ValueKey('library-view-collections'),
            selected: selected == _LibrarySupplementalView.collections,
            onSelected: (_) => onSelected(_LibrarySupplementalView.collections),
            avatar: const Icon(Icons.folder_outlined),
            label: const Text('Lists & tags'),
          ),
        ),
      ],
    ),
  );
}

class _QueueAuthorityBanner extends StatelessWidget {
  const _QueueAuthorityBanner({
    required this.authority,
    required this.offline,
    required this.syncIssue,
    required this.readOnlyMessage,
  });

  final LibraryWorkspaceAuthority authority;
  final bool offline;
  final LibrarySyncIssue? syncIssue;
  final String? readOnlyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String title, String detail) = switch (()) {
      _ when readOnlyMessage != null => (
        Icons.lock_outline,
        'Library is read-only',
        readOnlyMessage!,
      ),
      _ when authority.finishingQueue => (
        Icons.sync_rounded,
        'Finishing To Read',
        'Discovery stays hidden until the final change is confirmed.',
      ),
      _ when authority.activeItemCount > 0 => (
        Icons.bookmarks_outlined,
        '${authority.activeItemCount} active To Read',
        'Inbox, Read next, and Reading block recommendations.',
      ),
      _ when !authority.authorityComplete => (
        Icons.manage_search_rounded,
        'Checking queue',
        offline
            ? 'Connect to verify that To Read is empty.'
            : 'Recommendations stay hidden while Library verifies sync.',
      ),
      _ => (
        Icons.check_circle_outline,
        'To Read is confirmed empty',
        'Reviewed and Archived papers stay here without blocking discovery.',
      ),
    };
    final issue = syncIssue;
    return Semantics(
      liveRegion: authority.finishingQueue || issue != null,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(detail),
                    if (issue != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        issue.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryPaperCard extends StatelessWidget {
  const _LibraryPaperCard({
    required this.item,
    required this.onOpen,
    required this.onEdit,
    super.key,
  });

  final LibraryListItem item;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authors = item.paper.authors.join(', ');
    final date = MaterialLocalizations.of(
      context,
    ).formatShortDate(item.savedAt);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.paper.title, style: theme.textTheme.titleMedium),
                    if (authors.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        authors,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _MetadataPill(label: item.state.label),
                        if (item.saveSourceKind case final source?)
                          _MetadataPill(label: source.provenanceLabel),
                        _MetadataPill(label: 'Saved $date'),
                        if (item.reminderAt case final reminder?)
                          _MetadataPill(
                            label:
                                'Reminder ${MaterialLocalizations.of(context).formatShortDate(reminder.toLocal())} '
                                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(reminder.toLocal()))}',
                          ),
                        if (item.savedState.syncPending)
                          const _MetadataPill(label: 'Waiting to sync'),
                      ],
                    ),
                    if (item.privateNote case final note? when note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          '“$note”',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    if (item.listNames.isNotEmpty || item.tagNames.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          [
                            if (item.listNames.isNotEmpty)
                              'Lists: ${item.listNames.join(', ')}',
                            if (item.tagNames.isNotEmpty)
                              'Tags: ${item.tagNames.join(', ')}',
                          ].join('  •  '),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('library-edit-${item.paper.paperId}'),
                tooltip: 'Edit ${item.paper.title}',
                onPressed: onEdit,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataPill extends StatelessWidget {
  const _MetadataPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.state,
    required this.canAddPaper,
    required this.onAddPaper,
  });

  final LibraryItemState state;
  final bool canAddPaper;
  final VoidCallback? onAddPaper;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.library_books_outlined, size: 50),
          const SizedBox(height: 14),
          Text(
            'No papers in ${state.label}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 7),
          Text(switch (state) {
            LibraryItemState.inbox =>
              'Papers you add arrive here before you organize them.',
            LibraryItemState.readNext =>
              'Mark a paper Read next when it is near-term work.',
            LibraryItemState.reading =>
              'Opening a paper never marks it Reading automatically.',
            LibraryItemState.reviewed =>
              'Reviewed papers remain in your history without blocking discovery.',
            LibraryItemState.archived =>
              'Archived papers stay retained and out of To Read.',
          }, textAlign: TextAlign.center),
          if (state == LibraryItemState.inbox && canAddPaper) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey('library-empty-add-paper'),
              onPressed: onAddPaper,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add paper'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _SignedOutLibraryDestination extends StatelessWidget {
  const _SignedOutLibraryDestination();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Library')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_sync_outlined, size: 52),
              const SizedBox(height: 16),
              Text(
                'Sign in to see your Library',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Your saved papers and private organization belong to your '
                'account. Public reading stays available without signing in.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.push<void>('/auth'),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _UnavailableLibraryDestination extends StatelessWidget {
  const _UnavailableLibraryDestination({required this.status});

  final AccountStatus status;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Library')),
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _readOnlyMessage(status),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    ),
  );
}

String _readOnlyMessage(AccountStatus status) => switch (status) {
  AccountStatus.suspended =>
    'Account suspended. Your Library is read-only on this device.',
  AccountStatus.deletionPending =>
    'Account deletion is pending. Your Library is read-only.',
  AccountStatus.deleted => 'This account is deleted. Library is read-only.',
  AccountStatus.active => 'Library is read-only.',
};

int _count(List<LibraryListItem> items, LibraryItemState state) =>
    items.where((item) => item.state == state).length;

LibraryEditorScope? _editorScope(ActiveLibraryScope? scope) => scope == null
    ? null
    : LibraryEditorScope(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
      );
