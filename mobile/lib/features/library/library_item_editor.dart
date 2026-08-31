import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/library/library_models.dart';
import '../../design_system/motion.dart';
import 'library_workspace_models.dart';

Future<LibraryItemEditDraft?> showLibraryItemEditor({
  required BuildContext context,
  required LibraryListItem item,
  required LibraryEditorCapabilities capabilities,
  required int? expectedLibraryRevision,
  LibraryItemEditCallback? onSave,
  ValueListenable<LibraryEditorScope?>? accountScopeListenable,
  LibraryEditorScope? expectedAccountScope,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<LibraryItemEditDraft>(
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
    builder: (_) => _LibraryItemEditorSheet(
      item: item,
      capabilities: capabilities,
      expectedLibraryRevision: expectedLibraryRevision,
      onSave: onSave,
      accountScopeListenable: accountScopeListenable,
      expectedAccountScope: expectedAccountScope,
    ),
  );
}

class _LibraryItemEditorSheet extends StatefulWidget {
  const _LibraryItemEditorSheet({
    required this.item,
    required this.capabilities,
    required this.expectedLibraryRevision,
    required this.onSave,
    required this.accountScopeListenable,
    required this.expectedAccountScope,
  });

  final LibraryListItem item;
  final LibraryEditorCapabilities capabilities;
  final int? expectedLibraryRevision;
  final LibraryItemEditCallback? onSave;
  final ValueListenable<LibraryEditorScope?>? accountScopeListenable;
  final LibraryEditorScope? expectedAccountScope;

  @override
  State<_LibraryItemEditorSheet> createState() =>
      _LibraryItemEditorSheetState();
}

class _LibraryItemEditorSheetState extends State<_LibraryItemEditorSheet> {
  late LibraryItemState _state;
  late final TextEditingController _noteController;
  late final TextEditingController _listsController;
  late final TextEditingController _tagsController;
  DateTime? _reminderAt;
  DateTime? _completedReminderAt;
  bool _saving = false;
  bool _scopeInvalid = false;
  String? _error;

  bool get _canSave =>
      widget.capabilities.canEdit && widget.onSave != null && !_saving;

  @override
  void initState() {
    super.initState();
    _state = widget.item.state;
    final reminderAt = widget.item.reminderAt?.toUtc();
    if (reminderAt != null && !reminderAt.isAfter(DateTime.now().toUtc())) {
      _completedReminderAt = reminderAt;
      _reminderAt = null;
    } else {
      _reminderAt = reminderAt;
    }
    _noteController = TextEditingController(text: widget.item.privateNote);
    _listsController = TextEditingController(
      text: widget.item.listNames.join(', '),
    );
    _tagsController = TextEditingController(
      text: widget.item.tagNames.join(', '),
    );
    widget.accountScopeListenable?.addListener(_handleScopeChange);
  }

  @override
  void dispose() {
    widget.accountScopeListenable?.removeListener(_handleScopeChange);
    _noteController.dispose();
    _listsController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_scopeInvalid) return const SizedBox.shrink();
    final reducedMotion = platformPrefersReducedMotion(context);
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'Edit ${widget.item.paper.title}',
      explicitChildNodes: true,
      child: SafeArea(
        left: true,
        right: true,
        top: true,
        bottom: false,
        child: AnimatedPadding(
          duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.quick,
          curve: PakPerkMotion.emphasized,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * .94),
            child: Material(
              color: theme.colorScheme.surface,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _AccessibleDragHandle(),
                    const SizedBox(height: 10),
                    Text('Organize paper', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      widget.item.paper.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<LibraryItemState>(
                      key: const ValueKey('library-editor-state'),
                      initialValue: _state,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'State',
                        helperText:
                            'Inbox, Read next, and Reading stay in To Read.',
                      ),
                      items: [
                        for (final state in LibraryItemState.values)
                          DropdownMenuItem(
                            value: state,
                            child: Text(state.label),
                          ),
                      ],
                      onChanged: widget.capabilities.state
                          ? (value) {
                              if (value != null) {
                                setState(() {
                                  _state = value;
                                  if (!value.isActive) {
                                    _reminderAt = null;
                                    _completedReminderAt = null;
                                  }
                                });
                              }
                            }
                          : null,
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      key: const ValueKey('library-editor-reminder'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.notifications_none_rounded),
                      title: const Text('Remind me'),
                      subtitle: Text(_reminderLabel(context)),
                      enabled:
                          _state.isActive &&
                          (widget.capabilities.reminders ||
                              _reminderAt != null ||
                              _completedReminderAt != null),
                      onTap: widget.capabilities.reminders && _state.isActive
                          ? _pickReminder
                          : null,
                      trailing:
                          _reminderAt == null && _completedReminderAt == null
                          ? Icon(
                              widget.capabilities.reminders
                                  ? Icons.chevron_right_rounded
                                  : Icons.notifications_off_outlined,
                            )
                          : IconButton(
                              key: const ValueKey(
                                'library-editor-clear-reminder',
                              ),
                              tooltip: 'Clear reminder',
                              onPressed: _state.isActive
                                  ? () => setState(() {
                                      _reminderAt = null;
                                      _completedReminderAt = null;
                                    })
                                  : null,
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                    if (!_state.isActive)
                      Text(
                        'Reminders are available for Inbox, Read next, and Reading.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (_state.isActive && !widget.capabilities.reminders)
                      Text(
                        _reminderAt == null && _completedReminderAt == null
                            ? 'Turn on in-app notifications to set a reminder.'
                            : 'Notifications are unavailable in this build. You can still clear this reminder.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('library-editor-note'),
                      controller: _noteController,
                      enabled: widget.capabilities.privateNote,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: 500,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [LengthLimitingTextInputFormatter(500)],
                      decoration: const InputDecoration(
                        labelText: 'Why save this?',
                        hintText: 'Optional private note',
                        helperText:
                            'Private. Never used as recommendation input.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('library-editor-lists'),
                      controller: _listsController,
                      enabled: widget.capabilities.lists,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Lists',
                        hintText: 'Methods, Journal club',
                        helperText: 'Separate list names with commas.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('library-editor-tags'),
                      controller: _tagsController,
                      enabled: widget.capabilities.tags,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (_canSave) unawaited(_save());
                      },
                      decoration: const InputDecoration(
                        labelText: 'Tags',
                        hintText: 'transformers, evaluation',
                        helperText: 'Separate tags with commas.',
                      ),
                    ),
                    if (!widget.capabilities.canEdit) ...[
                      const SizedBox(height: 16),
                      _EditorMessage(
                        icon: Icons.lock_clock_outlined,
                        message:
                            widget.capabilities.unavailableReason ??
                            'Editing is not available.',
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: _EditorMessage(
                          icon: Icons.error_outline,
                          message: _error!,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('library-editor-save'),
                            onPressed: _canSave ? _save : null,
                            child: _saving
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(_error == null ? 'Save' : 'Retry'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: media.padding.bottom),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_canSave) return;
    if (!_scopeIsCurrent()) {
      _invalidateScope();
      return;
    }
    LibraryItemEditDraft draft;
    try {
      draft = LibraryItemEditDraft(
        state: _state,
        privateNote: _noteController.text,
        listNames: _splitNames(_listsController.text),
        tagNames: _splitNames(_tagsController.text),
        reminderAt: _reminderAt,
      );
    } on ArgumentError {
      setState(
        () => _error =
            'Use no more than 20 lists (100 characters) or tags '
            '(60 characters).',
      );
      return;
    }
    if (!draft.differsFrom(widget.item)) {
      Navigator.of(context).pop(draft);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave!(widget.item, draft, widget.expectedLibraryRevision);
      if (!_scopeIsCurrent()) {
        _invalidateScope();
      } else if (mounted) {
        Navigator.of(context).pop(draft);
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Changes were not queued on this device. Try again.';
      });
    }
  }

  String _reminderLabel(BuildContext context) {
    final completed = _completedReminderAt?.toLocal();
    if (completed != null) {
      final localizations = MaterialLocalizations.of(context);
      return 'Due ${localizations.formatMediumDate(completed)} at '
          '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(completed))}; '
          'saving clears it';
    }
    final reminder = _reminderAt?.toLocal();
    if (reminder == null) {
      if (!_state.isActive) return 'Cleared when the item leaves To Read';
      return widget.capabilities.reminders ? 'Optional' : 'Unavailable';
    }
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatMediumDate(reminder)} at '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(reminder))}';
  }

  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final current = _reminderAt?.toLocal();
    final initial = current != null && current.isAfter(now)
        ? current
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5, 12, 31),
      helpText: 'Choose reminder date',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Choose reminder time',
    );
    if (!mounted || time == null) return;
    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!selected.isAfter(DateTime.now())) {
      setState(() => _error = 'Choose a reminder time in the future.');
      return;
    }
    setState(() {
      _reminderAt = selected.toUtc();
      _completedReminderAt = null;
      _error = null;
    });
  }

  bool _scopeIsCurrent() {
    final listenable = widget.accountScopeListenable;
    return listenable == null ||
        listenable.value == widget.expectedAccountScope;
  }

  void _handleScopeChange() {
    if (!_scopeIsCurrent()) _invalidateScope();
  }

  void _invalidateScope() {
    if (_scopeInvalid) return;
    _scopeInvalid = true;
    _noteController.clear();
    _listsController.clear();
    _tagsController.clear();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }
}

class _AccessibleDragHandle extends StatelessWidget {
  const _AccessibleDragHandle();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Modal sheet',
    child: Center(
      child: Container(
        width: 36,
        height: 5,
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    ),
  );
}

class _EditorMessage extends StatelessWidget {
  const _EditorMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}

Iterable<String> _splitNames(String value) => value.split(',');
