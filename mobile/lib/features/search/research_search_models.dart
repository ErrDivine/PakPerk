import 'package:flutter/foundation.dart';

import '../../core/api/request_cancellation.dart';
import '../../core/discovery_search/discovery_search_models.dart';
import '../../core/models/paper.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';

enum ResearchSearchMode { lookup, explore }

enum ResearchSearchPhase {
  idle,
  exactReady,
  waiting,
  searching,
  results,
  empty,
  unavailable,
  failed,
}

enum ExploreSortOrder {
  relevance('Relevance'),
  newest('Newest');

  const ExploreSortOrder(this.label);

  final String label;
}

enum ExploreDateRange {
  anyTime('Any time'),
  pastYear('Past year'),
  pastFiveYears('Past 5 years'),
  savedRange('Saved range');

  const ExploreDateRange(this.label);

  final String label;
}

@immutable
final class ResearchSearchAccountScope {
  const ResearchSearchAccountScope({
    required this.accountId,
    required this.authEpoch,
    required this.accountGeneration,
  }) : assert(accountId != ''),
       assert(authEpoch >= 0),
       assert(accountGeneration >= 0);

  final String accountId;
  final int authEpoch;
  final int accountGeneration;

  @override
  bool operator ==(Object other) =>
      other is ResearchSearchAccountScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.accountGeneration == accountGeneration;

  @override
  int get hashCode => Object.hash(accountId, authEpoch, accountGeneration);

  @override
  String toString() =>
      'ResearchSearchAccountScope(accountId: <redacted>, '
      'authEpoch: $authEpoch, accountGeneration: $accountGeneration)';
}

