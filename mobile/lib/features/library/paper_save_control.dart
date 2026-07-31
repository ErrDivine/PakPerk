import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/library/library_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';

/// Connected control used once above the reader's stage PageView, so Abstract,
/// Introduction, and Connections always observe the same Drift projection.
class PaperSaveControl extends ConsumerStatefulWidget {
  const PaperSaveControl({required this.paper, super.key});

  final PaperSummary paper;

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
    final value = ref.watch(paperSavedStateProvider(widget.paper.paperId));
    final state = value.value ?? const LibrarySavedState.notSaved();
    return PaperSaveControlView(
      state: state,
      busy: _committing || value.isLoading,
      onPressed: () => unawaited(_toggle(state)),
    );
  }

  Future<void> _toggle(LibrarySavedState current) async {
    if (_committing) return;
    var scope = ref.read(libraryDisplayScopeProvider);
    if (scope == null) {
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

    setState(() => _committing = true);
    final saved = !current.saved;
    try {
      await ref
          .read(libraryRepositoryProvider)
          .setSaved(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            paperId: widget.paper.paperId,
            saved: saved,
            paper: widget.paper,
          );
      if (!mounted) return;
      await HapticFeedback.selectionClick();
      if (!mounted) return;
      if (MediaQuery.supportsAnnounceOf(context)) {
        await SemanticsService.sendAnnouncement(
          View.of(context),
          saved ? 'Saved to To Read' : 'Removed from To Read',
          Directionality.of(context),
        );
      }
      unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This save could not be stored on this device.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _committing = false);
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
    super.key,
  });

  final LibrarySavedState state;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final saved = state.saved;
    final actionLabel = saved ? 'Remove from To Read' : 'Save to To Read';
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Semantics(
        container: true,
        excludeSemantics: true,
        button: true,
        enabled: onPressed != null && !busy,
        label: actionLabel,
        value: state.syncPending
            ? 'Waiting to sync'
            : state.issue?.message ?? (saved ? 'Saved' : 'Not saved'),
        child: InkWell(
          key: const ValueKey('paper-save-control'),
          onTap: busy ? null : onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedSwitcher(
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
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      saved ? 'Saved to To Read' : 'Save to To Read',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
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
  }
}
