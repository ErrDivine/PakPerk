import 'package:flutter/material.dart';

import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

typedef ReaderSelectionChanged = void Function(String? selectedText);

/// Selection-aware action shell. The platform selection toolbar remains
/// intact for Copy/Look Up while reader-specific actions appear below the
/// selected block without stealing the selection gesture arena.
class SelectionToolbarShell extends StatefulWidget {
  const SelectionToolbarShell({
    required this.child,
    required this.onSelectionChanged,
    this.onHighlight,
    this.onAddNote,
    this.onAskQuestion,
    this.onAskAssistant,
    this.onDefine,
    this.onSaveEvidence,
    this.onReattach,
    super.key,
  });

  final Widget child;
  final ReaderSelectionChanged onSelectionChanged;
  final ValueChanged<String>? onHighlight;
  final ValueChanged<String>? onAddNote;
  final ValueChanged<String>? onAskQuestion;
  final ValueChanged<String>? onAskAssistant;
  final ValueChanged<String>? onDefine;
  final ValueChanged<String>? onSaveEvidence;
  final ValueChanged<String>? onReattach;

  @override
  State<SelectionToolbarShell> createState() => _SelectionToolbarShellState();
}

class _SelectionToolbarShellState extends State<SelectionToolbarShell> {
  String? _selection;

  @override
  void dispose() {
    if (_selection != null) widget.onSelectionChanged(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = platformPrefersReducedMotion(context);
    final selection = _selection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectionArea(
          onSelectionChanged: (content) {
            final text = content?.plainText.trim();
            final next = text?.isNotEmpty == true ? text : null;
            if (next == _selection) return;
            setState(() => _selection = next);
            widget.onSelectionChanged(next);
          },
          child: widget.child,
        ),
        AnimatedSwitcher(
          duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.quick,
          switchInCurve: PakPerkMotion.enter,
          switchOutCurve: PakPerkMotion.exit,
          child: selection == null
              ? const SizedBox.shrink(key: ValueKey('selection-actions-off'))
              : Semantics(
                  key: const ValueKey('selection-actions-on'),
                  container: true,
                  label: 'Selection actions',
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SingleChildScrollView(
                      key: const ValueKey('selection-actions-scroll'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (widget.onReattach != null)
                            _SelectionAction(
                              icon: Icons.link,
                              label: 'Attach here',
                              semanticLabel:
                                  'Attach pending annotation to selected source text',
                              onPressed: () => widget.onReattach!(selection),
                            ),
                          if (widget.onHighlight != null)
                            _SelectionAction(
                              icon: Icons.border_color_outlined,
                              label: 'Highlight',
                              semanticLabel: 'Highlight selected source text',
                              onPressed: () => widget.onHighlight!(selection),
                            ),
                          if (widget.onAddNote != null)
                            _SelectionAction(
                              icon: Icons.note_add_outlined,
                              label: 'Add note',
                              semanticLabel: 'Add note to selected source text',
                              onPressed: () => widget.onAddNote!(selection),
                            ),
                          if (widget.onAskQuestion != null)
                            _SelectionAction(
                              icon: Icons.help_outline,
                              label: 'Question',
                              semanticLabel:
                                  'Save a question about selected text',
                              onPressed: () => widget.onAskQuestion!(selection),
                            ),
                          if (widget.onAskAssistant != null)
                            _SelectionAction(
                              icon: Icons.question_answer_outlined,
                              label: 'Ask assistant',
                              semanticLabel:
                                  'Ask the assistant about selected source text',
                              onPressed: () =>
                                  widget.onAskAssistant!(selection),
                            ),
                          if (widget.onDefine != null)
                            _SelectionAction(
                              icon: Icons.menu_book_outlined,
                              label: 'Define term',
                              semanticLabel:
                                  'Show a prepared definition for selected text',
                              onPressed: () => widget.onDefine!(selection),
                            ),
                          if (widget.onSaveEvidence != null)
                            _SelectionAction(
                              icon: Icons.fact_check_outlined,
                              label: 'Evidence',
                              semanticLabel:
                                  'Save selected source text as evidence',
                              onPressed: () =>
                                  widget.onSaveEvidence!(selection),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _SelectionAction extends StatelessWidget {
  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Semantics(
      button: true,
      label: semanticLabel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PakPerkSizes.minimumInteractive,
        ),
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      ),
    ),
  );
}
