import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../core/models/semantic_span.dart';
import '../../design_system/sizes.dart';
import '../semantic/faceted_text.dart';

abstract final class InlineSpanRenderer {
  static InlineSpan build({
    required BuildContext context,
    required DocumentBlock block,
    required Iterable<PaperTerm> terms,
    required Iterable<SemanticSpan> semanticSpans,
    required SemanticDensity semanticDensity,
    required ValueChanged<PaperTerm> onOpenTerm,
    ValueChanged<DocumentInlineSpan>? onOpenReference,
    int? highlightStart,
    int? highlightEnd,
  }) {
    final runes = block.text.runes.toList(growable: false);
    final hasHighlight =
        highlightStart != null &&
        highlightEnd != null &&
        highlightStart >= 0 &&
        highlightEnd > highlightStart &&
        highlightEnd <= runes.length;
    final rangeStart = hasHighlight ? highlightStart : null;
    final rangeEnd = hasHighlight ? highlightEnd : null;
    final facetSegments = resolveSemanticFacetSegments(
      blockId: block.id,
      scalarLength: runes.length,
      spans: semanticSpans,
      density: semanticDensity,
    );
    final references = onOpenReference == null
        ? const <DocumentInlineSpan>[]
        : _validatedReferences(block.inlineSpans, runes.length);
    final occurrences = <({PaperTerm term, TermOccurrence occurrence})>[];
    for (final term in terms) {
      for (final occurrence in term.occurrences) {
        if (occurrence.blockId == block.id &&
            occurrence.startOffset >= 0 &&
            occurrence.endOffset <= runes.length &&
            occurrence.endOffset > occurrence.startOffset &&
            !references.any(
              (reference) => _overlaps(
                occurrence.startOffset,
                occurrence.endOffset,
                reference.start,
                reference.end,
              ),
            )) {
          occurrences.add((term: term, occurrence: occurrence));
        }
      }
    }
    occurrences.sort((a, b) {
      final start = a.occurrence.startOffset.compareTo(
        b.occurrence.startOffset,
      );
      return start != 0
          ? start
          : a.occurrence.endOffset.compareTo(b.occurrence.endOffset);
    });
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyLarge;
    final linkStyle = bodyStyle?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );
    final highlightStyle = TextStyle(
      color: theme.colorScheme.onPrimaryContainer,
      backgroundColor: theme.colorScheme.primaryContainer,
      fontWeight: FontWeight.w600,
    );
    final interactions =
        <_InlineInteraction>[
          for (final reference in references)
            _InlineInteraction.reference(reference),
          for (final item in occurrences) _InlineInteraction.term(item),
        ]..sort((left, right) {
          final start = left.start.compareTo(right.start);
          return start != 0 ? start : left.end.compareTo(right.end);
        });
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final interaction in interactions) {
      if (interaction.start < cursor) continue;
      if (interaction.start > cursor) {
        spans.addAll(
          _textSegments(
            context: context,
            runes: runes,
            start: cursor,
            end: interaction.start,
            facetSegments: facetSegments,
            highlightStart: rangeStart,
            highlightEnd: rangeEnd,
            highlightStyle: highlightStyle,
          ),
        );
      }
      final interactiveText = _textSegments(
        context: context,
        runes: runes,
        start: interaction.start,
        end: interaction.end,
        facetSegments: facetSegments,
        highlightStart: rangeStart,
        highlightEnd: rangeEnd,
        highlightStyle: highlightStyle,
      );
      final visible = String.fromCharCodes(
        runes.sublist(interaction.start, interaction.end),
      );
      if (interaction.reference case final reference?) {
        spans
          ..add(TextSpan(style: linkStyle, children: interactiveText))
          ..add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Semantics(
                button: true,
                label:
                    '$visible, ${_referenceKindLabel(reference.kind)}. Inspect reference context.',
                child: Tooltip(
                  message: 'Inspect ${_referenceKindLabel(reference.kind)}',
                  excludeFromSemantics: true,
                  child: InkWell(
                    key: ValueKey(
                      'inline-reference-${block.stableKey}-${reference.start}-${reference.end}',
                    ),
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => onOpenReference!(reference),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints.tightFor(
                        width: PakPerkSizes.minimumInteractive,
                        height: PakPerkSizes.minimumInteractive,
                      ),
                      child: Icon(_referenceIcon(reference.kind), size: 18),
                    ),
                  ),
                ),
              ),
            ),
          );
      } else if (interaction.term case final item?) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              button: true,
              label: '$visible, definition',
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: PakPerkSizes.minimumInteractive,
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onOpenTerm(item.term),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 10,
                    ),
                    child: Text.rich(
                      TextSpan(style: linkStyle, children: interactiveText),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      cursor = interaction.end;
    }
    if (cursor < runes.length) {
      spans.addAll(
        _textSegments(
          context: context,
          runes: runes,
          start: cursor,
          end: runes.length,
          facetSegments: facetSegments,
          highlightStart: rangeStart,
          highlightEnd: rangeEnd,
          highlightStyle: highlightStyle,
        ),
      );
    }
    return TextSpan(style: bodyStyle, children: spans);
  }

  static List<DocumentInlineSpan> _validatedReferences(
    Iterable<DocumentInlineSpan> spans,
    int scalarLength,
  ) {
    final candidates =
        spans
            .where(
              (span) =>
                  _knownReferenceKinds.contains(span.kind) &&
                  span.start >= 0 &&
                  span.end > span.start &&
                  span.end <= scalarLength &&
                  span.targetId?.trim().isNotEmpty == true,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final priority = _referencePriority(
              left.kind,
            ).compareTo(_referencePriority(right.kind));
            if (priority != 0) return priority;
            final start = left.start.compareTo(right.start);
            if (start != 0) return start;
            return right.end.compareTo(left.end);
          });
    final accepted = <DocumentInlineSpan>[];
    for (final candidate in candidates) {
      if (accepted.any(
        (current) => _overlaps(
          candidate.start,
          candidate.end,
          current.start,
          current.end,
        ),
      )) {
        continue;
      }
      accepted.add(candidate);
    }
    accepted.sort((left, right) => left.start.compareTo(right.start));
    return List.unmodifiable(accepted);
  }

  static List<InlineSpan> _textSegments({
    required BuildContext context,
    required List<int> runes,
    required int start,
    required int end,
    required List<ResolvedSemanticSegment> facetSegments,
    required int? highlightStart,
    required int? highlightEnd,
    required TextStyle highlightStyle,
  }) {
    if (start >= end) return const [];
    final boundaries = <int>{start, end};
    if (highlightStart != null &&
        highlightEnd != null &&
        highlightEnd > start &&
        highlightStart < end) {
      boundaries
        ..add(highlightStart.clamp(start, end).toInt())
        ..add(highlightEnd.clamp(start, end).toInt());
    }
    for (final segment in facetSegments) {
      if (segment.end <= start || segment.start >= end) continue;
      boundaries
        ..add(segment.start.clamp(start, end).toInt())
        ..add(segment.end.clamp(start, end).toInt());
    }
    final ordered = boundaries.toList()..sort();
    final spans = <InlineSpan>[];
    for (var index = 0; index + 1 < ordered.length; index++) {
      final segmentStart = ordered[index];
      final segmentEnd = ordered[index + 1];
      if (segmentStart >= segmentEnd) continue;
      final facet = facetSegments
          .where(
            (value) => value.start <= segmentStart && value.end >= segmentEnd,
          )
          .firstOrNull;
      TextStyle? style = facet == null
          ? null
          : semanticFacetTextStyle(context, facet.span);
      final highlighted =
          highlightStart != null &&
          highlightEnd != null &&
          highlightStart < segmentEnd &&
          highlightEnd > segmentStart;
      if (highlighted) {
        style = (style ?? const TextStyle()).merge(highlightStyle);
      }
      spans.add(
        TextSpan(
          text: String.fromCharCodes(runes.sublist(segmentStart, segmentEnd)),
          style: style,
        ),
      );
    }
    return spans;
  }
}

