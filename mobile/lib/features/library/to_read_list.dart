import 'package:flutter/material.dart';

import '../../core/library/library_models.dart';

class ToReadListView extends StatelessWidget {
  const ToReadListView({
    required this.items,
    required this.onOpen,
    required this.onRemove,
    this.onRefresh,
    this.offline = false,
    this.syncIssue,
    this.readOnlyMessage,
    super.key,
  });

  final List<LibraryListItem> items;
  final ValueChanged<LibraryListItem> onOpen;
  final ValueChanged<LibraryListItem>? onRemove;
  final Future<void> Function()? onRefresh;
  final bool offline;
  final LibrarySyncIssue? syncIssue;
  final String? readOnlyMessage;

  @override
  Widget build(BuildContext context) {
    final ordered = [...items]
      ..sort((left, right) {
        final byDate = right.savedAt.compareTo(left.savedAt);
        return byDate != 0
            ? byDate
            : right.paper.paperId.compareTo(left.paper.paperId);
      });
    final list = ListView.builder(
      key: const PageStorageKey<String>('to-read-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: ordered.isEmpty ? 1 : ordered.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _ListStatus(
            empty: ordered.isEmpty,
            offline: offline,
            issue: syncIssue,
            readOnlyMessage: readOnlyMessage,
            refreshable: onRefresh != null,
          );
        }
        final item = ordered[index - 1];
        return _ToReadCard(
          key: ValueKey('to-read-${item.paper.paperId}'),
          item: item,
          onOpen: () => onOpen(item),
          onRemove: onRemove == null ? null : () => onRemove!(item),
        );
      },
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class _ListStatus extends StatelessWidget {
  const _ListStatus({
    required this.empty,
    required this.offline,
    required this.issue,
    required this.readOnlyMessage,
    required this.refreshable,
  });

  final bool empty;
  final bool offline;
  final LibrarySyncIssue? issue;
  final String? readOnlyMessage;
  final bool refreshable;

  @override
  Widget build(BuildContext context) {
    final status = empty
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 320),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.bookmarks_outlined, size: 52),
                    const SizedBox(height: 16),
                    Text(
                      readOnlyMessage == null
                          ? 'Your To Read list is empty'
                          : 'No saved papers are available',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      readOnlyMessage == null
                          ? 'Save a paper from any Read stage and it will appear here.'
                          : 'This account is read-only, so the empty list cannot '
                                'be changed.',
                      textAlign: TextAlign.center,
                    ),
                    if (offline) ...[
                      const SizedBox(height: 12),
                      Text(
                        refreshable
                            ? 'Offline. Pull to refresh when you reconnect.'
                            : 'Offline. Showing cached saves.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (issue != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        issue!.message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          )
        : !offline && issue == null
        ? const SizedBox(height: 4)
        : Semantics(
            liveRegion: true,
            child: Card(
              color: issue == null
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      issue == null
                          ? Icons.cloud_off_outlined
                          : Icons.sync_problem,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        issue?.message ??
                            'Offline. Cached saves and pending changes remain available.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    if (readOnlyMessage == null) return status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          key: const ValueKey('to-read-read-only'),
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.lock_outline),
                const SizedBox(width: 10),
                Expanded(child: Text(readOnlyMessage!)),
              ],
            ),
          ),
        ),
        status,
      ],
    );
  }
}

class _ToReadCard extends StatelessWidget {
  const _ToReadCard({
    required this.item,
    required this.onOpen,
    required this.onRemove,
    super.key,
  });

  final LibraryListItem item;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final paper = item.paper;
    final authors = paper.authors.isEmpty
        ? 'Unknown authors'
        : paper.authors.take(3).join(', ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paper.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(authors, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Text(
                      '${paper.primaryCategory} · ${_date(paper.publishedAt)}'
                      ' · Saved ${_date(item.savedAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (item.savedState.syncPending) ...[
                      const SizedBox(height: 8),
                      const _StatusChip(
                        icon: Icons.schedule,
                        label: 'Waiting to sync',
                      ),
                    ] else if (item.savedState.issue case final issue?) ...[
                      const SizedBox(height: 8),
                      _StatusChip(
                        icon: Icons.sync_problem,
                        label: issue.message,
                        error: true,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('remove-to-read-${paper.paperId}'),
                tooltip: onRemove == null
                    ? 'To Read is read-only'
                    : 'Remove from To Read',
                onPressed: onRemove,
                icon: const Icon(Icons.bookmark_remove_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    this.error = false,
  });

  final IconData icon;
  final String label;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.secondary;
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

String _date(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
}