@immutable
final class ResearchSearchFailure {
  const ResearchSearchFailure({
    required this.code,
    required this.title,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String title;
  final String message;
  final bool retryable;
}

@immutable
final class ExploreSearchDraft {
  ExploreSearchDraft({
    required String query,
    Iterable<String> categories = const [],
    Iterable<String> topics = const [],
    this.sortOrder = ExploreSortOrder.relevance,
    this.dateRange = ExploreDateRange.anyTime,
    this.publishedAfter,
    this.publishedBefore,
  }) : query = _normalizeQuery(query),
       categories = _normalizeCategories(categories),
       topics = _normalizeCategories(topics) {
    if (dateRange == ExploreDateRange.savedRange &&
        publishedAfter == null &&
        publishedBefore == null) {
      throw ArgumentError('A saved date range requires a concrete date.');
    }
  }

  final String query;
  final List<String> categories;
  final List<String> topics;
  final ExploreSortOrder sortOrder;
  final ExploreDateRange dateRange;
  final String? publishedAfter;
  final String? publishedBefore;

  bool get canSubmit => query.runes.length >= 3;

  ExploreSearchDraft copyWith({
    String? query,
    Iterable<String>? categories,
    Iterable<String>? topics,
    ExploreSortOrder? sortOrder,
    ExploreDateRange? dateRange,
    String? publishedAfter,
    String? publishedBefore,
    bool clearConcreteDates = false,
  }) => ExploreSearchDraft(
    query: query ?? this.query,
    categories: categories ?? this.categories,
    topics: topics ?? this.topics,
    sortOrder: sortOrder ?? this.sortOrder,
    dateRange: dateRange ?? this.dateRange,
    publishedAfter: clearConcreteDates
        ? null
        : publishedAfter ?? this.publishedAfter,
    publishedBefore: clearConcreteDates
        ? null
        : publishedBefore ?? this.publishedBefore,
  );

  @override
  String toString() =>
      'ExploreSearchDraft(query: <redacted>, queryChars: '
      '${query.runes.length}, categories: ${categories.length}, '
      'topics: ${topics.length}, '
      'sortOrder: ${sortOrder.name}, dateRange: ${dateRange.name})';
}

@immutable
final class ExploreSearchPresentation {
  ExploreSearchPresentation({
    required Iterable<PaperSummary> papers,
    required this.coverageLabel,
    this.disclaimer = 'This is not a systematic or exhaustive search.',
  }) : papers = List<PaperSummary>.unmodifiable(papers);

  final List<PaperSummary> papers;
  final String coverageLabel;
  final String disclaimer;
}

@immutable
final class SavedResearchQueryDraft {
  const SavedResearchQueryDraft._({
    required this.mode,
    required this.query,
    required this.categories,
    required this.topics,
    required this.sortOrder,
    required this.dateRange,
    required this.publishedAfter,
    required this.publishedBefore,
    required this.savedSearchId,
  });

  factory SavedResearchQueryDraft.lookup(String query) =>
      SavedResearchQueryDraft._(
        mode: ResearchSearchMode.lookup,
        query: _normalizeQuery(query),
        categories: const [],
        topics: const [],
        sortOrder: null,
        dateRange: null,
        publishedAfter: null,
        publishedBefore: null,
        savedSearchId: null,
      );

  factory SavedResearchQueryDraft.explore(ExploreSearchDraft draft) =>
      SavedResearchQueryDraft._(
        mode: ResearchSearchMode.explore,
        query: draft.query,
        categories: draft.categories,
        topics: draft.topics,
        sortOrder: draft.sortOrder,
        dateRange: draft.dateRange,
        publishedAfter: draft.publishedAfter,
        publishedBefore: draft.publishedBefore,
        savedSearchId: null,
      );

  factory SavedResearchQueryDraft.savedExplore({
    required String savedSearchId,
    required ExploreSearchDraft draft,
  }) {
    final normalizedId = savedSearchId.trim().toLowerCase();
    if (!_savedSearchIdPattern.hasMatch(normalizedId)) {
      throw ArgumentError.value(savedSearchId, 'savedSearchId');
    }
    return SavedResearchQueryDraft._(
      mode: ResearchSearchMode.explore,
      query: draft.query,
      categories: draft.categories,
      topics: draft.topics,
      sortOrder: draft.sortOrder,
      dateRange: draft.dateRange,
      publishedAfter: draft.publishedAfter,
      publishedBefore: draft.publishedBefore,
      savedSearchId: normalizedId,
    );
  }

  final ResearchSearchMode mode;
  final String query;
  final List<String> categories;
  final List<String> topics;
  final ExploreSortOrder? sortOrder;
  final ExploreDateRange? dateRange;
  final String? publishedAfter;
  final String? publishedBefore;
  final String? savedSearchId;

  @override
  String toString() =>
      'SavedResearchQueryDraft(mode: ${mode.name}, query: <redacted>, '
      'queryChars: ${query.runes.length}, categories: ${categories.length}, '
      'persisted: ${savedSearchId != null})';
}

typedef ExploreSearchExecutor =
    Future<ExploreSearchPresentation> Function(
      ExploreSearchDraft draft,
      RequestCancellation cancellation,
    );

typedef SavedResearchQueryCallback =
    Future<void> Function(
      SavedResearchQueryDraft draft,
      RequestCancellation cancellation,
    );

typedef ResearchSearchCompletedCallback =
    void Function(ResearchSearchMode mode, String normalizedQuery);

@immutable
final class ResearchSearchState {
  ResearchSearchState({
    required this.mode,
    required this.phase,
    this.lookupInput = '',
    this.normalizedExactArxivId,
    Iterable<PaperSearchCandidate> lookupCandidates = const [],
    Iterable<DiscoveryRelatedTopic> lookupSuggestions = const [],
    ExploreSearchDraft? exploreDraft,
    this.explorePresentation,
    this.failure,
    this.savingQuery = false,
    this.querySaved = false,
  }) : lookupCandidates = List<PaperSearchCandidate>.unmodifiable(
         lookupCandidates,
       ),
       lookupSuggestions = List<DiscoveryRelatedTopic>.unmodifiable(
         lookupSuggestions,
       ),
       exploreDraft =
           exploreDraft ?? ExploreSearchDraft(query: '', categories: const []);

  factory ResearchSearchState.initial() => ResearchSearchState(
    mode: ResearchSearchMode.lookup,
    phase: ResearchSearchPhase.idle,
  );

  final ResearchSearchMode mode;
  final ResearchSearchPhase phase;
  final String lookupInput;
  final String? normalizedExactArxivId;
  final List<PaperSearchCandidate> lookupCandidates;
  final List<DiscoveryRelatedTopic> lookupSuggestions;
  final ExploreSearchDraft exploreDraft;
  final ExploreSearchPresentation? explorePresentation;
  final ResearchSearchFailure? failure;
  final bool savingQuery;
  final bool querySaved;

  bool get busy => phase == ResearchSearchPhase.searching || savingQuery;

  ResearchSearchState copyWith({
    ResearchSearchMode? mode,
    ResearchSearchPhase? phase,
    String? lookupInput,
    String? normalizedExactArxivId,
    bool clearExactArxivId = false,
    Iterable<PaperSearchCandidate>? lookupCandidates,
    Iterable<DiscoveryRelatedTopic>? lookupSuggestions,
    ExploreSearchDraft? exploreDraft,
    ExploreSearchPresentation? explorePresentation,
    bool clearExplorePresentation = false,
    ResearchSearchFailure? failure,
    bool clearFailure = false,
    bool? savingQuery,
    bool? querySaved,
  }) => ResearchSearchState(
    mode: mode ?? this.mode,
    phase: phase ?? this.phase,
    lookupInput: lookupInput ?? this.lookupInput,
    normalizedExactArxivId: clearExactArxivId
        ? null
        : normalizedExactArxivId ?? this.normalizedExactArxivId,
    lookupCandidates: lookupCandidates ?? this.lookupCandidates,
    lookupSuggestions: lookupSuggestions ?? this.lookupSuggestions,
    exploreDraft: exploreDraft ?? this.exploreDraft,
    explorePresentation: clearExplorePresentation
        ? null
        : explorePresentation ?? this.explorePresentation,
    failure: clearFailure ? null : failure ?? this.failure,
    savingQuery: savingQuery ?? this.savingQuery,
    querySaved: querySaved ?? this.querySaved,
  );

  @override
  String toString() =>
      'ResearchSearchState(mode: ${mode.name}, phase: ${phase.name}, '
      'lookupInput: <redacted>, lookupChars: ${lookupInput.runes.length}, '
      'lookupCandidates: ${lookupCandidates.length}, '
      'lookupSuggestions: ${lookupSuggestions.length}, '
      'exploreQueryChars: ${exploreDraft.query.runes.length}, '
      'exploreResults: ${explorePresentation?.papers.length ?? 0}, '
      'savingQuery: $savingQuery, querySaved: $querySaved)';
}

String _normalizeQuery(String value) => value
    .trim()
    .split(RegExp(r'\s+'))
    .where((part) => part.isNotEmpty)
    .join(' ');

List<String> _normalizeCategories(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    if (!RegExp(r'^[a-zA-Z-]+(?:\.[A-Za-z0-9-]+)?$').hasMatch(value) ||
        value.length > 32) {
      throw ArgumentError.value(raw, 'categories', 'Invalid category.');
    }
    if (seen.add(value.toLowerCase())) result.add(value);
    if (result.length > 12) {
      throw ArgumentError.value(values, 'categories', 'Too many categories.');
    }
  }
  return List<String>.unmodifiable(result);
}

final _savedSearchIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
