import 'package:flutter/material.dart';

import '../../core/models/connections.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/widgets/status_widgets.dart';
import '../paper_reader/abstract_view.dart';
import '../paper_reader/paper_processing_controller.dart';
import 'connections_controller.dart';

class ConnectionsView extends StatelessWidget {
  const ConnectionsView({
    required this.paper,
    required this.scrollController,
    required this.state,
    required this.processing,
    required this.capabilities,
    required this.onOpenPaper,
    required this.onRetryPreparation,
    required this.onRetryConnections,
    this.onPreviousPaper,
    this.onNextPaper,
    super.key,
  });

  final PaperSummary paper;
  final ScrollController scrollController;
  final ConnectionsState state;
  final ProcessingUiState processing;
  final PaperCapabilities capabilities;
  final Future<void> Function(String paperId) onOpenPaper;
  final VoidCallback onRetryPreparation;
  final VoidCallback onRetryConnections;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

  @override
  Widget build(BuildContext context) {
    final value = state.value;
    return CustomScrollView(
      key: const PageStorageKey('connections-scroll'),
      controller: scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          sliver: SliverList.list(
            children: [
              Text(
                paper.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              Text(
                'KEY CONNECTIONS',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 10),
              if (value != null && state.bundledDemo) ...[
                const BundledDemoNotice(),
                const SizedBox(height: 14),
              ],
              if (value != null && value.keyConnections.isNotEmpty)
                for (final connection in value.keyConnections.take(5)) ...[
                  _ConnectionCard(
                    connection: connection,
                    onTap: () => onOpenPaper(connection.paperId),
                  ),
                  const SizedBox(height: 10),
                ]
              else if (value != null)
                const EmptyStateCard(
                  title: 'No key connections yet',
                  message:
                      'No reference met the high-confidence relationship threshold for this paper.',
                )
              else if (state.errorMessage != null)
                EmptyStateCard(
                  title: 'Connections unavailable',
                  message: state.errorMessage!,
                  action: TextButton.icon(
                    onPressed: onRetryConnections,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                )
              else
                ProcessingStatusCard(
                  processing: processing.processing,
                  busy: state.loading || processing.requestInFlight,
                  offline: state.offline || processing.offline,
                  fallbackMessage: state.notReady
                      ? 'References are still being resolved.'
                      : null,
                  onRetry:
                      state.offline ||
                          processing.processing?.stage ==
                              ProcessingStage.failedRetryable
                      ? onRetryPreparation
                      : null,
                ),
              const SizedBox(height: 24),
              if (value != null) ...[
                _ReferencesSection(
                  references: value.references,
                  onOpenPaper: onOpenPaper,
                ),
                if (!value.ready || !capabilities.connections) ...[
                  const SizedBox(height: 18),
                  ProcessingStatusCard(
                    processing: processing.processing,
                    busy: processing.requestInFlight,
                    offline: processing.offline,
                    onRetry: processing.processing?.retryable == true
                        ? onRetryPreparation
                        : null,
                  ),
                ],
              ],
              const SizedBox(height: 28),
              PaperBoundaryActions(
                onPrevious: onPreviousPaper,
                onNext: onNextPaper,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.connection, required this.onTap});

  final KeyConnection connection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final firstAuthor = connection.authors.isEmpty
        ? 'Authors unavailable'
        : '${connection.authors.first}${connection.authors.length > 1 ? ' et al.' : ''}';
    final year = connection.year == null ? '' : ', ${connection.year}';
    final semanticLabel =
        '${relationLabel(connection.relationType)}. ${connection.title}. '
        '$firstAuthor$year. ${connection.summary}. Opens this paper.';
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          relationLabel(connection.relationType).toUpperCase(),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          connection.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text('$firstAuthor$year'),
                        const SizedBox(height: 9),
                        Text(connection.summary),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 8, top: 4),
                    child: Icon(Icons.arrow_forward),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReferencesSection extends StatelessWidget {
  const _ReferencesSection({
    required this.references,
    required this.onOpenPaper,
  });

  final List<PaperReference> references;
  final Future<void> Function(String paperId) onOpenPaper;

  @override
  Widget build(BuildContext context) {
    if (references.isEmpty) {
      return const EmptyStateCard(
        title: 'All references',
        message: 'The parser did not return a trustworthy bibliography.',
      );
    }
    final resolved = references.where((reference) => reference.isNavigable);
    final list = Column(
      children: [
        if (resolved.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              'No high-confidence arXiv matches were found. '
              'The extracted citations remain available below.',
            ),
          ),
        for (final reference in references)
          _ReferenceTile(
            reference: reference,
            onTap: reference.isNavigable
                ? () => onOpenPaper(reference.paperId!)
                : null,
          ),
      ],
    );

    if (references.length > 6) {
      return Card(
        child: ExpansionTile(
          initiallyExpanded: false,
          title: Text(
            'ALL REFERENCES',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          subtitle: Text('${references.length} extracted citations'),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          children: [list],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ALL REFERENCES', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 8),
        list,
      ],
    );
  }
}

class _ReferenceTile extends StatelessWidget {
  const _ReferenceTile({required this.reference, this.onTap});

  final PaperReference reference;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final citation = reference.rawText.trim().isEmpty
        ? reference.title ?? 'Reference details unavailable'
        : reference.rawText;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(
        child: Text('${reference.ordinal == 0 ? 1 : reference.ordinal}'),
      ),
      title: Text(citation),
      subtitle: Text(
        reference.isNavigable ? 'Open arXiv paper' : 'Not matched in arXiv',
      ),
      trailing: reference.isNavigable ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
}
