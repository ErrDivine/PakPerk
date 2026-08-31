import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_api.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:pakperk/features/search/research_search_controller.dart';
import 'package:pakperk/features/search/research_search_models.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('exact lookup is local and title lookup waits 400 ms', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);

    controller.updateLookupInput('https://arxiv.org/abs/1706.03762v7');
    expect(controller.state.phase, ResearchSearchPhase.exactReady);
    expect(controller.state.normalizedExactArxivId, '1706.03762v7');
    expect(remote.searches, isEmpty);

    controller.updateLookupInput('  Attention   Is All You Need  ');
    expect(controller.state.phase, ResearchSearchPhase.waiting);
    await tester.pump(const Duration(milliseconds: 399));
    expect(remote.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(remote.searches, hasLength(1));
    expect(remote.searches.single.query, 'Attention Is All You Need');
    expect(remote.searches.single.expectedAuthEpoch, 7);
    expect(remote.searches.single.limit, 10);

    remote.searches.single.response.complete(
      _searchResult(remote.searches.single.query),
    );
    await tester.pump();
    expect(controller.state.phase, ResearchSearchPhase.results);
    expect(controller.state.lookupCandidates, [_candidate]);
  });

  testWidgets('account generation change cancels and drops a late result', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);

    controller.updateLookupInput('Private query for account A');
    await tester.pump(const Duration(milliseconds: 400));
    final request = remote.searches.single;
    expect(request.cancellation?.isCancelled, isFalse);

    controller.updateAccountScope(
      const ResearchSearchAccountScope(
        accountId: 'account-b',
        authEpoch: 8,
        accountGeneration: 2,
      ),
    );
    expect(request.cancellation?.isCancelled, isTrue);
    expect(controller.state.phase, ResearchSearchPhase.idle);
    expect(controller.state.lookupInput, isEmpty);

    request.response.complete(_searchResult(request.query));
    await tester.pump();
    expect(controller.state.lookupCandidates, isEmpty);
    expect(controller.state.lookupInput, isEmpty);
  });

  test('title capability fails closed without blocking exact IDs', () {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote, titleSearchEnabled: false);
    addTearDown(controller.dispose);

    controller.updateLookupInput('Attention Is All You Need');
    expect(controller.state.phase, ResearchSearchPhase.unavailable);
    expect(controller.state.failure?.retryable, isFalse);
    expect(remote.searches, isEmpty);

    controller.updateLookupInput('1706.03762v7');
    expect(controller.state.phase, ResearchSearchPhase.exactReady);
    expect(controller.state.normalizedExactArxivId, '1706.03762v7');
  });

  test('Explore and saved queries are unavailable unless injected', () async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);

    controller.setMode(ResearchSearchMode.explore);
    controller.updateExploreDraft(
      ExploreSearchDraft(query: 'graph neural networks'),
    );
    await controller.submitExplore();
    await controller.saveCurrentQuery();

    expect(controller.state.phase, ResearchSearchPhase.unavailable);
    expect(controller.state.failure?.code, 'EXPLORE_SEARCH_UNAVAILABLE');
    expect(controller.exploreAvailable, isFalse);
    expect(controller.savedQueriesAvailable, isFalse);
    expect(remote.searches, isEmpty);
  });

  testWidgets('injected Explore and saved-query adapters stay typed', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final explore = Completer<ExploreSearchPresentation>();
    ExploreSearchDraft? exploredDraft;
    RequestCancellation? exploreCancellation;
    SavedResearchQueryDraft? savedDraft;
    RequestCancellation? saveCancellation;
    final controller = ResearchSearchController(
      titleSearch: remote,
      accountScope: _scope,
      exploreExecutor: (draft, cancellation) {
        exploredDraft = draft;
        exploreCancellation = cancellation;
        return explore.future;
      },
      savedQueryCallback: (draft, cancellation) async {
        savedDraft = draft;
        saveCancellation = cancellation;
      },
    );
    addTearDown(controller.dispose);

    controller.setMode(ResearchSearchMode.explore);
    controller.updateExploreDraft(
      ExploreSearchDraft(
        query: '  graph   neural networks ',
        categories: const ['cs.LG'],
        sortOrder: ExploreSortOrder.newest,
        dateRange: ExploreDateRange.pastYear,
      ),
    );
    unawaited(controller.submitExplore());
    expect(controller.state.phase, ResearchSearchPhase.searching);
    expect(exploredDraft?.query, 'graph neural networks');
    expect(exploreCancellation?.isCancelled, isFalse);

    explore.complete(
      ExploreSearchPresentation(
        papers: [samplePaper],
        coverageLabel: 'arXiv metadata coverage',
      ),
    );
    await tester.pump();
    expect(controller.state.phase, ResearchSearchPhase.results);

    await controller.saveCurrentQuery();
    expect(savedDraft?.mode, ResearchSearchMode.explore);
    expect(savedDraft?.query, 'graph neural networks');
    expect(savedDraft?.categories, ['cs.LG']);
    expect(saveCancellation?.isCancelled, isFalse);
    expect(controller.state.querySaved, isTrue);
  });

  testWidgets('scope change cancels a saved query and ignores completion', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final completion = Completer<void>();
    RequestCancellation? cancellation;
    final controller = ResearchSearchController(
      titleSearch: remote,
      accountScope: _scope,
      exploreExecutor: (_, __) async => ExploreSearchPresentation(
        papers: const [],
        coverageLabel: 'No coverage',
      ),
      savedQueryCallback: (_, request) {
        cancellation = request;
        return completion.future;
      },
    );
    addTearDown(controller.dispose);
    controller.setMode(ResearchSearchMode.explore);
    controller.updateExploreDraft(
      ExploreSearchDraft(query: 'Attention Is All You Need'),
    );
    unawaited(controller.saveCurrentQuery());
    expect(controller.state.savingQuery, isTrue);

    controller.updateAccountScope(null);
    expect(cancellation?.isCancelled, isTrue);
    completion.complete();
    await tester.pump();
    expect(controller.state.querySaved, isFalse);
    expect(controller.state.exploreDraft.query, isEmpty);
  });

  test('diagnostic strings redact account and query values', () {
    const account = 'account-secret-123';
    const query = 'private unreleased research topic';
    const scope = ResearchSearchAccountScope(
      accountId: account,
      authEpoch: 3,
      accountGeneration: 9,
    );
    final state = ResearchSearchState(
      mode: ResearchSearchMode.explore,
      phase: ResearchSearchPhase.idle,
      lookupInput: query,
      exploreDraft: ExploreSearchDraft(query: query),
    );
    final saved = SavedResearchQueryDraft.explore(state.exploreDraft);

    expect(scope.toString(), isNot(contains(account)));
    expect(state.toString(), isNot(contains(query)));
    expect(state.exploreDraft.toString(), isNot(contains(query)));
    expect(saved.toString(), isNot(contains(query)));
  });
}

