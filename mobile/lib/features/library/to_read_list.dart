import 'package:flutter/material.dart';

import '../../core/library/library_models.dart';

enum ToReadSortOrder {
  newest('Newest saved'),
  oldest('Oldest saved'),
  title('Title A–Z');

  const ToReadSortOrder(this.label);

  final String label;
}

class ToReadListView extends StatefulWidget {
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
  State<ToReadListView> createState() => _ToReadListViewState();
}

class _ToReadListViewState extends State<ToReadListView> {
  final _searchController = TextEditingController();
  ToReadSortOrder _sortOrder = ToReadSortOrder.newest;
  String _selectedCategory = '';

  @override
  void didUpdateWidget(ToReadListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedCategory.isNotEmpty &&
        !_availableCategories(widget.items).contains(_selectedCategory)) {
      _selectedCategory = '';
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _availableCategories(widget.items);
    final query = _searchController.text.trim().toLowerCase();
    final ordered =
        widget.items
            .where(
              (item) =>
                  _matchesCategory(item, _selectedCategory) &&
                  _matchesSearch(item, query),
            )
            .toList()
          ..sort((left, right) => _compareItems(left, right, _sortOrder));
    final sourceIsEmpty = widget.items.isEmpty;
    final noMatches = !sourceIsEmpty && ordered.isEmpty;
    final list = ListView.builder(
      key: const PageStorageKey<String>('to-read-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: sourceIsEmpty
          ? 1
          : noMatches
          ? 3
          : ordered.length + 2,
      itemBuilder: (context, index) {
        if (sourceIsEmpty) {
          return _ListStatus(
            empty: true,
            offline: widget.offline,
            issue: widget.syncIssue,
            readOnlyMessage: widget.readOnlyMessage,
            refreshable: widget.onRefresh != null,
          );
        }
        if (index == 0) {
          return _ToReadControls(
            searchController: _searchController,
            sortOrder: _sortOrder,
            selectedCategory: _selectedCategory,
            categories: categories,
            sourceCount: widget.items.length,
            visibleCount: ordered.length,
            onSearchChanged: (_) => setState(() {}),
            onClearSearch: () {
              _searchController.clear();
              setState(() {});
            },
            onSortChanged: (value) => setState(() => _sortOrder = value),
            onCategoryChanged: (value) =>
                setState(() => _selectedCategory = value),
          );
        }
        if (index == 1) {
          return _ListStatus(
            empty: false,
            offline: widget.offline,
            issue: widget.syncIssue,
            readOnlyMessage: widget.readOnlyMessage,
            refreshable: widget.onRefresh != null,
          );
        }
        if (noMatches) {
          return _NoMatchesStatus(onClear: _clearFilters);
        }
        final item = ordered[index - 2];
        return _ToReadCard(
          key: ValueKey('to-read-${item.paper.paperId}'),
          item: item,
          onOpen: () => widget.onOpen(item),
          onRemove: widget.onRemove == null
              ? null
              : () => widget.onRemove!(item),
        );
      },
    );
    if (widget.onRefresh == null) return list;
    return RefreshIndicator(onRefresh: widget.onRefresh!, child: list);
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() => _selectedCategory = '');
  }
}

class _ToReadControls extends StatelessWidget {
  const _ToReadControls({
    required this.searchController,
    required this.sortOrder,
    required this.selectedCategory,
    required this.categories,
    required this.sourceCount,
    required this.visibleCount,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSortChanged,
    required this.onCategoryChanged,
  });

