import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/models/paper.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../../design_system/sizes.dart';
import '../passport/paper_passport_card.dart';
import '../passport/passport_controller.dart';
import '../research/research_controller.dart';

class AbstractView extends ConsumerStatefulWidget {
  const AbstractView({
    required this.paper,
    required this.scrollController,
    required this.onStageRequested,
    this.passportGeneration,
    this.paperPassportReady = false,
    this.active = true,
    this.onPreviousPaper,
    this.onNextPaper,
    super.key,
  });

  final PaperSummary paper;
  final ScrollController scrollController;
  final ValueChanged<PaperStage> onStageRequested;
  final int? passportGeneration;
  final bool paperPassportReady;
  final bool active;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

  @override
  ConsumerState<AbstractView> createState() => _AbstractViewState();
}

class _AbstractViewState extends ConsumerState<AbstractView> {
  bool _authorsExpanded = false;
  AbstractPassportArgs? _scheduledPassportLoad;

  @override
  Widget build(BuildContext context) {
    final paper = widget.paper;
    final features = ref.watch(featureFlagsProvider);
    final generation = widget.passportGeneration;
    final canShowPreparedPassport =
        features.paperPassport &&
        widget.paperPassportReady &&
        generation != null &&
        generation > 0;
    AbstractPassportArgs? passportArgs;
    AbstractPassportState? passportState;
    if (canShowPreparedPassport) {
      passportArgs = AbstractPassportArgs(
        paperId: paper.paperId,
        versionKey: paper.arxivId,
        generation: generation,
        viewerScope: ref.watch(passportViewerScopeProvider),
      );
      passportState = ref.watch(
        abstractPassportControllerProvider(passportArgs),
      );
      if (widget.active && _scheduledPassportLoad != passportArgs) {
        _scheduledPassportLoad = passportArgs;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !widget.active ||
              _scheduledPassportLoad != passportArgs) {
            return;
          }
          ref
              .read(abstractPassportControllerProvider(passportArgs!).notifier)
              .load();
        });
      }
    } else {
      _scheduledPassportLoad = null;
    }
    return CustomScrollView(
      key: const PageStorageKey('abstract-scroll'),
      controller: widget.scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          sliver: SliverList.list(
            children: [
              Text(
                '${paper.primaryCategory}  ·  ${_dateLabel(paper.publishedAt)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(
                  paper.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 12),
              _AuthorsLine(
                authors: paper.authors,
                expanded: _authorsExpanded,
                onToggle: () =>
                    setState(() => _authorsExpanded = !_authorsExpanded),
              ),
              const SizedBox(height: 26),
              Text('ABSTRACT', style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 10),
              Text(
                paper.abstractText,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (passportArgs != null && passportState != null) ...[
                const SizedBox(height: 16),
                _AbstractPassportContent(
                  args: passportArgs,
                  state: passportState,
                  onOpenIntroduction: () =>
                      widget.onStageRequested(PaperStage.introduction),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (!features.library && !features.comments)
                    OutlinedButton.icon(
                      key: const ValueKey('paper-arxiv-control'),
                      onPressed: () => _open(paper.canonicalAbsUri),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open on arXiv'),
                    ),
                  FilledButton.icon(
                    onPressed: () =>
                        widget.onStageRequested(PaperStage.introduction),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Introduction'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'Pakperk uses arXiv metadata and is not affiliated with or endorsed by arXiv.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 20),
              _PaperBoundaryActions(
                onPrevious: widget.onPreviousPaper,
                onNext: widget.onNextPaper,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _open(Uri? uri) async {
    final opened =
        uri != null && await ref.read(externalLinkOpenerProvider).open(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the arXiv record.')),
      );
    }
  }
}

class _AbstractPassportContent extends ConsumerWidget {
  const _AbstractPassportContent({
    required this.args,
    required this.state,
    required this.onOpenIntroduction,
  });

  final AbstractPassportArgs args;
  final AbstractPassportState state;
  final VoidCallback onOpenIntroduction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final passport = state.passport;
    if (passport != null && state.phase == AbstractPassportPhase.ready) {
      final verified = ref.watch(verifiedLibraryScopeProvider);
      final sessionId = ref.watch(anonymousSessionIdProvider);
      final feedbackArgs = verified == null
          ? PassportControllerArgs.anonymous(
              anonymousSessionId: sessionId,
              paperId: args.paperId,
              versionKey: args.versionKey,
              generation: args.generation,
              passportId: passport.id,
              viewerScope: args.viewerScope,
            )
          : PassportControllerArgs.authenticated(
              accountId: verified.accountId,
              authEpoch: verified.authEpoch,
              paperId: args.paperId,
              versionKey: args.versionKey,
              generation: args.generation,
              passportId: passport.id,
              viewerScope: args.viewerScope,
            );
      final features = ref.watch(featureFlagsProvider);
      final researchArgs = verified != null && features.researchMemory
          ? ResearchControllerArgs(
              accountId: verified.accountId,
              authEpoch: verified.authEpoch,
              paperId: args.paperId,
              versionKey: args.versionKey,
              generation: args.generation,
            )
          : null;
      return PaperPassportCard(
        passport: passport,
        compact: true,
        feedbackArgs: feedbackArgs,
        onRemember: researchArgs == null
            ? null
            : (field) => ref
                  .read(researchControllerProvider(researchArgs).notifier)
                  .rememberPassportField(field),
        onInspectEvidence: (_) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Opening the prepared document evidence.'),
            ),
          );
          onOpenIntroduction();
        },
      );
    }
    if (state.phase == AbstractPassportPhase.failed) {
      return Card(
        key: const ValueKey('abstract-passport-unavailable'),
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Prepared Passport unavailable',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                state.message ?? 'The prepared Passport could not be verified.',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('abstract-passport-retry'),
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(
                    Size(
                      PakPerkSizes.minimumInteractive,
                      PakPerkSizes.minimumInteractive,
                    ),
                  ),
                ),
                onPressed: () => ref
                    .read(abstractPassportControllerProvider(args).notifier)
                    .load(),
                icon: const Icon(Icons.refresh),
                label: const Text('Try Passport again'),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      liveRegion: state.phase == AbstractPassportPhase.loading,
      label: 'Loading prepared Paper Passport',
      child: const Card(
        key: ValueKey('abstract-passport-loading'),
        margin: EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(child: Text('Loading prepared Paper Passport…')),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthorsLine extends StatelessWidget {
  const _AuthorsLine({
    required this.authors,
    required this.expanded,
    required this.onToggle,
  });

  final List<String> authors;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    const visibleCount = 3;
    final hasMore = authors.length > visibleCount;
    final visible = expanded || !hasMore
        ? authors
        : authors.take(visibleCount).toList(growable: false);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          visible.isEmpty ? 'Authors unavailable' : visible.join(', '),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (hasMore)
          TextButton(
            onPressed: onToggle,
            child: Text(
              expanded
                  ? 'Show fewer'
                  : '+${authors.length - visibleCount} authors',
            ),
          ),
      ],
    );
  }
}

class PaperBoundaryActions extends StatelessWidget {
  const PaperBoundaryActions({this.onPrevious, this.onNext, super.key});

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return _PaperBoundaryActions(onPrevious: onPrevious, onNext: onNext);
  }
}

class _PaperBoundaryActions extends StatelessWidget {
  const _PaperBoundaryActions({this.onPrevious, this.onNext});

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    if (onPrevious == null && onNext == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaledLabelHeight = MediaQuery.textScalerOf(context).scale(14);
        final stackActions =
            constraints.maxWidth < 360 || scaledLabelHeight > 19;
        final previous = onPrevious == null
            ? null
            : OutlinedButton.icon(
                onPressed: onPrevious,
                icon: const Icon(Icons.keyboard_arrow_up),
                label: const Text('Previous paper'),
              );
        final next = onNext == null
            ? null
            : FilledButton.tonalIcon(
                onPressed: onNext,
                icon: const Icon(Icons.keyboard_arrow_down),
                label: const Text('Next paper'),
              );
        if (stackActions) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (previous != null) previous,
              if (previous != null && next != null) const SizedBox(height: 8),
              if (next != null) next,
            ],
          );
        }
        return Row(
          children: [
            if (previous != null) Expanded(child: previous),
            if (previous != null && next != null) const SizedBox(width: 10),
            if (next != null) Expanded(child: next),
          ],
        );
      },
    );
  }
}

String _dateLabel(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
