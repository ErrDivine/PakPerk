import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/discovery_search/discovery_search_api.dart';
import '../../core/discovery_search/discovery_search_models.dart';
import '../../core/paper_resolution/paper_input_classifier.dart';
import '../../core/paper_resolution/paper_resolution_api.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';
import 'research_search_models.dart';

/// Owns one short-lived search task.
///
/// The confirmed title-search response is `private, no-store`, so the current
/// result exists only in this controller and is cleared on input, mode,
/// account-generation, or lifecycle changes. Durable behavior remains an
/// explicit caller concern: [onSearchCompleted] can feed an opt-in private
/// recorder, while an injected Explore executor may apply a derived cache.
final class ResearchSearchController extends ChangeNotifier {
  ResearchSearchController({
    required PaperResolutionRemoteDataSource titleSearch,
    required ResearchSearchAccountScope? accountScope,
    this.lookupSearch,
    this.titleSearchEnabled = true,
    this.exploreExecutor,
    this.savedQueryCallback,
    this.onSearchCompleted,
    this.lookupDebounce = const Duration(milliseconds: 400),
    this.lookupLimit = 10,
    PaperInputClassifier classifier = const PaperInputClassifier(),
  }) : assert(lookupLimit >= 1 && lookupLimit <= 10),
       _titleSearch = titleSearch,
       _scope = accountScope,
       _classifier = classifier,
       _state = ResearchSearchState.initial();

  final PaperResolutionRemoteDataSource _titleSearch;
  final DiscoverySearchRemoteDataSource? lookupSearch;
  final PaperInputClassifier _classifier;
  final bool titleSearchEnabled;
  final ExploreSearchExecutor? exploreExecutor;
  final SavedResearchQueryCallback? savedQueryCallback;
  final ResearchSearchCompletedCallback? onSearchCompleted;
  final Duration lookupDebounce;
  final int lookupLimit;

  ResearchSearchAccountScope? _scope;
  ResearchSearchState _state;
  ClassifiedPaperInput? _lookupClassification;
  Timer? _debounce;
  RequestCancellation? _request;
  RequestCancellation? _suggestionRequest;
  int _generation = 0;
  bool _disposed = false;

  ResearchSearchState get state => _state;
  ResearchSearchAccountScope? get accountScope => _scope;
  bool get exploreAvailable => exploreExecutor != null;
  bool get savedQueriesAvailable =>
      exploreAvailable && savedQueryCallback != null && _scope != null;

  void updateAccountScope(ResearchSearchAccountScope? next) {
    if (_scope == next) return;
    _scope = next;
    _invalidate('The search account scope changed.');
    _lookupClassification = null;
    _publish(
      ResearchSearchState(
        mode: _state.mode,
        phase: _state.mode == ResearchSearchMode.explore && !exploreAvailable
            ? ResearchSearchPhase.unavailable
            : ResearchSearchPhase.idle,
        exploreDraft: ExploreSearchDraft(query: ''),
      ),
    );
  }

  void setMode(ResearchSearchMode mode) {
    if (_disposed || mode == _state.mode) return;
    _invalidate('The search intent changed.');
    _lookupClassification = null;
    _publish(
      ResearchSearchState(
        mode: mode,
        phase: mode == ResearchSearchMode.explore && !exploreAvailable
            ? ResearchSearchPhase.unavailable
            : ResearchSearchPhase.idle,
        exploreDraft: _state.exploreDraft,
      ),
    );
  }

  void updateLookupInput(String input) {
    if (_disposed || _state.mode != ResearchSearchMode.lookup) return;
    _invalidate('The lookup input changed.');
    if (input.trim().isEmpty) {
      _lookupClassification = null;
      _publish(
        ResearchSearchState(
          mode: ResearchSearchMode.lookup,
          phase: ResearchSearchPhase.idle,
          lookupInput: input,
          exploreDraft: _state.exploreDraft,
        ),
      );
      return;
    }

    late final ClassifiedPaperInput classification;
    try {
      classification = _classifier.classify(input);
    } on PaperInputException catch (error) {
      _lookupClassification = null;
      _publish(
        ResearchSearchState(
          mode: ResearchSearchMode.lookup,
          phase: ResearchSearchPhase.failed,
          lookupInput: input,
          exploreDraft: _state.exploreDraft,
          failure: ResearchSearchFailure(
            code: error.reason.name,
            title: 'Check this lookup',
            message: error.message,
            retryable: false,
          ),
        ),
      );
      return;
    }
    _lookupClassification = classification;
    if (classification.isExact) {
      _publish(
        ResearchSearchState(
          mode: ResearchSearchMode.lookup,
          phase: ResearchSearchPhase.exactReady,
          lookupInput: input,
          normalizedExactArxivId: classification.identifier!.queryId,
          exploreDraft: _state.exploreDraft,
        ),
      );
      return;
    }
    if (!titleSearchEnabled) {
      _publish(_lookupUnavailable(input, 'Title lookup is not enabled.'));
      return;
    }
    if (_scope == null && lookupSearch == null) {
      _publish(
        _lookupUnavailable(
          input,
          'Sign in to search by title. arXiv links and IDs still open directly.',
        ),
      );
      return;
    }
    _publish(
      ResearchSearchState(
        mode: ResearchSearchMode.lookup,
        phase: ResearchSearchPhase.waiting,
        lookupInput: input,
        exploreDraft: _state.exploreDraft,
      ),
    );
    final requestScope = _scope;
    final generation = _generation;
    _debounce = Timer(lookupDebounce, () {
      _debounce = null;
      if (_isLookupCurrent(generation, requestScope) &&
          identical(_lookupClassification, classification)) {
        unawaited(_searchTitle(classification));
      }
    });
  }

