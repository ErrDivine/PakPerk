import 'package:flutter/material.dart';

import '../../core/library/library_action_failure.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

final class LibraryActionFailureCard extends StatelessWidget {
  const LibraryActionFailureCard({
    required this.failure,
    required this.onReview,
    required this.onDismiss,
    this.collectionsAvailable = true,
    super.key,
  });

  final LibraryActionFailure failure;
  final VoidCallback onReview;
  final VoidCallback onDismiss;
  final bool collectionsAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      explicitChildNodes: true,
      child: Card(
        key: ValueKey(('library-action-failure', failure)),
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(PakPerkSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.sync_problem_outlined,
                color: theme.colorScheme.primary,
                semanticLabel: 'Library change needs review',
              ),
              const SizedBox(width: PakPerkSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A Library change wasn’t saved',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: PakPerkSpacing.xxs),
                    Text(_detail(failure, collectionsAvailable)),
                    if (failure.paper case final paper?) ...[
                      const SizedBox(height: PakPerkSpacing.xs),
                      Text(
                        paper.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: PakPerkSpacing.sm),
                    Wrap(
                      spacing: PakPerkSpacing.xs,
                      runSpacing: PakPerkSpacing.xs,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: PakPerkSizes.minimumInteractive,
                          ),
                          child: OutlinedButton(
                            key: ValueKey((
                              'library-action-failure-review',
                              failure,
                            )),
                            onPressed: onReview,
                            child: Text(
                              _reviewLabel(
                                failure.action,
                                collectionsAvailable,
                              ),
                            ),
                          ),
                        ),
                        Semantics(
                          label: 'Dismiss Library change notice',
                          button: true,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: PakPerkSizes.minimumInteractive,
                            ),
                            child: TextButton(
                              key: ValueKey((
                                'library-action-failure-dismiss',
                                failure,
                              )),
                              onPressed: onDismiss,
                              child: const Text('Dismiss'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _detail(LibraryActionFailure failure, bool collectionsAvailable) {
  if (failure.action == LibraryActionFailureAction.signIn) {
    return 'Sign in again, then review the change you wanted to make.';
  }
  if (failure.kind == LibraryActionFailureKind.collectionsEdit &&
      !collectionsAvailable) {
    return 'This lists-and-tags change wasn’t saved. Review your Library '
        'before trying again.';
  }
  return switch (failure.kind) {
    LibraryActionFailureKind.paperAdd =>
      'The paper was not added. Review it and save again if you still want it.',
    LibraryActionFailureKind.paperRemove =>
      'The paper stayed in your Library. Review it before changing it again.',
    LibraryActionFailureKind.paperEdit =>
      'This paper change wasn’t saved. Review the paper in your Library '
          'before trying again.',
    LibraryActionFailureKind.collectionsEdit =>
      'Your last confirmed lists and tags were restored. Review them before '
          'making the change again.',
    LibraryActionFailureKind.localDataIssue =>
      'This change could not be read safely on this device. Review your '
          'Library before trying again.',
    LibraryActionFailureKind.unknown =>
      'Your Library is back to its last confirmed version. Review it before '
          'making the change again.',
  };
}

String _reviewLabel(
  LibraryActionFailureAction action,
  bool collectionsAvailable,
) => switch (action) {
  LibraryActionFailureAction.reviewPaper => 'Review paper',
  LibraryActionFailureAction.reviewItem => 'Review details',
  LibraryActionFailureAction.reviewCollections =>
    collectionsAvailable ? 'Review lists & tags' : 'Review Library',
  LibraryActionFailureAction.signIn => 'Sign in',
  LibraryActionFailureAction.reviewLibrary => 'Review Library',
};
