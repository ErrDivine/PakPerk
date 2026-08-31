import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/annotation.dart';
import '../../core/models/version_diff.dart';
import '../../core/providers.dart';
import '../../core/research/research_repository.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

class VersionHistoryPanel extends StatefulWidget {
  const VersionHistoryPanel({
    required this.repository,
    required this.scope,
    required this.linkOpener,
    this.annotations = const [],
    super.key,
  });

  final ResearchRepository repository;
  final ResearchRequestScope scope;
  final ExternalLinkOpener linkOpener;
  final List<Annotation> annotations;

  @override
  State<VersionHistoryPanel> createState() => _VersionHistoryPanelState();
}

class _VersionHistoryPanelState extends State<VersionHistoryPanel> {
  late Future<List<DocumentVersion>> _versions;
  PaperVersionDiff? _diff;
  bool _loadingDiff = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _versions = widget.repository.versions(widget.scope);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DocumentVersion>>(
    future: _versions,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading document versions',
            child: const CircularProgressIndicator(),
          ),
        );
      }
      if (snapshot.hasError) {
        final error = snapshot.error;
        return _UnavailableVersionState(
          message: error is ApiException
              ? error.message
              : 'Version history could not be verified.',
          onRetry: () => setState(() {
            _versions = widget.repository.versions(widget.scope, force: true);
          }),
        );
      }
      final versions = snapshot.data ?? const [];
      if (versions.isEmpty) {
        return const Center(child: Text('No version history is available.'));
      }
      // The API intentionally returns newest-first history. Keep that useful
      // display order, but always request a diff from the older generation to
      // the newer generation. Using the final two response items would invert
      // the pair (and, with three or more versions, compare the oldest pair).
      final orderedVersions = versions.toList(growable: false)
        ..sort((left, right) => right.generation.compareTo(left.generation));
      final comparison = latestDocumentVersionComparison(orderedVersions);
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text(
            'Document versions',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          const Text(
            'Changes describe parser-supported document differences, not author intent.',
          ),
          const SizedBox(height: 12),
          for (final version in orderedVersions)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          version.isCurrent
                              ? Icons.check_circle_outline
                              : Icons.history,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${version.arxivId}${version.isCurrent ? ' · current' : ''}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Parser ${version.parserId} ${version.parserVersion} · generation ${version.generation}',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _VersionAction(
                          icon: Icons.open_in_new,
                          label: 'Exact abstract source',
                          onPressed: () =>
                              widget.linkOpener.open(version.sourceAbsUrl),
                        ),
                        _VersionAction(
                          icon: Icons.picture_as_pdf_outlined,
                          label: 'Exact PDF source',
                          onPressed: () =>
                              widget.linkOpener.open(version.sourcePdfUrl),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (comparison != null) ...[
            const SizedBox(height: 8),
            _VersionAction(
              icon: Icons.difference_outlined,
              label: _loadingDiff
                  ? 'Comparing…'
                  : 'Compare latest two versions',
              onPressed: _loadingDiff
                  ? null
                  : () => _loadDiff(comparison.from, comparison.to),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          if (_diff case final diff?) ...[
            const SizedBox(height: 16),
            _VersionDiffView(
              diff: diff,
              linkOpener: widget.linkOpener,
              annotations: widget.annotations,
            ),
          ],
        ],
      );
    },
  );

  Future<void> _loadDiff(DocumentVersion from, DocumentVersion to) async {
    setState(() {
      _loadingDiff = true;
      _error = null;
    });
    try {
      final diff = await widget.repository.versionDiff(
        scope: widget.scope,
        fromGeneration: from.generation,
        toGeneration: to.generation,
      );
      if (!mounted) return;
      setState(() => _diff = diff);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Version comparison could not be verified.');
      }
    } finally {
      if (mounted) setState(() => _loadingDiff = false);
    }
  }
}

class _VersionDiffView extends StatelessWidget {
  const _VersionDiffView({
    required this.diff,
    required this.linkOpener,
    required this.annotations,
  });

