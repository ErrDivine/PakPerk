import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/database/library_dao.dart';
import '../../core/database/library_v2_dao.dart';
import '../../core/interactions/interaction_models.dart';
import '../../core/library/library_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../library/paper_save_control.dart';

/// Paper-scoped access to the canonical Library v2 state authority.
///
/// Unsaved papers retain the established add/remove control. Once a v2 item
/// exists, every state or note change is routed through the account-fenced
/// Library repository and durable outbox.
class ReaderLibraryControl extends ConsumerWidget {
  const ReaderLibraryControl({
    required this.paper,
    this.saveSourceKind,
    this.interactionContext,
    super.key,
  });

  final PaperSummary paper;
  final LibrarySaveSourceKind? saveSourceKind;
  final PaperInteractionContext? interactionContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flags = ref.watch(featureFlagsProvider);
    final scope = ref.watch(libraryDisplayScopeProvider);
    if (!flags.libraryV2Enabled || scope == null) {
      return PaperSaveControl(
        paper: paper,
        compact: true,
        saveSourceKind: saveSourceKind,
        interactionContext: interactionContext,
      );
    }
    final items = ref.watch(libraryItemsProvider(scope));
    if (!items.hasValue) {
      return _ReaderLibraryStatusControl(
        loading: items.isLoading,
        onRetry: items.hasError
            ? () => ref.invalidate(libraryItemsProvider(scope))
            : null,
      );
    }
    final item = _paperItem(items.value, paper.paperId);
    if (item == null) {
      return PaperSaveControl(
        paper: paper,
        compact: true,
        saveSourceKind: saveSourceKind,
        interactionContext: interactionContext,
      );
    }
    return _ReaderLibraryControlButton(
      item: item,
      onPressed: () => unawaited(
        showReaderLibrarySheet(
          context: context,
          scope: scope,
          initialItem: item,
        ),
      ),
    );
  }
}