  Future<void> lookupNow() async {
    final classification = _lookupClassification;
    if (classification == null || classification.kind != PaperInputKind.title) {
      return;
    }
    await _searchTitle(classification);
  }

  void updateExploreDraft(ExploreSearchDraft draft) {
    if (_disposed) return;
    _invalidate('The explore query changed.');
    _publish(
      _state.copyWith(
        mode: ResearchSearchMode.explore,
        phase: exploreAvailable
            ? ResearchSearchPhase.idle
            : ResearchSearchPhase.unavailable,
        exploreDraft: draft,
        clearExplorePresentation: true,
        clearFailure: true,
        querySaved: false,
      ),
    );
  }

  void updateExploreQuery(String query) {
    updateExploreDraft(_state.exploreDraft.copyWith(query: query));
  }

  void updateExploreSortOrder(ExploreSortOrder sortOrder) {
    updateExploreDraft(_state.exploreDraft.copyWith(sortOrder: sortOrder));
  }

  void updateExploreDateRange(ExploreDateRange dateRange) {
    updateExploreDraft(
      _state.exploreDraft.copyWith(
        dateRange: dateRange,
        clearConcreteDates: true,
      ),
    );
  }

  void setExploreCategory(String category, {required bool selected}) {
    final categories = [..._state.exploreDraft.categories];
    if (selected) {
      if (!categories.contains(category)) categories.add(category);
    } else {
      categories.remove(category);
    }
    updateExploreDraft(_state.exploreDraft.copyWith(categories: categories));
  }

  void selectSuggestion(DiscoveryRelatedTopic suggestion) {
    if (_disposed || _state.mode != ResearchSearchMode.lookup) return;
    if (exploreAvailable) {
      setMode(ResearchSearchMode.explore);
      updateExploreDraft(ExploreSearchDraft(query: suggestion.label));
      return;
    }
    updateLookupInput(suggestion.label);
  }

  void applySavedQuery(SavedResearchQueryDraft saved) {
    if (_disposed || saved.mode != ResearchSearchMode.explore) return;
    setMode(ResearchSearchMode.explore);
    updateExploreDraft(
      ExploreSearchDraft(
        query: saved.query,
        categories: saved.categories,
        topics: saved.topics,
        sortOrder: saved.sortOrder ?? ExploreSortOrder.relevance,
        dateRange: saved.dateRange ?? ExploreDateRange.anyTime,
        publishedAfter: saved.publishedAfter,
        publishedBefore: saved.publishedBefore,
      ),
    );
  }