ResearchSearchController _controller(
  _FakePaperResolutionRemote remote, {
  bool titleSearchEnabled = true,
}) => ResearchSearchController(
  titleSearch: remote,
  accountScope: _scope,
  titleSearchEnabled: titleSearchEnabled,
  lookupLimit: 10,
);

const _scope = ResearchSearchAccountScope(
  accountId: 'account-a',
  authEpoch: 7,
  accountGeneration: 1,
);

final _candidate = PaperSearchCandidate(
  arxivId: samplePaper.arxivId,
  title: samplePaper.title,
  authors: samplePaper.authors,
  abstractText: samplePaper.abstractText,
  primaryCategory: samplePaper.primaryCategory,
  categories: samplePaper.categories,
  publishedAt: samplePaper.publishedAt,
  updatedAt: samplePaper.updatedAt,
  absUri: Uri.parse(samplePaper.absUrl),
  rank: 1,
);

PaperSearchResult _searchResult(String query) => PaperSearchResult(
  queryId: '018f47a6-4b56-7f4c-8c7a-e2656e820201',
  normalizedQuery: query,
  candidates: [_candidate],
);

final class _FakePaperResolutionRemote
    implements PaperResolutionRemoteDataSource {
  final List<_SearchRequest> searches = [];

  @override
  Future<PaperSearchResult> searchByTitle({
    required String query,
    required int expectedAuthEpoch,
    int limit = 8,
    RequestCancellation? cancellation,
  }) {
    final request = _SearchRequest(
      query: query,
      expectedAuthEpoch: expectedAuthEpoch,
      limit: limit,
      cancellation: cancellation,
    );
    searches.add(request);
    return request.response.future;
  }

  @override
  Future<PaperImportResult> importPaper({
    required PaperImportSource source,
    required String operationId,
    required LibrarySaveSourceKind saveSourceKind,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnsupportedError('Search never imports papers directly.');
}

final class _SearchRequest {
  _SearchRequest({
    required this.query,
    required this.expectedAuthEpoch,
    required this.limit,
    required this.cancellation,
  });

  final String query;
  final int expectedAuthEpoch;
  final int limit;
  final RequestCancellation? cancellation;
  final Completer<PaperSearchResult> response = Completer<PaperSearchResult>();
}
