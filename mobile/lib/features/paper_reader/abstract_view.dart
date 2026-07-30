import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/paper.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';

class AbstractView extends ConsumerStatefulWidget {
  const AbstractView({
    required this.paper,
    required this.scrollController,
    required this.onStageRequested,
    this.onPreviousPaper,
    this.onNextPaper,
    super.key,
  });

  final PaperSummary paper;
  final ScrollController scrollController;
  final ValueChanged<PaperStage> onStageRequested;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

  @override
  ConsumerState<AbstractView> createState() => _AbstractViewState();
}

class _AbstractViewState extends ConsumerState<AbstractView> {
  bool _authorsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final paper = widget.paper;
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
              SelectableText(
                paper.abstractText,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _open(paper.absUrl),
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

  Future<void> _open(String value) async {
    final uri = Uri.tryParse(value);
    final opened =
        uri != null && await ref.read(externalLinkOpenerProvider).open(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the arXiv record.')),
      );
    }
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
