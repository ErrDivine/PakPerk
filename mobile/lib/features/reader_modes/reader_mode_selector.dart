import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import 'reader_mode.dart';
import 'reader_mode_controller.dart';

class ReaderModeSelector extends ConsumerWidget {
  const ReaderModeSelector({required this.readerKey, super.key});

  final String readerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(readerDepthModeProvider(readerKey));
    final reducedMotion = platformPrefersReducedMotion(context);
    return Semantics(
      container: true,
      label: 'Reading depth',
      child: SingleChildScrollView(
        key: const ValueKey('reader-mode-selector-scroll'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            for (final mode in ReaderDepthMode.values) ...[
              _ModeButton(
                mode: mode,
                selected: mode == selected,
                reducedMotion: reducedMotion,
                onPressed: () async {
                  if (mode == selected) return;
                  ref
                      .read(readerModeControllerProvider(readerKey))
                      .select(mode);
                  try {
                    await HapticFeedback.selectionClick();
                  } on Object {
                    // Haptics are an optional commit affordance.
                  }
                },
              ),
              if (mode != ReaderDepthMode.values.last) const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.selected,
    required this.reducedMotion,
    required this.onPressed,
  });

  final ReaderDepthMode mode;
  final bool selected;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${mode.label} reading mode',
      child: AnimatedContainer(
        key: ValueKey('reader-mode-${mode.wireValue}'),
        duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.quick,
        curve: PakPerkMotion.emphasized,
        constraints: const BoxConstraints(
          minHeight: PakPerkSizes.minimumInteractive,
          minWidth: 88,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Center(
              child: Text(
                mode.label,
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