class _ReaderLibraryStatusControl extends StatelessWidget {
  const _ReaderLibraryStatusControl({
    required this.loading,
    required this.onRetry,
  });

  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final label = loading
        ? 'Loading Library state'
        : 'Library state unavailable';
    return Semantics(
      container: true,
      button: onRetry != null,
      label: label,
      child: Tooltip(
        message: onRetry == null ? label : '$label. Retry',
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('reader-library-status'),
          onTap: onRetry,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: PakPerkSizes.minimumInteractive,
              minHeight: 56,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.sync_problem_outlined, size: 22),
                const SizedBox(height: 4),
                const Text(
                  'Library',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderLibraryControlButton extends StatelessWidget {
  const _ReaderLibraryControlButton({
    required this.item,
    required this.onPressed,
  });

  final LibraryListItem item;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final pending = item.savedState.syncPending;
    final label = pending
        ? '${item.state.label}, pending sync'
        : item.state.label;
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: 'Library state: $label. Open Library controls.',
      child: Tooltip(
        message: 'Library state: ${item.state.label}',
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('reader-library-control'),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: PakPerkSizes.minimumInteractive,
              minHeight: 56,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  pending
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.local_library_outlined, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    item.state.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showReaderLibrarySheet({
  required BuildContext context,
  required ActiveLibraryScope scope,
  required LibraryListItem initialItem,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    isScrollControlled: true,
    showDragHandle: false,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (_) => _ReaderLibrarySheet(scope: scope, initialItem: initialItem),
  );
}

class _ReaderLibrarySheet extends ConsumerStatefulWidget {
  const _ReaderLibrarySheet({required this.scope, required this.initialItem});

  final ActiveLibraryScope scope;
  final LibraryListItem initialItem;

  @override
  ConsumerState<_ReaderLibrarySheet> createState() =>
      _ReaderLibrarySheetState();
}

class _ReaderLibrarySheetState extends ConsumerState<_ReaderLibrarySheet> {
  late final TextEditingController _note;
  bool _busy = false;
  bool _removedLocally = false;
  bool _finalTransitionRequested = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.initialItem.privateNote ?? '');
  }

  @override
  void dispose() {
    _note
      ..clear()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ActiveLibraryScope?>(libraryDisplayScopeProvider, (_, next) {
      if (next == widget.scope) return;
      _note.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    });
    final items = ref.watch(libraryItemsProvider(widget.scope));
    final item = items.value == null
        ? widget.initialItem
        : _paperItem(items.value, widget.initialItem.paper.paperId);
    final activeItems = ref.watch(toReadItemsProvider(widget.scope)).value;
    final checkpoint = ref
        .watch(librarySyncCheckpointProvider(widget.scope))
        .value;
    final mutationScope = ref.watch(libraryMutationScopeProvider);
    final acknowledgement = ref.watch(
      libraryFinalCompletionAcknowledgementProvider,
    );
    final scopeCurrent = mutationScope == widget.scope;
    final authorityReady =
        checkpoint?.initialized == true && checkpoint?.resetting == false;
    final pending = item?.savedState.syncPending ?? _removedLocally;
    final enabled =
        item != null && scopeCurrent && authorityReady && !_busy && !pending;
    final finalChecking =
        _finalTransitionRequested &&
        acknowledgement?.accountId == widget.scope.accountId &&
        acknowledgement?.authEpoch == widget.scope.authEpoch;

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'Library controls for ${widget.initialItem.paper.title}',
      explicitChildNodes: true,
      child: SafeArea(
        top: true,
        bottom: false,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .92,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            'Library state',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('reader-library-close'),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: 'Close Library controls',
                        constraints: const BoxConstraints.tightFor(
                          width: PakPerkSizes.minimumInteractive,
                          height: PakPerkSizes.minimumInteractive,
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    widget.initialItem.paper.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  if (item != null) ...[
                    Text(
                      'Current: ${item.state.label}',
                      key: const ValueKey('reader-library-current-state'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final state in const [
                          LibraryItemState.reading,
                          LibraryItemState.reviewed,
                          LibraryItemState.archived,
                        ])
                          _StateAction(
                            state: state,
                            selected: item.state == state,
                            enabled: enabled && item.state != state,
                            onPressed: () => _changeState(
                              item: item,
                              activeItems: activeItems,
                              checkpoint: checkpoint!,
                              state: state,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const ValueKey('reader-library-note'),
                      controller: _note,
                      enabled: enabled,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 500,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(500),
                        FilteringTextInputFormatter.deny(RegExp(r'\x00')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Private save note',
                        helperText:
                            'Private. Never used as recommendation input.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    _FullWidthAction(
                      key: const ValueKey('reader-library-save-note'),
                      label: 'Save private note',
                      icon: Icons.edit_note_outlined,
                      onPressed:
                          enabled &&
                              _note.text.trim() != (item.privateNote ?? '')
                          ? () => _saveNote(item, checkpoint!)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    _FullWidthAction(
                      key: const ValueKey('reader-library-remove'),
                      label: 'Remove from Library',
                      icon: Icons.remove_circle_outline,
                      destructive: true,
                      onPressed: enabled
                          ? () => _confirmRemove(
                              item: item,
                              activeItems: activeItems,
                              checkpoint: checkpoint!,
                            )
                          : null,
                    ),
                  ] else ...[
                    const Text(
                      'Removed from Library. This paper remains open until you leave the reader.',
                    ),
                  ],
                  if (_busy ||
                      pending ||
                      finalChecking ||
                      _message != null) ...[
                    const SizedBox(height: 16),
                    _LibraryMutationStatus(
                      busy: _busy,
                      pending: pending,
                      finalChecking: finalChecking,
                      message: _message,
                      error: _messageIsError,
                    ),
                  ],
                  if (!scopeCurrent || !authorityReady) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        !scopeCurrent
                            ? 'Library changes are unavailable for this account.'
                            : 'Library sync must finish before changing this item.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _changeState({
    required LibraryListItem item,
    required List<LibraryListItem>? activeItems,
    required LibrarySyncCheckpoint checkpoint,
    required LibraryItemState state,
  }) async {
    final finalTransition =
        item.state.isActive &&
        !state.isActive &&
        activeItems?.where((value) => value.state.isActive).length == 1;
    await _commit(
      finalTransition: finalTransition,
      action: () => ref
          .read(libraryRepositoryProvider)
          .editItemV2(
            accountId: widget.scope.accountId,
            authEpoch: widget.scope.authEpoch,
            paperId: item.paper.paperId,
            state: state,
            privateNote: item.privateNote ?? '',
            reminderAt: state.isActive ? item.reminderAt : null,
            listNames: item.listNames,
            tagNames: item.tagNames,
            expectedRevision: checkpoint.lastRevision,
          ),
      success: '${state.label} queued. Waiting to sync.',
    );
  }

  Future<void> _saveNote(
    LibraryListItem item,
    LibrarySyncCheckpoint checkpoint,
  ) => _commit(
    finalTransition: false,
    action: () => ref
        .read(libraryRepositoryProvider)
        .editItemV2(
          accountId: widget.scope.accountId,
          authEpoch: widget.scope.authEpoch,
          paperId: item.paper.paperId,
          state: item.state,
          privateNote: _note.text,
          reminderAt: item.reminderAt,
          listNames: item.listNames,
          tagNames: item.tagNames,
          expectedRevision: checkpoint.lastRevision,
        ),
    success: 'Private note queued. Waiting to sync.',
  );

  Future<void> _confirmRemove({
    required LibraryListItem item,
    required List<LibraryListItem>? activeItems,
    required LibrarySyncCheckpoint checkpoint,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from Library?'),
        content: const Text(
          'This removes the paper from To Read and Library history. Your reader stays open.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final finalTransition =
        item.state.isActive &&
        activeItems?.where((value) => value.state.isActive).length == 1;
    await _commit(
      finalTransition: finalTransition,
      action: () => ref
          .read(libraryRepositoryProvider)
          .removeItemV2(
            accountId: widget.scope.accountId,
            authEpoch: widget.scope.authEpoch,
            paperId: item.paper.paperId,
            expectedRevision: checkpoint.lastRevision,
          ),
      success: 'Removal queued. Waiting for Library verification.',
      removed: true,
    );
  }

  Future<void> _commit({
    required bool finalTransition,
    required Future<Object?> Function() action,
    required String success,
    bool removed = false,
  }) async {
    if (_busy || ref.read(libraryMutationScopeProvider) != widget.scope) return;
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await action();
      if (!mounted || ref.read(libraryMutationScopeProvider) != widget.scope) {
        return;
      }
      unawaited(_acknowledgeCommittedMutation());
      setState(() {
        _busy = false;
        _removedLocally = removed;
        _finalTransitionRequested |= finalTransition;
        _message = finalTransition
            ? 'Finishing To Read waits for server-confirmed emptiness.'
            : success;
      });
      unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
    } on LibraryScopeChanged {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on LibraryRevisionConflict {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = 'Library changed elsewhere. Refresh, then try again.';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = 'This change could not be queued on this device. Try again.';
      });
    }
  }

  Future<void> _acknowledgeCommittedMutation() async {
    try {
      await HapticFeedback.selectionClick();
    } on Object {
      // Haptics are best-effort and occur only after the durable local commit.
    }
  }
}

class _StateAction extends StatelessWidget {
  const _StateAction({
    required this.state,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final LibraryItemState state;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final child = selected
        ? FilledButton.tonalIcon(
            onPressed: null,
            icon: const Icon(Icons.check),
            label: Text(state.label),
          )
        : OutlinedButton.icon(
            onPressed: enabled ? onPressed : null,
            icon: Icon(_stateIcon(state)),
            label: Text(state.label),
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: PakPerkSizes.minimumInteractive,
      ),
      child: child,
    );
  }
}

class _FullWidthAction extends StatelessWidget {
  const _FullWidthAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: PakPerkSizes.minimumInteractive,
    ),
    child: OutlinedButton.icon(
      style: destructive
          ? OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            )
          : null,
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}

class _LibraryMutationStatus extends StatelessWidget {
  const _LibraryMutationStatus({
    required this.busy,
    required this.pending,
    required this.finalChecking,
    required this.message,
    required this.error,
  });

  final bool busy;
  final bool pending;
  final bool finalChecking;
  final String? message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final text = finalChecking
        ? 'Checking To Read with the server before discovery can resume.'
        : message ??
              (busy
                  ? 'Saving Library change on this device…'
                  : 'Library change is waiting to sync.');
    return Semantics(
      container: true,
      liveRegion: true,
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: error
              ? Theme.of(context).colorScheme.errorContainer
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (busy || pending)
                const Padding(
                  padding: EdgeInsetsDirectional.only(end: 12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 12),
                  child: Icon(error ? Icons.error_outline : Icons.check_circle),
                ),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

LibraryListItem? _paperItem(List<LibraryListItem>? items, String paperId) {
  if (items == null) return null;
  for (final item in items) {
    if (item.paper.paperId == paperId) return item;
  }
  return null;
}

IconData _stateIcon(LibraryItemState state) => switch (state) {
  LibraryItemState.reading => Icons.menu_book_outlined,
  LibraryItemState.reviewed => Icons.task_alt_outlined,
  LibraryItemState.archived => Icons.archive_outlined,
  LibraryItemState.inbox || LibraryItemState.readNext => Icons.bookmark_outline,
};
