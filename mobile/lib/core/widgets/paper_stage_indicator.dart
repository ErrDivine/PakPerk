import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design_system/motion.dart';
import '../models/reader_state.dart';

/// A compact, touch-first stage switcher for the horizontal paper reader.
///
/// When [pageController] is attached, the selection capsule follows the live
/// PageView position instead of waiting for [currentStage] to change. This
/// keeps the control visually attached to a drag while still allowing reduced
/// motion to remove programmatic selection travel.
class PaperStageIndicator extends StatefulWidget {
  const PaperStageIndicator({
    required this.currentStage,
    required this.onSelected,
    this.pageController,
    this.enabled = true,
    super.key,
  });

  final PaperStage currentStage;
  final ValueChanged<PaperStage> onSelected;
  final PageController? pageController;
  final bool enabled;

  @override
  State<PaperStageIndicator> createState() => _PaperStageIndicatorState();
}

class _PaperStageIndicatorState extends State<PaperStageIndicator> {
  final ScrollController _overflowController = ScrollController();
  bool _usesScrollableTrack = false;
  bool _scrollSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.pageController?.addListener(_handlePagePosition);
  }

  @override
  void didUpdateWidget(covariant PaperStageIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_handlePagePosition);
      widget.pageController?.addListener(_handlePagePosition);
    }
    if (oldWidget.currentStage != widget.currentStage ||
        oldWidget.pageController != widget.pageController) {
      _scheduleOverflowSync();
    }
  }

  @override
  void dispose() {
    widget.pageController?.removeListener(_handlePagePosition);
    _overflowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reducedMotion = platformPrefersReducedMotion(context);
    return Semantics(
      container: true,
      label: 'Paper views',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = _StageLayout.resolve(context, constraints);
            _usesScrollableTrack = layout.scrollable;
            _scheduleOverflowSync();

            final track = SizedBox(
              width: layout.trackExtent,
              child: _StageTrack(
                currentStage: widget.currentStage,
                onSelected: widget.onSelected,
                pageController: widget.pageController,
                segmentExtent: layout.segmentExtent,
                reducedMotion: reducedMotion,
                enabled: widget.enabled,
              ),
            );
            final content = layout.scrollable
                ? SingleChildScrollView(
                    key: const ValueKey('stage-indicator-scroll'),
                    controller: _overflowController,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: track,
                  )
                : track;

            return DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: .8),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: content,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _handlePagePosition() {
    _syncOverflowToPage();
  }

  void _scheduleOverflowSync() {
    if (_scrollSyncScheduled) return;
    _scrollSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollSyncScheduled = false;
      if (mounted) _syncOverflowToPage();
    });
  }

  void _syncOverflowToPage() {
    if (!_usesScrollableTrack || !_overflowController.hasClients) return;
    final maxScrollExtent = _overflowController.position.maxScrollExtent;
    if (maxScrollExtent <= 0) return;
    final page = _pagePosition().clamp(
      0.0,
      (PaperStage.values.length - 1).toDouble(),
    );
    final target = page / (PaperStage.values.length - 1) * maxScrollExtent;
    if ((_overflowController.offset - target).abs() > .5) {
      _overflowController.jumpTo(target);
    }
  }

  double _pagePosition() {
    final controller = widget.pageController;
    if (controller == null ||
        !controller.hasClients ||
        controller.positions.length != 1) {
      return widget.currentStage.index.toDouble();
    }
    return controller.page ?? widget.currentStage.index.toDouble();
  }
}

class _StageLayout {
  const _StageLayout({
    required this.scrollable,
    required this.segmentExtent,
    required this.trackExtent,
  });

  final bool scrollable;
  final double segmentExtent;
  final double trackExtent;

  factory _StageLayout.resolve(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    const capsuleInsets = 6.0;
    const labelInsets = 18.0;
    final available = constraints.hasBoundedWidth
        ? (constraints.maxWidth - capsuleInsets).clamp(0.0, double.infinity)
        : 360.0;
    final style =
        Theme.of(context).textTheme.labelLarge ??
        DefaultTextStyle.of(context).style;
    var widestLabel = 0.0;
    for (final stage in PaperStage.values) {
      final painter = TextPainter(
        text: TextSpan(text: stage.label, style: style),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      widestLabel = widestLabel < painter.width ? painter.width : widestLabel;
      painter.dispose();
    }

    final equalExtent = available / PaperStage.values.length;
    final readableExtent = (widestLabel + labelInsets).clamp(88.0, 240.0);
    final scrollable = readableExtent > equalExtent;
    final segmentExtent = scrollable ? readableExtent : equalExtent;
    return _StageLayout(
      scrollable: scrollable,
      segmentExtent: segmentExtent,
      trackExtent: segmentExtent * PaperStage.values.length,
    );
  }
}

class _StageTrack extends StatelessWidget {
  const _StageTrack({
    required this.currentStage,
    required this.onSelected,
    required this.pageController,
    required this.segmentExtent,
    required this.reducedMotion,
    required this.enabled,
  });

