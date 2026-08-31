import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/account_providers.dart';
import '../../app/discovery_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/discovery_search/discovery_search_api.dart';
import '../../core/discovery_search/discovery_search_models.dart';
import '../../core/discovery_search/search_privacy_store.dart';
import '../../core/providers.dart';
import '../library/paper_import_flow.dart';
import 'research_search_controller.dart';
import 'research_search_models.dart';
import 'research_search_screen.dart';
import 'saved_query_subscription_controller.dart';
import 'search_privacy_controller.dart';

/// Binds the navigation-agnostic search UI to the landed v1 search contracts.
///
/// Search pages and raw queries remain controller-local. Account changes clear
/// saved-query responses synchronously and cancel the old authenticated task,
/// so an account-owned query can never flash in a later account scope.
final class ResearchSearchDestination extends ConsumerStatefulWidget {
  const ResearchSearchDestination({
    required this.onOpenPaper,
    required this.onMapPaper,
    super.key,
  });

  final ValueChanged<String> onOpenPaper;
  final ValueChanged<String> onMapPaper;

  @override
  ConsumerState<ResearchSearchDestination> createState() =>
      _ResearchSearchDestinationState();
}

final class _ResearchSearchDestinationState
    extends ConsumerState<ResearchSearchDestination> {
  late final DiscoverySearchRemoteDataSource _remote;
  late final ResearchSearchController _controller;
  late final SearchPrivacyController _privacyController;
  late final SavedQuerySubscriptionController _subscriptionController;
  ProviderSubscription<VerifiedDiscoveryAccountScope?>? _scopeSubscription;
  ResearchSearchAccountScope? _scope;
  RequestCancellation? _savedListRequest;
  List<SavedResearchQueryDraft> _savedQueries = const [];
  final Map<String, String> _saveOperationIds = {};
  final Map<String, RequestCancellation> _savedDeleteRequests = {};
  var _accountGeneration = 0;
  var _savedGeneration = 0;
  var _savedLoading = false;
  var _savedLoadFailed = false;

  @override
  void initState() {
    super.initState();
    final flags = ref.read(featureFlagsProvider);
    _remote = ref.read(discoverySearchApiProvider);
    _scope = _searchScope(ref.read(verifiedDiscoveryAccountScopeProvider));
    _privacyController = SearchPrivacyController(
      store: ref.read(searchPrivacyStoreProvider),
      accountDataWriteBarrier: ref.read(accountDataWriteBarrierProvider),
      accountScope: _scope,
    )..addListener(_onPrivacyChanged);
    _controller = ResearchSearchController(
      titleSearch: ref.read(paperResolutionApiProvider),
      lookupSearch: flags.searchLookupEnabled ? _remote : null,
      titleSearchEnabled: flags.searchLookupEnabled,
      accountScope: _scope,
      exploreExecutor: flags.searchExploreEnabled ? _explore : null,
      savedQueryCallback: flags.savedQueriesEnabled ? _saveQuery : null,
      onSearchCompleted: _recordCompletedSearch,
    );
    _subscriptionController = SavedQuerySubscriptionController(
      remote: ref.read(engagementApiProvider),
      accountScope: _scope,
      enabled: flags.savedQueriesEnabled && flags.subscriptionsEnabled,
    )..addListener(_onSubscriptionChanged);
    _scopeSubscription = ref.listenManual<VerifiedDiscoveryAccountScope?>(
      verifiedDiscoveryAccountScopeProvider,
      _onScopeChanged,
    );
    if (flags.savedQueriesEnabled && _scope != null) {
      unawaited(_loadSavedQueries());
    }
  }

  @override
  void dispose() {
    _scopeSubscription?.close();
    _savedListRequest?.cancel('The search destination closed.');
    for (final request in _savedDeleteRequests.values) {
      request.cancel('The search destination closed.');
    }
    _savedDeleteRequests.clear();
    _subscriptionController
      ..removeListener(_onSubscriptionChanged)
      ..dispose();
    _privacyController
      ..removeListener(_onPrivacyChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(featureFlagsProvider);
    if (!flags.searchLookupEnabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('Search')),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Research search is not enabled for this build.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }
    final canImport = ref.watch(paperImportAvailableProvider);
    final canSubscribe =
        flags.savedQueriesEnabled &&
        flags.subscriptionsEnabled &&
        _subscriptionController.available;
    final privacy = _privacyController.state;
    return ResearchSearchScreen(
      controller: _controller,
      onOpenPaper: widget.onOpenPaper,
      onMapPaper: widget.onMapPaper,
      onAddPaper: canImport
          ? (arxivId) => unawaited(
              showAccountAddPaperFlow(
                context: context,
                ref: ref,
                initialInput: arxivId,
              ),
            )
          : null,
      savedQueries: _savedQueries,
      savedQueriesLoading: _savedLoading,
      savedQueriesLoadFailed: _savedLoadFailed,
      onReloadSavedQueries: _loadSavedQueries,
      onSubscribeSavedQuery: canSubscribe
          ? _subscriptionController.subscribe
          : null,
      savedQuerySubscriptionPhase: _subscriptionController.phaseFor,
      savedQuerySubscriptionBusy: _subscriptionController.busy,
      onDeleteSavedQuery: _scope == null ? null : _deleteSavedQuery,
      savedQueryDeleting: (query) =>
          query.savedSearchId != null &&
          _savedDeleteRequests.containsKey(query.savedSearchId),
      privateHistoryAvailable: privacy.available,
      privateHistoryLoading: privacy.loading || privacy.saving,
      privateHistoryEnabled: privacy.enabled,
      privateHistoryEntries: privacy.entries,
      privateHistoryError: privacy.errorMessage,
      onPrivateHistoryEnabled: (enabled) =>
          unawaited(_privacyController.setEnabled(enabled)),
      onClearPrivateHistory: () => unawaited(_privacyController.clearHistory()),
      onReloadPrivateHistory: () => unawaited(_privacyController.reload()),
    );
  }

  void _onSubscriptionChanged() {
    if (mounted) setState(() {});
  }

  void _onPrivacyChanged() {
    if (mounted) setState(() {});
  }

  void _onScopeChanged(
    VerifiedDiscoveryAccountScope? previous,
    VerifiedDiscoveryAccountScope? next,
  ) {
    if (previous == next) return;
    _accountGeneration += 1;
    _savedGeneration += 1;
    _savedListRequest?.cancel('The saved-query account scope changed.');
    _savedListRequest = null;
    for (final request in _savedDeleteRequests.values) {
      request.cancel('The saved-query account scope changed.');
    }
    _savedDeleteRequests.clear();
    _saveOperationIds.clear();
    _scope = _searchScope(next);
    _controller.updateAccountScope(_scope);
    _privacyController.updateAccountScope(_scope);
    _subscriptionController.updateAccountScope(_scope);
    if (mounted) {
      setState(() {
        _savedQueries = const [];
        _savedLoading = false;
        _savedLoadFailed = false;
      });
    }
    if (ref.read(featureFlagsProvider).savedQueriesEnabled && _scope != null) {
      unawaited(_loadSavedQueries());
    }
  }

  ResearchSearchAccountScope? _searchScope(
    VerifiedDiscoveryAccountScope? scope,
  ) {
    if (scope == null) return null;
    return ResearchSearchAccountScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      accountGeneration: _accountGeneration,
    );
  }

  Future<ExploreSearchPresentation> _explore(
    ExploreSearchDraft draft,
    RequestCancellation cancellation,
  ) async {
    final scope = _scope;
    final filters = _filters(draft);
    final sort = switch (draft.sortOrder) {
      ExploreSortOrder.relevance => DiscoverySearchSort.relevance,
      ExploreSortOrder.newest => DiscoverySearchSort.recency,
    };
    final fingerprint = exploreSearchCacheFingerprint(
      query: draft.query,
      categories: filters.categories,
      topics: filters.topics,
      sort: sort.name,
      publishedAfter: filters.publishedAfter,
      publishedBefore: filters.publishedBefore,
    );
    try {
      final page = await _remote.explore(
        query: draft.query,
        filters: filters,
        sort: sort,
        cancellation: cancellation,
      );
      final presentation = ExploreSearchPresentation(
        papers: page.items.map((item) => item.paper),
        coverageLabel:
            'Partial arXiv metadata coverage · ${page.matchesReturned} matches',
        disclaimer: page.disclaimer!,
      );
      if (scope != null &&
          _scope == scope &&
          !cancellation.isCancelled &&
          presentation.papers.isNotEmpty) {
        unawaited(_cacheExploreResult(scope, fingerprint, presentation));
      }
      return presentation;
    } on ApiException catch (error) {
      if (!error.permitsDerivedFallback ||
          error.cancelled ||
          cancellation.isCancelled ||
          scope == null ||
          _scope != scope) {
        rethrow;
      }
      final cached = await ref
          .read(searchPrivacyStoreProvider)
          .loadExplore(scope.accountId, fingerprint);
      if (cancellation.isCancelled || _scope != scope || cached == null) {
        rethrow;
      }
      return ExploreSearchPresentation(
        papers: cached.papers,
        coverageLabel: '${cached.coverageLabel} · saved on this device',
        disclaimer: cached.disclaimer,
      );
    }
  }

  Future<void> _cacheExploreResult(
    ResearchSearchAccountScope scope,
    String fingerprint,
    ExploreSearchPresentation presentation,
  ) async {
    final now = DateTime.now().toUtc();
    final entry = ExploreSearchCacheEntry(
      queryFingerprint: fingerprint,
      papers: presentation.papers,
      coverageLabel: presentation.coverageLabel,
      disclaimer: presentation.disclaimer,
      cachedAt: now,
      expiresAt: now.add(const Duration(minutes: 15)),
    );
    try {
      await ref
          .read(accountDataWriteBarrierProvider)
          .writeIfCurrent(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            isCurrent: () => mounted && _scope == scope,
            write: () => ref
                .read(searchPrivacyStoreProvider)
                .saveExplore(scope.accountId, entry),
          );
    } on Object {
      // Explore remains a live network result when its derived cache fails.
    }
  }

  void _recordCompletedSearch(ResearchSearchMode mode, String query) {
    unawaited(
      _privacyController.record(
        mode == ResearchSearchMode.lookup
            ? PrivateSearchHistoryMode.lookup
            : PrivateSearchHistoryMode.explore,
        query,
      ),
    );
  }

  Future<void> _saveQuery(
    SavedResearchQueryDraft draft,
    RequestCancellation cancellation,
  ) async {
    final scope = _scope;
    if (scope == null) {
      throw const ApiException(
        code: 'UNAUTHENTICATED',
        message: 'Sign in before saving a query.',
        retryable: false,
        statusCode: 401,
      );
    }
    final key = _operationKey(draft);
    final operationId = _saveOperationIds.putIfAbsent(
      key,
      () => const Uuid().v7(),
    );
    await _remote.save(
      operationId: operationId,
      query: draft.query,
      filters: _savedFilters(draft),
      sort: switch (draft.sortOrder) {
        ExploreSortOrder.newest => DiscoverySearchSort.recency,
        _ => DiscoverySearchSort.relevance,
      },
      expectedAuthEpoch: scope.authEpoch,
      cancellation: cancellation,
    );
    if (_scope == scope) await _loadSavedQueries();
  }

  Future<void> _loadSavedQueries() async {
    final scope = _scope;
    if (scope == null || !ref.read(featureFlagsProvider).savedQueriesEnabled) {
      return;
    }
    _savedListRequest?.cancel('A newer saved-query refresh started.');
    final request = RequestCancellation();
    _savedListRequest = request;
    final generation = ++_savedGeneration;
    if (mounted) {
      setState(() {
        _savedLoading = true;
        _savedLoadFailed = false;
      });
    }
    try {
      final saved = await _remote.listSaved(
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (!mounted || _scope != scope || generation != _savedGeneration) {
        return;
      }
      setState(() {
        _savedQueries = saved.map(_savedDraft).toList(growable: false);
        _savedLoading = false;
        _savedLoadFailed = false;
      });
    } on ApiException catch (error) {
      if (!mounted ||
          error.cancelled ||
          _scope != scope ||
          generation != _savedGeneration) {
        return;
      }
      setState(() {
        _savedQueries = const [];
        _savedLoading = false;
        _savedLoadFailed = true;
      });
    } on Object {
      if (!mounted || _scope != scope || generation != _savedGeneration) {
        return;
      }
      setState(() {
        _savedQueries = const [];
        _savedLoading = false;
        _savedLoadFailed = true;
      });
    } finally {
      if (identical(_savedListRequest, request)) _savedListRequest = null;
    }
  }

  Future<void> _deleteSavedQuery(SavedResearchQueryDraft query) async {
    final scope = _scope;
    final savedSearchId = query.savedSearchId;
    if (scope == null ||
        savedSearchId == null ||
        _savedDeleteRequests.containsKey(savedSearchId)) {
      return;
    }
    _savedListRequest?.cancel('A saved query is being deleted.');
    _savedListRequest = null;
    _savedGeneration += 1;
    final request = RequestCancellation();
    _savedDeleteRequests[savedSearchId] = request;
    if (mounted) setState(() {});
    try {
      await _remote.deleteSaved(
        savedSearchId: savedSearchId,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (!mounted || request.isCancelled || _scope != scope) return;
      _subscriptionController.forgetSavedQuery(savedSearchId);
      setState(() {
        _savedQueries = _savedQueries
            .where((candidate) => candidate.savedSearchId != savedSearchId)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Saved query deleted. Linked alerts were turned off.',
            ),
          ),
        );
    } on ApiException catch (error) {
      if (!mounted ||
          error.cancelled ||
          request.isCancelled ||
          _scope != scope) {
        return;
      }
      _showDeleteFailure();
    } on Object {
      if (!mounted || request.isCancelled || _scope != scope) return;
      _showDeleteFailure();
    } finally {
      if (identical(_savedDeleteRequests[savedSearchId], request)) {
        _savedDeleteRequests.remove(savedSearchId);
        if (mounted) setState(() {});
      }
    }
  }

  void _showDeleteFailure() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Couldn’t delete the saved query. Please try again.'),
        ),
      );
  }
}

