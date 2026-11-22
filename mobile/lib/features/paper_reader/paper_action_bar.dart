import '../../l10n/ui.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/paper.dart';
import '../../core/library/library_models.dart';
import '../../app/discovery_providers.dart';
import '../../core/interactions/interaction_models.dart';
import '../../core/providers.dart';
import '../comments/paper_comments_control.dart';
import '../document_reader/reader_library_control.dart';

/// Paper-scoped actions that stay available while the reader changes stages.
class PaperActionBar extends ConsumerWidget {
  const PaperActionBar({
    required this.paper,
    this.contextualAction,
    this.saveSourceKind,
    this.interactionContext,
    super.key,
  });

  final PaperSummary paper;
  final Widget? contextualAction;
  final LibrarySaveSourceKind? saveSourceKind;
  final PaperInteractionContext? interactionContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final features = ref.watch(featureFlagsProvider);
    final actions = <Widget>[
      if (features.library)
        ReaderLibraryControl(
          paper: paper,
          iconOnly: true,
          saveSourceKind: saveSourceKind,
          interactionContext: interactionContext,
        ),
      if (features.comments) PaperCommentsControl(paper: paper, compact: true),
      if (contextualAction != null) contextualAction!,
      _PaperArxivControl(paper: paper, interactionContext: interactionContext),
    ];

    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      widthFactor: 1,
      child: Material(
        key: const ValueKey('paper-action-bar'),
        color: colors.surfaceContainerLow,
        shape: StadiumBorder(side: BorderSide(color: colors.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < actions.length; index++)
                    FocusTraversalOrder(
                      order: NumericFocusOrder(index.toDouble()),
                      child: actions[index],
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

class _PaperArxivControl extends ConsumerWidget {
  const _PaperArxivControl({
    required this.paper,
    required this.interactionContext,
  });

  final PaperSummary paper;
  final PaperInteractionContext? interactionContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: uiString(context, 'Open on arXiv'),
      child: Tooltip(
        message: 'Open on arXiv',
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('paper-arxiv-control'),
          onTap: () => unawaited(_open(context, ref)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: UiText(
                  'arXiv',
                  key: const ValueKey('paper-arxiv-label'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final uri = paper.canonicalAbsUri;
    final opened =
        uri != null && await ref.read(externalLinkOpenerProvider).open(uri);
    if (opened) {
      ref
          .read(interactionEventBatcherProvider)
          .record(
            eventType: PaperInteractionEventType.openedOriginal,
            paperId: paper.paperId,
            feedMode: interactionContext?.feedMode,
            batchId: interactionContext?.batchId,
            position: interactionContext?.position,
          );
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: UiText('Could not open the arXiv record.')),
      );
    }
  }
}
