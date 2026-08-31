import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../design_system/motion.dart';

Future<String?> showSourceEvidenceSheet({
  required BuildContext context,
  required String title,
  required Iterable<String> sourceBlockIds,
  required Map<String, DocumentBlock> blocksById,
  Future<List<DocumentBlock>> Function()? loadSources,
  String? statusLabel,
  String? limitation,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  final ids = sourceBlockIds.toSet().take(128).toList(growable: false);
  final sources = ids
      .map((id) => blocksById[id])
      .whereType<DocumentBlock>()
      .toList(growable: false);
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: .72,
      child: _SourceEvidenceSheet(
        title: title,
        sourceIds: ids,
        initialSources: sources,
        loadSources: loadSources,
        statusLabel: statusLabel,
        limitation: limitation,
      ),
    ),
  );
}

class _SourceEvidenceSheet extends StatefulWidget {
  const _SourceEvidenceSheet({
    required this.title,
    required this.sourceIds,
    required this.initialSources,
    required this.loadSources,
    required this.statusLabel,
    required this.limitation,
  });

  final String title;
  final List<String> sourceIds;
  final List<DocumentBlock> initialSources;
  final Future<List<DocumentBlock>> Function()? loadSources;
  final String? statusLabel;
  final String? limitation;

  @override
  State<_SourceEvidenceSheet> createState() => _SourceEvidenceSheetState();
}

class _SourceEvidenceSheetState extends State<_SourceEvidenceSheet> {
  late final Future<List<DocumentBlock>> _sources;

  @override
  void initState() {
    super.initState();
    _sources =
        widget.initialSources.length == widget.sourceIds.length ||
            widget.loadSources == null
        ? Future.value(widget.initialSources)
        : widget.loadSources!();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${widget.title} source evidence',
    child: FutureBuilder<List<DocumentBlock>>(
      future: _sources,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState != ConnectionState.done;
        final sources = snapshot.data ?? widget.initialSources;
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              title: Text(widget.title),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.statusLabel != null)
                      Text('Status: ${widget.statusLabel}'),
                    if (widget.limitation != null) ...[
                      const SizedBox(height: 8),
                      Text(widget.limitation!),
                    ],
                    if (!waiting && sources.isEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        snapshot.hasError
                            ? 'Exact source blocks could not be loaded. Open the original source to verify.'
                            : 'No exact source block is available. Open the original source to verify.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (waiting)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    label: 'Loading exact source evidence',
                    child: const CircularProgressIndicator.adaptive(),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final block = sources[index];
                  return ListTile(
                    minTileHeight: 48,
                    title: Text(block.sectionLabel),
                    subtitle: Text(
                      block.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.my_location_outlined),
                    onTap: () => Navigator.pop(context, block.id),
                  );
                },
              ),
          ],
        );
      },
    ),
  );
}
