import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/library/library_v2_models.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import 'library_workspace_models.dart';

typedef LibraryListSaveCallback =
    Future<void> Function(
      LibraryV2LocalList? existing,
      String name,
      String description,
      int sortOrder,
    );
typedef LibraryListDeleteCallback =
    Future<void> Function(LibraryV2LocalList list);
typedef LibraryListReorderCallback =
    Future<void> Function(List<String> orderedListIds);
typedef LibraryTagSaveCallback =
    Future<void> Function(LibraryV2LocalTag? existing, String name);
typedef LibraryTagDeleteCallback = Future<void> Function(LibraryV2LocalTag tag);

final class LibraryCollectionsView extends StatefulWidget {
  const LibraryCollectionsView({
    required this.lists,
    required this.tags,
    required this.loading,
    required this.onSaveList,
    required this.onDeleteList,
    required this.onReorderLists,
    required this.onSaveTag,
    required this.onDeleteTag,
    this.accountScopeListenable,
    this.expectedAccountScope,
    super.key,
  });

  final List<LibraryV2LocalList> lists;
  final List<LibraryV2LocalTag> tags;
  final bool loading;
  final LibraryListSaveCallback? onSaveList;
  final LibraryListDeleteCallback? onDeleteList;
  final LibraryListReorderCallback? onReorderLists;
  final LibraryTagSaveCallback? onSaveTag;
  final LibraryTagDeleteCallback? onDeleteTag;
  final ValueListenable<LibraryEditorScope?>? accountScopeListenable;
  final LibraryEditorScope? expectedAccountScope;

  @override
  State<LibraryCollectionsView> createState() => _LibraryCollectionsViewState();
}

final class _LibraryCollectionsViewState extends State<LibraryCollectionsView> {
  var _busy = false;
  var _dialogOpen = false;
  var _scopeCloseScheduled = false;
  Route<dynamic>? _dialogRoute;
  String? _errorMessage;

  bool get _enabled =>
      !_busy &&
      !widget.loading &&
      _scopeIsCurrent &&
      widget.onSaveList != null &&
      widget.onSaveTag != null;

  bool get _scopeIsCurrent {
    final expected = widget.expectedAccountScope;
    return expected == null || widget.accountScopeListenable?.value == expected;
  }

  @override
  void initState() {
    super.initState();
    widget.accountScopeListenable?.addListener(_onAccountScopeChanged);
  }

