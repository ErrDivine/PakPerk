import 'package:flutter/material.dart';

import '../../core/models/annotation.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

final class AnnotationDraft {
  const AnnotationDraft({required this.kind, required this.body});

  final AnnotationKind kind;
  final String body;
}

Future<AnnotationDraft?> showAnnotationEditor({
  required BuildContext context,
  required AnnotationKind kind,
  required String selectedText,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<AnnotationDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    sheetAnimationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
    builder: (_) => _AnnotationEditor(kind: kind, selectedText: selectedText),
  );
}

class _AnnotationEditor extends StatefulWidget {
  const _AnnotationEditor({required this.kind, required this.selectedText});

  final AnnotationKind kind;
  final String selectedText;

  @override
  State<_AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<_AnnotationEditor> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.kind == AnnotationKind.question ? 'Question' : 'Note';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Semantics(
          container: true,
          label: '$label editor for selected source text',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    widget.selectedText,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                maxLength: 32000,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: widget.kind == AnnotationKind.question
                      ? 'What do you want to resolve?'
                      : 'Add your interpretation or context',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: FilledButton.icon(
                  onPressed: () {
                    final body = _controller.text.trim();
                    if (body.isEmpty) return;
                    Navigator.of(
                      context,
                    ).pop(AnnotationDraft(kind: widget.kind, body: body));
                  },
                  icon: const Icon(Icons.check),
                  label: Text('Save $label'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