  final PaperStage currentStage;
  final ValueChanged<PaperStage> onSelected;
  final PageController? pageController;
  final double segmentExtent;
  final bool reducedMotion;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget buildTrack() {
      final livePage = _livePagePosition();
      final tracksLivePage = livePage != null;
      final page = (livePage ?? currentStage.index.toDouble()).clamp(
        0.0,
        (PaperStage.values.length - 1).toDouble(),
      );
      final capsule = _SelectionCapsule(
        key: const ValueKey('stage-selection-capsule'),
      );
      final positionedCapsule = tracksLivePage
          ? PositionedDirectional(
              start: page * segmentExtent,
              top: 0,
              bottom: 0,
              width: segmentExtent,
              child: capsule,
            )
          : AnimatedPositionedDirectional(
              start: page * segmentExtent,
              top: 0,
              bottom: 0,
              width: segmentExtent,
              duration: reducedMotion
                  ? PakPerkMotion.instant
                  : PakPerkMotion.quick,
              curve: PakPerkMotion.emphasized,
              child: capsule,
            );
      return Stack(
        children: [
          positionedCapsule,
          Row(
            children: [
              for (final stage in PaperStage.values)
                SizedBox(
                  width: segmentExtent,
                  child: _StageControl(
                    stage: stage,
                    selected: currentStage == stage,
                    reducedMotion: reducedMotion,
                    enabled: enabled,
                    onSelected: onSelected,
                  ),
                ),
            ],
          ),
        ],
      );
    }

    final controller = pageController;
    if (controller == null) return buildTrack();
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => buildTrack(),
    );
  }

  double? _livePagePosition() {
    final controller = pageController;
    if (controller == null ||
        !controller.hasClients ||
        controller.positions.length != 1) {
      return null;
    }
    return controller.page;
  }
}

class _SelectionCapsule extends StatelessWidget {
  const _SelectionCapsule({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .72),
          ),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: .14),
              blurRadius: 5,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageControl extends StatefulWidget {
  const _StageControl({
    required this.stage,
    required this.selected,
    required this.reducedMotion,
    required this.onSelected,
    required this.enabled,
  });

  final PaperStage stage;
  final bool selected;
  final bool reducedMotion;
  final ValueChanged<PaperStage> onSelected;
  final bool enabled;

  @override
  State<_StageControl> createState() => _StageControlState();
}

class _StageControlState extends State<_StageControl> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final baseStyle =
        Theme.of(context).textTheme.labelLarge ??
        DefaultTextStyle.of(context).style;
    final labelStyle = baseStyle.copyWith(
      color: widget.selected ? colors.primary : colors.onSurfaceVariant,
      fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w600,
    );
    return Semantics(
      selected: widget.selected,
      button: true,
      enabled: widget.enabled,
      sortKey: OrdinalSortKey(widget.stage.index.toDouble()),
      label:
          '${widget.stage.label} view, '
          '${widget.selected ? 'selected' : 'not selected'}',
      child: ExcludeSemantics(
        child: AnimatedScale(
          scale: _pressed ? .98 : 1,
          duration: widget.reducedMotion
              ? PakPerkMotion.instant
              : const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('stage-${widget.stage.name}'),
              borderRadius: BorderRadius.circular(10),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return colors.primary.withValues(alpha: .12);
                }
                if (states.contains(WidgetState.focused)) {
                  return colors.primary.withValues(alpha: .08);
                }
                if (states.contains(WidgetState.hovered)) {
                  return colors.primary.withValues(alpha: .06);
                }
                return null;
              }),
              onHighlightChanged: widget.enabled
                  ? (pressed) {
                      if (_pressed != pressed) {
                        setState(() => _pressed = pressed);
                      }
                    }
                  : null,
              onTap: widget.enabled
                  ? () => widget.onSelected(widget.stage)
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 7,
                  ),
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: widget.reducedMotion
                          ? PakPerkMotion.instant
                          : PakPerkMotion.crossFade,
                      curve: PakPerkMotion.emphasized,
                      style: labelStyle,
                      child: Text(
                        widget.stage.label,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
