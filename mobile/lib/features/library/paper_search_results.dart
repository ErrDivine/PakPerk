import 'package:flutter/material.dart';

import '../../core/paper_resolution/paper_resolution_models.dart';
import '../../design_system/radii.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

/// A bounded, keyboard-operable candidate picker.
///
/// Selection is intentionally separate from import. The caller must receive
/// [onSelected] and then explicitly commit the chosen candidate.
class PaperSearchResults extends StatelessWidget {
  const PaperSearchResults({
    required this.candidates,
    required this.selectedArxivId,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<PaperSearchCandidate> candidates;
  final String? selectedArxivId;
  final ValueChanged<PaperSearchCandidate> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) {
      return Semantics(
        key: const ValueKey('paper-search-empty'),
        container: true,
        label: 'No matching papers found',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: PakPerkSpacing.lg),
          child: Column(
            children: [
              Icon(
                Icons.search_off_rounded,
                size: 28,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: PakPerkSpacing.sm),
              Text(
                'No matching papers',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: PakPerkSpacing.xs),
              Text(
                'Try a more specific title, an arXiv link, or an arXiv ID.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: '${candidates.length} paper search results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Choose the paper',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          Text(
            'Nothing is added until you select a result and confirm.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          for (var index = 0; index < candidates.length; index += 1) ...[
            _PaperSearchCandidateTile(
              candidate: candidates[index],
              selected: candidates[index].arxivId == selectedArxivId,
              enabled: enabled,
              onSelected: onSelected,
            ),
            if (index != candidates.length - 1)
              const SizedBox(height: PakPerkSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _PaperSearchCandidateTile extends StatelessWidget {
  const _PaperSearchCandidateTile({
    required this.candidate,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final PaperSearchCandidate candidate;
  final bool selected;
  final bool enabled;
  final ValueChanged<PaperSearchCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final authors = candidate.authors.take(3).join(', ');
    final extraAuthors = candidate.authors.length - 3;
    final authorLabel = authors.isEmpty
        ? 'Authors unavailable'
        : extraAuthors > 0
        ? '$authors, and $extraAuthors more'
        : authors;
    final publishedLabel = _publishedDateLabel(candidate.publishedAt);
    final metadataLabel = '$publishedLabel · ${candidate.primaryCategory}';
    final semanticLabel = <String>[
      candidate.title,
      authorLabel,
      'Published $publishedLabel',
      'Category ${candidate.primaryCategory}',
      'arXiv ${candidate.arxivId}',
      selected ? 'Selected' : 'Not selected',
    ].join('. ');

    return Semantics(
      key: ValueKey('paper-search-candidate-${candidate.arxivId}'),
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: .62)
            : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: PakPerkRadii.input,
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => onSelected(candidate) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: Padding(
              padding: const EdgeInsets.all(PakPerkSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 24,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: PakPerkSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          candidate.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: PakPerkSpacing.xxs),
                        Text(
                          authorLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: PakPerkSpacing.xxs),
                        Text(
                          metadataLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: PakPerkSpacing.xxs),
                        Text(
                          'arXiv ${candidate.arxivId}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
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

String _publishedDateLabel(DateTime value) {
  final utc = value.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}
