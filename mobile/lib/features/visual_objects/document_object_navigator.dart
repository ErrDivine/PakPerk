import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:smart_latex/smart_latex.dart';

import '../../core/api/request_cancellation.dart';
import '../../core/document/mathml_latex_adapter.dart';
import '../../core/document/visual_asset_repository.dart';
import '../../core/document/visual_asset_limits.dart';
import '../../core/models/document_block.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../document_reader/reader_interaction_state.dart';

class DocumentObjectNavigator extends StatelessWidget {
  const DocumentObjectNavigator({
    required this.figures,
    required this.tables,
    required this.equations,
    required this.onInspect,
    super.key,
  });

  final List<DocumentFigure> figures;
  final List<DocumentTable> tables;
  final List<DocumentEquation> equations;
  final ValueChanged<DocumentEvidenceObject> onInspect;

  @override
  Widget build(BuildContext context) {
    final objects = <DocumentEvidenceObject>[
      ...figures,
      ...tables,
      ...equations,
    ];
    if (objects.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          'No reliable figures, tables, or equations are available for this generation.',
        ),
      );
    }
    final dynamicTypeExpansion = (MediaQuery.textScalerOf(context).scale(1) - 1)
        .clamp(0.0, 1.0)
        .toDouble();
    return Semantics(
      container: true,
      label: 'Figures, tables, and equations',
      child: SizedBox(
        height: 126 + 72 * dynamicTypeExpansion,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          scrollDirection: Axis.horizontal,
          itemCount: objects.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final object = objects[index];
            return SizedBox(
              width: 220,
              child: Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onInspect(object),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          object.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          object.caption ?? 'Caption unavailable',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const Spacer(),
                        Text(
                          '${object.status.name}${object.page == null ? '' : ' · page ${object.page}'}',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

Future<void> showDocumentObjectSheet({
  required BuildContext context,
  required DocumentEvidenceObject object,
  required ReaderInteractionController interaction,
  required VoidCallback onInspectSources,
  required ValueChanged<String> onInspectReference,
  required VoidCallback onOpenOriginal,
  VoidCallback? onSaveEvidence,
  VoidCallback? onAskObject,
  Future<VisualAssetLease> Function(RequestCancellation cancellation)?
  loadFigureAsset,
}) async {
  interaction.setActive(ReaderInteractionKind.objectInspector, true);
  final reducedMotion = platformPrefersReducedMotion(context);
  try {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: AnimationStyle(
        duration: reducedMotion
            ? PakPerkMotion.instant
            : PakPerkMotion.standard,
        reverseDuration: reducedMotion
            ? PakPerkMotion.instant
            : PakPerkMotion.quick,
      ),
      builder: (context) => FractionallySizedBox(
        heightFactor: object is DocumentTable ? .9 : .78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        object.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: 'Close object',
                    constraints: const BoxConstraints(
                      minWidth: PakPerkSizes.minimumInteractive,
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(
                child: CustomScrollView(
                  key: const ValueKey('document-object-sheet-scroll'),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_statusLabel(object)),
                            if (object.limitation != null) ...[
                              const SizedBox(height: 6),
                              Text(object.limitation!),
                            ],
                            if (object.caption != null) ...[
                              const SizedBox(height: 12),
                              SelectableText(object.caption!),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: _objectPresentationHeight(context, object),
                        child: switch (object) {
                          DocumentTable table => _ArbitratedTable(
                            table: table,
                            interaction: interaction,
                          ),
                          DocumentEquation equation => _EquationSource(
                            equation: equation,
                          ),
                          DocumentFigure figure => _FigurePresentation(
                            figure: figure,
                            loadAsset: loadFigureAsset,
                          ),
                          _ => const SizedBox.shrink(),
                        },
                      ),
                    ),
                    if (object.referencedBy.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _ReferencedBySection(
                            references: object.referencedBy,
                            onOpenReference: onInspectReference,
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _ObjectAction(
                      onPressed: object.sourceBlockIds.isEmpty
                          ? null
                          : onInspectSources,
                      icon: Icons.fact_check_outlined,
                      label: 'Sources',
                    ),
                    const SizedBox(width: 8),
                    _ObjectAction(
                      onPressed: onOpenOriginal,
                      icon: Icons.picture_as_pdf_outlined,
                      label: object.page == null
                          ? 'Original PDF'
                          : 'PDF · page ${object.page}',
                    ),
                    if (onSaveEvidence != null) ...[
                      const SizedBox(width: 8),
                      _ObjectAction(
                        onPressed: onSaveEvidence,
                        icon: Icons.bookmark_add_outlined,
                        label: 'Save evidence',
                      ),
                    ],
                    if (onAskObject != null) ...[
                      const SizedBox(width: 8),
                      _ObjectAction(
                        onPressed: onAskObject,
                        icon: Icons.chat_bubble_outline,
                        label: 'Ask about this',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  } finally {
    interaction.setActive(ReaderInteractionKind.objectInspector, false);
  }
}

double _objectPresentationHeight(
  BuildContext context,
  DocumentEvidenceObject object,
) {
  final expansion = (MediaQuery.textScalerOf(context).scale(1) - 1)
      .clamp(0.0, 1.0)
      .toDouble();
  return switch (object) {
    DocumentTable() => 440 + 120 * expansion,
    DocumentEquation() => 280 + 100 * expansion,
    DocumentFigure() => 300 + 80 * expansion,
    _ => 260 + 80 * expansion,
  };
}

class _ReferencedBySection extends StatelessWidget {
  const _ReferencedBySection({
    required this.references,
    required this.onOpenReference,
  });

  final List<DocumentObjectReference> references;
  final ValueChanged<String> onOpenReference;

  @override
  Widget build(BuildContext context) {
    final textExpansion = (MediaQuery.textScalerOf(context).scale(1) - 1)
        .clamp(0.0, 1.0)
        .toDouble();
    return Semantics(
      container: true,
      label: 'Referenced by ${references.length} source contexts',
      child: SizedBox(
        height: 132 + 56 * textExpansion,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Referenced by',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: references.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final reference = references[index];
                  final location = [
                    reference.sectionLabel,
                    if (reference.pageNumber != null)
                      'page ${reference.pageNumber}',
                  ].join(' · ');
                  return SizedBox(
                    width: 280,
                    child: Semantics(
                      button: true,
                      label:
                          'Open reference in $location. ${reference.context}',
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: InkWell(
                          onTap: () => onOpenReference(reference.blockId),
                          borderRadius: BorderRadius.circular(12),
                          child: ExcludeSemantics(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    location,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Expanded(
                                    child: Text(
                                      reference.context,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(DocumentEvidenceObject object) {
  final page = object.page == null ? '' : ' · source page ${object.page}';
  return switch (object.status) {
    DocumentObjectStatus.ready => 'Source representation ready$page',
    DocumentObjectStatus.partial => 'Partial extraction$page',
    DocumentObjectStatus.uncertain => 'Association uncertain$page',
    DocumentObjectStatus.unavailable =>
      'Source representation unavailable$page',
    DocumentObjectStatus.failed => 'Extraction failed$page',
  };
}

class _ObjectAction extends StatelessWidget {
  const _ObjectAction({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

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

class _FigurePresentation extends StatefulWidget {
  const _FigurePresentation({required this.figure, this.loadAsset});

  final DocumentFigure figure;
  final Future<VisualAssetLease> Function(RequestCancellation cancellation)?
  loadAsset;

  @override
  State<_FigurePresentation> createState() => _FigurePresentationState();
}

class _FigurePresentationState extends State<_FigurePresentation> {
  RequestCancellation? _cancellation;
  VisualAssetLease? _lease;
  bool _loading = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.loadAsset != null) {
      _loading = true;
      final cancellation = RequestCancellation();
      _cancellation = cancellation;
      unawaited(_load(cancellation));
    }
  }

  Future<void> _load(RequestCancellation cancellation) async {
    try {
      final lease = await widget.loadAsset!(cancellation);
      if (!mounted || !identical(_cancellation, cancellation)) {
        lease.release();
        return;
      }
      setState(() {
        _lease = lease;
        _loading = false;
        _loadFailed = false;
      });
    } on Object {
      if (!mounted || !identical(_cancellation, cancellation)) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _retry() {
    _cancellation?.cancel('A newer figure request replaced this one.');
    final cancellation = RequestCancellation();
    setState(() {
      _cancellation = cancellation;
      _loading = true;
      _loadFailed = false;
    });
    unawaited(_load(cancellation));
  }

  @override
  void dispose() {
    _cancellation?.cancel('The figure inspector was closed.');
    _lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lease = _lease;
    if (lease != null) {
      final decodeSize = _decodeSize(context, lease.payload);
      return InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Semantics(
          image: true,
          label:
              widget.figure.altText ??
              widget.figure.caption ??
              widget.figure.label,
          child: Image.memory(
            lease.payload.bytes,
            fit: BoxFit.contain,
            cacheWidth: decodeSize.width,
            cacheHeight: decodeSize.height,
            excludeFromSemantics: true,
            errorBuilder: (_, __, ___) =>
                _FigureFallback(figure: widget.figure),
          ),
        ),
      );
    }
    if (_loading) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Loading trusted figure image.',
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return _FigureFallback(
      figure: widget.figure,
      onRetry: _loadFailed ? _retry : null,
    );
  }
}

({int width, int height}) _decodeSize(
  BuildContext context,
  VisualAssetPayload payload,
) {
  final media = MediaQuery.of(context);
  final displayWidth = media.size.width * media.devicePixelRatio * 2;
  final displayHeight = media.size.height * media.devicePixelRatio * 2;
  var scale = 1.0;
  scale = math.min(scale, maximumVisualAssetDecodeDimension / payload.width);
  scale = math.min(scale, maximumVisualAssetDecodeDimension / payload.height);
  scale = math.min(scale, displayWidth / payload.width);
  scale = math.min(scale, displayHeight / payload.height);
  scale = math.min(
    scale,
    math.sqrt(
      maximumVisualAssetDecodePixels / (payload.width * payload.height),
    ),
  );
  return (
    width: math.max(1, (payload.width * scale).floor()),
    height: math.max(1, (payload.height * scale).floor()),
  );
}

class _FigureFallback extends StatelessWidget {
  const _FigureFallback({required this.figure, this.onRetry});

  final DocumentFigure figure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    image: true,
    label:
        '${figure.label}. Image unavailable. ${figure.caption ?? 'Caption unavailable.'}',
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text(
              'No trustworthy image derivative is available. Use the caption and original page to verify the figure.',
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry image'),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _EquationSource extends StatefulWidget {
  const _EquationSource({required this.equation});

  final DocumentEquation equation;

  @override
  State<_EquationSource> createState() => _EquationSourceState();
}

class _EquationSourceState extends State<_EquationSource> {
  double _scale = 1;
  RenderableMathMl? _convertedMathMl;

  @override
  void initState() {
    super.initState();
    _convertedMathMl = _convertMathMl(widget.equation);
  }

  @override
  void didUpdateWidget(covariant _EquationSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.equation.latex != widget.equation.latex ||
        oldWidget.equation.mathMl != widget.equation.mathMl) {
      _convertedMathMl = _convertMathMl(widget.equation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final equation = widget.equation;
    final source = equation.latex ?? equation.mathMl ?? equation.plainText;
    if (source == null) {
      return const Center(
        child: Text('Reliable equation source is unavailable.'),
      );
    }
    final renderSource = equation.latex ?? _convertedMathMl?.latex;
    final sourceKind = equation.latex != null
        ? 'LaTeX'
        : equation.mathMl != null
        ? 'MathML'
        : 'source';
    final copyLabel = sourceKind == 'source'
        ? 'Copy source'
        : 'Copy $sourceKind';
    return SingleChildScrollView(
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  onPressed: _scale <= 1
                      ? null
                      : () => setState(() => _scale -= .25),
                  tooltip: 'Decrease equation size',
                  constraints: const BoxConstraints(
                    minWidth: PakPerkSizes.minimumInteractive,
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  icon: const Icon(Icons.remove),
                ),
                Text('${(_scale * 100).round()}%'),
                IconButton(
                  onPressed: _scale >= 2
                      ? null
                      : () => setState(() => _scale += .25),
                  tooltip: 'Increase equation size',
                  constraints: const BoxConstraints(
                    minWidth: PakPerkSizes.minimumInteractive,
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (renderSource case final expression?)
              SmartMath(
                expression,
                key: const ValueKey('equation-rendered-math'),
                display: true,
                // Parser output is evidence. Never let a renderer silently
                // repair it into a different formula; malformed input falls
                // back to the exact source below.
                sanitize: false,
                scrollable: true,
                semanticLabel:
                    equation.plainText ??
                    _convertedMathMl?.altText ??
                    'Rendered equation. Accessible text alternative unavailable.',
                style: Theme.of(context).textTheme.titleMedium,
                textScaler: TextScaler.linear(
                  MediaQuery.textScalerOf(context).scale(1) * _scale,
                ),
                errorBuilder: (context, expression) => Semantics(
                  liveRegion: true,
                  label: 'Equation rendering unavailable. Source shown.',
                  child: SelectableText(source),
                ),
              )
            else
              Semantics(
                label:
                    equation.plainText ??
                    'Equation source. Accessible text alternative unavailable.',
                excludeSemantics: true,
                child: SelectableText(
                  source,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize:
                        (Theme.of(context).textTheme.titleMedium?.fontSize ??
                            16) *
                        _scale,
                  ),
                ),
              ),
            if (renderSource != null) ...[
              const SizedBox(height: 12),
              Text('Source', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Semantics(
                label: '$sourceKind source',
                child: SelectableText(
                  source,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: source));
                  if (!context.mounted) return;
                  try {
                    await HapticFeedback.lightImpact();
                  } on Object {
                    // Optional feedback follows the clipboard commit only.
                  }
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Equation source copied.')),
                  );
                },
                icon: const Icon(Icons.copy_outlined),
                label: Text(copyLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static RenderableMathMl? _convertMathMl(DocumentEquation equation) {
    final mathMl = equation.mathMl;
    return equation.latex == null && mathMl != null
        ? renderableMathMl(mathMl)
        : null;
  }
}

class _ArbitratedTable extends StatefulWidget {
  const _ArbitratedTable({required this.table, required this.interaction});

  final DocumentTable table;
  final ReaderInteractionController interaction;

  @override
  State<_ArbitratedTable> createState() => _ArbitratedTableState();
}

class _ArbitratedTableState extends State<_ArbitratedTable> {
  Offset _movement = Offset.zero;
  bool _plainText = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.table_chart_outlined),
              label: Text('Structured'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.text_snippet_outlined),
              label: Text('Plain text'),
            ),
          ],
          selected: {_plainText},
          onSelectionChanged: (selection) {
            final next = selection.first;
            if (next != _plainText) setState(() => _plainText = next);
          },
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _plainText
              ? SingleChildScrollView(
                  child: SelectableText(
                    widget.table.plainText ??
                        'Reliable plain-text table content is unavailable.',
                  ),
                )
              : Listener(
                  onPointerDown: (_) {
                    _movement = Offset.zero;
                    widget.interaction.beginTablePan();
                  },
                  onPointerMove: (event) {
                    _movement += event.delta;
                    widget.interaction.updateTablePan(
                      accumulatedDx: _movement.dx,
                      accumulatedDy: _movement.dy,
                    );
                  },
                  onPointerUp: (_) => widget.interaction.endTablePan(),
                  onPointerCancel: (_) => widget.interaction.endTablePan(),
                  child: Semantics(
                    container: true,
                    label:
                        '${widget.table.label}, swipe horizontally to inspect columns',
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: _StructuredTable(table: widget.table),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _StructuredTable extends StatefulWidget {
  const _StructuredTable({required this.table});

  final DocumentTable table;

  @override
  State<_StructuredTable> createState() => _StructuredTableState();
}

class _StructuredTableState extends State<_StructuredTable> {
  static const _rowsPerPage = 25;
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final rows = table.structureRows;
    final rowCount = rows.isEmpty ? table.rows.length : rows.length;
    final maximumPage = rowCount == 0 ? 0 : (rowCount - 1) ~/ _rowsPerPage;
    final page = _page.clamp(0, maximumPage);
    final start = page * _rowsPerPage;
    final end = math.min(start + _rowsPerPage, rowCount);
    final Widget content;
    if (rows.isEmpty) {
      content = DataTable(
        columns: [
          for (final column in table.columns) DataColumn(label: Text(column)),
        ],
        rows: [
          for (final row in table.rows.sublist(start, end))
            DataRow(cells: [for (final cell in row) DataCell(Text(cell))]),
        ],
      );
    } else {
      final maximumColumns = rows
          .map((row) => row.length)
          .fold<int>(
            0,
            (maximum, length) => length > maximum ? length : maximum,
          );
      final colors = Theme.of(context).colorScheme;
      content = Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: colors.outlineVariant),
        children: [
          for (var rowIndex = start; rowIndex < end; rowIndex++)
            TableRow(
              children: [
                for (
                  var columnIndex = 0;
                  columnIndex < maximumColumns;
                  columnIndex++
                )
                  if (columnIndex < rows[rowIndex].length)
                    _StructuredCell(
                      cell: rows[rowIndex][columnIndex],
                      row: rowIndex + 1,
                      column: columnIndex + 1,
                    )
                  else
                    const SizedBox.shrink(),
              ],
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        if (maximumPage > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TablePageButton(
                  tooltip: 'Previous table rows',
                  icon: Icons.chevron_left,
                  onPressed: page == 0
                      ? null
                      : () => setState(() => _page = page - 1),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Semantics(
                    liveRegion: true,
                    label: 'Rows ${start + 1} through $end of $rowCount',
                    child: Text('${start + 1}–$end of $rowCount'),
                  ),
                ),
                _TablePageButton(
                  tooltip: 'Next table rows',
                  icon: Icons.chevron_right,
                  onPressed: page == maximumPage
                      ? null
                      : () => setState(() => _page = page + 1),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TablePageButton extends StatelessWidget {
  const _TablePageButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: PakPerkSizes.minimumInteractive,
    child: IconButton(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon)),
  );
}

class _StructuredCell extends StatelessWidget {
  const _StructuredCell({
    required this.cell,
    required this.row,
    required this.column,
  });

  final DocumentTableCell cell;
  final int row;
  final int column;

  @override
  Widget build(BuildContext context) {
    final spanLabel = [
      if (cell.rowSpan > 1) 'spans ${cell.rowSpan} rows',
      if (cell.columnSpan > 1) 'spans ${cell.columnSpan} columns',
    ].join(', ');
    return Semantics(
      label:
          '${cell.header ? 'Header' : 'Cell'}, row $row, column $column${spanLabel.isEmpty ? '' : ', $spanLabel'}: ${cell.text}',
      child: Container(
        constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: cell.header
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : null,
        child: Text(
          cell.text,
          style: cell.header
              ? Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
              : Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
