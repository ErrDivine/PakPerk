import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/comments_providers.dart';
import '../../app/router.dart';
import '../../core/comments/comment_controllers.dart';
import '../../core/comments/comment_models.dart';

final class MyCommentsScreen extends ConsumerWidget {
  const MyCommentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(verifiedCommentScopeProvider);
    if (scope == null) {
      final viewer = ref.watch(commentViewerScopeProvider);
      final readOnlyStatus = ref.watch(commentReadOnlyAccountStatusProvider);
      return Scaffold(
        appBar: AppBar(title: const Text('My comments')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: viewer.authenticated
                ? _UnavailableAccountComments(readOnly: readOnlyStatus != null)
                : FilledButton.icon(
                    onPressed: () => context.push<void>(PakPerkRoutes.auth),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in to view your comments'),
                  ),
          ),
        ),
      );
    }
    final state = ref.watch(myCommentsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My comments')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(myCommentsControllerProvider.notifier).load(),
        child: _body(context, ref, state),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, MyCommentsState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 96),
          const Icon(Icons.comment_outlined, size: 48),
          const SizedBox(height: 12),
          Center(
            child: Text(
              state.errorMessage ??
                  'Your published and under-review comments appear here.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: state.items.length + (state.nextCursor == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == state.items.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: TextButton(
                onPressed: state.loadingMore
                    ? null
                    : () => ref
                          .read(myCommentsControllerProvider.notifier)
                          .load(more: true),
                child: Text(state.loadingMore ? 'Loading…' : 'Load more'),
              ),
            ),
          );
        }
        final PaperComment comment = state.items[index];
        return Card(
          child: ListTile(
            isThreeLine: true,
            title: Text(
              comment.body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_statusLabel(comment)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push<void>(
              PakPerkRoutes.paperComments(comment.paperId),
            ),
          ),
        );
      },
    );
  }
}

class _UnavailableAccountComments extends StatelessWidget {
  const _UnavailableAccountComments({required this.readOnly});

  final bool readOnly;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.lock_outline, size: 48),
      const SizedBox(height: 12),
      Text(
        readOnly ? 'Account comments are read-only' : 'Account is offline',
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text(
        readOnly
            ? 'Public comments remain readable from each paper, but My '
                  'Comments is unavailable for this account.'
            : 'Reconnect and verify this saved session to load My Comments. '
                  'Paper-level cached comments and drafts remain on this device.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

String _statusLabel(PaperComment comment) => switch (comment.status) {
  CommentStatus.pendingReview => 'Under review · only you can see this',
  CommentStatus.published => comment.editedAt == null ? 'Published' : 'Edited',
  CommentStatus.hidden => 'Hidden by moderation',
  CommentStatus.deleted => 'Deleted',
};
