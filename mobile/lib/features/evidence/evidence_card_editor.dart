import 'package:flutter/material.dart';

import '../../core/models/evidence_card.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

final class EvidenceCardDraft {
  const EvidenceCardDraft({required this.title, this.note});

  final String title;
  final String? note;
}

Future<EvidenceCardDraft?> showEvidenceCardEditor({
  required BuildContext context,
  required String selectedText,
  String? initialTitle,
  String? initialNote,
}) {
  return showModalBottomSheet<EvidenceCardDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    sheetAnimationStyle: platformPrefersReducedMotion(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _EvidenceCardEditor(
      selectedText: selectedText,
      initialTitle: initialTitle,
      initialNote: initialNote,
    ),
  );
}

class _EvidenceCardEditor extends StatefulWidget {
  const _EvidenceCardEditor({
    required this.selectedText,
    this.initialTitle,
    this.initialNote,
  });

  final String selectedText;
  final String? initialTitle;
  final String? initialNote;

  @override
  State<_EvidenceCardEditor> createState() => _EvidenceCardEditorState();
}

class _EvidenceCardEditorState extends State<_EvidenceCardEditor> {
  late final TextEditingController _title;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final words = widget.selectedText.trim().split(RegExp(r'\s+'));
    _title = TextEditingController(
      text: widget.initialTitle ?? words.take(10).join(' '),
    );
    _note = TextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  String? get _titleError {
    final title = _title.text.trim();
    if (title.contains('\u0000')) {
      return 'Remove unsupported control characters.';
    }
    if (title.runes.length > evidenceCardTitleMaximumScalars) {
      return 'Use $evidenceCardTitleMaximumScalars Unicode characters or fewer.';
    }
    return null;
  }

  String? get _noteError {
    final note = _note.text.trim();
    if (note.contains('\u0000')) {
      return 'Remove unsupported control characters.';
    }
    if (note.runes.length > evidenceCardNoteMaximumScalars) {
      return 'Your note is too long to save safely.';
    }
    return null;
  }

  bool get _canSave =>
      _title.text.trim().isNotEmpty &&
      _titleError == null &&
      _noteError == null;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      4,
      20,
      20 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Save evidence', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'The exact selected source stays attached to this card.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: evidenceCardTitleMaximumScalars,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Evidence title',
              errorText: _titleError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 6,
            maxLength: 32000,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Your note (optional)',
              errorText: _noteError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: FilledButton.icon(
              onPressed: _canSave
                  ? () {
                      final title = _title.text.trim();
                      final note = _note.text.trim();
                      Navigator.of(context).pop(
                        EvidenceCardDraft(
                          title: title,
                          note: note.isEmpty ? null : note,
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Save evidence card'),
            ),
          ),
        ],
      ),
    ),
  );
}
