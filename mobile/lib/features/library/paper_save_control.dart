import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/account/account_profile.dart';
import '../../core/database/library_dao.dart';
import '../../core/library/library_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';

/// Connected control used once above the reader's stage PageView, so Abstract,
/// Introduction, and Connections always observe the same Drift projection.
class PaperSaveControl extends ConsumerStatefulWidget {
  const PaperSaveControl({
    required this.paper,
    this.compact = false,
    super.key,
  });

  final PaperSummary paper;
  final bool compact;

  @override
  ConsumerState<PaperSaveControl> createState() => _PaperSaveControlState();
}

class _PaperSaveControlState extends ConsumerState<PaperSaveControl> {
  bool _committing = false;

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(featureFlagsProvider).library) {
      return const SizedBox.shrink();
    }
    final displayScope = ref.watch(libraryDisplayScopeProvider);
    final value = ref.watch(
      paperSavedStateProvider((
        accountId: displayScope?.accountId,
        authEpoch: displayScope?.authEpoch,
        paperId: widget.paper.paperId,
      )),
    );
    final state = value.value ?? const LibrarySavedState.notSaved();
    final mutationScope = ref.watch(libraryMutationScopeProvider);
    final readOnlyStatus = ref.watch(libraryReadOnlyAccountStatusProvider);
    return PaperSaveControlView(
      state: state,
      busy: _committing || value.isLoading,
      compact: widget.compact,
      disabledReason: readOnlyStatus == null
          ? null
          : _libraryReadOnlyMessage(readOnlyStatus),
      onPressed:
          readOnlyStatus != null ||
              (displayScope != null && mutationScope == null)
          ? null
          : () => unawaited(_toggle(state)),
    );
  }

  Future<void> _toggle(LibrarySavedState current) async {
    if (_committing) return;
    if (ref.read(libraryReadOnlyAccountStatusProvider) != null) return;
    final scope = ref.read(libraryMutationScopeProvider);
    if (scope == null) {
      if (ref.read(libraryDisplayScopeProvider) != null) return;
      final continueToSignIn = await _showSignInRationale();
      if (!mounted || !continueToSignIn) return;
      ref
          .read(pendingAuthenticatedActionProvider.notifier)
          .replace(
            AppPendingAuthenticatedAction(
              kind: AppPendingActionKind.savePaper,
              targetId: widget.paper.paperId,
            ),
          );
      await context.push<void>('/auth');
      return;
    }

    final repository = ref.read(libraryRepositoryProvider);
    final sync = ref.read(librarySyncControllerProvider.notifier);
    final telemetry = ref.read(telemetrySinkProvider);
    setState(() => _committing = true);
    final saved = !current.saved;
    emitTelemetry(telemetry, PakPerkTelemetryEvent.saveRequested, {
      'intent': saved ? 'save' : 'remove',
    });
    try {
      try {
        await repository.setSaved(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          paperId: widget.paper.paperId,
          saved: saved,
          paper: widget.paper,
        );
      } on Object {
        emitTelemetry(telemetry, PakPerkTelemetryEvent.saveFailed, {
          'intent': saved ? 'save' : 'remove',
          'failure_code': 'local_write',
          'retryable': true,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This save could not be stored on this device.'),
          ),
        );
        return;
      }
      // A successful local write includes the durable outbox operation. Drain
      // it even if navigation disposes this control while the write awaits.
      unawaited(sync.drain());
      if (!mounted) return;
      // Platform feedback is best-effort. It must not delay durable sync or
      // the time-sensitive Undo affordance.
      unawaited(
        _acknowledgeSelection(
          saved ? 'Saved to To Read' : 'Removed from To Read',
        ),
      );
      if (saved) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Removed from To Read'),
            action: SnackBarAction(
              key: const ValueKey('paper-save-undo'),
              label: 'Undo',
              onPressed: () => unawaited(_undoRemoval(scope)),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  Future<void> _undoRemoval(ActiveLibraryScope scope) async {
    if (ref.read(libraryMutationScopeProvider) != scope) return;
    final repository = ref.read(libraryRepositoryProvider);
    final sync = ref.read(librarySyncControllerProvider.notifier);
    try {
      // setSaved always allocates a fresh operation ID. Undo is therefore a
      // new save intent and never rewrites the removal that may already have
      // crossed the network boundary.
      await repository.setSaved(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
        paperId: widget.paper.paperId,
        saved: true,
        paper: widget.paper,
      );
    } on LibraryScopeChanged {
      // A stale Undo must not cross an account or authentication epoch.
      return;
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This paper could not be restored on this device.'),
        ),
      );
      return;
    }
    // Undo is itself a fresh durable operation and must not depend on the
    // originating reader widget remaining mounted.
    unawaited(sync.drain());
    if (!mounted) return;
    await _acknowledgeSelection('Restored to To Read');
  }

  Future<void> _acknowledgeSelection(String announcement) async {
    try {
      await HapticFeedback.selectionClick();
    } on Object {
      // Platform feedback must not turn a durable local mutation into an
      // apparent failure or suppress its Undo affordance.
    }
    if (!mounted || !MediaQuery.supportsAnnounceOf(context)) return;
    try {
      await SemanticsService.sendAnnouncement(
        View.of(context),
        announcement,
        Directionality.of(context),
      );
    } on Object {
      // The visual state and snackbar remain authoritative and accessible.
    }
  }

  Future<bool> _showSignInRationale() async {
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
                Text(
                  'Save across your devices',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sign in to add this paper to your synchronized To Read '
                  'list. Reading stays available without an account.',
                ),
                const SizedBox(height: 20),
                FilledButton(
                  key: const ValueKey('save-sign-in-continue'),
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: const Text('Continue to sign in'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }
}

/// Compact shared reader action. The connected wrapper supplies the one Drift
/// saved-state stream; this view contains no independent optimistic state.
class PaperSaveControlView extends StatelessWidget {
  const PaperSaveControlView({
    required this.state,
    required this.onPressed,
    this.busy = false,
    this.compact = false,
    this.disabledReason,
    super.key,
  });

  final LibrarySavedState state;
  final VoidCallback? onPressed;
  final bool busy;
  final bool compact;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final saved = state.saved;
    final actionLabel = saved ? 'Remove from To Read' : 'Save to To Read';
    final colorScheme = Theme.of(context).colorScheme;
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      child: busy || state.syncPending
          ? SizedBox.square(
              key: const ValueKey('save-sync-pending'),
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            )
          : Icon(
              saved ? Icons.bookmark : Icons.bookmark_outline,
              key: ValueKey(saved ? 'saved' : 'not-saved'),
              size: 22,
              color: state.issue == null
                  ? colorScheme.primary
                  : colorScheme.error,
            ),
    );
    final action = Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      enabled: onPressed != null && !busy,
      label: actionLabel,
      value:
          disabledReason ??
          (state.syncPending
              ? 'Waiting to sync'
              : state.issue?.message ?? (saved ? 'Saved' : 'Not saved')),
      child: Tooltip(
        message: disabledReason ?? actionLabel,
        excludeFromSemantics: true,
        child: InkWell(
          key: const ValueKey('paper-save-control'),
          onTap: busy ? null : onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 56 : 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 4 : 16,
                vertical: compact ? 8 : 6,
              ),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            icon,
                            if (state.issue != null) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.error_outline,
                                size: 20,
                                color: colorScheme.error,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          saved ? 'Saved' : 'Save',
                          key: const ValueKey('paper-save-label'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: state.issue == null
                                    ? colorScheme.onSurface
                                    : colorScheme.error,
                              ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        icon,
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            saved ? 'Saved to To Read' : 'Save to To Read',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: state.issue == null
                                      ? colorScheme.onSurface
                                      : colorScheme.error,
                                ),
                          ),
                        ),
                        if (state.issue != null) ...[
                          const SizedBox(width: 8),
                          Tooltip(
                            message: state.issue!.message,
                            child: Icon(
                              Icons.error_outline,
                              size: 20,
                              color: colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    if (compact) return action;
    return Material(color: colorScheme.surfaceContainerLow, child: action);
  }
}

String _libraryReadOnlyMessage(AccountStatus status) => switch (status) {
  AccountStatus.suspended => 'Account suspended · To Read is read-only',
  AccountStatus.deletionPending =>
    'Account deletion pending · To Read is read-only',
  AccountStatus.deleted => 'Account deleted · To Read is read-only',
  AccountStatus.active => 'To Read is read-only',
};
