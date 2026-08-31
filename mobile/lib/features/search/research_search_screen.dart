import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/discovery_search/discovery_search_models.dart';
import '../../core/discovery_search/search_privacy_store.dart';
import '../../core/models/paper.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';
import '../../design_system/colors.dart';
import '../../design_system/motion.dart';
import '../../design_system/radii.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import 'research_search_controller.dart';
import 'research_search_models.dart';
import 'saved_query_subscription_controller.dart';

typedef OpenResearchPaperCallback = void Function(String arxivId);
typedef StartAddResearchPaperCallback = void Function(String arxivId);
typedef MapResearchPaperCallback = void Function(String arxivId);
typedef SubscribeSavedResearchQueryCallback =
    Future<void> Function(SavedResearchQueryDraft query);
typedef SavedQuerySubscriptionPhaseResolver =
    SavedQuerySubscriptionPhase Function(SavedResearchQueryDraft query);
typedef DeleteSavedResearchQueryCallback =
    Future<void> Function(SavedResearchQueryDraft query);
typedef SavedQueryDeletingResolver =
    bool Function(SavedResearchQueryDraft query);

/// A navigation-agnostic Search destination with explicit intent modes.
///
/// Lookup uses only the confirmed private title-search contract. Exact arXiv
/// identifiers are normalized locally, then opened only after a user action.
/// Explore and saved queries fail closed until callers inject their respective
/// adapters. [onAddPaper] should present the canonical Add Paper flow; this
/// widget never writes a library row or maintains a second optimistic ledger.
class ResearchSearchScreen extends StatefulWidget {
  const ResearchSearchScreen({
    required this.controller,
    required this.onOpenPaper,
    this.onAddPaper,
    this.onMapPaper,
    this.availableExploreCategories = const [],
    this.savedQueries = const [],
    this.savedQueriesLoading = false,
    this.savedQueriesLoadFailed = false,
    this.onReloadSavedQueries,
    this.onSubscribeSavedQuery,
    this.savedQuerySubscriptionPhase,
    this.savedQuerySubscriptionBusy = false,
    this.onDeleteSavedQuery,
    this.savedQueryDeleting,
    this.privateHistoryAvailable = false,
    this.privateHistoryLoading = false,
    this.privateHistoryEnabled = false,
    this.privateHistoryEntries = const [],
    this.privateHistoryError,
    this.onPrivateHistoryEnabled,
    this.onClearPrivateHistory,
    this.onReloadPrivateHistory,
    super.key,
  });

  final ResearchSearchController controller;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final MapResearchPaperCallback? onMapPaper;
  final List<String> availableExploreCategories;
  final List<SavedResearchQueryDraft> savedQueries;
  final bool savedQueriesLoading;
  final bool savedQueriesLoadFailed;
  final AsyncCallback? onReloadSavedQueries;
  final SubscribeSavedResearchQueryCallback? onSubscribeSavedQuery;
  final SavedQuerySubscriptionPhaseResolver? savedQuerySubscriptionPhase;
  final bool savedQuerySubscriptionBusy;
  final DeleteSavedResearchQueryCallback? onDeleteSavedQuery;
  final SavedQueryDeletingResolver? savedQueryDeleting;
  final bool privateHistoryAvailable;
  final bool privateHistoryLoading;
  final bool privateHistoryEnabled;
  final List<PrivateSearchHistoryEntry> privateHistoryEntries;
  final String? privateHistoryError;
  final ValueChanged<bool>? onPrivateHistoryEnabled;
  final VoidCallback? onClearPrivateHistory;
  final VoidCallback? onReloadPrivateHistory;

  @override
  State<ResearchSearchScreen> createState() => _ResearchSearchScreenState();
}

class _ResearchSearchScreenState extends State<ResearchSearchScreen> {
  late final TextEditingController _lookupText;
  late final TextEditingController _exploreText;
  final FocusNode _lookupFocus = FocusNode(debugLabel: 'lookup-search');
  final FocusNode _exploreFocus = FocusNode(debugLabel: 'explore-search');

  @override
  void initState() {
    super.initState();
    _lookupText = TextEditingController(
      text: widget.controller.state.lookupInput,
    );
    _exploreText = TextEditingController(
      text: widget.controller.state.exploreDraft.query,
    );
    widget.controller.addListener(_handleControllerChange);
  }

