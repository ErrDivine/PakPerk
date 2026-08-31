import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../core/models/semantic_span.dart';
import '../../design_system/motion.dart';
import '../semantic/faceted_text.dart';
import 'inline_span_renderer.dart';
import 'selection_toolbar.dart';

class DocumentBlockRenderer extends StatelessWidget {
  const DocumentBlockRenderer({
    required this.block,
    required this.terms,
    required this.highlighted,
    required this.onSelectionChanged,
    required this.onOpenTerm,
    this.onOpenReference,
    this.semanticSpans = const [],
    this.semanticDensity = SemanticDensity.off,
    this.highlightStart,
    this.highlightEnd,
    this.onAddNote,
    this.onHighlight,
    this.onAskQuestion,
    this.onAskAssistant,
    this.onDefine,
    this.onSaveEvidence,
    this.onReattach,
    super.key,
  });

  final DocumentBlock block;
  final List<PaperTerm> terms;
  final bool highlighted;
  final int? highlightStart;
  final int? highlightEnd;
  final ReaderSelectionChanged onSelectionChanged;
  final ValueChanged<PaperTerm> onOpenTerm;
  final ValueChanged<DocumentInlineSpan>? onOpenReference;
  final List<SemanticSpan> semanticSpans;
  final SemanticDensity semanticDensity;
  final ValueChanged<String>? onAddNote;
  final ValueChanged<String>? onHighlight;
  final ValueChanged<String>? onAskQuestion;
  final ValueChanged<String>? onAskAssistant;
  final ValueChanged<String>? onDefine;
  final ValueChanged<String>? onSaveEvidence;
  final ValueChanged<String>? onReattach;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reducedMotion = platformPrefersReducedMotion(context);
    final opaque = platformPrefersReducedTransparency(context);
    final scalarLength = block.text.runes.length;
    final rangeRequested = highlightStart != null || highlightEnd != null;
    final hasExactRange =
        highlightStart != null &&
        highlightEnd != null &&
        highlightStart! >= 0 &&
        highlightEnd! > highlightStart! &&
        highlightEnd! <= scalarLength;
    // Never fall back to a whole-block highlight when an exact range was
    // requested but failed validation.
    final effectivelyHighlighted =
        highlighted && (!rangeRequested || hasExactRange);
    final resolvedFacets = resolveSemanticFacetSegments(
      blockId: block.id,
      scalarLength: scalarLength,
      spans: semanticSpans,
      density: semanticDensity,
    );
    final seenFacets = <SemanticFacet>{};
    final facetCues = resolvedFacets
        .map((value) => value.span)
        .where((value) => seenFacets.add(value.facet))
        .toList(growable: false);
    final style = switch (block.kind) {
      DocumentBlockKind.heading => theme.textTheme.headlineSmall,
      DocumentBlockKind.caption ||
      DocumentBlockKind.footnote => theme.textTheme.bodyMedium,
      DocumentBlockKind.quote || DocumentBlockKind.theoremDefinition =>
        theme.textTheme.bodyLarge?.copyWith(fontStyle: FontStyle.italic),
      _ => theme.textTheme.bodyLarge,
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      header: block.kind == DocumentBlockKind.heading,
      selected: effectivelyHighlighted,
      label:
          '${block.kind.wireValue}, ${block.sectionLabel}'
          '${effectivelyHighlighted && hasExactRange
              ? ', exact source range highlighted, characters ${highlightStart! + 1} through $highlightEnd'
              : effectivelyHighlighted
              ? ', exact source block highlighted'
              : ''}',
      child: AnimatedContainer(
        key: ValueKey('document-block-${block.stableKey}'),
        duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.quick,
        curve: PakPerkMotion.emphasized,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: effectivelyHighlighted && !hasExactRange
              ? theme.colorScheme.primaryContainer.withValues(
                  alpha: opaque ? 1 : .72,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: effectivelyHighlighted
              ? Border.all(color: theme.colorScheme.primary)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (facetCues.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final span in facetCues) SemanticFacetCue(span: span),
                ],
              ),
              const SizedBox(height: 8),
            ],
            SelectionToolbarShell(
              onSelectionChanged: onSelectionChanged,
              onHighlight: onHighlight,
              onAddNote: onAddNote,
              onAskQuestion: onAskQuestion,
              onAskAssistant: onAskAssistant,
              onDefine: onDefine,
              onSaveEvidence: onSaveEvidence,
              onReattach: onReattach,
              child: Text.rich(
                InlineSpanRenderer.build(
                  context: context,
                  block: block,
                  terms: terms,
                  semanticSpans: semanticSpans,
                  semanticDensity: semanticDensity,
                  onOpenTerm: onOpenTerm,
                  onOpenReference: onOpenReference,
                  highlightStart: effectivelyHighlighted && hasExactRange
                      ? highlightStart
                      : null,
                  highlightEnd: effectivelyHighlighted && hasExactRange
                      ? highlightEnd
                      : null,
                ),
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
