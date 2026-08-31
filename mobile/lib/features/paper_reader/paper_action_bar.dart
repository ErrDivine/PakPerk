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
          saveSourceKind: saveSourceKind,
          interactionContext: interactionContext,
        ),
      if (features.comments) PaperCommentsControl(paper: paper, compact: true),
      if (contextualAction != null) contextualAction!,
      _PaperArxivControl(paper: paper, interactionContext: interactionContext),
    ];

    return Material(
      key: const ValueKey('paper-action-bar'),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < actions.length; index++) ...[
                if (index > 0)
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                Expanded(
                  child: FocusTraversalOrder(
                    order: NumericFocusOrder(index.toDouble()),
                    child: actions[index],
                  ),
                ),
              ],
            ],
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
      label: 'Open on arXiv',
      child: Tooltip(
        message: 'Open on arXiv',
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('paper-arxiv-control'),
          onTap: () => unawaited(_open(context, ref)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.open_in_new, size: 22),
                  SizedBox(height: 4),
                  Text(
                    'arXiv',
                    key: ValueKey('paper-arxiv-label'),
                    textAlign: TextAlign.center,
                  ),
                ],
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
        const SnackBar(content: Text('Could not open the arXiv record.')),
      );
    }
  }
}
