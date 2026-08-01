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
      label: 'Open paper discussions',
      child: Tooltip(
        message: 'Open paper discussions',
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
            constraints: BoxConstraints(minHeight: compact ? 56 : 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 4 : 16,
                vertical: compact ? 8 : 6,
              ),
              child: compact
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.forum_outlined, size: 22),
                        SizedBox(height: 4),
                        Text(
                          'Comments',
                          key: ValueKey('paper-comments-label'),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.forum_outlined, size: 22),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
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
