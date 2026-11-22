import '../../l10n/ui.dart';
import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../core/models/paper.dart';

final class PaperCommentsControl extends StatelessWidget {
  const PaperCommentsControl({
    required this.paper,
    this.compact = false,
    super.key,
  });

  final PaperSummary paper;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final action = Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: uiString(context, 'Open paper discussions'),
      child: Tooltip(
        message: uiString(context, 'Open paper discussions'),
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('paper-comments-control'),
          onTap: () => openPaperComments(
            context,
            PaperCommentsRouteData(
              paperId: paper.paperId,
              paperTitle: paper.title,
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: compact ? 48 : 0,
              minHeight: 48,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 16,
                vertical: compact ? 12 : 6,
              ),
              child: compact
                  ? const Icon(
                      Icons.forum_outlined,
                      size: 22,
                      key: ValueKey('paper-comments-label'),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.forum_outlined, size: 22),
                        SizedBox(width: 8),
                        Flexible(
                          child: UiText(
                            'Paper discussions',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    if (compact) return action;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: action,
    );
  }
}
