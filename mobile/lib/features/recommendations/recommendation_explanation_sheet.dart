import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/recommendations/recommendation_interaction_models.dart';
import '../../design_system/colors.dart';
import '../../design_system/motion.dart';
import '../../design_system/radii.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import 'recommendation_interaction_controller.dart';

typedef RecommendationFeedbackSubmittedCallback =
    void Function(
      RecommendationFeedbackSelection selection,
      RecommendationFeedbackResult result,
    );

/// Opens an ephemeral, private recommendation explanation task.
///
/// The sheet refuses to open unless its controller has both default-off
/// capability authority and a validated recommendation-only item context.
Future<RecommendationFeedbackResult?> showRecommendationExplanationSheet({
  required BuildContext context,
  required RecommendationInteractionController controller,
  required String paperTitle,
  RecommendationFeedbackSubmittedCallback? onFeedbackSubmitted,
  VoidCallback? onAdjustPersonalization,
  VoidCallback? onOpenPrivacy,
  bool useRootNavigator = true,
}) async {
  if (!controller.controlsAvailable) return null;
  final router = GoRouter.maybeOf(context);
  final reducedMotion = platformPrefersReducedMotion(context);
  if (controller.capabilities.explanations &&
      controller.state.explanationPhase ==
          RecommendationExplanationPhase.idle) {
    unawaited(controller.loadExplanation());
  }
  return showModalBottomSheet<RecommendationFeedbackResult>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    useSafeArea: false,
    showDragHandle: false,
    enableDrag: true,
    isDismissible: true,
    requestFocus: false,
    barrierLabel: 'Dismiss recommendation details',
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (sheetContext) => RecommendationExplanationSheet(
      controller: controller,
      paperTitle: paperTitle,
      onFeedbackSubmitted: onFeedbackSubmitted,
      onAdjustPersonalization:
          onAdjustPersonalization ??
          (router == null ? null : () => router.push('/you/research-profile')),
      onOpenPrivacy:
          onOpenPrivacy ??
          (router == null ? null : () => router.push('/legal/privacy')),
      reducedMotion: reducedMotion,
    ),
  );
}

/// A compact recommendation-only entry point suitable for a paper action row.
///
/// It renders nothing for queue items, absent batch provenance, or disabled
/// capabilities. Callers do not need to duplicate those checks.
class RecommendationInteractionButton extends StatelessWidget {
  const RecommendationInteractionButton({
    required this.controller,
    required this.paperTitle,
    this.onFeedbackSubmitted,
    this.onAdjustPersonalization,
    this.onOpenPrivacy,
    super.key,
  });

  final RecommendationInteractionController controller;
  final String paperTitle;
  final RecommendationFeedbackSubmittedCallback? onFeedbackSubmitted;
  final VoidCallback? onAdjustPersonalization;
  final VoidCallback? onOpenPrivacy;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.controlsAvailable) return const SizedBox.shrink();
        return OutlinedButton.icon(
          key: const ValueKey('recommendation-details-action'),
          onPressed: () => showRecommendationExplanationSheet(
            context: context,
            controller: controller,
            paperTitle: paperTitle,
            onFeedbackSubmitted: onFeedbackSubmitted,
            onAdjustPersonalization: onAdjustPersonalization,
            onOpenPrivacy: onOpenPrivacy,
          ),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Why this paper?'),
        );
      },
    );
  }
}

class RecommendationExplanationSheet extends StatefulWidget {
  const RecommendationExplanationSheet({
    required this.controller,
    required this.paperTitle,
    this.onFeedbackSubmitted,
    this.onAdjustPersonalization,
    this.onOpenPrivacy,
    this.onDismiss,
    this.reducedMotion,
    super.key,
  });

  final RecommendationInteractionController controller;
  final String paperTitle;
  final RecommendationFeedbackSubmittedCallback? onFeedbackSubmitted;
  final VoidCallback? onAdjustPersonalization;
  final VoidCallback? onOpenPrivacy;
  final VoidCallback? onDismiss;
  final bool? reducedMotion;

  @override
  State<RecommendationExplanationSheet> createState() =>
      _RecommendationExplanationSheetState();
}

