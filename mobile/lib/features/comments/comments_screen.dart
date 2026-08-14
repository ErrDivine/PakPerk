import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/comments_providers.dart';
import '../../app/router.dart';
import '../../core/account/account_profile.dart';
import '../../core/comments/comment_models.dart';
import '../../core/comments/comment_controllers.dart';
import '../../core/comments/comment_repository.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';

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
  bool _intentResumeScheduled = false;
  bool _draftHydrationScheduled = false;
  String? _composerScopeIdentity;
  int _draftHydrationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      emitTelemetry(
        ref.read(telemetrySinkProvider),
        PakPerkTelemetryEvent.commentSheetOpened,
        {
          'viewer': ref.read(commentViewerScopeProvider).authenticated
              ? 'authenticated'
              : 'guest',
        },
      );
    });
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
    final viewer = ref.watch(commentViewerScopeProvider);
    final composerScopeIdentity = _localViewerIdentity(
      paperId: widget.paperId,
      viewer: viewer,
    );
    _synchronizeComposerScope(composerScopeIdentity);
    final state = ref.watch(commentThreadProvider(widget.paperId));
    final canCompose = ref.watch(commentComposerEligibleProvider);
    final readOnlyStatus = ref.watch(commentReadOnlyAccountStatusProvider);
    final offline =
        ref.watch(authSessionOfflineUnknownProvider) ||
        ref
            .watch(networkOfflineProvider)
            .maybeWhen(data: (value) => value, orElse: () => false);
    final commentCountLabel = _knownCommentCountLabel(state);
    _hydrateComposerFromLoadedDraft(state);

    ref.listen<CommentThreadState>(commentThreadProvider(widget.paperId), (
      previous,
      next,
    ) {
      if (_composerScopeIdentity != composerScopeIdentity) return;
      if (next.draftInputIssue == null &&
          next.draft.isEmpty &&
          _composer.text.isNotEmpty &&
          !next.sending) {
        _composer.clear();
      } else if (_composer.text.isEmpty && next.draft.isNotEmpty) {
        _composer.value = TextEditingValue(
          text: next.draft,
          selection: TextSelection.collapsed(offset: next.draft.length),
        );
      }
      if (next.initialLoadSettled &&
          ref.read(commentUiIntentProvider) != null) {
        _scheduleResumeIntent();
      }
    });
    ref.listen<CommentUiIntent?>(commentUiIntentProvider, (_, intent) {
      if (intent == null) return;
      _scheduleResumeIntent();
    });
    // The executor can publish while this route is covered by the auth route.
    // A rebuilt screen must also observe that already-present one-shot value;
    // Riverpod listeners intentionally do not fire for prior state by default.
    if (state.initialLoadSettled && ref.read(commentUiIntentProvider) != null) {
      _scheduleResumeIntent();
    }

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
            if (commentCountLabel != null)
              Text(
                commentCountLabel,
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
              Expanded(
                child: _buildList(
                  state,
                  currentAccountId: viewer.remotelyVerified
                      ? viewer.accountId
                      : null,
                  actionsEnabled:
                      readOnlyStatus == null &&
                      !offline &&
                      (!viewer.authenticated || viewer.remotelyVerified),
                  cacheOnly: viewer.cacheOnly,
                  accountReadOnly: readOnlyStatus != null,
                ),
              ),
              const Divider(height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .55,
                ),
                child: viewer.authenticated && canCompose
                    ? _buildComposer(state, offline: offline)
                    : readOnlyStatus != null
                    ? _buildReadOnlyAccount(readOnlyStatus)
                    : viewer.authenticated && !viewer.remotelyVerified
                    ? _buildComposer(
                        state,
                        offline: offline,
                        draftOnlyMessage: offline
                            ? 'Offline · your draft stays on this device.'
                            : 'Account verification unavailable · your draft '
                                  'stays on this device.',
                      )
                    : _buildSignInOrSetup(viewer),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(
    CommentThreadState state, {
    required String? currentAccountId,
    required bool actionsEnabled,
    required bool cacheOnly,
    required bool accountReadOnly,
  }) {
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
        onRefresh: _refreshComments,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 96),
            const Icon(Icons.forum_outlined, size: 48),
            const SizedBox(height: 12),
            Center(
              child: Text(
                cacheOnly
                    ? 'No saved comments are available.'
                    : 'No published comments yet.',
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                accountReadOnly
                    ? 'This account is read-only.'
                    : cacheOnly
                    ? 'Reconnect to refresh the paper discussion.'
                    : 'Start a thoughtful paper discussion.',
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshComments,
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
            currentAccountId: currentAccountId,
            actionsEnabled: actionsEnabled,
            onEdit: () => _edit(state.items[index]),
            onDelete: () => _delete(state.items[index]),
            onReportComment: () => _reportComment(state.items[index]),
            onReportUser: () => _reportUser(state.items[index].author),
            onBlock: () => _block(state.items[index].author),
          );
        },
      ),
    );
  }

  Widget _buildComposer(
    CommentThreadState state, {
    required bool offline,
    String? draftOnlyMessage,
  }) {
    final disabled =
        state.sending ||
        state.draftValidationPending ||
        state.draftInputIssue != null ||
        state.draft.isEmpty ||
        state.creationDisabled ||
        offline ||
        draftOnlyMessage != null;
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
            else if (draftOnlyMessage != null)
              Text(draftOnlyMessage)
            else if (offline)
              const Text('Offline · your draft stays on this device.'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const ValueKey('comment-composer'),
                        controller: _composer,
                        focusNode: _composerFocus,
                        enabled: !state.sending,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          labelText: 'Add a public comment',
                          hintText: 'Discuss the paper…',
                        ),
                        onChanged: (value) => unawaited(
                          ref
                              .read(
                                commentThreadProvider(widget.paperId).notifier,
                              )
                              .saveDraft(value),
                        ),
                      ),
                      _CommentLengthCounter(
                        controller: _composer,
                        onValidation: (input, issue) {
                          if (!mounted || _composer.text != input) return;
                          ref
                              .read(
                                commentThreadProvider(widget.paperId).notifier,
                              )
                              .completeDraftValidation(
                                body: input,
                                issue: issue,
                              );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey('comment-send'),
                  tooltip: state.draftInputIssue != null
                      ? 'Fix comment text before sending'
                      : state.draftValidationPending
                      ? 'Checking comment text'
                      : offline
                      ? 'Reconnect to send comment'
                      : draftOnlyMessage != null
                      ? 'Wait for account verification to send comment'
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

  Widget _buildReadOnlyAccount(AccountStatus status) {
    final message = switch (status) {
      AccountStatus.suspended =>
        'Account suspended · public comments remain readable, but posting, '
            'editing, reporting, and blocking are unavailable.',
      AccountStatus.deletionPending =>
        'Account deletion is pending · comments are read-only.',
      AccountStatus.deleted =>
        'This account is deleted · comments are read-only.',
      AccountStatus.active => 'Comments are read-only for this account.',
    };
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        key: const ValueKey('comments-account-read-only'),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.lock_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    final comment = await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .send();
    if (!mounted) return;
    if (comment == null) {
      emitTelemetry(
        ref.read(telemetrySinkProvider),
        PakPerkTelemetryEvent.commentRejected,
        const {'failure_code': 'not_accepted', 'retryable': true},
      );
      return;
    }
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      comment.underReview
          ? PakPerkTelemetryEvent.commentPending
          : PakPerkTelemetryEvent.commentCreated,
      {'visibility': comment.underReview ? 'private_review' : 'published'},
    );
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
    final actionScope = _verifiedActionScope();
    if (actionScope == null) return;
    final body = await showDialog<String>(
      context: context,
      builder: (_) => _EditCommentDialog(initialBody: comment.body),
    );
    if (!_actionScopeIsCurrent(actionScope) || body == null) return;
    await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .edit(comment, body);
  }

  Future<void> _delete(PaperComment comment) async {
    final actionScope = _verifiedActionScope();
    if (actionScope == null) return;
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
    if (confirmed == true && _actionScopeIsCurrent(actionScope)) {
      await ref
          .read(commentThreadProvider(widget.paperId).notifier)
          .delete(comment);
    }
  }

  Future<void> _reportComment(PaperComment comment) async {
    final actionScope = _verifiedActionScope();
    if (actionScope == null) {
      await _authenticateFor(AppPendingActionKind.reportComment, comment.id);
      return;
    }
    final selection =
        await showDialog<({CommentReportReason reason, String? detail})>(
          context: context,
          builder: (_) => const _ReportDialog(title: 'Report comment'),
        );
    if (selection == null || !_actionScopeIsCurrent(actionScope)) return;
    final sent = await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .report(
          commentId: comment.id,
          reason: selection.reason,
          detail: selection.detail,
        );
    if (mounted && sent) {
      emitTelemetry(
        ref.read(telemetrySinkProvider),
        PakPerkTelemetryEvent.commentReported,
        const {'outcome': 'accepted'},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report received. Thank you.')),
      );
    }
  }

  Future<void> _reportUser(CommentAuthor author) async {
    final actionScope = _verifiedActionScope();
    if (actionScope == null) {
      await _authenticateFor(AppPendingActionKind.reportUser, author.id);
      return;
    }
    final selection =
        await showDialog<({CommentReportReason reason, String? detail})>(
          context: context,
          builder: (_) => _ReportDialog(title: 'Report ${author.visibleName}'),
        );
    if (selection == null || !_actionScopeIsCurrent(actionScope)) return;
    final sent = await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .reportUser(
          userId: author.id,
          reason: selection.reason,
          detail: selection.detail,
        );
    if (mounted && sent) {
      emitTelemetry(
        ref.read(telemetrySinkProvider),
        PakPerkTelemetryEvent.userReported,
        const {'outcome': 'accepted'},
      );
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('User report received. No block was added.'),
        ),
      );
    }
  }

  Future<void> _block(CommentAuthor author) async {
    final actionScope = _verifiedActionScope();
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
    if (confirmed != true ||
        !_actionScopeIsCurrent(actionScope, allowUnverified: true)) {
      return;
    }
    if (actionScope == null) {
      await _authenticateFor(AppPendingActionKind.blockUser, author.id);
      return;
    }
    await ref
        .read(commentThreadProvider(widget.paperId).notifier)
        .block(author);
  }

  VerifiedCommentScope? _verifiedActionScope() {
    final scope = ref.read(verifiedCommentScopeProvider);
    final viewer = ref.read(commentViewerScopeProvider);
    if (scope == null ||
        !viewer.remotelyVerified ||
        viewer.accountId != scope.accountId ||
        viewer.authEpoch != scope.authEpoch) {
      return null;
    }
    return scope;
  }

  bool _actionScopeIsCurrent(
    VerifiedCommentScope? expected, {
    bool allowUnverified = false,
  }) {
    if (!mounted) return false;
    final current = _verifiedActionScope();
    if (expected == null) {
      return allowUnverified && current == null;
    }
    return current == expected;
  }

  Future<void> _authenticateFor(
    AppPendingActionKind kind,
    String targetId,
  ) async {
    final viewer = ref.read(commentViewerScopeProvider);
    if (viewer.authenticated && !viewer.remotelyVerified) return;
    if (!viewer.authenticated) {
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
      AppPendingActionKind.reportUser => (
        'Report this user safely',
        'Sign in so Pakperk can record one durable user report. Reporting '
            'does not block the user or hide their comments.',
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
    final intent = ref.read(commentUiIntentProvider);
    if (intent == null) return;
    final intents = ref.read(commentUiIntentProvider.notifier);
    switch (intent.kind) {
      case CommentUiIntentKind.openComposer:
        if (intents.takeIfCurrent(intent) == null) return;
        if (intent.targetId == widget.paperId) {
          _composerFocus.requestFocus();
        } else {
          _showUnavailableIntent(intent.kind);
        }
        return;
      case CommentUiIntentKind.reportComment:
        final comment = await _targetComment(intent, authorTarget: false);
        if (comment == null || !mounted) return;
        if (intents.takeIfCurrent(intent) == null) return;
        await _reportComment(comment);
        return;
      case CommentUiIntentKind.reportUser:
        final comment = await _targetComment(intent, authorTarget: true);
        if (comment == null || !mounted) return;
        if (intents.takeIfCurrent(intent) == null) return;
        await _reportUser(comment.author);
        return;
      case CommentUiIntentKind.blockUser:
        final comment = await _targetComment(intent, authorTarget: true);
        if (comment == null || !mounted) return;
        if (intents.takeIfCurrent(intent) == null) return;
        await ref
            .read(commentThreadProvider(widget.paperId).notifier)
            .block(comment.author);
        return;
    }
  }

  Future<PaperComment?> _targetComment(
    CommentUiIntent intent, {
    required bool authorTarget,
  }) async {
    final provider = commentThreadProvider(widget.paperId);
    var thread = ref.read(provider);
    if (!thread.initialLoadSettled ||
        thread.loadingInitial ||
        thread.refreshing ||
        thread.loadingMore) {
      return null;
    }
    PaperComment? target() => authorTarget
        ? thread.items
              .where((item) => item.author.id == intent.targetId)
              .firstOrNull
        : thread.items.where((item) => item.id == intent.targetId).firstOrNull;
    var comment = target();
    if (comment != null) return comment;

    final cursor = thread.nextCursor;
    final intents = ref.read(commentUiIntentProvider.notifier);
    if (cursor != null && intents.claimTargetPageLoad(intent)) {
      await ref.read(provider.notifier).loadMore();
      if (!mounted || !identical(ref.read(commentUiIntentProvider), intent)) {
        return null;
      }
      thread = ref.read(provider);
      comment = target();
      if (comment != null) return comment;
      if (thread.errorMessage == null) {
        _scheduleResumeIntent();
        return null;
      }
    }

    if (intents.takeIfCurrent(intent) != null && mounted) {
      _showUnavailableIntent(intent.kind);
    }
    return null;
  }

  void _scheduleResumeIntent() {
    if (_intentResumeScheduled) return;
    _intentResumeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _intentResumeScheduled = false;
      if (mounted) unawaited(_resumeIntent());
    });
  }

  void _hydrateComposerFromLoadedDraft(CommentThreadState state) {
    if (_draftHydrationScheduled ||
        _composer.text.isNotEmpty ||
        state.draft.isEmpty) {
      return;
    }
    _draftHydrationScheduled = true;
    final generation = _draftHydrationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _draftHydrationScheduled = false;
      if (!mounted ||
          generation != _draftHydrationGeneration ||
          _composer.text.isNotEmpty) {
        return;
      }
      final draft = ref.read(commentThreadProvider(widget.paperId)).draft;
      if (draft.isEmpty) return;
      _composer.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    });
  }

  void _synchronizeComposerScope(String nextIdentity) {
    if (_composerScopeIdentity == nextIdentity) return;
    final hadScope = _composerScopeIdentity != null;
    _composerScopeIdentity = nextIdentity;
    _draftHydrationGeneration += 1;
    _draftHydrationScheduled = false;
    if (hadScope) _composer.clear();
  }

  String _localViewerIdentity({
    required String paperId,
    required CommentViewerScope viewer,
  }) {
    final accountId = viewer.accountId;
    final viewerIdentity = accountId == null
        ? 'guest'
        : 'account:$accountId:${viewer.authEpoch}';
    return 'paper:$paperId|$viewerIdentity';
  }

  void _showUnavailableIntent(CommentUiIntentKind kind) {
    final message = switch (kind) {
      CommentUiIntentKind.openComposer =>
        'The requested paper discussion is no longer available.',
      CommentUiIntentKind.reportComment =>
        'The comment is no longer available to report.',
      CommentUiIntentKind.reportUser =>
        'The user is no longer available to report.',
      CommentUiIntentKind.blockUser =>
        'The user is no longer available to block.',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _refreshComments() async {
    if (ref.read(authSessionOfflineUnknownProvider)) {
      await ref.read(accountSessionRecoveryProvider).recover();
    }
    if (!mounted) return;
    await ref.read(commentThreadProvider(widget.paperId).notifier).refresh();
  }
}

final class _CommentCard extends StatelessWidget {
  const _CommentCard({
    required this.comment,
    required this.currentAccountId,
    required this.actionsEnabled,
    required this.onEdit,
    required this.onDelete,
    required this.onReportComment,
    required this.onReportUser,
    required this.onBlock,
  });

  final PaperComment comment;
  final String? currentAccountId;
  final bool actionsEnabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReportComment;
  final VoidCallback onReportUser;
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
                    if (actionsEnabled)
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
                            case 'report-comment':
                              onReportComment();
                              break;
                            case 'report-user':
                              onReportUser();
                              break;
                            case 'block':
                              onBlock();
                              break;
                          }
                        },
                        itemBuilder: (_) => mine
                            ? const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ]
                            : const [
                                PopupMenuItem(
                                  value: 'report-comment',
                                  child: Text('Report comment'),
                                ),
                                PopupMenuItem(
                                  value: 'report-user',
                                  child: Text('Report user'),
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

final class _EditCommentDialog extends StatefulWidget {
  const _EditCommentDialog({required this.initialBody});

  final String initialBody;

  @override
  State<_EditCommentDialog> createState() => _EditCommentDialogState();
}

class _EditCommentDialogState extends State<_EditCommentDialog> {
  late final TextEditingController _controller;
  String? _validationError;
  var _validationPending = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialBody);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final analysis = analyzeCommentBody(_controller.text);
    if (analysis.issue case final issue?) {
      setState(() => _validationError = issue);
      return;
    }
    Navigator.pop(context, analysis.canonicalBody);
  }

  void _changed(String value) {
    final rawIssue = validateCommentDraftInput(value);
    setState(() {
      _validationError = rawIssue;
      _validationPending = value.isNotEmpty && rawIssue == null;
    });
  }

  void _validated(String input, String? issue) {
    if (!mounted || _controller.text != input) return;
    setState(() {
      _validationPending = false;
      _validationError = issue;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Edit comment'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: 'Public comment',
            errorText: _validationError,
          ),
          onChanged: _changed,
        ),
        _CommentLengthCounter(
          controller: _controller,
          onValidation: _validated,
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _validationPending || _validationError != null
            ? null
            : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

final class _CommentLengthCounter extends StatefulWidget {
  const _CommentLengthCounter({
    required this.controller,
    required this.onValidation,
  });

  final TextEditingController controller;
  final void Function(String input, String? issue) onValidation;

  @override
  State<_CommentLengthCounter> createState() => _CommentLengthCounterState();
}

class _CommentLengthCounterState extends State<_CommentLengthCounter> {
  static const _backgroundThresholdCodeUnits = 256;
  static const _debounceDuration = Duration(milliseconds: 120);

  Timer? _debounce;
  var _generation = 0;
  var _count = 0;
  String? _inputIssue;
  var _measuring = false;
  var _measurementInFlight = false;
  String? _queuedInput;
  int? _queuedGeneration;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleMeasurement);
    _scheduleMeasurement();
  }

  @override
  void didUpdateWidget(_CommentLengthCounter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_scheduleMeasurement);
    widget.controller.addListener(_scheduleMeasurement);
    _scheduleMeasurement();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_scheduleMeasurement);
    super.dispose();
  }

  void _scheduleMeasurement() {
    _debounce?.cancel();
    final generation = ++_generation;
    final input = widget.controller.text;
    final inputIssue = validateCommentDraftInput(input);
    if (inputIssue != null) {
      _queuedInput = null;
      _queuedGeneration = null;
      setState(() {
        _inputIssue = inputIssue;
        _measuring = false;
      });
      _notifyValidation(input, inputIssue, generation);
      return;
    }
    if (input.length <= _backgroundThresholdCodeUnits) {
      final measurement = measureCommentBody(input);
      _queuedInput = null;
      _queuedGeneration = null;
      setState(() {
        _count = measurement.normalizedScalars;
        _inputIssue = input.isEmpty ? null : measurement.issue;
        _measuring = false;
      });
      _notifyValidation(input, measurement.issue, generation);
      return;
    }
    setState(() {
      _inputIssue = null;
      _measuring = true;
    });
    _debounce = Timer(
      _debounceDuration,
      () => _measureInBackground(input, generation),
    );
  }

  Future<void> _measureInBackground(String input, int generation) async {
    if (_measurementInFlight) {
      _queuedInput = input;
      _queuedGeneration = generation;
      return;
    }
    _measurementInFlight = true;
    try {
      final measurement = await compute(measureCommentBody, input);
      if (!mounted || generation != _generation) return;
      setState(() {
        _count = measurement.normalizedScalars;
        _inputIssue = measurement.issue;
        _measuring = false;
      });
      _notifyValidation(input, measurement.issue, generation);
    } on Object {
      if (!mounted || generation != _generation) return;
      const issue = 'This text cannot be counted safely.';
      setState(() {
        _inputIssue = issue;
        _measuring = false;
      });
      _notifyValidation(input, issue, generation);
    } finally {
      _measurementInFlight = false;
      if (mounted) {
        final queuedInput = _queuedInput;
        final queuedGeneration = _queuedGeneration;
        _queuedInput = null;
        _queuedGeneration = null;
        if (queuedInput != null &&
            queuedGeneration != null &&
            queuedGeneration == _generation) {
          unawaited(_measureInBackground(queuedInput, queuedGeneration));
        }
      }
    }
  }

  void _notifyValidation(String input, String? issue, int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _generation ||
          widget.controller.text != input) {
        return;
      }
      widget.onValidation(input, issue);
    });
  }

  @override
  Widget build(BuildContext context) {
    final overLimit = _inputIssue != null || _count > commentMaximumScalars;
    final color = overLimit
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final visibleText = _inputIssue != null
        ? _inputIssue == commentRawInputTooLargeMessage
              ? 'Too much text · $commentMaximumScalars max'
              : _inputIssue == commentComplexTextMessage
              ? 'Text is too complex · simplify it'
              : _inputIssue ==
                    'Comments are limited to $commentMaximumScalars characters.'
              ? 'Too much text · $commentMaximumScalars max'
              : _inputIssue == 'Comments may contain at most three links.'
              ? 'Too many links · three max'
              : 'Unsupported text · $commentMaximumScalars max'
        : _measuring
        ? 'Counting… / $commentMaximumScalars'
        : '$_count / $commentMaximumScalars';
    final semanticLabel = _inputIssue != null
        ? _inputIssue!
        : _measuring
        ? 'Counting normalized comment characters'
        : '$_count of $commentMaximumScalars normalized comment characters';
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Semantics(
        liveRegion: true,
        label: semanticLabel,
        child: ExcludeSemantics(
          child: Text(
            visibleText,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

final class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.title});

  final String title;

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
      title: Text(widget.title),
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

String? _knownCommentCountLabel(CommentThreadState state) {
  if (state.loadingInitial ||
      state.showingCached ||
      state.nextCursor != null ||
      (state.items.isEmpty && state.errorMessage != null)) {
    return null;
  }
  final count = state.items.length;
  return '$count ${count == 1 ? 'comment' : 'comments'}';
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