const _knownReferenceKinds = <String>{
  'bibliography_reference',
  'figure_reference',
  'table_reference',
  'equation_reference',
  'footnote',
  'term',
  'symbol',
  'external_resource',
};

bool _overlaps(int leftStart, int leftEnd, int rightStart, int rightEnd) =>
    leftStart < rightEnd && rightStart < leftEnd;

int _referencePriority(String kind) => switch (kind) {
  'term' || 'symbol' => 1,
  _ => 0,
};

String _referenceKindLabel(String kind) => switch (kind) {
  'bibliography_reference' => 'bibliography reference',
  'figure_reference' => 'figure reference',
  'table_reference' => 'table reference',
  'equation_reference' => 'equation reference',
  'footnote' => 'footnote',
  'term' => 'term reference',
  'symbol' => 'symbol reference',
  'external_resource' => 'external resource reference',
  _ => 'source reference',
};

IconData _referenceIcon(String kind) => switch (kind) {
  'bibliography_reference' => Icons.format_quote_rounded,
  'figure_reference' => Icons.image_outlined,
  'table_reference' => Icons.table_chart_outlined,
  'equation_reference' => Icons.functions_rounded,
  'footnote' => Icons.notes_rounded,
  'term' => Icons.menu_book_outlined,
  'symbol' => Icons.data_object_rounded,
  'external_resource' => Icons.link_rounded,
  _ => Icons.info_outline,
};

final class _InlineInteraction {
  const _InlineInteraction._({
    required this.start,
    required this.end,
    this.term,
    this.reference,
  });

  factory _InlineInteraction.term(
    ({PaperTerm term, TermOccurrence occurrence}) item,
  ) => _InlineInteraction._(
    start: item.occurrence.startOffset,
    end: item.occurrence.endOffset,
    term: item,
  );

  factory _InlineInteraction.reference(DocumentInlineSpan reference) =>
      _InlineInteraction._(
        start: reference.start,
        end: reference.end,
        reference: reference,
      );

  final int start;
  final int end;
  final ({PaperTerm term, TermOccurrence occurrence})? term;
  final DocumentInlineSpan? reference;
}
