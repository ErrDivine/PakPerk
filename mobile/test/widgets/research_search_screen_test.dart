import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/discovery_search/discovery_search_api.dart';
import 'package:pakperk/core/discovery_search/discovery_search_models.dart';
import 'package:pakperk/core/discovery_search/search_privacy_store.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_api.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/search/research_search_controller.dart';
import 'package:pakperk/features/search/research_search_models.dart';
import 'package:pakperk/features/search/research_search_screen.dart';
import 'package:pakperk/features/search/saved_query_subscription_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('Explore and saved queries are visibly fail closed', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpScreen(tester, controller: controller);

    await tester.tap(
      find.byKey(const ValueKey('research-search-mode-explore')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explore search is not enabled'), findsOneWidget);
    expect(
      find.textContaining(
        'Recent papers are not substituted for a query search.',
      ),
      findsOneWidget,
    );
    expect(find.text('Saved queries are not enabled.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('research-search-explore-submit')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('research-search-save-query')),
          )
          .onPressed,
      isNull,
    );
    expect(remote.searches, isEmpty);
  });

  testWidgets('exact lookup requires explicit Open or Add paper actions', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    final opened = <String>[];
    final added = <String>[];
    await _pumpScreen(
      tester,
      controller: controller,
      onOpenPaper: opened.add,
      onAddPaper: added.add,
    );

    await tester.enterText(
      find.byKey(const ValueKey('research-search-lookup-input')),
      'https://arxiv.org/pdf/1706.03762v7.pdf',
    );
    await tester.pump();

    expect(find.text('arXiv 1706.03762v7'), findsOneWidget);
    expect(remote.searches, isEmpty);
    expect(opened, isEmpty);
    expect(added, isEmpty);
    final open = find.byKey(
      const ValueKey('research-search-open-1706.03762v7'),
    );
    final add = find.byKey(const ValueKey('research-search-add-1706.03762v7'));
    expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(add).height, greaterThanOrEqualTo(48));

    await tester.tap(open);
    await tester.tap(add);
    expect(opened, ['1706.03762v7']);
    expect(added, ['1706.03762v7']);
  });

  testWidgets('title results never open or add automatically', (tester) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    final opened = <String>[];
    final added = <String>[];
    await _pumpScreen(
      tester,
      controller: controller,
      onOpenPaper: opened.add,
      onAddPaper: added.add,
    );

    await tester.enterText(
      find.byKey(const ValueKey('research-search-lookup-input')),
      'Attention Is All You Need',
    );
    await tester.pump(const Duration(milliseconds: 399));
    expect(remote.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    remote.searches.single.response.complete(
      _searchResult(remote.searches.single.query),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(
          ValueKey('research-search-lookup-${samplePaper.arxivId}'),
        ),
        matching: find.text(samplePaper.title),
      ),
      findsOneWidget,
    );
    expect(opened, isEmpty);
    expect(added, isEmpty);
    await tester.tap(
      find.byKey(ValueKey('research-search-open-${samplePaper.arxivId}')),
    );
    await tester.tap(
      find.byKey(ValueKey('research-search-add-${samplePaper.arxivId}')),
    );
    expect(opened, [samplePaper.arxivId]);
    expect(added, [samplePaper.arxivId]);
  });

  testWidgets('public Lookup uses local suggestions without an account', (
    tester,
  ) async {
    final titleRemote = _FakePaperResolutionRemote();
    final searchRemote = _FakeDiscoverySearchRemote();
    final controller = ResearchSearchController(
      titleSearch: titleRemote,
      lookupSearch: searchRemote,
      accountScope: null,
      exploreExecutor: (_, _) async => ExploreSearchPresentation(
        papers: const [],
        coverageLabel: 'Partial arXiv metadata coverage',
      ),
    );
    addTearDown(controller.dispose);
    await _pumpScreen(tester, controller: controller);

    await tester.enterText(
      find.byKey(const ValueKey('research-search-lookup-input')),
      'retrieval systems',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(titleRemote.searches, isEmpty);
    expect(searchRemote.lookups, ['retrieval systems']);
    expect(searchRemote.suggestionQueries, ['retrieval systems']);
    final suggestion = find.byKey(
      const ValueKey(
        'research-search-suggestion-10000000-0000-4000-8000-000000000001',
      ),
    );
    expect(suggestion, findsOneWidget);
    await tester.tap(suggestion);
    await tester.pump();
    expect(controller.state.mode, ResearchSearchMode.explore);
    expect(controller.state.exploreDraft.query, 'Information retrieval');
  });

  testWidgets('Explore adapter renders diagnostics and typed saved query', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    ExploreSearchDraft? explored;
    SavedResearchQueryDraft? saved;
    final mapped = <String>[];
    final controller = ResearchSearchController(
      titleSearch: remote,
      accountScope: _scope,
      exploreExecutor: (draft, _) async {
        explored = draft;
        return ExploreSearchPresentation(
          papers: [samplePaper],
          coverageLabel: 'arXiv and local metadata',
        );
      },
      savedQueryCallback: (draft, _) async => saved = draft,
    );
    addTearDown(controller.dispose);
    await _pumpScreen(
      tester,
      controller: controller,
      onMapPaper: mapped.add,
      availableExploreCategories: const ['cs.LG'],
    );

    await tester.tap(
      find.byKey(const ValueKey('research-search-mode-explore')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('research-search-explore-input')),
      'parameter efficient adaptation',
    );
    final category = find.byKey(
      const ValueKey('research-search-category-cs.LG'),
    );
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pump();
    final submit = find.byKey(const ValueKey('research-search-explore-submit'));
    await tester.ensureVisible(submit);
    expect(
      controller.state.exploreDraft.query,
      'parameter efficient adaptation',
    );
    expect(controller.state.exploreDraft.categories, ['cs.LG']);
    final submitButton = tester.widget<FilledButton>(submit);
    expect(submitButton.onPressed, isNotNull);
    submitButton.onPressed!();
    await tester.pump();

    expect(explored?.query, 'parameter efficient adaptation');
    expect(explored?.categories, ['cs.LG']);
    expect(find.text('arXiv and local metadata'), findsOneWidget);
    expect(
      find.text('This is not a systematic or exhaustive search.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          ValueKey('research-search-explore-${samplePaper.arxivId}'),
        ),
        matching: find.text(samplePaper.title),
      ),
      findsOneWidget,
    );
    final map = find.byKey(
      ValueKey('research-search-map-${samplePaper.arxivId}'),
    );
    expect(find.text('Map from this paper'), findsOneWidget);
    final mapButton = tester.widget<OutlinedButton>(map);
    expect(mapButton.onPressed, isNotNull);
    mapButton.onPressed!();
    await tester.pump();
    expect(mapped, [samplePaper.arxivId]);

    final save = find.byKey(const ValueKey('research-search-save-query'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    expect(saved?.mode, ResearchSearchMode.explore);
    expect(saved?.query, 'parameter efficient adaptation');
    expect(find.text('Query saved'), findsOneWidget);
    expect(remote.searches, isEmpty);
  });

  testWidgets('retry is immediate after a retryable lookup failure', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpScreen(tester, controller: controller);

    await tester.enterText(
      find.byKey(const ValueKey('research-search-lookup-input')),
      'Attention Is All You Need',
    );
    await tester.pump(const Duration(milliseconds: 400));
    remote.searches.single.response.completeError(
      const ApiException(
        code: 'UPSTREAM_UNAVAILABLE',
        message: 'raw upstream detail',
        retryable: true,
      ),
    );
    await tester.pump();

    expect(find.text('Couldn’t look up papers'), findsOneWidget);
    expect(find.text('Search is temporarily unavailable.'), findsOneWidget);
    expect(find.text('raw upstream detail'), findsNothing);
    final retry = find.byKey(const ValueKey('research-search-retry'));
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    await tester.pump();
    expect(remote.searches, hasLength(2));
  });

  testWidgets('narrow 200 percent text and reduced motion remain usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpScreen(
      tester,
      controller: controller,
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('research-search-mode-lookup')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedSwitcher && widget.duration == Duration.zero,
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('research-search-mode-explore')),
    );
    await tester.pump();
    expect(find.text('Explore search is not enabled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'persisted saved query offers an accessible scoped subscription handoff',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final remote = _FakePaperResolutionRemote();
      final controller = ResearchSearchController(
        titleSearch: remote,
        accountScope: _scope,
        exploreExecutor: (_, __) async => ExploreSearchPresentation(
          papers: const [],
          coverageLabel: 'Partial arXiv metadata coverage',
        ),
        savedQueryCallback: (_, __) async {},
      );
      addTearDown(controller.dispose);
      final savedQuery = SavedResearchQueryDraft.savedExplore(
        savedSearchId: _savedSearchId,
        draft: ExploreSearchDraft(query: 'private saved discovery query'),
      );
      final subscribed = <SavedResearchQueryDraft>[];

      await _pumpScreen(
        tester,
        controller: controller,
        savedQueries: [savedQuery],
        media: const MediaQueryData(textScaler: TextScaler.linear(2)),
      );
      await tester.tap(
        find.byKey(const ValueKey('research-search-mode-explore')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('research-search-subscribe-saved-query-0')),
        findsNothing,
      );

      await _pumpScreen(
        tester,
        controller: controller,
        savedQueries: [savedQuery],
        onSubscribeSavedQuery: (query) async => subscribed.add(query),
        savedQuerySubscriptionPhase: (_) => SavedQuerySubscriptionPhase.idle,
        media: const MediaQueryData(textScaler: TextScaler.linear(2)),
      );
      final subscribe = find.byKey(
        const ValueKey('research-search-subscribe-saved-query-0'),
      );
      await tester.drag(
        find.byKey(const ValueKey('research-search-scroll-view')),
        const Offset(0, -1400),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(subscribe).height, greaterThanOrEqualTo(48));
      expect(find.text(_savedSearchId), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(subscribe);
      await tester.pump();
      expect(subscribed, [savedQuery]);
    },
  );

  testWidgets(
    'saved-query deletion confirms scope and leaves private history alone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final remote = _FakePaperResolutionRemote();
      final controller = ResearchSearchController(
        titleSearch: remote,
        accountScope: _scope,
        exploreExecutor: (_, __) async => ExploreSearchPresentation(
          papers: const [],
          coverageLabel: 'Partial arXiv metadata coverage',
        ),
        savedQueryCallback: (_, __) async {},
      );
      addTearDown(controller.dispose);
      final savedQuery = SavedResearchQueryDraft.savedExplore(
        savedSearchId: _savedSearchId,
        draft: ExploreSearchDraft(query: 'private saved discovery query'),
      );
      final deleted = <SavedResearchQueryDraft>[];
      final history = PrivateSearchHistoryEntry(
        query: 'local history survives',
        mode: PrivateSearchHistoryMode.explore,
        searchedAt: DateTime.utc(2026, 8, 28),
      );

      await _pumpScreen(
        tester,
        controller: controller,
        savedQueries: [savedQuery],
        onDeleteSavedQuery: (query) async => deleted.add(query),
        privateHistoryAvailable: true,
        privateHistoryEnabled: true,
        privateHistoryEntries: [history],
        media: const MediaQueryData(textScaler: TextScaler.linear(2)),
      );
      controller.setMode(ResearchSearchMode.explore);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('research-search-scroll-view')),
        const Offset(0, -1800),
      );
      await tester.pumpAndSettle();
      final delete = find.byKey(
        const ValueKey('research-search-delete-saved-query-0'),
      );
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      expect(tester.getSize(delete).height, greaterThanOrEqualTo(48));
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete saved query?'), findsOneWidget);
      expect(find.textContaining('alerts linked to it'), findsOneWidget);
      expect(find.textContaining('on-device search history'), findsOneWidget);
      expect(find.textContaining('reading queue'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('saved-query-delete-cancel')));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);

      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('saved-query-delete-confirm')),
      );
      await tester.pumpAndSettle();
      expect(deleted, [savedQuery]);
      await tester.drag(
        find.byKey(const ValueKey('research-search-scroll-view')),
        const Offset(0, 2400),
      );
      await tester.pumpAndSettle();
      expect(find.text('local history survives'), findsOneWidget);
    },
  );

  testWidgets('private on-device history is opt-in and user controlled', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    bool? requestedEnabled;
    var cleared = false;
    final entry = PrivateSearchHistoryEntry(
      query: 'robust retrieval',
      mode: PrivateSearchHistoryMode.explore,
      searchedAt: DateTime.utc(2026, 8, 28),
    );

    await _pumpScreen(
      tester,
      controller: controller,
      privateHistoryAvailable: true,
      onPrivateHistoryEnabled: (value) => requestedEnabled = value,
    );
    expect(find.text('Private search history'), findsOneWidget);
    expect(find.textContaining('Off by default'), findsOneWidget);
    expect(find.text('robust retrieval'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('private-search-history-toggle')),
    );
    expect(requestedEnabled, isTrue);

    await _pumpScreen(
      tester,
      controller: controller,
      privateHistoryAvailable: true,
      privateHistoryEnabled: true,
      privateHistoryEntries: [entry],
      onPrivateHistoryEnabled: (value) => requestedEnabled = value,
      onClearPrivateHistory: () => cleared = true,
      media: const MediaQueryData(textScaler: TextScaler.linear(2)),
    );
    expect(find.text('Recent on this device'), findsOneWidget);
    expect(find.text('robust retrieval'), findsOneWidget);
    final clear = find.byKey(const ValueKey('private-search-history-clear'));
    expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
    await tester.tap(clear);
    expect(cleared, isTrue);

    await tester.tap(find.text('robust retrieval'));
    await tester.pump();
    expect(controller.state.mode, ResearchSearchMode.explore);
    expect(controller.state.exploreDraft.query, 'robust retrieval');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required ResearchSearchController controller,
  ValueChanged<String>? onOpenPaper,
  ValueChanged<String>? onAddPaper,
  ValueChanged<String>? onMapPaper,
  List<String> availableExploreCategories = const [],
  List<SavedResearchQueryDraft> savedQueries = const [],
  SubscribeSavedResearchQueryCallback? onSubscribeSavedQuery,
  SavedQuerySubscriptionPhaseResolver? savedQuerySubscriptionPhase,
  DeleteSavedResearchQueryCallback? onDeleteSavedQuery,
  SavedQueryDeletingResolver? savedQueryDeleting,
  bool privateHistoryAvailable = false,
  bool privateHistoryEnabled = false,
  List<PrivateSearchHistoryEntry> privateHistoryEntries = const [],
  ValueChanged<bool>? onPrivateHistoryEnabled,
  VoidCallback? onClearPrivateHistory,
  MediaQueryData media = const MediaQueryData(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PakPerkTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: media.textScaler,
            disableAnimations: media.disableAnimations,
            accessibleNavigation: media.accessibleNavigation,
          ),
          child: ResearchSearchScreen(
            controller: controller,
            onOpenPaper: onOpenPaper ?? (_) {},
            onAddPaper: onAddPaper,
            onMapPaper: onMapPaper,
            availableExploreCategories: availableExploreCategories,
            savedQueries: savedQueries,
            onSubscribeSavedQuery: onSubscribeSavedQuery,
            savedQuerySubscriptionPhase: savedQuerySubscriptionPhase,
            onDeleteSavedQuery: onDeleteSavedQuery,
            savedQueryDeleting: savedQueryDeleting,
            privateHistoryAvailable: privateHistoryAvailable,
            privateHistoryEnabled: privateHistoryEnabled,
            privateHistoryEntries: privateHistoryEntries,
            onPrivateHistoryEnabled: onPrivateHistoryEnabled,
            onClearPrivateHistory: onClearPrivateHistory,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ResearchSearchController _controller(_FakePaperResolutionRemote remote) =>
    ResearchSearchController(
      titleSearch: remote,
      accountScope: _scope,
      lookupLimit: 10,
    );

const _scope = ResearchSearchAccountScope(
  accountId: 'account-a',
  authEpoch: 7,
  accountGeneration: 1,
);

const _savedSearchId = '10000000-0000-4000-8000-000000000001';

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

final class _FakeDiscoverySearchRemote
    implements DiscoverySearchRemoteDataSource {
  final List<String> lookups = [];
  final List<String> suggestionQueries = [];

  @override
  Future<DiscoverySearchSuggestions> suggestions({
    required String query,
    RequestCancellation? cancellation,
  }) async {
    suggestionQueries.add(query);
    return const DiscoverySearchSuggestions(
      normalizedQuery: 'retrieval systems',
      items: [
        DiscoveryRelatedTopic(
          topicId: '10000000-0000-4000-8000-000000000001',
          label: 'Information retrieval',
          sourceVocabulary: 'pakperk_topics_v1',
        ),
      ],
    );
  }

  @override
  Future<DiscoverySearchPage> lookup({
    required String query,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) async {
    lookups.add(query);
    return DiscoverySearchPage(
      normalizedQuery: query,
      items: [
        DiscoverySearchResult(
          paper: samplePaper,
          matchKind: 'phrase',
          relevanceBucket: 5,
        ),
      ],
      nextCursor: null,
      matchesReturned: 1,
      relatedTopics: const [],
      disclaimer: null,
    );
  }

  @override
  Future<DiscoverySearchPage> explore({
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) => throw UnsupportedError('The controller injects its Explore adapter.');

  @override
  Future<List<DiscoverySavedSearch>> listSaved({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnsupportedError('Saved queries are not enabled.');

  @override
  Future<DiscoverySavedSearch> save({
    required String operationId,
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnsupportedError('Saved queries are not enabled.');

  @override
  Future<void> deleteSaved({
    required String savedSearchId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnsupportedError('Saved queries are not enabled.');
}