  Future<void> submitExplore() async {
    final executor = exploreExecutor;
    final draft = _state.exploreDraft;
    if (_disposed || _state.mode != ResearchSearchMode.explore) return;
    if (executor == null) {
      _publish(
        _state.copyWith(
          phase: ResearchSearchPhase.unavailable,
          failure: _exploreUnavailable,
        ),
      );
      return;
    }
    if (!draft.canSubmit) {
      _publish(
        _state.copyWith(
          phase: ResearchSearchPhase.failed,
          failure: const ResearchSearchFailure(
            code: 'INVALID_EXPLORE_QUERY',
            title: 'Add a search topic',
            message: 'Explore queries must contain at least 3 characters.',
            retryable: false,
          ),
        ),
      );
      return;
    }
    _invalidate('A newer Explore search replaced this one.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    _publish(
      _state.copyWith(
        phase: ResearchSearchPhase.searching,
        clearExplorePresentation: true,
        clearFailure: true,
        querySaved: false,
      ),
    );
    try {
      final result = await executor(draft, request);
      if (!_isGenerationCurrent(generation)) return;
      _publish(
        _state.copyWith(
          phase: result.papers.isEmpty
              ? ResearchSearchPhase.empty
              : ResearchSearchPhase.results,
          explorePresentation: result,
          clearFailure: true,
        ),
      );
      _notifySearchCompleted(ResearchSearchMode.explore, draft.query);
    } on ApiException catch (error) {
      if (!_isGenerationCurrent(generation) || error.cancelled) return;
      _publish(_failureState(error, title: 'Couldn’t explore papers'));
    } on Object {
      if (!_isGenerationCurrent(generation)) return;
      _publish(_unexpectedFailure('Couldn’t explore papers'));
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> retry() async {
    if (!(_state.failure?.retryable ?? false)) return;
    if (_state.mode == ResearchSearchMode.lookup) {
      await lookupNow();
    } else {
      await submitExplore();
    }
  }

  Future<void> saveCurrentQuery() async {
    final callback = savedQueryCallback;
    if (_disposed ||
        callback == null ||
        !savedQueriesAvailable ||
        _state.mode != ResearchSearchMode.explore ||
        _state.savingQuery) {
      return;
    }
    final draft = _state.exploreDraft.canSubmit
        ? SavedResearchQueryDraft.explore(_state.exploreDraft)
        : null;
    if (draft == null) return;
    _invalidate('A newer saved-query task replaced this one.');
    final request = RequestCancellation();
    _request = request;
    final requestScope = _scope;
    final generation = ++_generation;
    _publish(
      _state.copyWith(savingQuery: true, querySaved: false, clearFailure: true),
    );
    try {
      await callback(draft, request);
      if (!_isGenerationCurrent(generation) || _scope != requestScope) return;
      _publish(_state.copyWith(savingQuery: false, querySaved: true));
    } on ApiException catch (error) {
      if (!_isGenerationCurrent(generation) ||
          _scope != requestScope ||
          error.cancelled) {
        return;
      }
      _publish(
        _failureState(
          error,
          title: 'Couldn’t save this query',
        ).copyWith(savingQuery: false),
      );
    } on Object {
      if (!_isGenerationCurrent(generation) || _scope != requestScope) return;
      _publish(
        _unexpectedFailure(
          'Couldn’t save this query',
        ).copyWith(savingQuery: false),
      );
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _searchTitle(ClassifiedPaperInput classification) async {
    final requestScope = _scope;
    if (_disposed ||
        (requestScope == null && lookupSearch == null) ||
        !identical(_lookupClassification, classification) ||
        !titleSearchEnabled) {
      return;
    }
    _debounce?.cancel();
    _debounce = null;
    _request?.cancel('A newer title lookup replaced this one.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    if (lookupSearch != null) {
      final suggestionRequest = RequestCancellation();
      _suggestionRequest?.cancel('A newer suggestion request started.');
      _suggestionRequest = suggestionRequest;
      unawaited(
        _loadSuggestions(
          classification: classification,
          requestScope: requestScope,
          generation: generation,
          request: suggestionRequest,
        ),
      );
    }
    _publish(
      ResearchSearchState(
        mode: ResearchSearchMode.lookup,
        phase: ResearchSearchPhase.searching,
        lookupInput: _state.lookupInput,
        exploreDraft: _state.exploreDraft,
      ),
    );
    try {
      final candidates = lookupSearch == null
          ? (await _titleSearch.searchByTitle(
              query: classification.normalizedValue,
              expectedAuthEpoch: requestScope!.authEpoch,
              limit: lookupLimit,
              cancellation: request,
            )).candidates
          : _lookupCandidates(
              await lookupSearch!.lookup(
                query: classification.normalizedValue,
                limit: lookupLimit,
                cancellation: request,
              ),
            );
      if (!_isLookupCurrent(generation, requestScope) ||
          !identical(_lookupClassification, classification)) {
        return;
      }
      _publish(
        ResearchSearchState(
          mode: ResearchSearchMode.lookup,
          phase: candidates.isEmpty
              ? ResearchSearchPhase.empty
              : ResearchSearchPhase.results,
          lookupInput: _state.lookupInput,
          lookupCandidates: candidates,
          lookupSuggestions: _state.lookupSuggestions,
          exploreDraft: _state.exploreDraft,
        ),
      );
      _notifySearchCompleted(
        ResearchSearchMode.lookup,
        classification.normalizedValue,
      );
    } on ApiException catch (error) {
      if (!_isLookupCurrent(generation, requestScope) || error.cancelled) {
        return;
      }
      _publish(_failureState(error, title: 'Couldn’t look up papers'));
    } on Object {
      if (!_isLookupCurrent(generation, requestScope)) return;
      _publish(_unexpectedFailure('Couldn’t look up papers'));
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _loadSuggestions({
    required ClassifiedPaperInput classification,
    required ResearchSearchAccountScope? requestScope,
    required int generation,
    required RequestCancellation request,
  }) async {
    try {
      final suggestions = await lookupSearch!.suggestions(
        query: classification.normalizedValue,
        cancellation: request,
      );
      if (!_isLookupCurrent(generation, requestScope) ||
          !identical(_lookupClassification, classification)) {
        return;
      }
      _publish(_state.copyWith(lookupSuggestions: suggestions.items));
    } on Object {
      // Supplementary local-vocabulary suggestions never block Lookup.
    } finally {
      if (identical(_suggestionRequest, request)) _suggestionRequest = null;
    }
  }

  ResearchSearchState _lookupUnavailable(String input, String message) =>
      ResearchSearchState(
        mode: ResearchSearchMode.lookup,
        phase: ResearchSearchPhase.unavailable,
        lookupInput: input,
        exploreDraft: _state.exploreDraft,
        failure: ResearchSearchFailure(
          code: 'LOOKUP_UNAVAILABLE',
          title: 'Title lookup unavailable',
          message: message,
          retryable: false,
        ),
      );

  ResearchSearchState _failureState(
    ApiException error, {
    required String title,
  }) => _state.copyWith(
    phase: ResearchSearchPhase.failed,
    failure: ResearchSearchFailure(
      code: _safeCode(error.code),
      title: title,
      message: _failureMessage(error),
      retryable: error.retryable,
    ),
  );

  ResearchSearchState _unexpectedFailure(String title) => _state.copyWith(
    phase: ResearchSearchPhase.failed,
    failure: ResearchSearchFailure(
      code: 'SEARCH_UNAVAILABLE',
      title: title,
      message: 'Search is temporarily unavailable.',
      retryable: true,
    ),
  );

  bool _isLookupCurrent(int generation, ResearchSearchAccountScope? scope) =>
      _isGenerationCurrent(generation) && _scope == scope;

  bool _isGenerationCurrent(int generation) =>
      !_disposed && generation == _generation;

  void _invalidate(String reason) {
    _generation += 1;
    _debounce?.cancel();
    _debounce = null;
    _request?.cancel(reason);
    _request = null;
    _suggestionRequest?.cancel(reason);
    _suggestionRequest = null;
  }

  void _publish(ResearchSearchState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  void _notifySearchCompleted(ResearchSearchMode mode, String query) {
    try {
      onSearchCompleted?.call(mode, query);
    } on Object {
      // An optional local-history recorder cannot fail the search itself.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate('The search task closed.');
    _lookupClassification = null;
    _state = ResearchSearchState.initial();
    super.dispose();
  }
}

List<PaperSearchCandidate> _lookupCandidates(DiscoverySearchPage page) =>
    List<PaperSearchCandidate>.unmodifiable(
      page.items.indexed.map((entry) {
        final paper = entry.$2.paper;
        final absUri = paper.canonicalAbsUri;
        if (absUri == null) {
          throw const FormatException(
            'Search returned an invalid arXiv paper.',
          );
        }
        return PaperSearchCandidate(
          arxivId: paper.arxivId,
          title: paper.title,
          authors: paper.authors,
          abstractText: paper.abstractText,
          primaryCategory: paper.primaryCategory,
          categories: paper.categories,
          publishedAt: paper.publishedAt,
          updatedAt: paper.updatedAt,
          absUri: absUri,
          rank: entry.$1 + 1,
        );
      }),
    );

const _exploreUnavailable = ResearchSearchFailure(
  code: 'EXPLORE_SEARCH_UNAVAILABLE',
  title: 'Explore search is not enabled',
  message:
      'Recent papers are not substituted for a query search. Try again after '
      'Explore search is enabled.',
  retryable: false,
);

String _failureMessage(ApiException error) => switch (error.code) {
  'RATE_LIMITED' => 'Too many searches. Wait a moment and try again.',
  'UNAUTHENTICATED' ||
  'TOKEN_EXPIRED' => 'Sign in again before searching by title.',
  'PAPER_SEARCH_QUERY_TOO_SHORT' ||
  'INVALID_PAPER_INPUT' => 'Enter a more specific paper title.',
  _ => 'Search is temporarily unavailable.',
};

String _safeCode(String value) =>
    RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value)
    ? value
    : 'SEARCH_UNAVAILABLE';
