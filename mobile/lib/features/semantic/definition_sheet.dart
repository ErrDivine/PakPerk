import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

Future<String?> showDefinitionSheet({
  required BuildContext context,
  required PaperTerm term,
  String? contextBlockId,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  final definitions = orderedTermDefinitions(
    term,
    contextBlockId: contextBlockId,
  );
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => Semantics(
      container: true,
      label: '${term.displayTerm} definition sources',
      child: FractionallySizedBox(
        heightFactor: .82,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Text(
              term.displayTerm,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text('${term.kind.label} · ${term.definitionStatus.label}'),
            if (term.kind == PaperTermKind.symbol) ...[
              const SizedBox(height: 12),
              const _DefinitionNotice(
                icon: Icons.functions,
                text:
                    'Symbol meaning can change by section. Pakperk shows the nearest prepared current-paper context first and does not assume equivalence elsewhere.',
              ),
            ],
            const SizedBox(height: 16),
            if (definitions.isEmpty)
              _DefinitionNotice(
                icon: Icons.info_outline,
                text: _unavailableMessage(term.definitionStatus),
              )
            else
              for (var index = 0; index < definitions.length; index++) ...[
                _DefinitionCard(
                  definition: definitions[index],
                  currentContext:
                      contextBlockId != null &&
                      definitions[index].sourceBlockIds.contains(
                        contextBlockId,
                      ),
                  onOpenSource: definitions[index].sourceBlockIds.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                          contextBlockId != null &&
                                  definitions[index].sourceBlockIds.contains(
                                    contextBlockId,
                                  )
                              ? contextBlockId
                              : definitions[index].sourceBlockIds.first,
                        ),
                ),
                if (index + 1 < definitions.length) const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    ),
  );
}

Future<void> showUnavailableDefinitionSheet({
  required BuildContext context,
  required String selectedText,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  final safeSelection = _boundedSelectionLabel(selectedText);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => Semantics(
      container: true,
      liveRegion: true,
      label: 'Prepared definition unavailable for $safeSelection',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(safeSelection, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const _DefinitionNotice(
              icon: Icons.info_outline,
              text:
                  'No single prepared definition matches this selection. Nothing was generated or inferred from the selection.',
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

List<TermDefinition> orderedTermDefinitions(
  PaperTerm term, {
  String? contextBlockId,
}) {
  final values = List<TermDefinition>.of(term.definitions);
  values.sort((left, right) {
    final source = left.sourceType.precedence.compareTo(
      right.sourceType.precedence,
    );
    if (source != 0) return source;
    final leftCurrent =
        contextBlockId != null && left.sourceBlockIds.contains(contextBlockId);
    final rightCurrent =
        contextBlockId != null && right.sourceBlockIds.contains(contextBlockId);
    if (leftCurrent != rightCurrent) return leftCurrent ? -1 : 1;
    final confidence = _confidencePrecedence(
      left.confidenceStatus,
    ).compareTo(_confidencePrecedence(right.confidenceStatus));
    if (confidence != 0) return confidence;
    return left.id.compareTo(right.id);
  });
  return List.unmodifiable(values);
}

int _confidencePrecedence(TermDefinitionConfidence value) => switch (value) {
  TermDefinitionConfidence.supported => 0,
  TermDefinitionConfidence.inferred => 1,
  TermDefinitionConfidence.uncertain => 2,
};

String _unavailableMessage(TermDefinitionStatus status) => switch (status) {
  TermDefinitionStatus.notFound =>
    'A reliable definition was not found in the prepared paper or configured sources.',
  TermDefinitionStatus.notApplicable =>
    'This prepared item does not have a definition in this context.',
  TermDefinitionStatus.uncertain =>
    'The prepared sources were not strong enough to show a definition.',
  TermDefinitionStatus.available =>
    'The prepared definition payload is unavailable. No substitute was generated.',
};

String _boundedSelectionLabel(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return 'Selected text';
  final runes = normalized.runes.toList(growable: false);
  if (runes.length <= 80) return normalized;
  return '${String.fromCharCodes(runes.take(79))}…';
}

class _DefinitionCard extends StatelessWidget {
  const _DefinitionCard({
    required this.definition,
    required this.currentContext,
    required this.onOpenSource,
  });

  final TermDefinition definition;
  final bool currentContext;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    final generated = definition.sourceType == TermDefinitionSource.generated;
    final sourceLabel =
        currentContext &&
            definition.sourceType == TermDefinitionSource.currentPaper
        ? 'Nearest current-paper context'
        : definition.sourceType.label;
    return Semantics(
      container: true,
      label:
          '$sourceLabel, ${definition.confidenceStatus.label.toLowerCase()}'
          '${generated ? ', generated and not source evidence' : ''}',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    sourceLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(definition.confidenceStatus.label),
                  ),
                ],
              ),
              if (generated) ...[
                const SizedBox(height: 6),
                Text(
                  'Generated explanation · not source evidence',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              SelectableText(definition.definition),
              if (onOpenSource != null) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: onOpenSource,
                    icon: const Icon(Icons.find_in_page_outlined),
                    label: const Text('Open exact source'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DefinitionNotice extends StatelessWidget {
  const _DefinitionNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    ),
  );
}