  final TextEditingController searchController;
  final ToReadSortOrder sortOrder;
  final String selectedCategory;
  final List<String> categories;
  final int sourceCount;
  final int visibleCount;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<ToReadSortOrder> onSortChanged;
  final ValueChanged<String> onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    final filtering =
        searchController.text.trim().isNotEmpty || selectedCategory.isNotEmpty;
    final resultLabel = filtering
        ? '$visibleCount of $sourceCount saved papers shown'
        : '$sourceCount saved ${sourceCount == 1 ? 'paper' : 'papers'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('to-read-search'),
                controller: searchController,
                onChanged: onSearchChanged,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Search saved papers',
                  hintText: 'Title, author, arXiv ID, or category',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('to-read-clear-search'),
                          tooltip: 'Clear saved-paper search',
                          onPressed: onClearSearch,
                          icon: const Icon(Icons.clear),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SelectMenuButton<ToReadSortOrder>(
                    key: const ValueKey('to-read-sort-menu'),
                    tooltip: 'Sort saved papers. Current: ${sortOrder.label}',
                    icon: Icons.sort,
                    label: sortOrder.label,
                    selectedValue: sortOrder,
                    options: [
                      for (final value in ToReadSortOrder.values)
                        _SelectMenuOption(value: value, label: value.label),
                    ],
                    onSelected: onSortChanged,
                  ),
                  _SelectMenuButton<String>(
                    key: const ValueKey('to-read-category-menu'),
                    tooltip: selectedCategory.isEmpty
                        ? 'Filter saved papers by category'
                        : 'Filter saved papers by category. Current: '
                              '$selectedCategory',
                    icon: Icons.filter_list,
                    label: selectedCategory.isEmpty
                        ? 'All categories'
                        : selectedCategory,
                    selectedValue: selectedCategory,
                    options: [
                      const _SelectMenuOption(
                        value: '',
                        label: 'All categories',
                      ),
                      for (final category in categories)
                        _SelectMenuOption(value: category, label: category),
                    ],
                    onSelected: onCategoryChanged,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Semantics(
                key: const ValueKey('to-read-result-count'),
                liveRegion: true,
                label: resultLabel,
                excludeSemantics: true,
                child: Text(
                  resultLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectMenuOption<T> {
  const _SelectMenuOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// Keeps the menu overlay owned by the account-scoped list subtree. Unlike a
/// route-backed popup, [MenuAnchor] removes its overlay synchronously when this
/// widget is disposed, so an auth/account epoch change cannot leave category
/// names from the previous scope visible above the replacement screen.
class _SelectMenuButton<T> extends StatefulWidget {
  const _SelectMenuButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.selectedValue,
    required this.options,
    required this.onSelected,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final T selectedValue;
  final List<_SelectMenuOption<T>> options;
  final ValueChanged<T> onSelected;

  @override
  State<_SelectMenuButton<T>> createState() => _SelectMenuButtonState<T>();
}

class _SelectMenuButtonState<T> extends State<_SelectMenuButton<T>> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    childFocusNode: _focusNode,
    consumeOutsideTap: true,
    menuChildren: [
      for (final option in widget.options)
        Semantics(
          selected: option.value == widget.selectedValue,
          child: MenuItemButton(
            trailingIcon: option.value == widget.selectedValue
                ? const Icon(Icons.check, size: 20)
                : null,
            onPressed: () => _select(option.value),
            child: Text(option.label),
          ),
        ),
    ],
    builder: (context, controller, child) => Tooltip(
      message: widget.tooltip,
      child: Semantics(
        expanded: controller.isOpen,
        child: InkWell(
          focusNode: _focusNode,
          borderRadius: BorderRadius.circular(20),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: _ControlLabel(icon: widget.icon, label: widget.label),
        ),
      ),
    ),
  );

  void _select(T value) {
    // MenuItemButton delivers activation after restoring focus. The exact
    // account-scoped subtree may have been replaced in that intervening frame.
    if (mounted) widget.onSelected(value);
  }
}

class _ControlLabel extends StatelessWidget {
  const _ControlLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    ),
  );
}

class _NoMatchesStatus extends StatelessWidget {
  const _NoMatchesStatus({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 240),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 48),
            const SizedBox(height: 12),
            Text(
              'No saved papers match these filters',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Try another title, author, arXiv ID, or category.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const ValueKey('to-read-clear-filters'),
              onPressed: onClear,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('Clear filters'),
            ),
          ],
        ),
      ),
    ),
  );
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

List<String> _availableCategories(List<LibraryListItem> items) {
  final categories = <String>{};
  for (final item in items) {
    final paper = item.paper;
    for (final category in [paper.primaryCategory, ...paper.categories]) {
      final value = category.trim();
      if (value.isNotEmpty) categories.add(value);
    }
  }
  return categories.toList()
    ..sort((left, right) => left.toLowerCase().compareTo(right.toLowerCase()));
}

bool _matchesCategory(LibraryListItem item, String category) {
  if (category.isEmpty) return true;
  final normalizedCategory = category.toLowerCase();
  return [
    item.paper.primaryCategory,
    ...item.paper.categories,
  ].any((value) => value.trim().toLowerCase() == normalizedCategory);
}

bool _matchesSearch(LibraryListItem item, String query) {
  if (query.isEmpty) return true;
  final paper = item.paper;
  return [
    paper.title,
    paper.arxivId,
    paper.primaryCategory,
    ...paper.authors,
    ...paper.categories,
  ].any((value) => value.toLowerCase().contains(query));
}

int _compareItems(
  LibraryListItem left,
  LibraryListItem right,
  ToReadSortOrder order,
) {
  switch (order) {
    case ToReadSortOrder.newest:
      final byDate = right.savedAt.compareTo(left.savedAt);
      return byDate != 0
          ? byDate
          : right.paper.paperId.compareTo(left.paper.paperId);
    case ToReadSortOrder.oldest:
      final byDate = left.savedAt.compareTo(right.savedAt);
      return byDate != 0
          ? byDate
          : left.paper.paperId.compareTo(right.paper.paperId);
    case ToReadSortOrder.title:
      final byFoldedTitle = left.paper.title.toLowerCase().compareTo(
        right.paper.title.toLowerCase(),
      );
      if (byFoldedTitle != 0) return byFoldedTitle;
      final byExactTitle = left.paper.title.compareTo(right.paper.title);
      return byExactTitle != 0
          ? byExactTitle
          : left.paper.paperId.compareTo(right.paper.paperId);
  }
}

String _date(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
}
