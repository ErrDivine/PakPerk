import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/semantic_span.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

final class ResolvedSemanticSegment {
  const ResolvedSemanticSegment({
    required this.start,
    required this.end,
    required this.span,
  });

  final int start;
  final int end;
  final SemanticSpan span;
}

/// Resolves overlapping server spans into stable, non-overlapping intervals.
/// Invalid ranges are omitted rather than widened or clamped: a semantic cue
/// must never decorate source text the server did not identify.
List<ResolvedSemanticSegment> resolveSemanticFacetSegments({
  required String blockId,
  required int scalarLength,
  required Iterable<SemanticSpan> spans,
  required SemanticDensity density,
}) {
  if (density == SemanticDensity.off || scalarLength <= 0) return const [];
  final candidates = spans
      .where(
        (span) =>
            span.visibleAt(density) &&
            span.isValidForBlock(blockId: blockId, scalarLength: scalarLength),
      )
      .toList(growable: false);
  if (candidates.isEmpty) return const [];

  final boundaries = <int>{};
  for (final span in candidates) {
    boundaries
      ..add(span.startOffset)
      ..add(span.endOffset);
  }
  final orderedBoundaries = boundaries.toList()..sort();
  final resolved = <ResolvedSemanticSegment>[];
  for (var index = 0; index + 1 < orderedBoundaries.length; index++) {
    final start = orderedBoundaries[index];
    final end = orderedBoundaries[index + 1];
    if (start >= end) continue;
    final covering =
        candidates
            .where((span) => span.startOffset <= start && span.endOffset >= end)
            .toList(growable: false)
          ..sort(_compareSemanticPrecedence);
    if (covering.isEmpty) continue;
    final winner = covering.first;
    final previous = resolved.lastOrNull;
    if (previous != null &&
        previous.end == start &&
        previous.span.id == winner.id) {
      resolved[resolved.length - 1] = ResolvedSemanticSegment(
        start: previous.start,
        end: end,
        span: winner,
      );
    } else {
      resolved.add(
        ResolvedSemanticSegment(start: start, end: end, span: winner),
      );
    }
  }
  return List.unmodifiable(resolved);
}

int _compareSemanticPrecedence(SemanticSpan left, SemanticSpan right) {
  int compare(bool leftPreferred, bool rightPreferred) =>
      leftPreferred == rightPreferred ? 0 : (leftPreferred ? -1 : 1);

  var result = compare(
    left.supportStatus == SemanticSupportStatus.supported,
    right.supportStatus == SemanticSupportStatus.supported,
  );
  if (result != 0) return result;
  result = compare(
    left.minimumDensity == SemanticDensity.key,
    right.minimumDensity == SemanticDensity.key,
  );
  if (result != 0) return result;
  result = right.confidenceBasisPoints.compareTo(left.confidenceBasisPoints);
  if (result != 0) return result;
  result = (left.endOffset - left.startOffset).compareTo(
    right.endOffset - right.startOffset,
  );
  if (result != 0) return result;
  result = compare(
    left.sourceKind == SemanticSpanSourceKind.deterministic,
    right.sourceKind == SemanticSpanSourceKind.deterministic,
  );
  if (result != 0) return result;
  result = _facetPrecedence(
    left.facet,
  ).compareTo(_facetPrecedence(right.facet));
  if (result != 0) return result;
  result = left.ordinal.compareTo(right.ordinal);
  return result != 0 ? result : left.id.compareTo(right.id);
}

int _facetPrecedence(SemanticFacet facet) => switch (facet) {
  SemanticFacet.limitation => 0,
  SemanticFacet.evidence => 1,
  SemanticFacet.result => 2,
  SemanticFacet.method => 3,
  SemanticFacet.objective => 4,
  SemanticFacet.claim => 5,
  SemanticFacet.definition => 6,
  SemanticFacet.futureWork => 7,
};

TextStyle semanticFacetTextStyle(BuildContext context, SemanticSpan span) {
  final colors = Theme.of(context).colorScheme;
  final decorationStyle = switch (span.facet) {
    SemanticFacet.result ||
    SemanticFacet.evidence => TextDecorationStyle.double,
    SemanticFacet.method ||
    SemanticFacet.definition => TextDecorationStyle.dotted,
    SemanticFacet.limitation ||
    SemanticFacet.futureWork => TextDecorationStyle.dashed,
    SemanticFacet.objective || SemanticFacet.claim => TextDecorationStyle.solid,
  };
  return TextStyle(
    decoration: TextDecoration.underline,
    decorationStyle: decorationStyle,
    decorationColor: colors.primary,
    decorationThickness: span.supportStatus == SemanticSupportStatus.supported
        ? 1.7
        : 1.1,
    fontWeight: span.supportStatus == SemanticSupportStatus.supported
        ? FontWeight.w500
        : FontWeight.normal,
  );
}

class SemanticFacetCue extends StatelessWidget {
  const SemanticFacetCue({required this.span, super.key});

  final SemanticSpan span;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final opaque = platformPrefersReducedTransparency(context);
    final label =
        '${span.facet.label} facet, ${span.supportStatus.label.toLowerCase()}';
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('semantic-facet-cue-${span.id}'),
          margin: const EdgeInsets.only(right: 5),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: opaque
                ? colors.surfaceContainerHighest
                : colors.primaryContainer.withValues(alpha: .72),
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            span.facet.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class SemanticDensitySelector extends StatelessWidget {
  const SemanticDensitySelector({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final SemanticDensity selected;
  final ValueChanged<SemanticDensity> onSelected;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = platformPrefersReducedMotion(context);
    return Semantics(
      container: true,
      label: 'Semantic cue density',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            label: 'Semantic cues: ${selected.label}',
            child: Text(
              'Semantic cues · ${selected.label}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            key: const ValueKey('semantic-density-selector-scroll'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final density in SemanticDensity.values) ...[
                  _DensityButton(
                    density: density,
                    selected: density == selected,
                    reducedMotion: reducedMotion,
                    onPressed: () async {
                      if (density == selected) return;
                      onSelected(density);
                      try {
                        await HapticFeedback.selectionClick();
                      } on Object {
                        // Optional feedback follows the committed selection.
                      }
                    },
                  ),
                  if (density != SemanticDensity.values.last)
                    const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DensityButton extends StatelessWidget {
  const _DensityButton({
    required this.density,
    required this.selected,
    required this.reducedMotion,
    required this.onPressed,
  });

  final SemanticDensity density;
  final bool selected;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${density.label} semantic cues',
      child: AnimatedContainer(
        key: ValueKey('semantic-density-${density.wireValue}'),
        duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.quick,
        curve: PakPerkMotion.emphasized,
        constraints: const BoxConstraints(
          minHeight: PakPerkSizes.minimumInteractive,
          minWidth: 76,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHigh,
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Center(
              child: Text(
                density.label,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected
                      ? colors.onPrimaryContainer
                      : colors.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
