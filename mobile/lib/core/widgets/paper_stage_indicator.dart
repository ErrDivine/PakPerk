import 'package:flutter/material.dart';

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
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Paper views',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            for (final stage in PaperStage.values)
              Expanded(
                child: Semantics(
                  selected: currentStage == stage,
                  button: true,
                  label:
                      '${stage.label} view, ${currentStage == stage ? 'selected' : 'not selected'}',
                  child: ExcludeSemantics(
                    child: InkWell(
                      key: ValueKey('stage-${stage.name}'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onSelected(stage),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: currentStage == stage ? 10 : 8,
                                height: currentStage == stage ? 10 : 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: currentStage == stage
                                      ? colors.primary
                                      : colors.outlineVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  stage.label,
                                  maxLines: 1,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
