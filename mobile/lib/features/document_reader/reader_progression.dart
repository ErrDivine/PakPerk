import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../design_system/sizes.dart';
import '../reader_modes/reader_mode.dart';

const skimDocumentBlockLimit = 8;

List<DocumentBlock> visibleDocumentBlocksForMode(
  Iterable<DocumentBlock> blocks,
  ReaderDepthMode mode,
) => switch (mode) {
  ReaderDepthMode.skim =>
    blocks.take(skimDocumentBlockLimit).toList(growable: false),
  ReaderDepthMode.read ||
  ReaderDepthMode.inspect => blocks.toList(growable: false),
};

bool shouldLoadNextDocumentPage({
  required ReaderDepthMode mode,
  required bool active,
  required bool loadingMore,
  required String? nextCursor,
  required double extentAfter,
}) =>
    active &&
    mode != ReaderDepthMode.skim &&
    !loadingMore &&
    nextCursor != null &&
    extentAfter <= 320;

bool shouldRecordTrueDocumentEnd({
  required ReaderDepthMode mode,
  required bool active,
  required String? nextCursor,
  required double extentAfter,
}) =>
    active &&
    mode != ReaderDepthMode.skim &&
    nextCursor == null &&
    extentAfter <= 320;

bool isTopLevelSectionBoundary(DocumentBlock current, DocumentBlock next) {
  final currentSection = current.sectionPath.firstOrNull?.trim();
  final nextSection = next.sectionPath.firstOrNull?.trim();
  return currentSection != null &&
      currentSection.isNotEmpty &&
      nextSection != null &&
      nextSection.isNotEmpty &&
      currentSection != nextSection;
}

/// Stable, human-readable section order for reader progress.
///
/// The complete outline wins so pagination does not make the denominator jump.
/// Loaded block paths are a conservative fallback for older snapshots.
List<String> documentSectionProgressTitles({
  required DocumentOutline outline,
  required Iterable<DocumentBlock> loadedBlocks,
}) {
  final titles = <String>[];
  final seen = <String>{};

  void add(String raw) {
    final title = raw.trim();
    final identity = title.toLowerCase();
    if (title.isNotEmpty && seen.add(identity)) titles.add(title);
  }

  for (final section in outline.sections) {
    if (section.level == 1) add(section.title);
  }
  if (titles.isEmpty) {
    for (final block in loadedBlocks) {
      if (block.sectionPath.isNotEmpty) add(block.sectionPath.first);
    }
  }
  return List.unmodifiable(titles);
}

int sectionProgressIndex(List<String> sections, String? currentSection) {
  if (sections.isEmpty || currentSection == null) return 0;
  final normalized = currentSection.trim().toLowerCase();
  final index = sections.indexWhere(
    (section) => section.trim().toLowerCase() == normalized,
  );
  return index < 0 ? 0 : index;
}

class ReaderSectionProgress extends StatelessWidget {
  const ReaderSectionProgress({
    required this.sections,
    required this.currentSection,
    super.key,
  });

  final List<String> sections;
  final String? currentSection;

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) return const SizedBox.shrink();
    final index = sectionProgressIndex(sections, currentSection);
    final ordinal = index + 1;
    final title = sections[index];
    final next = index + 1 < sections.length ? sections[index + 1] : null;
    final label = 'Reading section $ordinal of ${sections.length}: $title';
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Section $ordinal of ${sections.length}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  key: const ValueKey('reader-current-section'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (next != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Next: $next',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: ordinal / sections.length,
                  minHeight: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? normalizedAssistantQuestion(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.runes.length > 500 ||
      normalized.contains('\u0000')) {
    return null;
  }
  return normalized;
}

final class ReaderStoppingAction {
  const ReaderStoppingAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.emphasized = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool emphasized;
}

class ReaderStoppingPoint extends StatelessWidget {
  const ReaderStoppingPoint({
    required this.semanticLabel,
    required this.title,
    required this.message,
    required this.actions,
    super.key,
  });

  final String semanticLabel;
  final String title;
  final String message;
  final List<ReaderStoppingAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 6),
                Text(message),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action in actions)
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: PakPerkSizes.minimumInteractive,
                          ),
                          child: action.emphasized
                              ? FilledButton.icon(
                                  onPressed: action.onPressed,
                                  icon: Icon(action.icon),
                                  label: Text(action.label),
                                )
                              : OutlinedButton.icon(
                                  onPressed: action.onPressed,
                                  icon: Icon(action.icon),
                                  label: Text(action.label),
                                ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef ReadAssistantSubmit = Future<bool> Function(String question);

class ReadAssistantComposer extends StatefulWidget {
  const ReadAssistantComposer({
    required this.enabled,
    required this.onCompositionChanged,
    required this.onSubmit,
    super.key,
  });

  final bool enabled;
  final ValueChanged<bool> onCompositionChanged;
  final ReadAssistantSubmit onSubmit;

  @override
  State<ReadAssistantComposer> createState() => _ReadAssistantComposerState();
}

class _ReadAssistantComposerState extends State<ReadAssistantComposer> {
  final TextEditingController _question = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _submitting = false;

  bool get _composing =>
      widget.enabled &&
      (_focusNode.hasFocus || _question.text.trim().isNotEmpty || _submitting);

  bool get _canSubmit =>
      widget.enabled &&
      !_submitting &&
      normalizedAssistantQuestion(_question.text) != null;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_notifyCompositionChanged);
  }

  @override
  void didUpdateWidget(covariant ReadAssistantComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _focusNode.unfocus();
      widget.onCompositionChanged(false);
    } else if (!oldWidget.enabled && widget.enabled) {
      _notifyCompositionChanged();
    }
  }

  @override
  void dispose() {
    widget.onCompositionChanged(false);
    _focusNode.removeListener(_notifyCompositionChanged);
    _focusNode.dispose();
    _question.dispose();
    super.dispose();
  }

  void _notifyCompositionChanged() {
    widget.onCompositionChanged(_composing);
  }

  Future<void> _submit() async {
    final question = normalizedAssistantQuestion(_question.text);
    if (question == null || _submitting || !widget.enabled) return;
    setState(() => _submitting = true);
    _notifyCompositionChanged();
    var handedOff = false;
    try {
      handedOff = await widget.onSubmit(question);
      if (handedOff &&
          mounted &&
          normalizedAssistantQuestion(_question.text) == question) {
        _question.clear();
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
        _notifyCompositionChanged();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('read-assistant-composer'),
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Semantics(
            container: true,
            label: 'Persistent Read Assistant composer',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('read-assistant-question'),
                      controller: _question,
                      focusNode: _focusNode,
                      enabled: widget.enabled && !_submitting,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onChanged: (_) {
                        setState(() {});
                        _notifyCompositionChanged();
                      },
                      onSubmitted: (_) {
                        if (_canSubmit) _submit();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Ask this paper',
                        hintText: 'Question grounded in this paper',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: _submitting ? 'Opening Assistant' : 'Ask Assistant',
                    child: Tooltip(
                      message: 'Ask Assistant',
                      excludeFromSemantics: true,
                      child: IconButton.filled(
                        key: const ValueKey('read-assistant-submit'),
                        onPressed: _canSubmit ? _submit : null,
                        constraints: const BoxConstraints.tightFor(
                          width: PakPerkSizes.minimumInteractive,
                          height: PakPerkSizes.minimumInteractive,
                        ),
                        icon: _submitting
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator.adaptive(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_upward_rounded),
                      ),
                    ),
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