  @override
  void didUpdateWidget(ResearchSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChange);
    widget.controller.addListener(_handleControllerChange);
    _syncText(force: true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChange);
    _lookupText.dispose();
    _exploreText.dispose();
    _lookupFocus.dispose();
    _exploreFocus.dispose();
    super.dispose();
  }

  void _handleControllerChange() {
    if (!mounted) return;
    _syncText();
    setState(() {});
  }

  void _syncText({bool force = false}) {
    final state = widget.controller.state;
    if (force || !_lookupFocus.hasFocus || state.lookupInput.isEmpty) {
      _setText(_lookupText, state.lookupInput);
    }
    if (force || !_exploreFocus.hasFocus || state.exploreDraft.query.isEmpty) {
      _setText(_exploreText, state.exploreDraft.query);
    }
  }

  void _setMode(ResearchSearchMode mode) {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.controller.setMode(mode);
  }

  void _selectPrivateHistory(PrivateSearchHistoryEntry entry) {
    final mode = entry.mode == PrivateSearchHistoryMode.lookup
        ? ResearchSearchMode.lookup
        : ResearchSearchMode.explore;
    _setMode(mode);
    if (mode == ResearchSearchMode.lookup) {
      widget.controller.updateLookupInput(entry.query);
      _lookupFocus.requestFocus();
    } else {
      widget.controller.updateExploreDraft(
        ExploreSearchDraft(query: entry.query),
      );
      _exploreFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final reducedMotion = platformPrefersReducedMotion(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: SafeArea(
        top: false,
        left: true,
        right: true,
        bottom: true,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: PakPerkSizes.contentMaxWidth,
            ),
            child: ListView(
              key: const ValueKey('research-search-scroll-view'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(
                PakPerkSpacing.lg,
                PakPerkSpacing.md,
                PakPerkSpacing.lg,
                PakPerkSpacing.xxl,
              ),
              children: [
                _SearchModeControl(selected: state.mode, onSelected: _setMode),
                if (widget.privateHistoryAvailable) ...[
                  const SizedBox(height: PakPerkSpacing.md),
                  _PrivateSearchHistoryControl(
                    loading: widget.privateHistoryLoading,
                    enabled: widget.privateHistoryEnabled,
                    entries: widget.privateHistoryEntries,
                    errorMessage: widget.privateHistoryError,
                    onEnabledChanged: widget.onPrivateHistoryEnabled,
                    onClear: widget.onClearPrivateHistory,
                    onReload: widget.onReloadPrivateHistory,
                    onSelected: _selectPrivateHistory,
                  ),
                ],
                const SizedBox(height: PakPerkSpacing.lg),
                AnimatedSwitcher(
                  duration: reducedMotion
                      ? PakPerkMotion.instant
                      : PakPerkMotion.crossFade,
                  switchInCurve: PakPerkMotion.enter,
                  switchOutCurve: PakPerkMotion.exit,
                  child: state.mode == ResearchSearchMode.lookup
                      ? _buildLookup(context, state)
                      : _buildExplore(context, state),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLookup(BuildContext context, ResearchSearchState state) {
    return Column(
      key: const ValueKey('research-search-lookup'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Look up a paper',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Text(
          'Use a paper title, canonical arXiv link, or arXiv ID. Opening a '
          'result never adds it to your reading queue.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.md),
        TextField(
          key: const ValueKey('research-search-lookup-input'),
          controller: _lookupText,
          focusNode: _lookupFocus,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: widget.controller.updateLookupInput,
          onSubmitted: (_) => widget.controller.lookupNow(),
          decoration: InputDecoration(
            labelText: 'Paper title, arXiv link, or ID',
            hintText: 'Attention Is All You Need',
            suffixIcon: _lookupText.text.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('research-search-lookup-clear'),
                    tooltip: 'Clear lookup',
                    onPressed: () {
                      _lookupText.clear();
                      widget.controller.updateLookupInput('');
                      _lookupFocus.requestFocus();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        if (state.lookupSuggestions.isNotEmpty) ...[
          const SizedBox(height: PakPerkSpacing.sm),
          _LookupSuggestions(
            suggestions: state.lookupSuggestions,
            exploreAvailable: widget.controller.exploreAvailable,
            onSelected: widget.controller.selectSuggestion,
          ),
        ],
        const SizedBox(height: PakPerkSpacing.md),
        _LookupStatus(
          state: state,
          onOpenPaper: widget.onOpenPaper,
          onAddPaper: widget.onAddPaper,
          onRetry: widget.controller.retry,
        ),
      ],
    );
  }

  Widget _buildExplore(BuildContext context, ResearchSearchState state) {
    final draft = state.exploreDraft;
    final exploreEnabled = widget.controller.exploreAvailable;
    return Column(
      key: const ValueKey('research-search-explore'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Explore a topic',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Text(
          'Explore is an intentional topic search. Results stay separate from '
          'your reading feed until you choose Add paper.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (widget.controller.savedQueriesAvailable) ...[
          const SizedBox(height: PakPerkSpacing.md),
          _SavedQueries(
            queries: widget.savedQueries,
            loading: widget.savedQueriesLoading,
            loadFailed: widget.savedQueriesLoadFailed,
            onSelected: widget.controller.applySavedQuery,
            onReload: widget.onReloadSavedQueries,
            onSubscribe: widget.onSubscribeSavedQuery,
            subscriptionPhase: widget.savedQuerySubscriptionPhase,
            subscriptionBusy: widget.savedQuerySubscriptionBusy,
            onDelete: widget.onDeleteSavedQuery,
            deleting: widget.savedQueryDeleting,
          ),
        ],
        const SizedBox(height: PakPerkSpacing.md),
        TextField(
          key: const ValueKey('research-search-explore-input'),
          controller: _exploreText,
          focusNode: _exploreFocus,
          textInputAction: TextInputAction.search,
          onChanged: widget.controller.updateExploreQuery,
          onSubmitted: exploreEnabled
              ? (_) => widget.controller.submitExplore()
              : null,
          decoration: const InputDecoration(
            labelText: 'Topic or research question',
            hintText: 'Efficient language model adaptation',
          ),
        ),
        const SizedBox(height: PakPerkSpacing.md),
        _ExploreFilters(
          draft: draft,
          availableCategories: widget.availableExploreCategories,
          enabled: exploreEnabled && !state.busy,
          onSortChanged: widget.controller.updateExploreSortOrder,
          onDateChanged: widget.controller.updateExploreDateRange,
          onCategoryChanged: (category, selected) => widget.controller
              .setExploreCategory(category, selected: selected),
        ),
        const SizedBox(height: PakPerkSpacing.md),
        Wrap(
          spacing: PakPerkSpacing.sm,
          runSpacing: PakPerkSpacing.xs,
          children: [
            FilledButton.icon(
              key: const ValueKey('research-search-explore-submit'),
              onPressed: exploreEnabled && !state.busy && draft.canSubmit
                  ? widget.controller.submitExplore
                  : null,
              icon: const Icon(Icons.search_rounded),
              label: const Text('Explore'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('research-search-save-query'),
              onPressed:
                  widget.controller.savedQueriesAvailable &&
                      !state.busy &&
                      draft.canSubmit
                  ? widget.controller.saveCurrentQuery
                  : null,
              icon: state.savingQuery
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.notifications_none_rounded),
              label: Text(state.querySaved ? 'Query saved' : 'Save query'),
            ),
          ],
        ),
        if (!widget.controller.savedQueriesAvailable) ...[
          const SizedBox(height: PakPerkSpacing.xs),
          Text(
            'Saved queries are not enabled.',
            key: const ValueKey('research-search-saved-unavailable'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: PakPerkSpacing.lg),
        _ExploreStatus(
          state: state,
          exploreEnabled: exploreEnabled,
          onOpenPaper: widget.onOpenPaper,
          onAddPaper: widget.onAddPaper,
          onMapPaper: widget.onMapPaper,
          onRetry: widget.controller.retry,
        ),
      ],
    );
  }
}

class _LookupSuggestions extends StatelessWidget {
  const _LookupSuggestions({
    required this.suggestions,
    required this.exploreAvailable,
    required this.onSelected,
  });

  final List<DiscoveryRelatedTopic> suggestions;
  final bool exploreAvailable;
  final ValueChanged<DiscoveryRelatedTopic> onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${suggestions.length} related topic suggestions',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Related topics', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: PakPerkSpacing.xs),
        Wrap(
          spacing: PakPerkSpacing.xs,
          runSpacing: PakPerkSpacing.xs,
          children: [
            for (final suggestion in suggestions)
              ActionChip(
                key: ValueKey(
                  'research-search-suggestion-${suggestion.topicId}',
                ),
                avatar: Icon(
                  exploreAvailable
                      ? Icons.explore_outlined
                      : Icons.search_rounded,
                ),
                label: Text(suggestion.label),
                tooltip: exploreAvailable
                    ? 'Explore ${suggestion.label}'
                    : 'Look up ${suggestion.label}',
                onPressed: () => onSelected(suggestion),
              ),
          ],
        ),
      ],
    ),
  );
}

class _SavedQueries extends StatelessWidget {
  const _SavedQueries({
    required this.queries,
    required this.loading,
    required this.loadFailed,
    required this.onSelected,
    required this.onReload,
    required this.onSubscribe,
    required this.subscriptionPhase,
    required this.subscriptionBusy,
    required this.onDelete,
    required this.deleting,
  });

  final List<SavedResearchQueryDraft> queries;
  final bool loading;
  final bool loadFailed;
  final ValueChanged<SavedResearchQueryDraft> onSelected;
  final AsyncCallback? onReload;
  final SubscribeSavedResearchQueryCallback? onSubscribe;
  final SavedQuerySubscriptionPhaseResolver? subscriptionPhase;
  final bool subscriptionBusy;
  final DeleteSavedResearchQueryCallback? onDelete;
  final SavedQueryDeletingResolver? deleting;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const LinearProgressIndicator(
        key: ValueKey('research-search-saved-loading'),
        semanticsLabel: 'Loading saved queries',
      );
    }
    if (loadFailed) {
      return _SearchStatusCard(
        key: const ValueKey('research-search-saved-failed'),
        icon: Icons.sync_problem_outlined,
        title: 'Saved queries unavailable',
        message: 'Your current search is still available.',
        actions: onReload == null
            ? null
            : FilledButton.tonalIcon(
                onPressed: onReload,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
      );
    }
    if (queries.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: '${queries.length} saved queries',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Saved queries', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: PakPerkSpacing.xs),
          for (final (index, query) in queries.indexed) ...[
            _SavedQueryCard(
              index: index,
              query: query,
              onSelected: onSelected,
              onSubscribe: onSubscribe,
              subscriptionPhase: subscriptionPhase,
              subscriptionBusy: subscriptionBusy,
              onDelete: onDelete,
              deleting: deleting,
            ),
            if (index != queries.length - 1)
              const SizedBox(height: PakPerkSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _SavedQueryCard extends StatelessWidget {
  const _SavedQueryCard({
    required this.index,
    required this.query,
    required this.onSelected,
    required this.onSubscribe,
    required this.subscriptionPhase,
    required this.subscriptionBusy,
    required this.onDelete,
    required this.deleting,
  });

  final int index;
  final SavedResearchQueryDraft query;
  final ValueChanged<SavedResearchQueryDraft> onSelected;
  final SubscribeSavedResearchQueryCallback? onSubscribe;
  final SavedQuerySubscriptionPhaseResolver? subscriptionPhase;
  final bool subscriptionBusy;
  final DeleteSavedResearchQueryCallback? onDelete;
  final SavedQueryDeletingResolver? deleting;

  @override
  Widget build(BuildContext context) {
    final canOfferSubscription =
        onSubscribe != null &&
        subscriptionPhase != null &&
        query.savedSearchId != null;
    final phase = canOfferSubscription
        ? subscriptionPhase!(query)
        : SavedQuerySubscriptionPhase.idle;
    final subscribing = phase == SavedQuerySubscriptionPhase.subscribing;
    final subscribed = phase == SavedQuerySubscriptionPhase.subscribed;
    final failed = phase == SavedQuerySubscriptionPhase.failed;
    final deletingNow = deleting?.call(query) ?? false;
    final canDelete = onDelete != null && query.savedSearchId != null;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: ValueKey('research-search-saved-query-$index'),
            leading: const Icon(Icons.bookmark_outline_rounded),
            title: Text(query.query),
            subtitle: const Text('Open saved query'),
            onTap: () => onSelected(query),
          ),
          if (canOfferSubscription)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PakPerkSpacing.md,
                0,
                PakPerkSpacing.md,
                PakPerkSpacing.sm,
              ),
              child: Semantics(
                liveRegion: failed || subscribed,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  child: OutlinedButton.icon(
                    key: ValueKey(
                      'research-search-subscribe-saved-query-$index',
                    ),
                    onPressed: subscriptionBusy || subscribed || deletingNow
                        ? null
                        : () => onSubscribe!(query),
                    icon: subscribing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            subscribed
                                ? Icons.notifications_active_rounded
                                : failed
                                ? Icons.refresh_rounded
                                : Icons.notifications_none_rounded,
                          ),
                    label: Text(
                      subscribing
                          ? 'Subscribing…'
                          : subscribed
                          ? 'Daily alerts on'
                          : failed
                          ? 'Retry daily alerts'
                          : 'Get daily alerts',
                    ),
                  ),
                ),
              ),
            ),
          if (canDelete)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PakPerkSpacing.md,
                0,
                PakPerkSpacing.md,
                PakPerkSpacing.sm,
              ),
              child: Semantics(
                liveRegion: deletingNow,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  child: OutlinedButton.icon(
                    key: ValueKey('research-search-delete-saved-query-$index'),
                    onPressed: subscriptionBusy || deletingNow
                        ? null
                        : () => _confirmDelete(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: deletingNow
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline_rounded),
                    label: Text(deletingNow ? 'Deleting…' : 'Delete query'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Delete saved query?'),
        content: Text(
          '“${query.query}” and any alerts linked to it will be removed. '
          'This won’t clear private on-device search history or change your '
          'reading queue.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('saved-query-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('saved-query-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            child: const Text('Delete query'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) await onDelete!(query);
  }
}

class _PrivateSearchHistoryControl extends StatelessWidget {
  const _PrivateSearchHistoryControl({
    required this.loading,
    required this.enabled,
    required this.entries,
    required this.errorMessage,
    required this.onEnabledChanged,
    required this.onClear,
    required this.onReload,
    required this.onSelected,
  });

  final bool loading;
  final bool enabled;
  final List<PrivateSearchHistoryEntry> entries;
  final String? errorMessage;
  final ValueChanged<bool>? onEnabledChanged;
  final VoidCallback? onClear;
  final VoidCallback? onReload;
  final ValueChanged<PrivateSearchHistoryEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = entries.take(6).toList(growable: false);
    return Semantics(
      key: const ValueKey('private-search-history-control'),
      container: true,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: PakPerkRadii.card,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('private-search-history-toggle'),
              value: enabled,
              onChanged: loading ? null : onEnabledChanged,
              title: const Text('Private search history'),
              subtitle: const Text(
                'Off by default. When enabled, successful queries stay only '
                'on this device.',
              ),
              secondary: loading
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.history_rounded),
            ),
            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PakPerkSpacing.md,
                  0,
                  PakPerkSpacing.md,
                  PakPerkSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        errorMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(width: PakPerkSpacing.xs),
                    TextButton.icon(
                      key: const ValueKey('private-search-history-reload'),
                      onPressed: loading ? null : onReload,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            if (enabled && recent.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PakPerkSpacing.md,
                  0,
                  PakPerkSpacing.md,
                  PakPerkSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recent on this device',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('private-search-history-clear'),
                          onPressed: loading ? null : onClear,
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: PakPerkSpacing.xs,
                      runSpacing: PakPerkSpacing.xs,
                      children: [
                        for (final entry in recent)
                          ActionChip(
                            avatar: Icon(
                              entry.mode == PrivateSearchHistoryMode.lookup
                                  ? Icons.search_rounded
                                  : Icons.explore_outlined,
                            ),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                entry.query,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            tooltip: 'Use ${entry.query}',
                            onPressed: () => onSelected(entry),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchModeControl extends StatelessWidget {
  const _SearchModeControl({required this.selected, required this.onSelected});

  final ResearchSearchMode selected;
  final ValueChanged<ResearchSearchMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Search intent',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: PakPerkRadii.input,
        ),
        child: Padding(
          padding: const EdgeInsets.all(PakPerkSpacing.xxs),
          child: Row(
            children: [
              for (final mode in ResearchSearchMode.values)
                Expanded(
                  child: _SearchModeButton(
                    mode: mode,
                    selected: selected == mode,
                    onPressed: () => onSelected(mode),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchModeButton extends StatelessWidget {
  const _SearchModeButton({
    required this.mode,
    required this.selected,
    required this.onPressed,
  });

  final ResearchSearchMode mode;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = mode == ResearchSearchMode.lookup ? 'Lookup' : 'Explore';
    return Semantics(
      key: ValueKey('research-search-mode-${mode.name}'),
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected ? scheme.surface : Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PakPerkSpacing.sm,
                  vertical: PakPerkSpacing.xs,
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExploreFilters extends StatelessWidget {
  const _ExploreFilters({
    required this.draft,
    required this.availableCategories,
    required this.enabled,
    required this.onSortChanged,
    required this.onDateChanged,
    required this.onCategoryChanged,
  });

  final ExploreSearchDraft draft;
  final List<String> availableCategories;
  final bool enabled;
  final ValueChanged<ExploreSortOrder> onSortChanged;
  final ValueChanged<ExploreDateRange> onDateChanged;
  final void Function(String category, bool selected) onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final sort = DropdownButtonFormField<ExploreSortOrder>(
              key: const ValueKey('research-search-explore-sort'),
              initialValue: draft.sortOrder,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Sort'),
              items: [
                for (final value in ExploreSortOrder.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) onSortChanged(value);
                    }
                  : null,
            );
            final date = DropdownButtonFormField<ExploreDateRange>(
              key: const ValueKey('research-search-explore-date'),
              initialValue: draft.dateRange,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Published'),
              items: [
                for (final value in ExploreDateRange.values)
                  if (value != ExploreDateRange.savedRange ||
                      draft.dateRange == ExploreDateRange.savedRange)
                    DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) onDateChanged(value);
                    }
                  : null,
            );
            if (constraints.maxWidth < 520) {
              return Column(
                children: [
                  sort,
                  const SizedBox(height: PakPerkSpacing.sm),
                  date,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: sort),
                const SizedBox(width: PakPerkSpacing.sm),
                Expanded(child: date),
              ],
            );
          },
        ),
        if (availableCategories.isNotEmpty) ...[
          const SizedBox(height: PakPerkSpacing.md),
          Text('Categories', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: PakPerkSpacing.xs),
          Wrap(
            spacing: PakPerkSpacing.xs,
            runSpacing: PakPerkSpacing.xs,
            children: [
              for (final category in availableCategories)
                FilterChip(
                  key: ValueKey('research-search-category-$category'),
                  label: Text(category),
                  selected: draft.categories.contains(category),
                  onSelected: enabled
                      ? (selected) => onCategoryChanged(category, selected)
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LookupStatus extends StatelessWidget {
  const _LookupStatus({
    required this.state,
    required this.onOpenPaper,
    required this.onAddPaper,
    required this.onRetry,
  });

  final ResearchSearchState state;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final AsyncCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (state.phase) {
    ResearchSearchPhase.idle => const SizedBox.shrink(),
    ResearchSearchPhase.waiting => const _SearchStatusCard(
      key: ValueKey('research-search-waiting'),
      icon: Icons.more_horiz_rounded,
      title: 'Waiting for you to pause',
      message: 'Title lookup starts after a brief pause.',
    ),
    ResearchSearchPhase.searching => const _SearchProgress(
      message: 'Looking up matching papers…',
    ),
    ResearchSearchPhase.exactReady => _ExactLookupCard(
      arxivId: state.normalizedExactArxivId!,
      onOpenPaper: onOpenPaper,
      onAddPaper: onAddPaper,
    ),
    ResearchSearchPhase.results => _LookupResults(
      candidates: state.lookupCandidates,
      onOpenPaper: onOpenPaper,
      onAddPaper: onAddPaper,
    ),
    ResearchSearchPhase.empty => const _SearchStatusCard(
      key: ValueKey('research-search-empty'),
      icon: Icons.search_off_rounded,
      title: 'No matching papers',
      message: 'Try a more specific title, canonical arXiv link, or arXiv ID.',
    ),
    ResearchSearchPhase.unavailable || ResearchSearchPhase.failed =>
      _SearchFailureCard(failure: state.failure!, onRetry: onRetry),
  };
}

class _ExploreStatus extends StatelessWidget {
  const _ExploreStatus({
    required this.state,
    required this.exploreEnabled,
    required this.onOpenPaper,
    required this.onAddPaper,
    required this.onMapPaper,
    required this.onRetry,
  });

  final ResearchSearchState state;
  final bool exploreEnabled;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final MapResearchPaperCallback? onMapPaper;
  final AsyncCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!exploreEnabled) {
      return const _SearchStatusCard(
        key: ValueKey('research-search-explore-unavailable'),
        icon: Icons.lock_outline_rounded,
        title: 'Explore search is not enabled',
        message:
            'Recent papers are not substituted for a query search. Explore '
            'will appear here only when its search source is available.',
      );
    }
    return switch (state.phase) {
      ResearchSearchPhase.idle ||
      ResearchSearchPhase.waiting => const SizedBox.shrink(),
      ResearchSearchPhase.searching => const _SearchProgress(
        message: 'Exploring this topic…',
      ),
      ResearchSearchPhase.results ||
      ResearchSearchPhase.empty => _ExploreResults(
        presentation: state.explorePresentation!,
        onOpenPaper: onOpenPaper,
        onAddPaper: onAddPaper,
        onMapPaper: onMapPaper,
      ),
      ResearchSearchPhase.failed || ResearchSearchPhase.unavailable =>
        _SearchFailureCard(failure: state.failure!, onRetry: onRetry),
      ResearchSearchPhase.exactReady => const SizedBox.shrink(),
    };
  }
}

class _ExactLookupCard extends StatelessWidget {
  const _ExactLookupCard({
    required this.arxivId,
    required this.onOpenPaper,
    required this.onAddPaper,
  });

  final String arxivId;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;

  @override
  Widget build(BuildContext context) {
    return _SearchStatusCard(
      key: const ValueKey('research-search-exact-ready'),
      icon: Icons.article_outlined,
      title: 'arXiv $arxivId',
      message: 'The identifier is ready. Nothing opens or saves automatically.',
      actions: _PaperActions(
        arxivId: arxivId,
        onOpenPaper: onOpenPaper,
        onAddPaper: onAddPaper,
      ),
    );
  }
}

class _LookupResults extends StatelessWidget {
  const _LookupResults({
    required this.candidates,
    required this.onOpenPaper,
    required this.onAddPaper,
  });

  final List<PaperSearchCandidate> candidates;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${candidates.length} paper lookup results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Results',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          Text(
            'Open or add a paper explicitly. Results are never inserted into '
            'your feed automatically.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          for (var index = 0; index < candidates.length; index += 1) ...[
            _LookupCandidateCard(
              candidate: candidates[index],
              onOpenPaper: onOpenPaper,
              onAddPaper: onAddPaper,
            ),
            if (index != candidates.length - 1)
              const SizedBox(height: PakPerkSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _LookupCandidateCard extends StatelessWidget {
  const _LookupCandidateCard({
    required this.candidate,
    required this.onOpenPaper,
    required this.onAddPaper,
  });

  final PaperSearchCandidate candidate;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;

  @override
  Widget build(BuildContext context) {
    final authors = _authorLabel(candidate.authors);
    return Card(
      key: ValueKey('research-search-lookup-${candidate.arxivId}'),
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              candidate.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(authors, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: PakPerkSpacing.xs),
            Text(
              '${candidate.publishedAt.year} · ${candidate.primaryCategory} '
              '· arXiv ${candidate.arxivId}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: PakPerkSpacing.sm),
            _PaperActions(
              arxivId: candidate.arxivId,
              onOpenPaper: onOpenPaper,
              onAddPaper: onAddPaper,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExploreResults extends StatelessWidget {
  const _ExploreResults({
    required this.presentation,
    required this.onOpenPaper,
    required this.onAddPaper,
    required this.onMapPaper,
  });

  final ExploreSearchPresentation presentation;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final MapResearchPaperCallback? onMapPaper;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${presentation.papers.length} Explore search results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchStatusCard(
            key: const ValueKey('research-search-explore-diagnostics'),
            icon: Icons.info_outline_rounded,
            title: presentation.coverageLabel,
            message: presentation.disclaimer,
          ),
          if (presentation.papers.isEmpty) ...[
            const SizedBox(height: PakPerkSpacing.sm),
            const _SearchStatusCard(
              key: ValueKey('research-search-explore-empty'),
              icon: Icons.search_off_rounded,
              title: 'No papers found',
              message: 'Try broader terms or remove a filter.',
            ),
          ] else ...[
            const SizedBox(height: PakPerkSpacing.md),
            for (
              var index = 0;
              index < presentation.papers.length;
              index += 1
            ) ...[
              _ExplorePaperCard(
                paper: presentation.papers[index],
                onOpenPaper: onOpenPaper,
                onAddPaper: onAddPaper,
                onMapPaper: onMapPaper,
              ),
              if (index != presentation.papers.length - 1)
                const SizedBox(height: PakPerkSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class _ExplorePaperCard extends StatelessWidget {
  const _ExplorePaperCard({
    required this.paper,
    required this.onOpenPaper,
    required this.onAddPaper,
    required this.onMapPaper,
  });

  final PaperSummary paper;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final MapResearchPaperCallback? onMapPaper;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('research-search-explore-${paper.arxivId}'),
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(paper.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(
              _authorLabel(paper.authors),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            Text(
              '${paper.publishedAt.year} · ${paper.primaryCategory} '
              '· arXiv ${paper.arxivId}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: PakPerkSpacing.sm),
            _PaperActions(
              arxivId: paper.arxivId,
              onOpenPaper: onOpenPaper,
              onAddPaper: onAddPaper,
              onMapPaper: onMapPaper,
            ),
          ],
        ),
      ),
    );
  }
}

class _PaperActions extends StatelessWidget {
  const _PaperActions({
    required this.arxivId,
    required this.onOpenPaper,
    required this.onAddPaper,
    this.onMapPaper,
  });

  final String arxivId;
  final OpenResearchPaperCallback onOpenPaper;
  final StartAddResearchPaperCallback? onAddPaper;
  final MapResearchPaperCallback? onMapPaper;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: PakPerkSpacing.sm,
      runSpacing: PakPerkSpacing.xs,
      children: [
        FilledButton.icon(
          key: ValueKey('research-search-open-$arxivId'),
          onPressed: () => onOpenPaper(arxivId),
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open paper'),
        ),
        if (onAddPaper != null)
          OutlinedButton.icon(
            key: ValueKey('research-search-add-$arxivId'),
            onPressed: () => onAddPaper!(arxivId),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add paper'),
          ),
        if (onMapPaper != null)
          OutlinedButton.icon(
            key: ValueKey('research-search-map-$arxivId'),
            onPressed: () => onMapPaper!(arxivId),
            icon: const Icon(Icons.hub_outlined),
            label: const Text('Map from this paper'),
          ),
      ],
    );
  }
}

class _SearchProgress extends StatelessWidget {
  const _SearchProgress({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('research-search-progress'),
      liveRegion: true,
      label: message,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(PakPerkSpacing.md),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: PakPerkSpacing.sm),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchFailureCard extends StatelessWidget {
  const _SearchFailureCard({required this.failure, required this.onRetry});

  final ResearchSearchFailure failure;
  final AsyncCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _SearchStatusCard(
      key: const ValueKey('research-search-failure'),
      icon: failure.retryable
          ? Icons.cloud_off_outlined
          : Icons.info_outline_rounded,
      title: failure.title,
      message: failure.message,
      error: failure.retryable,
      actions: failure.retryable
          ? FilledButton.icon(
              key: const ValueKey('research-search-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            )
          : null,
    );
  }
}

class _SearchStatusCard extends StatelessWidget {
  const _SearchStatusCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actions,
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? actions;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final semantic = context.pakPerkColors;
    return Semantics(
      liveRegion: true,
      container: true,
      label: '$title. $message',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(PakPerkSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                color: error ? semantic.destructive : semantic.processing,
              ),
              const SizedBox(width: PakPerkSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: PakPerkSpacing.xxs),
                    Text(message),
                    if (actions != null) ...[
                      const SizedBox(height: PakPerkSpacing.sm),
                      actions!,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _authorLabel(List<String> authors) {
  if (authors.isEmpty) return 'Authors unavailable';
  final visible = authors.take(3).join(', ');
  final remaining = authors.length - 3;
  return remaining > 0 ? '$visible, and $remaining more' : visible;
}

void _setText(TextEditingController controller, String value) {
  if (controller.text == value) return;
  controller.value = TextEditingValue(
    text: value,
    selection: TextSelection.collapsed(offset: value.length),
  );
}
