import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../core/models/paper.dart';

final class PaperCommentsControl extends StatelessWidget {
  const PaperCommentsControl({required this.paper, super.key});

  final PaperSummary paper;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
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
          constraints: const BoxConstraints(minHeight: 48),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.forum_outlined, size: 22),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Paper discussions',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
