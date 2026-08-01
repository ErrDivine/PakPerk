import 'package:flutter/material.dart';

import '../../design_system/motion.dart';
import '../models/reader_state.dart';

class PaperStageIndicator extends StatelessWidget {
  const PaperStageIndicator({
    required this.currentStage,
    required this.onSelected,
    super.key,
  });

  final PaperStage currentStage;
  final ValueChanged<PaperStage> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Paper views',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stackControls = _labelsNeedFullWidth(context, constraints);
            final controls = [
              for (final stage in PaperStage.values)
                _StageControl(
                  stage: stage,
                  selected: currentStage == stage,
                  horizontal: stackControls,
                  onSelected: onSelected,
                ),
            ];
            return stackControls
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: controls,
                  )
                : Row(
                    children: [
                      for (final control in controls) Expanded(child: control),
                    ],
                  );
          },
        ),
      ),
    );
  }

  bool _labelsNeedFullWidth(BuildContext context, BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth) return false;
    const controlHorizontalPadding = 6.0;
    final availableLabelWidth =
        constraints.maxWidth / PaperStage.values.length -
        controlHorizontalPadding;
    if (availableLabelWidth <= 0) return true;
    final style =
        Theme.of(context).textTheme.labelMedium ??
        DefaultTextStyle.of(context).style;
    for (final stage in PaperStage.values) {
      final painter = TextPainter(
        text: TextSpan(text: stage.label, style: style),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final fits = painter.width <= availableLabelWidth;
      painter.dispose();
      if (!fits) return true;
    }
    return false;
  }
}

class _StageControl extends StatelessWidget {
  const _StageControl({
    required this.stage,
    required this.selected,
    required this.horizontal,
    required this.onSelected,
  });

  final PaperStage stage;
  final bool selected;
  final bool horizontal;
  final ValueChanged<PaperStage> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dot = AnimatedContainer(
      duration: platformPrefersReducedMotion(context)
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
      width: selected ? 10 : 8,
      height: selected ? 10 : 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? colors.primary : colors.outlineVariant,
      ),
    );
    final label = Text(
      stage.label,
      maxLines: horizontal ? 2 : 1,
      textAlign: TextAlign.center,
      overflow: TextOverflow.visible,
      style: Theme.of(context).textTheme.labelMedium,
    );
    return Semantics(
      selected: selected,
      button: true,
      label: '${stage.label} view, ${selected ? 'selected' : 'not selected'}',
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey('stage-${stage.name}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onSelected(stage),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              child: horizontal
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        dot,
                        const SizedBox(width: 8),
                        Flexible(child: label),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [dot, const SizedBox(height: 4), label],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