DiscoverySearchFilters _filters(ExploreSearchDraft draft) {
  final after =
      draft.publishedAfter ??
      switch (draft.dateRange) {
        ExploreDateRange.pastYear => _daysAgo(365),
        ExploreDateRange.pastFiveYears => _daysAgo(365 * 5),
        _ => null,
      };
  return DiscoverySearchFilters(
    categories: draft.categories,
    topics: draft.topics,
    publishedAfter: after,
    publishedBefore: draft.publishedBefore,
  );
}

DiscoverySearchFilters _savedFilters(SavedResearchQueryDraft draft) =>
    DiscoverySearchFilters(
      categories: draft.categories,
      topics: draft.topics,
      publishedAfter:
          draft.publishedAfter ??
          switch (draft.dateRange) {
            ExploreDateRange.pastYear => _daysAgo(365),
            ExploreDateRange.pastFiveYears => _daysAgo(365 * 5),
            _ => null,
          },
      publishedBefore: draft.publishedBefore,
    );

SavedResearchQueryDraft _savedDraft(DiscoverySavedSearch saved) =>
    SavedResearchQueryDraft.savedExplore(
      savedSearchId: saved.id,
      draft: ExploreSearchDraft(
        query: saved.query,
        categories: saved.filters.categories,
        topics: saved.filters.topics,
        sortOrder: saved.sort == DiscoverySearchSort.recency
            ? ExploreSortOrder.newest
            : ExploreSortOrder.relevance,
        dateRange:
            saved.filters.publishedAfter != null ||
                saved.filters.publishedBefore != null
            ? ExploreDateRange.savedRange
            : ExploreDateRange.anyTime,
        publishedAfter: saved.filters.publishedAfter,
        publishedBefore: saved.filters.publishedBefore,
      ),
    );

String _operationKey(SavedResearchQueryDraft draft) => jsonEncode({
  'query': draft.query,
  'categories': draft.categories,
  'topics': draft.topics,
  'sort': draft.sortOrder?.name,
  'date': draft.dateRange?.name,
  'after': draft.publishedAfter,
  'before': draft.publishedBefore,
});

String _daysAgo(int days) {
  final value = DateTime.now().toUtc().subtract(Duration(days: days));
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