class _RecommendationExplanationSheetState
    extends State<RecommendationExplanationSheet> {
  RecommendationFeedbackReason? _selectedReason;
  bool _choosingReason = false;
  String? _reportedFeedbackId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChange);
    if (widget.controller.capabilities.explanations &&
        widget.controller.state.explanationPhase ==
            RecommendationExplanationPhase.idle) {
      unawaited(widget.controller.loadExplanation());
    }
  }

  @override
  void didUpdateWidget(RecommendationExplanationSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChange);
    widget.controller.addListener(_handleControllerChange);
    _reportedFeedbackId = null;
    _selectedReason = null;
    _choosingReason = false;
    if (widget.controller.capabilities.explanations &&
        widget.controller.state.explanationPhase ==
            RecommendationExplanationPhase.idle) {
      unawaited(widget.controller.loadExplanation());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChange);
    super.dispose();
  }

  void _handleControllerChange() {
    if (!mounted) return;
    final state = widget.controller.state;
    final result = state.feedbackResult;
    final selection = state.feedbackSelection;
    if (result != null &&
        selection != null &&
        result.feedbackId != _reportedFeedbackId) {
      _reportedFeedbackId = result.feedbackId;
      widget.onFeedbackSubmitted?.call(selection, result);
    }
    setState(() {});
  }

  void _dismiss() {
    if (widget.onDismiss != null) {
      widget.onDismiss!();
    } else {
      Navigator.of(context).pop(widget.controller.state.feedbackResult);
    }
  }

  void _dismissThen(VoidCallback action) {
    _dismiss();
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.controlsAvailable) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    final reducedMotion =
        widget.reducedMotion ?? platformPrefersReducedMotion(context);
    final maximumHeight =
        media.size.height - media.viewPadding.top - media.viewInsets.bottom;

    return AnimatedPadding(
      key: const ValueKey('recommendation-sheet-keyboard-padding'),
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.crossFade,
      curve: PakPerkMotion.enter,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        key: const ValueKey('recommendation-sheet-safe-area'),
        top: false,
        left: true,
        right: true,
        bottom: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: maximumHeight > 0 ? maximumHeight : media.size.height,
          ),
          child: Semantics(
            container: true,
            scopesRoute: true,
            namesRoute: true,
            label: 'Recommendation details modal sheet',
            explicitChildNodes: true,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: PakPerkRadii.sheet,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _AccessibleDragHandle(),
                  _SheetHeader(onClose: _dismiss),
                  Flexible(
                    child: SingleChildScrollView(
                      key: const ValueKey('recommendation-sheet-scroll-view'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(
                        PakPerkSpacing.lg,
                        0,
                        PakPerkSpacing.lg,
                        PakPerkSpacing.xl,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.paperTitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: PakPerkSpacing.lg),
                          _ExplanationSection(controller: widget.controller),
                          if (widget.onAdjustPersonalization != null ||
                              widget.onOpenPrivacy != null) ...[
                            const SizedBox(height: PakPerkSpacing.md),
                            Wrap(
                              spacing: PakPerkSpacing.xs,
                              runSpacing: PakPerkSpacing.xs,
                              children: [
                                if (widget.onAdjustPersonalization != null)
                                  OutlinedButton.icon(
                                    key: const ValueKey(
                                      'recommendation-adjust-personalization',
                                    ),
                                    onPressed: () => _dismissThen(
                                      widget.onAdjustPersonalization!,
                                    ),
                                    icon: const Icon(Icons.tune_rounded),
                                    label: const Text('Adjust recommendations'),
                                  ),
                                if (widget.onOpenPrivacy != null)
                                  TextButton.icon(
                                    key: const ValueKey(
                                      'recommendation-open-privacy',
                                    ),
                                    onPressed: () =>
                                        _dismissThen(widget.onOpenPrivacy!),
                                    icon: const Icon(
                                      Icons.privacy_tip_outlined,
                                    ),
                                    label: const Text(
                                      'Personalization privacy',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (widget.controller.capabilities.feedback) ...[
                            const SizedBox(height: PakPerkSpacing.xl),
                            Divider(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                            const SizedBox(height: PakPerkSpacing.md),
                            _buildFeedback(context, reducedMotion),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedback(BuildContext context, bool reducedMotion) {
    final state = widget.controller.state;
    final busy = state.feedbackPhase == RecommendationFeedbackPhase.sending;
    if (state.feedbackPhase == RecommendationFeedbackPhase.succeeded) {
      return Semantics(
        key: const ValueKey('recommendation-feedback-success'),
        liveRegion: true,
        label: 'Feedback sent',
        child: _FeedbackMessage(
          icon: Icons.check_circle_outline_rounded,
          title: 'Feedback sent',
          message: 'Thanks. This changes discovery signals, not queue state.',
          action: FilledButton(
            key: const ValueKey('recommendation-feedback-done'),
            onPressed: _dismiss,
            child: const Text('Done'),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Tune your recommendations',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Text(
          'Feedback changes future discovery signals. It never marks a paper '
          'read, saved, or removed.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.md),
        Wrap(
          spacing: PakPerkSpacing.sm,
          runSpacing: PakPerkSpacing.xs,
          children: [
            FilledButton.icon(
              key: const ValueKey('recommendation-feedback-relevant'),
              onPressed: busy
                  ? null
                  : () => widget.controller.submitFeedback(
                      const RecommendationFeedbackSelection.relevant(),
                    ),
              icon: const Icon(Icons.thumb_up_outlined),
              label: const Text('Helpful'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('recommendation-feedback-not-relevant'),
              onPressed: busy
                  ? null
                  : () => setState(() => _choosingReason = !_choosingReason),
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Not for me'),
            ),
            TextButton.icon(
              key: const ValueKey('recommendation-feedback-dismissed'),
              onPressed: busy
                  ? null
                  : () => widget.controller.submitFeedback(
                      const RecommendationFeedbackSelection(
                        type: RecommendationFeedbackType.dismissed,
                      ),
                    ),
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('Dismiss suggestion'),
            ),
          ],
        ),
        AnimatedSwitcher(
          duration: reducedMotion
              ? PakPerkMotion.instant
              : PakPerkMotion.crossFade,
          switchInCurve: PakPerkMotion.enter,
          switchOutCurve: PakPerkMotion.exit,
          child: !_choosingReason
              ? const SizedBox.shrink()
              : Padding(
                  key: const ValueKey('recommendation-feedback-reasons'),
                  padding: const EdgeInsets.only(top: PakPerkSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'What missed the mark?',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: PakPerkSpacing.xs),
                      Wrap(
                        spacing: PakPerkSpacing.xs,
                        runSpacing: PakPerkSpacing.xs,
                        children: [
                          for (final reason
                              in RecommendationFeedbackReason.values)
                            ChoiceChip(
                              key: ValueKey(
                                'recommendation-feedback-reason-'
                                '${reason.wireValue}',
                              ),
                              label: Text(reason.label),
                              selected: _selectedReason == reason,
                              onSelected: busy
                                  ? null
                                  : (selected) => setState(
                                      () => _selectedReason = selected
                                          ? reason
                                          : null,
                                    ),
                            ),
                        ],
                      ),
                      const SizedBox(height: PakPerkSpacing.sm),
                      FilledButton(
                        key: const ValueKey(
                          'recommendation-feedback-submit-negative',
                        ),
                        onPressed: busy || _selectedReason == null
                            ? null
                            : () => widget.controller.submitFeedback(
                                RecommendationFeedbackSelection(
                                  type: RecommendationFeedbackType.notRelevant,
                                  reason: _selectedReason,
                                ),
                              ),
                        child: const Text('Send feedback'),
                      ),
                    ],
                  ),
                ),
        ),
        if (busy) ...[
          const SizedBox(height: PakPerkSpacing.md),
          Semantics(
            key: const ValueKey('recommendation-feedback-progress'),
            liveRegion: true,
            label: 'Sending feedback',
            child: const LinearProgressIndicator(),
          ),
        ],
        if (state.feedbackPhase == RecommendationFeedbackPhase.failed &&
            state.feedbackFailure != null) ...[
          const SizedBox(height: PakPerkSpacing.md),
          _FeedbackFailure(
            failure: state.feedbackFailure!,
            onRetry: widget.controller.retryFeedback,
          ),
        ],
      ],
    );
  }
}

class _ExplanationSection extends StatelessWidget {
  const _ExplanationSection({required this.controller});

  final RecommendationInteractionController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Why this paper?',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.sm),
        switch (state.explanationPhase) {
          RecommendationExplanationPhase.unavailable => const _FeedbackMessage(
            icon: Icons.info_outline_rounded,
            title: 'Explanations are not enabled',
            message: 'No reason is inferred or substituted on this device.',
          ),
          RecommendationExplanationPhase.idle ||
          RecommendationExplanationPhase.loading => Semantics(
            key: const ValueKey('recommendation-explanation-progress'),
            liveRegion: true,
            label: 'Loading recommendation explanation',
            child: const LinearProgressIndicator(),
          ),
          RecommendationExplanationPhase.ready => Column(
            children: [
              for (
                var index = 0;
                index < state.explanations.length;
                index += 1
              ) ...[
                _ExplanationCard(explanation: state.explanations[index]),
                if (index != state.explanations.length - 1)
                  const SizedBox(height: PakPerkSpacing.sm),
              ],
            ],
          ),
          RecommendationExplanationPhase.failed => _FeedbackFailure(
            failure: state.explanationFailure!,
            onRetry: controller.loadExplanation,
          ),
        },
        const SizedBox(height: PakPerkSpacing.sm),
        Text(
          'These are immutable reasons recorded for this recommendation. They '
          'are not proof that your reading queue is empty.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ExplanationCard extends StatelessWidget {
  const _ExplanationCard({required this.explanation});

  final RecommendationExplanation explanation;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('recommendation-explanation-${explanation.code.wireValue}'),
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              color: context.pakPerkColors.processing,
            ),
            const SizedBox(width: PakPerkSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    explanation.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: PakPerkSpacing.xxs),
                  Text(explanation.detail),
                  const SizedBox(height: PakPerkSpacing.sm),
                  _ExplanationFact(
                    label: 'Candidate source',
                    value: _sourceLabel(explanation.source),
                  ),
                  const SizedBox(height: PakPerkSpacing.xxs),
                  _ExplanationFact(
                    label: 'Behavior used',
                    value: _behaviorUse(explanation.behaviorUsed),
                  ),
                  const SizedBox(height: PakPerkSpacing.xxs),
                  _ExplanationFact(
                    label: 'Selection role',
                    value: _selectionRole(explanation.code),
                  ),
                  if (explanation.seedPaperId != null) ...[
                    const SizedBox(height: PakPerkSpacing.xxs),
                    const _ExplanationFact(
                      label: 'Historical seed',
                      value: 'A recorded paper in your library',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplanationFact extends StatelessWidget {
  const _ExplanationFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          Text(
            '$label: ',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

String _sourceLabel(RecommendationSource source) => switch (source) {
  RecommendationSource.recent => 'Recent public papers',
  RecommendationSource.categoryFollow => 'A category you follow',
  RecommendationSource.topicFollow => 'A topic you follow',
  RecommendationSource.authorFollow => 'An author you follow',
  RecommendationSource.savedQuery => 'A saved search',
  RecommendationSource.feedbackAffinity => 'Recommendation feedback',
  RecommendationSource.inferredAffinity => 'An inferred category signal',
  RecommendationSource.semantic => 'Public-metadata similarity',
  RecommendationSource.citation => 'The published citation graph',
  RecommendationSource.exploration => 'An exploration slot',
};

String _behaviorUse(bool behaviorUsed) => behaviorUsed
    ? 'Yes — recorded behavior affected ranking'
    : 'No — explicit preferences or public metadata only';

String _selectionRole(RecommendationExplanationCode code) => switch (code) {
  RecommendationExplanationCode.adjacentTopicExploration ||
  RecommendationExplanationCode.underrepresentedCategoryExploration =>
    'Exploration — broadens beyond close matches',
  RecommendationExplanationCode.diversitySlot =>
    'Diversity — avoids a repetitive result set',
  _ => 'Relevance — matches a recorded signal',
};

class _FeedbackFailure extends StatelessWidget {
  const _FeedbackFailure({required this.failure, required this.onRetry});

  final RecommendationInteractionFailure failure;
  final AsyncCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('recommendation-interaction-failure'),
      liveRegion: true,
      container: true,
      label: '${failure.title}. ${failure.message}',
      child: _FeedbackMessage(
        icon: Icons.error_outline_rounded,
        title: failure.title,
        message: failure.message,
        error: true,
        action: failure.retryable
            ? FilledButton.icon(
                key: const ValueKey('recommendation-interaction-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              )
            : null,
      ),
    );
  }
}

class _FeedbackMessage extends StatelessWidget {
  const _FeedbackMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.error = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: error
                  ? context.pakPerkColors.destructive
                  : context.pakPerkColors.processing,
            ),
            const SizedBox(width: PakPerkSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: PakPerkSpacing.xxs),
                  Text(message),
                  if (action != null) ...[
                    const SizedBox(height: PakPerkSpacing.sm),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PakPerkSpacing.lg,
        PakPerkSpacing.xs,
        PakPerkSpacing.xs,
        PakPerkSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Recommendation details',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('recommendation-sheet-close'),
            tooltip: 'Close recommendation details',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _AccessibleDragHandle extends StatelessWidget {
  const _AccessibleDragHandle();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Drag handle',
      child: SizedBox(
        height: PakPerkSizes.compactInteractive,
        child: Center(
          child: Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: .42),
              borderRadius: const BorderRadius.all(
                Radius.circular(PakPerkRadii.pill),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
