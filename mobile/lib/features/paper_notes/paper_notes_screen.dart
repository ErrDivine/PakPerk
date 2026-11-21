import '../../l10n/ui.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/paper.dart';
import 'paper_notes_store.dart';

class PaperNotesScreen extends StatefulWidget {
  const PaperNotesScreen({
    required this.paper,
    this.store = const SharedPreferencesPaperNotesStore(),
    super.key,
  });

  final PaperSummary paper;
  final PaperNotesStore store;

  @override
  State<PaperNotesScreen> createState() => _PaperNotesScreenState();
}

class _PaperNotesScreenState extends State<PaperNotesScreen>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  List<String> _pages = [''];
  int _page = 0;
  bool _switching = false;
  Timer? _saveTimer;
  Future<void> _writeQueue = Future<void>.value();
  PaperNotes _saved = const PaperNotes();
  bool _loaded = false;
  bool _closing = false;
  bool _canPop = false;
  String _status = 'Saved on this device';
  String? _loadError;

  PaperNotes get _current {
    final pages = List<String>.of(_pages);
    pages[_page] = _text.text;
    return PaperNotes(pages: List.unmodifiable(pages));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_loaded && state != AppLifecycleState.resumed) unawaited(_persist());
  }

  Future<void> _load() async {
    try {
      final notes = await widget.store.read(widget.paper.arxivBaseId);
      if (!mounted) return;
      _pages = List.of(notes.pages);
      _text.text = _pages.first;
      setState(() {
        _saved = notes;
        _loaded = true;
        _loadError = null;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = 'Could not open your notes.');
    }
  }

  void _changed(String _) {
    _saveTimer?.cancel();
    setState(() => _status = 'Saving soon…');
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persist());
    });
  }

  Future<bool> _persist() {
    _saveTimer?.cancel();
    final notes = _current;
    final task = _writeQueue.then((_) async {
      if (notes == _saved) return true;
      if (mounted) setState(() => _status = 'Saving…');
      try {
        await widget.store.write(widget.paper.arxivBaseId, notes);
        _saved = notes;
        if (mounted) {
          setState(
            () => _status = _current == notes
                ? 'Saved on this device'
                : 'Saving soon…',
          );
        }
        return true;
      } catch (_) {
        if (mounted) setState(() => _status = 'Could not save · tap Retry');
        return false;
      }
    });
    _writeQueue = task.then((_) {});
    return task;
  }

  Future<void> _finish() async {
    if (_closing) return;
    _closing = true;
    final saved = !_loaded || await _persist();
    if (!mounted) return;
    if (!saved) {
      _closing = false;
      return;
    }
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const UiText('Clear this page?'),
        content: const UiText(
          'Only the current page will be cleared. Your other pages will stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const UiText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const UiText('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _text.clear();
    _pages[_page] = '';
    await _persist();
    if (mounted) setState(() {});
  }

  Future<void> _selectPage(int? index) async {
    if (_switching) return;
    setState(() => _switching = true);
    _pages[_page] = _text.text;
    final saved = await _persist();
    if (!mounted) return;
    if (saved) {
      setState(() {
        if (index == null) _pages.add('');
        _page = index ?? _pages.length - 1;
        _text.text = _pages[_page];
      });
      await _persist();
    }
    if (mounted) setState(() => _switching = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: uiString(context, 'Back to paper'),
            onPressed: _finish,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const UiText('My notes'),
          actions: [
            if (_loaded && _text.text.trim().isNotEmpty)
              IconButton(
                key: const ValueKey('paper-notes-delete'),
                tooltip: uiString(context, 'Clear current page'),
                onPressed: _delete,
                icon: const Icon(Icons.clear_all),
              ),
          ],
        ),
        body: !_loaded
            ? Center(
                child: _loadError == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UiText(_loadError!),
                          TextButton(
                            onPressed: _load,
                            child: const UiText('Retry'),
                          ),
                        ],
                      ),
              )
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  children: [
                    Text(
                      widget.paper.arxivBaseId,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.paper.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        UiText(
                          'Your words · On this device only',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (var i = 0; i < _pages.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: UiText('Page ${i + 1}'),
                                      selected: _page == i,
                                      onSelected: _switching
                                          ? null
                                          : (_) => _selectPage(i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('paper-notes-new-page'),
                          onPressed: _switching
                              ? null
                              : () => _selectPage(null),
                          icon: const Icon(Icons.add),
                          label: const UiText('New page'),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('paper-notes-clear'),
                        onPressed: _switching || _text.text.isEmpty
                            ? null
                            : _delete,
                        icon: const Icon(Icons.clear_all),
                        label: const UiText('Clear'),
                      ),
                    ),
                    TextField(
                      key: const ValueKey('paper-notes-editor'),
                      controller: _text,
                      readOnly: _switching,
                      onChanged: _changed,
                      maxLines: null,
                      minLines: 14,
                      maxLength: 30000,
                      textCapitalization: TextCapitalization.sentences,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(height: 1.5),
                      decoration: InputDecoration(
                        hintText: uiString(
                          context,
                          'Write whatever you want to remember about this paper…',
                        ),
                        filled: true,
                        fillColor: colors.surfaceContainerLow,
                        contentPadding: const EdgeInsets.all(20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(color: colors.outlineVariant),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(color: colors.outlineVariant),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 2,
                          ),
                        ),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    UiText(
                      'This note is yours to keep, change, or remove. It is not sent to the assistant.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
        bottomNavigationBar: !_loaded
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          key: const ValueKey('paper-notes-status'),
                          liveRegion: true,
                          child: _status.startsWith('Could not')
                              ? TextButton.icon(
                                  onPressed: () => unawaited(_persist()),
                                  icon: const Icon(Icons.refresh),
                                  label: const UiText('Could not save · Retry'),
                                )
                              : Row(
                                  children: [
                                    Icon(
                                      _status.startsWith('Saved')
                                          ? Icons.check_circle_outline
                                          : Icons.sync,
                                      color: colors.primary,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: UiText(
                                        _status,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: colors.primary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        key: const ValueKey('paper-notes-done'),
                        onPressed: _closing ? null : _finish,
                        child: const UiText('Done'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