  @override
  void didUpdateWidget(covariant LibraryCollectionsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountScopeListenable != widget.accountScopeListenable) {
      oldWidget.accountScopeListenable?.removeListener(_onAccountScopeChanged);
      widget.accountScopeListenable?.addListener(_onAccountScopeChanged);
    }
    if (oldWidget.expectedAccountScope != widget.expectedAccountScope) {
      _onAccountScopeChanged();
    }
  }

  @override
  void dispose() {
    widget.accountScopeListenable?.removeListener(_onAccountScopeChanged);
    super.dispose();
  }

  void _onAccountScopeChanged() {
    if (_scopeIsCurrent || !_dialogOpen || _scopeCloseScheduled || !mounted) {
      return;
    }
    if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle &&
        _dialogRoute != null) {
      _closeDialogForAccountChange();
      return;
    }
    _scopeCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scopeCloseScheduled = false;
      _closeDialogForAccountChange();
    });
  }

  void _closeDialogForAccountChange() {
    if (!mounted || _scopeIsCurrent || !_dialogOpen) return;
    final route = _dialogRoute;
    if (route == null || !route.isActive) return;
    // Account transitions are a privacy boundary, so remove the exact private
    // editor immediately instead of animating stale account content through a
    // reverse transition.
    Navigator.of(context, rootNavigator: true).removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      key: const ValueKey('library-collections-view'),
      container: true,
      label: 'Private lists and tags',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PakPerkSpacing.md,
          PakPerkSpacing.xs,
          PakPerkSpacing.md,
          PakPerkSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: theme.colorScheme.surfaceContainerLow,
              child: const ListTile(
                leading: Icon(Icons.lock_outline_rounded),
                title: Text('Private organization'),
                subtitle: Text(
                  'Lists and tags help you find papers. They never determine whether discovery is allowed.',
                ),
              ),
            ),
            const SizedBox(height: PakPerkSpacing.lg),
            _SectionHeader(
              title: 'Lists',
              actionKey: const ValueKey('library-list-add'),
              actionLabel: 'New list',
              enabled: _enabled && widget.lists.length < 20,
              onPressed: () => _editList(null),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            if (widget.loading)
              const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Loading Library lists and tags',
                ),
              )
            else if (widget.lists.isEmpty)
              const _EmptyCollection(
                label: 'No lists yet. Create one for an ordered collection.',
              )
            else
              for (var index = 0; index < widget.lists.length; index += 1) ...[
                _ListCard(
                  list: widget.lists[index],
                  index: index,
                  count: widget.lists.length,
                  enabled: _enabled,
                  onMoveUp: () => _moveList(index, -1),
                  onMoveDown: () => _moveList(index, 1),
                  onEdit: () => _editList(widget.lists[index]),
                  onDelete: () => _deleteList(widget.lists[index]),
                ),
                const SizedBox(height: PakPerkSpacing.xs),
              ],
            const SizedBox(height: PakPerkSpacing.lg),
            _SectionHeader(
              title: 'Tags',
              actionKey: const ValueKey('library-tag-add'),
              actionLabel: 'New tag',
              enabled: _enabled && widget.tags.length < 50,
              onPressed: () => _editTag(null),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            if (!widget.loading && widget.tags.isEmpty)
              const _EmptyCollection(
                label: 'No tags yet. Add reusable labels to saved papers.',
              )
            else if (!widget.loading)
              Wrap(
                spacing: PakPerkSpacing.xs,
                runSpacing: PakPerkSpacing.xs,
                children: [
                  for (final tag in widget.tags)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: PakPerkSizes.minimumInteractive,
                      ),
                      child: InputChip(
                        key: ValueKey('library-tag-${tag.id}'),
                        label: Text(
                          tag.syncPending ? '${tag.name} · syncing' : tag.name,
                        ),
                        avatar: const Icon(Icons.sell_outlined),
                        onPressed: _enabled ? () => _editTag(tag) : null,
                        deleteButtonTooltipMessage: 'Delete tag ${tag.name}',
                        onDeleted: _enabled ? () => _deleteTag(tag) : null,
                      ),
                    ),
                ],
              ),
            if (_errorMessage != null) ...[
              const SizedBox(height: PakPerkSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  _errorMessage!,
                  key: const ValueKey('library-collections-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editList(LibraryV2LocalList? existing) async {
    final callback = widget.onSaveList;
    if (!_enabled || callback == null) return;
    var name = existing?.name ?? '';
    var description = existing?.description ?? '';
    final draft =
        await _showAccountScopedDialog<({String name, String description})>(
          builder: (context) => AlertDialog.adaptive(
            title: Text(
              existing == null ? 'New private list' : 'Edit private list',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey('library-list-name-input'),
                    initialValue: name,
                    onChanged: (value) => name = value,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'List name'),
                    maxLength: 100,
                    textInputAction: TextInputAction.next,
                  ),
                  TextFormField(
                    key: const ValueKey('library-list-description-input'),
                    initialValue: description,
                    onChanged: (value) => description = value,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pop((name: name, description: description)),
                child: const Text('Save list'),
              ),
            ],
          ),
        );
    if (draft == null || !mounted || !_scopeIsCurrent) return;
    final normalized = draft.name.trim();
    if (normalized.isEmpty) {
      setState(() => _errorMessage = 'Enter a list name.');
      return;
    }
    final sortOrder =
        existing?.sortOrder ??
        (widget.lists.isEmpty
            ? 0
            : widget.lists.last.sortOrder.clamp(0, 999000) + 1000);
    await _run(
      () => callback(existing, normalized, draft.description, sortOrder),
    );
  }

  Future<void> _editTag(LibraryV2LocalTag? existing) async {
    final callback = widget.onSaveTag;
    if (!_enabled || callback == null) return;
    var name = existing?.name ?? '';
    final value = await _showAccountScopedDialog<String>(
      builder: (context) => AlertDialog.adaptive(
        title: Text(existing == null ? 'New private tag' : 'Rename tag'),
        content: TextFormField(
          key: const ValueKey('library-tag-name-input'),
          initialValue: name,
          onChanged: (value) => name = value,
          autofocus: true,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Tag name'),
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(name),
            child: const Text('Save tag'),
          ),
        ],
      ),
    );
    if (value == null || !mounted || !_scopeIsCurrent) return;
    if (value.trim().isEmpty) {
      setState(() => _errorMessage = 'Enter a tag name.');
      return;
    }
    await _run(() => callback(existing, value.trim()));
  }

  Future<void> _deleteList(LibraryV2LocalList list) async {
    final callback = widget.onDeleteList;
    if (!_enabled || callback == null) return;
    final confirmed = await _confirmDelete(
      title: 'Delete “${list.name}”?',
      detail:
          'The list is removed from its papers. The papers and their To Read states stay unchanged.',
      action: 'Delete list',
    );
    if (confirmed && mounted) await _run(() => callback(list));
  }

  Future<void> _deleteTag(LibraryV2LocalTag tag) async {
    final callback = widget.onDeleteTag;
    if (!_enabled || callback == null) return;
    final confirmed = await _confirmDelete(
      title: 'Delete “${tag.name}”?',
      detail:
          'The tag is removed from its papers. The papers and their To Read states stay unchanged.',
      action: 'Delete tag',
    );
    if (confirmed && mounted) await _run(() => callback(tag));
  }

  Future<void> _moveList(int index, int delta) async {
    final callback = widget.onReorderLists;
    final target = index + delta;
    if (!_enabled ||
        callback == null ||
        target < 0 ||
        target >= widget.lists.length) {
      return;
    }
    final ordered = widget.lists.map((list) => list.id).toList();
    final moved = ordered.removeAt(index);
    ordered.insert(target, moved);
    await _run(() => callback(List.unmodifiable(ordered)));
  }

  Future<bool> _confirmDelete({
    required String title,
    required String detail,
    required String action,
  }) async =>
      await _showAccountScopedDialog<bool>(
        builder: (context) => AlertDialog.adaptive(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<T?> _showAccountScopedDialog<T>({
    required WidgetBuilder builder,
  }) async {
    if (!_scopeIsCurrent || _dialogOpen) return null;
    _dialogOpen = true;
    Route<dynamic>? presentedRoute;
    try {
      return await showDialog<T>(
        context: context,
        builder: (dialogContext) {
          presentedRoute ??= ModalRoute.of(dialogContext);
          _dialogRoute = presentedRoute;
          if (!_scopeIsCurrent) _onAccountScopeChanged();
          return builder(dialogContext);
        },
      );
    } finally {
      if (identical(_dialogRoute, presentedRoute)) _dialogRoute = null;
      _dialogOpen = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await action();
    } on Object {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'That organization change could not be queued. Refresh Library and try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionKey,
    required this.actionLabel,
    required this.enabled,
    required this.onPressed,
  });

  final String title;
  final Key actionKey;
  final String actionLabel;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PakPerkSizes.minimumInteractive,
        ),
        child: FilledButton.tonalIcon(
          key: actionKey,
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.add_rounded),
          label: Text(actionLabel),
        ),
      ),
    ],
  );
}