  final PaperVersionDiff diff;
  final ExternalLinkOpener linkOpener;
  final List<Annotation> annotations;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label:
        'Version comparison from v${diff.fromArxivVersion} to v${diff.toArxivVersion}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'v${diff.fromArxivVersion} → v${diff.toArxivVersion}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (diff.parserChangeUncertainty)
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: const ListTile(
              leading: Icon(Icons.warning_amber_outlined),
              title: Text('Parser changed'),
              subtitle: Text(
                'Some differences may come from extraction changes. Treat uncertain items as review prompts.',
              ),
            ),
          ),
        Text(
          '${diff.summary.added} added · ${diff.summary.removed} removed · '
          '${diff.summary.modified} modified · ${diff.summary.moved} moved',
        ),
        if (annotations.isNotEmpty) ...[
          const SizedBox(height: 8),
          _AnnotationAnchorSummary(
            annotations: annotations,
            toGeneration: diff.toGeneration,
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _VersionAction(
              icon: Icons.history,
              label: 'Open exact old source',
              onPressed: () => linkOpener.open(diff.fromSourceAbsUrl),
            ),
            _VersionAction(
              icon: Icons.open_in_new,
              label: 'Open exact new source',
              onPressed: () => linkOpener.open(diff.toSourceAbsUrl),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final item in diff.items.take(100))
          ListTile(
            contentPadding: EdgeInsets.zero,
            minVerticalPadding: 12,
            leading: Icon(
              item.confidenceStatus == DiffConfidenceStatus.supported
                  ? Icons.check_circle_outline
                  : item.confidenceStatus == DiffConfidenceStatus.uncertain
                  ? Icons.warning_amber_outlined
                  : Icons.help_outline,
            ),
            title: Text('${item.changeType.name} ${item.kind.label}'),
            subtitle: Text(
              'Confidence: ${item.confidenceStatus.name}'
              '${item.similarity == null ? '' : ' · ${(item.similarity! * 100).round()}% match'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showItemSources(context, item),
          ),
        if (diff.items.length > 100)
          Text(
            '${diff.items.length - 100} additional changes are omitted here.',
          ),
      ],
    ),
  );

  Future<void> _showItemSources(
    BuildContext context,
    VersionDiffItem item,
  ) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: platformPrefersReducedMotion(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${item.changeType.name} ${item.kind.label}',
            style: Theme.of(sheetContext).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Open the exact retained arXiv version. When the parser published a trustworthy page, the PDF opens at that page; opaque item identifiers are never treated as public links.',
          ),
          const SizedBox(height: 16),
          if (item.oldObjectId != null)
            _VersionAction(
              icon: Icons.history,
              label: _sourceActionLabel(
                version: diff.fromArxivVersion,
                target: item.oldSource,
              ),
              onPressed: () => linkOpener.open(
                item.oldSource?.preferredSourceUrl ?? diff.fromSourceAbsUrl,
              ),
            ),
          if (item.oldObjectId != null && item.newObjectId != null)
            const SizedBox(height: 8),
          if (item.newObjectId != null)
            _VersionAction(
              icon: Icons.open_in_new,
              label: _sourceActionLabel(
                version: diff.toArxivVersion,
                target: item.newSource,
              ),
              onPressed: () => linkOpener.open(
                item.newSource?.preferredSourceUrl ?? diff.toSourceAbsUrl,
              ),
            ),
        ],
      ),
    ),
  );

  String _sourceActionLabel({
    required int version,
    required VersionDiffSourceTarget? target,
  }) {
    final page = target?.exactPageNumber;
    if (page != null) return 'Open v$version at page $page';
    if (target != null) return 'Open exact v$version PDF';
    return 'Open exact v$version source';
  }
}

class _AnnotationAnchorSummary extends StatelessWidget {
  const _AnnotationAnchorSummary({
    required this.annotations,
    required this.toGeneration,
  });

  final List<Annotation> annotations;
  final int toGeneration;

  @override
  Widget build(BuildContext context) {
    final current = annotations
        .where(
          (annotation) =>
              annotation.generation == toGeneration &&
              annotation.anchorStatus == AnnotationAnchorStatus.anchored,
        )
        .length;
    final uncertain = annotations
        .where(
          (annotation) =>
              annotation.anchorStatus == AnnotationAnchorStatus.uncertain,
        )
        .length;
    final orphaned = annotations
        .where(
          (annotation) =>
              annotation.anchorStatus == AnnotationAnchorStatus.orphaned,
        )
        .length;
    return Semantics(
      container: true,
      label:
          'Your annotation anchors: $current current, $uncertain need review, $orphaned orphaned',
      child: Card(
        child: ListTile(
          leading: Icon(
            uncertain + orphaned == 0
                ? Icons.bookmark_added_outlined
                : Icons.bookmark_border,
          ),
          title: const Text('Your annotation anchors'),
          subtitle: Text(
            '$current current · $uncertain need review · $orphaned orphaned',
          ),
        ),
      ),
    );
  }
}

class _VersionAction extends StatelessWidget {
  const _VersionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: PakPerkSizes.minimumInteractive,
    ),
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}

class _UnavailableVersionState extends StatelessWidget {
  const _UnavailableVersionState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          _VersionAction(
            icon: Icons.refresh,
            label: 'Retry version history',
            onPressed: onRetry,
          ),
        ],
      ),
    ),
  );
}
