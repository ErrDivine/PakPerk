import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/comments_providers.dart';
import '../../app/router.dart';
import '../../core/comments/comment_models.dart';
import '../../core/comments/comment_controllers.dart';
import '../../core/comments/comment_repository.dart';
import '../../core/providers.dart';

final class CommentsScreen extends ConsumerStatefulWidget {
  const CommentsScreen({
    required this.paperId,
    required this.paperTitle,
    required this.onClose,
    super.key,
  });

  final String paperId;
  final String paperTitle;
  final VoidCallback onClose;

  @override
  ConsumerState<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends ConsumerState<CommentsScreen> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(commentThreadProvider(widget.paperId));
    final viewer = ref.watch(commentViewerScopeProvider);
    final canCompose = ref.watch(commentComposerEligibleProvider);
    final offline = ref
        .watch(networkOfflineProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);

    ref.listen<CommentThreadState>(commentThreadProvider(widget.paperId), (
      previous,
      next,
    ) {
      if (next.draft.isEmpty && _composer.text.isNotEmpty && !next.sending) {
        _composer.clear();
      } else if (_composer.text.isEmpty && next.draft.isNotEmpty) {
        _composer.value = TextEditingValue(
          text: next.draft,
          selection: TextSelection.collapsed(offset: next.draft.length),
        );
      }
    });
    ref.listen<CommentUiIntent?>(commentUiIntentProvider, (_, intent) {
      if (intent == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resumeIntent();
      });
    });

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight:
            80 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
        leading: IconButton(
          tooltip: 'Close paper discussions',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.paperTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${state.items.length} ${state.items.length == 1 ? 'comment' : 'comments'}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              if (state.errorMessage case final message?)
                _ThreadNotice(
                  message: message,
                  onDismiss: ref
                      .read(commentThreadProvider(widget.paperId).notifier)
                      .dismissError,
                ),
              Expanded(child: _buildList(state)),
              const Divider(height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .55,
                ),
                child: viewer.authenticated && canCompose
                    ? _buildComposer(state, offline)
                    : _buildSignInOrSetup(viewer),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(CommentThreadState state) {
    if (state.loadingInitial && state.items.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'Loading paper comments',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (state.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: ref
            .read(commentThreadProvider(widget.paperId).notifier)
            .refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 96),
            Icon(Icons.forum_outlined, size: 48),
            SizedBox(height: 12),
            Center(child: Text('No published comments yet.')),
            SizedBox(height: 6),
            Center(child: Text('Start a thoughtful paper discussion.')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: ref
          .read(commentThreadProvider(widget.paperId).notifier)
          .refresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount:
            state.items.length +
            (state.nextCursor != null || state.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == state.items.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: state.loadingMore
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: ref
                            .read(
                              commentThreadProvider(widget.paperId).notifier,
                            )
                            .loadMore,
                        child: const Text('Load more comments'),
                      ),
              ),
            );
          }
          return _CommentCard(
            comment: state.items[index],
            currentAccountId: ref
                .watch(verifiedCommentScopeProvider)
                ?.accountId,
            onEdit: () => _edit(state.items[index]),
            onDelete: () => _delete(state.items[index]),
            onReport: () => _report(state.items[index]),
            onBlock: () => _block(state.items[index].author),
          );
        },
      ),
    );
  }

  Widget _buildComposer(CommentThreadState state, bool offline) {
    final disabled = state.sending || state.creationDisabled || offline;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.creationDisabled)
              const Text(
                'New comments are paused. Existing discussions remain available.',
              )
            else if (offline)
              const Text('Offline · your draft stays on this device.'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('comment-composer'),
                    controller: _composer,
                    focusNode: _composerFocus,
                    enabled: !state.sending,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 2000,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      labelText: 'Add a public comment',
                      hintText: 'Discuss the paper…',
                    ),
                    onChanged: (value) => unawaited(
                      ref
                          .read(commentThreadProvider(widget.paperId).notifier)
                          .saveDraft(value),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey('comment-send'),
                  tooltip: offline
                      ? 'Reconnect to send comment'
                      : 'Send public comment',
                  onPressed: disabled ? null : _send,
                  icon: state.sending
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignInOrSetup(CommentViewerScope viewer) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.icon(
        key: const ValueKey('comments-sign-in-cta'),
        onPressed: () =>
            _authenticateFor(AppPendingActionKind.openComposer, widget.paperId),
        icon: Icon(viewer.authenticated ? Icons.rule : Icons.login),
        label: Text(
          viewer.authenticated
              ? 'Complete profile and community acceptance'
              : 'Sign in to join the discussion',
        ),
      ),
    );
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    final comment = await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .send();
    if (!mounted || comment == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          comment.underReview
              ? 'Comment accepted and privately held for review.'
              : 'Comment published.',
        ),
      ),
    );
  }

  Future<void> _edit(PaperComment comment) async {
    final controller = TextEditingController(text: comment.body);
    final body = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit comment'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          maxLength: 2000,
          decoration: const InputDecoration(labelText: 'Public comment'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || body == null || validateCommentBody(body) != null) return;
    await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .edit(comment, body);
  }

  Future<void> _delete(PaperComment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text('This removes the public comment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(commentThreadProvider(widget.paperId).notifier)
          .delete(comment);
    }
  }

  Future<void> _report(PaperComment comment) async {
    if (ref.read(verifiedCommentScopeProvider) == null) {
      await _authenticateFor(AppPendingActionKind.reportComment, comment.id);
      return;
    }
    final selection =
        await showDialog<({CommentReportReason reason, String? detail})>(
          context: context,
          builder: (_) => const _ReportDialog(),
        );
    if (!mounted || selection == null) return;
    final sent = await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .report(
          commentId: comment.id,
          reason: selection.reason,
          detail: selection.detail,
        );
    if (mounted && sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report received. Thank you.')),
      );
    }
  }

  Future<void> _block(CommentAuthor author) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Block ${author.visibleName}?'),
        content: const Text(
          'Their comments will disappear immediately. The block syncs across your devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block user'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (ref.read(verifiedCommentScopeProvider) == null) {
      await _authenticateFor(AppPendingActionKind.blockUser, author.id);
      return;
    }
    await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .block(author);
  }

  Future<void> _authenticateFor(
    AppPendingActionKind kind,
    String targetId,
  ) async {
    if (!ref.read(commentViewerScopeProvider).authenticated) {
      final continueToSignIn = await _showSignInRationale(kind);
      if (!mounted || !continueToSignIn) return;
    }
    ref
        .read(pendingAuthenticatedActionProvider.notifier)
        .replace(AppPendingAuthenticatedAction(kind: kind, targetId: targetId));
    await context.push<void>(PakPerkRoutes.auth);
  }

  Future<bool> _showSignInRationale(AppPendingActionKind kind) async {
    final (title, explanation) = switch (kind) {
      AppPendingActionKind.openComposer => (
        'Join the paper discussion',
        'Sign in to post a public plain-text comment. Reading comments stays '
            'available without an account, and drafts are never sent '
            'automatically.',
      ),
      AppPendingActionKind.reportComment => (
        'Report safely',
        'Sign in so Pakperk can record one durable report without exposing '
            'your identity to other readers.',
      ),
      AppPendingActionKind.blockUser => (
        'Hide this author',
        'Sign in to keep this author hidden across your devices.',
      ),
      AppPendingActionKind.savePaper => ('Sign in', 'Sign in to continue.'),
    };
    return await showModalBottomSheet<bool>(
          context: context,
          useSafeArea: true,
          showDragHandle: true,
          builder: (sheetContext) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(explanation),
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('comments-sign-in-continue'),
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Text('Continue to sign in'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext, false),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _resumeIntent() async {
    final taken = ref.read(commentUiIntentProvider.notifier).take();
    if (taken == null) return;
    switch (taken.kind) {
      case CommentUiIntentKind.openComposer:
        if (taken.targetId == widget.paperId) _composerFocus.requestFocus();
        return;
      case CommentUiIntentKind.reportComment:
        final comment = ref
            .read(commentThreadProvider(widget.paperId).notifier)
            .commentById(taken.targetId);
        if (comment != null) await _report(comment);
        return;
      case CommentUiIntentKind.blockUser:
        final comment = ref
            .read(commentThreadProvider(widget.paperId))
            .items
            .where((item) => item.author.id == taken.targetId)
            .firstOrNull;
        if (comment != null) {
          await ref
              .read(commentThreadProvider(widget.paperId).notifier)
              .block(comment.author);
        }
        return;
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter > 320 ||
        ref.read(commentThreadProvider(widget.paperId)).loadingMore) {
      return;
    }
    unawaited(
      ref.read(commentThreadProvider(widget.paperId).notifier).loadMore(),
    );
  }
}

final class _CommentCard extends StatelessWidget {
  const _CommentCard({
    required this.comment,
    required this.currentAccountId,
    required this.onEdit,
    required this.onDelete,
    required this.onReport,
    required this.onBlock,
  });

  final PaperComment comment;
  final String? currentAccountId;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReport;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final mine = comment.author.id == currentAccountId;
    return Semantics(
      container: true,
      label: comment.underReview ? 'Your comment, under review' : 'Comment',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.author.visibleName,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('comment-actions-${comment.id}'),
                      tooltip: 'Comment actions',
                      onSelected: (value) {
                        switch (value) {
                          case 'edit':
                            onEdit();
                            break;
                          case 'delete':
                            onDelete();
                            break;
                          case 'report':
                            onReport();
                            break;
                          case 'block':
                            onBlock();
                            break;
                        }
                      },
                      itemBuilder: (_) => mine
                          ? const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ]
                          : const [
                              PopupMenuItem(
                                value: 'report',
                                child: Text('Report'),
                              ),
                              PopupMenuItem(
                                value: 'block',
                                child: Text('Block user'),
                              ),
                            ],
                    ),
                  ],
                ),
                if (comment.underReview)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Chip(
                      avatar: Icon(Icons.visibility_off_outlined, size: 16),
                      label: Text('Under review · only you can see this'),
                    ),
                  ),
                const SizedBox(height: 8),
                SelectableText(comment.body),
                const SizedBox(height: 10),
                Text(
                  _commentTimestamp(comment),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ReportDialog extends StatefulWidget {
  const _ReportDialog();

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  CommentReportReason _reason = CommentReportReason.spam;
  final _detail = TextEditingController();

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report comment'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<CommentReportReason>(
              initialValue: _reason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: [
                for (final reason in CommentReportReason.values)
                  DropdownMenuItem(value: reason, child: Text(reason.label)),
              ],
              onChanged: (value) =>
                  setState(() => _reason = value ?? CommentReportReason.spam),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _detail,
              maxLength: 500,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Additional detail (optional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            reason: _reason,
            detail: _detail.text.trim().isEmpty ? null : _detail.text.trim(),
          )),
          child: const Text('Send report'),
        ),
      ],
    );
  }
}

final class _ThreadNotice extends StatelessWidget {
  const _ThreadNotice({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: MaterialBanner(
      content: Text(message),
      actions: [TextButton(onPressed: onDismiss, child: const Text('Dismiss'))],
    ),
  );
}

String _commentTimestamp(PaperComment comment) {
  final edited = comment.editedAt == null ? '' : ' · edited';
  final date = comment.updatedAt.toLocal();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}$edited';
}
