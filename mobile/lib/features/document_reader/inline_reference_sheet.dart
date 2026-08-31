import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';

/// Opens a bounded, non-navigating context view for an inline reference.
///
/// `targetId` is parser-owned data, so external-looking values are never
/// launched from here. The only navigation escapes to the paper's trusted
/// original-source path at the block's known page.
Future<bool?> showInlineReferenceContextSheet({
  required BuildContext context,
  required DocumentBlock block,
  required DocumentInlineSpan reference,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    isScrollControlled: true,
    showDragHandle: false,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) =>
        _InlineReferenceContext(block: block, reference: reference),
  );
}

class _InlineReferenceContext extends StatelessWidget {
  const _InlineReferenceContext({required this.block, required this.reference});

  final DocumentBlock block;
  final DocumentInlineSpan reference;

  @override
  Widget build(BuildContext context) {
    final title = _kindLabel(reference.kind);
    final marker = reference.label?.trim();
    final target = reference.targetId?.trim();
    final excerpt = _scalarPrefix(block.text, 600);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: '$title context',
      explicitChildNodes: true,
      child: SafeArea(
        top: true,
        bottom: false,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .88,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('inline-reference-close'),
                        onPressed: () => Navigator.of(context).pop(false),
                        tooltip: 'Close reference context',
                        constraints: const BoxConstraints.tightFor(
                          width: PakPerkSizes.minimumInteractive,
                          height: PakPerkSizes.minimumInteractive,
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (marker?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    Text('Marker: $marker'),
                  ],
                  if (target?.isNotEmpty == true &&
                      reference.kind != 'external_resource') ...[
                    const SizedBox(height: 8),
                    Text(
                      'Resolved locator: $target',
                      key: const ValueKey('inline-reference-target'),
                    ),
                  ],
                  if (reference.kind == 'external_resource') ...[
                    const SizedBox(height: 8),
                    const Text(
                      'This extracted external target is not opened directly. Verify it in the original paper.',
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    block.sectionLabel,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(excerpt),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: FilledButton.icon(
                      key: const ValueKey('inline-reference-original'),
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Verify in original'),
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

String _kindLabel(String kind) => switch (kind) {
  'bibliography_reference' => 'Bibliography reference',
  'figure_reference' => 'Figure reference',
  'table_reference' => 'Table reference',
  'equation_reference' => 'Equation reference',
  'footnote' => 'Footnote',
  'term' => 'Term reference',
  'symbol' => 'Symbol reference',
  'external_resource' => 'External resource',
  _ => 'Source reference',
};

String _scalarPrefix(String value, int maximum) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= maximum) return value;
  return '${String.fromCharCodes(runes.take(maximum))}…';
}