final class _ListCard extends StatelessWidget {
  const _ListCard({
    required this.list,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onEdit,
    required this.onDelete,
  });

  final LibraryV2LocalList list;
  final int index;
  final int count;
  final bool enabled;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        PakPerkSpacing.md,
        PakPerkSpacing.sm,
        PakPerkSpacing.xs,
        PakPerkSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(list.name, style: Theme.of(context).textTheme.titleMedium),
          if (list.description case final description?
              when description.isNotEmpty) ...[
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(description),
          ],
          if (list.syncPending) ...[
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(
              'Waiting to sync',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              IconButton(
                key: ValueKey('library-list-up-${list.id}'),
                tooltip: 'Move ${list.name} earlier',
                onPressed: enabled && index > 0 ? onMoveUp : null,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              IconButton(
                key: ValueKey('library-list-down-${list.id}'),
                tooltip: 'Move ${list.name} later',
                onPressed: enabled && index + 1 < count ? onMoveDown : null,
                icon: const Icon(Icons.arrow_downward_rounded),
              ),
              IconButton(
                key: ValueKey('library-list-edit-${list.id}'),
                tooltip: 'Edit ${list.name}',
                onPressed: enabled ? onEdit : null,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: ValueKey('library-list-delete-${list.id}'),
                tooltip: 'Delete ${list.name}',
                onPressed: enabled ? onDelete : null,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

final class _EmptyCollection extends StatelessWidget {
  const _EmptyCollection({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: PakPerkSpacing.md),
    child: Text(label),
  );
}
