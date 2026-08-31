import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/discovery/guest_discovery_preferences.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_api.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_models.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/design_system/skeleton.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/feed/feed_controller.dart';
import 'package:pakperk/features/feed/feed_screen.dart';
import 'package:pakperk/features/feed/guest_category_onboarding.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('cache miss renders an accessible paper-card skeleton', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final cached = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..cachedFeedCompleter = cached;

    await _pumpFeed(tester, repository);

    expect(
      find.byKey(const ValueKey('feed-cache-miss-skeleton')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(PaperCardSkeleton.semanticsLabel),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    semantics.dispose();

    cached.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.deviceCache,
        offline: false,
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('stale cached abstract remains visible during revalidation', (
    tester,
  ) async {
    final network = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..cachedFeed = FeedPage(items: [samplePaper])
      ..networkFeedCompleter = network;

    await _pumpFeed(tester, repository);
    await tester.pump();

    expect(find.text(samplePaper.title), findsWidgets);
    expect(
      find.byKey(const ValueKey('feed-cache-miss-skeleton')),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    network.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
    'signed-in unknown authority replaces public cards synchronously',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final repository = FakePaperDataSource(paper: samplePaper)
        ..cachedFeed = FeedPage(items: [samplePaper]);

      await _pumpFeed(
        tester,
        repository,
        effective: const EffectiveFeedState(
          items: [],
          nextCursor: null,
          category: null,
          loadingInitial: true,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.checkingQueue,
          queueAuthority: QueueAuthority.unknown,
          personalized: true,
          activeToReadCount: null,
        ),
      );

      expect(find.text('Checking To Read'), findsOneWidget);
      expect(find.text(samplePaper.title), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Checking To Read')), findsWidgets);
      semantics.dispose();
    },
  );

  testWidgets('final removal has a stable finishing state without retry', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);

    await _pumpFeed(
      tester,
      repository,
      effective: const EffectiveFeedState(
        items: [],
        nextCursor: null,
        category: null,
        loadingInitial: false,
        loadingMore: false,
        offline: false,
        origin: null,
        errorMessage: null,
        mode: ReadingFeedMode.finishingQueue,
        queueAuthority: QueueAuthority.stale,
        personalized: true,
        activeToReadCount: 0,
      ),
    );

    expect(find.text('Finishing your queue'), findsOneWidget);
    expect(find.textContaining('final removal is confirmed'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets(
    'only a provenance-bound personalized card exposes recommendation details',
    (tester) async {
      final repository = FakePaperDataSource(paper: samplePaper);
      final recommendation = ReadingFeedItem(
        paper: samplePaper,
        queue: null,
        source: ReadingFeedItemSource.forYouV1,
        recommendation: ReadingFeedRecommendationMetadata(
          mode: ReadingFeedRecommendationMode.forYou,
          reasonCodes: const [RecommendationExplanationCode.followedTopic],
          reasonLabel: 'Matches a followed topic',
          explanationAvailable: true,
        ),
      );

      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        remote: _NoopRecommendationRemote(),
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.recommendations,
          queueAuthority: QueueAuthority.serverConfirmedEmpty,
          personalized: true,
          activeToReadCount: 0,
          recommendationItems: [recommendation],
          recommendationBatchId: _batchId,
          authEpoch: 4,
          accountGeneration: 8,
        ),
      );

      expect(
        find.byKey(const ValueKey('recommendation-feed-control')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Recommendation details. Matches a followed topic',
        ),
        findsOneWidget,
      );

      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        remote: _NoopRecommendationRemote(),
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.toRead,
          queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
          personalized: true,
          activeToReadCount: 1,
          recommendationItems: [recommendation],
          recommendationBatchId: _batchId,
          authEpoch: 4,
          accountGeneration: 8,
        ),
      );

      expect(
        find.byKey(const ValueKey('recommendation-feed-control')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'later recommendation pages use their own batch and local position',
    (tester) async {
      final repository = FakePaperDataSource(paper: samplePaper);
      final recommendations = [
        for (final paper in [samplePaper, _secondPaper])
          ReadingFeedItem(
            paper: paper,
            queue: null,
            source: ReadingFeedItemSource.forYouV1,
            recommendation: ReadingFeedRecommendationMetadata(
              mode: ReadingFeedRecommendationMode.forYou,
              reasonCodes: const [RecommendationExplanationCode.followedTopic],
              reasonLabel: 'Matches a followed topic',
              explanationAvailable: true,
            ),
          ),
      ];
      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        remote: _NoopRecommendationRemote(),
        effective: EffectiveFeedState(
          items: [samplePaper, _secondPaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.recommendations,
          queueAuthority: QueueAuthority.serverConfirmedEmpty,
          personalized: true,
          activeToReadCount: 0,
          recommendationItems: recommendations,
          recommendationProvenance: [
            ReadingFeedRecommendationProvenance(
              paperId: samplePaper.paperId,
              batchId: _batchId,
              batchMetadata: _batchMetadata,
              rerankedPosition: 0,
            ),
            ReadingFeedRecommendationProvenance(
              paperId: _secondPaper.paperId,
              batchId: _otherBatchId,
              batchMetadata: _batchMetadata,
              rerankedPosition: 0,
            ),
          ],
          recommendationMode: ReadingFeedRecommendationMode.forYou,
          authEpoch: 4,
          accountGeneration: 8,
        ),
      );

      final verticalFeed = tester.widget<PageView>(
        find.byKey(const PageStorageKey('vertical-paper-feed')),
      );
      unawaited(
        verticalFeed.controller!.animateToPage(
          1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
      await tester.pumpAndSettle();

      final secondReader = tester
          .widgetList<PaperReader>(find.byType(PaperReader))
          .singleWhere(
            (reader) => reader.paper.paperId == _secondPaper.paperId,
          );
      expect(secondReader.interactionContext?.batchId, _otherBatchId);
      expect(secondReader.interactionContext?.position, 0);
      expect(
        find.byKey(
          ValueKey(
            'recommendation-control-$_otherBatchId-${_secondPaper.paperId}',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('To Read renders non-color provenance and private note context', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repository = FakePaperDataSource(paper: samplePaper);
    final queueItem = ReadingFeedQueuePresentation(
      paper: samplePaper,
      savedAt: DateTime.utc(2026, 8, 19),
      state: LibraryItemState.readNext,
      saveSourceKind: LibrarySaveSourceKind.titleSearch,
      privateNote: 'Compare the evaluation protocol',
    );

    await _pumpFeed(
      tester,
      repository,
      effective: EffectiveFeedState(
        items: [samplePaper],
        queueItems: [queueItem],
        nextCursor: null,
        category: null,
        loadingInitial: false,
        loadingMore: false,
        offline: false,
        origin: null,
        errorMessage: null,
        mode: ReadingFeedMode.toRead,
        queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
        personalized: true,
        activeToReadCount: 1,
      ),
    );

    expect(
      find.text('Discovery resumes when To Read is empty.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Read next. Added by title search. Saved'),
      findsOneWidget,
    );
    expect(
      find.text('Why save this? Compare the evaluation protocol'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp('To Read.*Added by title search.*Private note'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recommendation-mode-controls')),
      findsNothing,
    );
    semantics.dispose();
  });

  testWidgets(
    'loaded To Read exhaustion shows a natural stop without recommendations',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final repository = FakePaperDataSource(paper: samplePaper);
      await _pumpFeed(
        tester,
        repository,
        effective: EffectiveFeedState(
          items: [samplePaper],
          queueItems: [
            ReadingFeedQueuePresentation(
              paper: samplePaper,
              savedAt: DateTime.utc(2026, 8, 19),
              state: LibraryItemState.inbox,
              saveSourceKind: LibrarySaveSourceKind.titleSearch,
              privateNote: null,
            ),
          ],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.toRead,
          queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
          personalized: true,
          activeToReadCount: 1,
        ),
      );

      await tester.drag(
        find.byKey(const PageStorageKey('vertical-paper-feed')),
        const Offset(0, -650),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('to-read-natural-end')), findsOneWidget);
      expect(
        find.text('You’ve reached the end of this queue view'),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing was removed'), findsOneWidget);
      expect(
        find.text('Reading to the end does not clear To Read.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recommendation-mode-controls')),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(RegExp('End of this queue view.*Discovery')),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'Reading Brief entry is accessible only with safely proven authority',
    (tester) async {
      final repository = FakePaperDataSource(paper: samplePaper);
      var opened = 0;
      await _pumpFeed(
        tester,
        repository,
        flags: _readingBriefFlags,
        textScaler: const TextScaler.linear(2),
        onOpenBrief: () => opened += 1,
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.toRead,
          queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
          personalized: true,
          activeToReadCount: 1,
        ),
      );

      final entry = find.byKey(const ValueKey('feed-reading-brief-entry'));
      expect(entry, findsOneWidget);
      expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
      expect(find.textContaining('Pause anytime'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(entry);
      expect(opened, 1);

      await _pumpFeed(
        tester,
        repository,
        flags: _readingBriefFlags,
        onOpenBrief: () => opened += 1,
        effective: const EffectiveFeedState(
          items: [],
          nextCursor: null,
          category: null,
          loadingInitial: true,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.checkingQueue,
          queueAuthority: QueueAuthority.unknown,
          personalized: true,
          activeToReadCount: null,
        ),
      );
      expect(entry, findsNothing);
    },
  );

  testWidgets(
    'recommendation modes appear only with proven authority at large text',
    (tester) async {
      final repository = FakePaperDataSource(paper: samplePaper);
      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        textScaler: const TextScaler.linear(2),
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.recommendations,
          queueAuthority: QueueAuthority.serverConfirmedEmpty,
          personalized: true,
          activeToReadCount: 0,
          recommendationMode: ReadingFeedRecommendationMode.forYou,
        ),
      );

      expect(
        find.byKey(const ValueKey('recommendation-mode-controls')),
        findsOneWidget,
      );
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('For You'), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.recommendations,
          queueAuthority: QueueAuthority.serverConfirmedEmpty,
          personalized: true,
          activeToReadCount: 0,
          recommendationMode: ReadingFeedRecommendationMode.recent,
          forYouAvailable: false,
        ),
      );
      expect(find.text('For You'), findsNothing);
      expect(
        find.text('For You is available when personalization is on.'),
        findsOneWidget,
      );

      await _pumpFeed(
        tester,
        repository,
        flags: _recommendationFlags,
        effective: EffectiveFeedState(
          items: [samplePaper],
          queueItems: [
            ReadingFeedQueuePresentation(
              paper: samplePaper,
              savedAt: DateTime.utc(2026, 8, 19),
              state: LibraryItemState.inbox,
              saveSourceKind: null,
              privateNote: null,
            ),
          ],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: null,
          errorMessage: null,
          mode: ReadingFeedMode.toRead,
          queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
          personalized: true,
          activeToReadCount: 1,
          recommendationMode: ReadingFeedRecommendationMode.forYou,
        ),
      );
      expect(
        find.byKey(const ValueKey('recommendation-mode-controls')),
        findsNothing,
      );
    },
  );

  testWidgets('guest Recent and Explore affordances remain explicit', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);
    var openedSearch = false;
    await _pumpFeed(
      tester,
      repository,
      flags: _guestExploreFlags,
      onOpenSearch: () => openedSearch = true,
      effective: EffectiveFeedState(
        items: [samplePaper],
        nextCursor: null,
        category: null,
        loadingInitial: false,
        loadingMore: false,
        offline: false,
        origin: DataOrigin.network,
        errorMessage: null,
        mode: ReadingFeedMode.guestDiscovery,
        queueAuthority: QueueAuthority.unknown,
        personalized: false,
        activeToReadCount: null,
      ),
    );

    expect(
      find.byKey(const ValueKey('guest-discovery-controls')),
      findsOneWidget,
    );
    await tester.tap(find.text('Explore'));
    await tester.pump();
    expect(openedSearch, isTrue);
  });

  testWidgets(
    'completed guest category choice filters the existing public feed',
    (tester) async {
      final repository = FakePaperDataSource(paper: samplePaper);
      await _pumpFeed(
        tester,
        repository,
        guestPreferences: GuestDiscoveryPreferences(
          onboardingComplete: true,
          categories: const ['cs.CL', 'cs.AI'],
        ),
        effective: EffectiveFeedState(
          items: [samplePaper],
          nextCursor: null,
          category: null,
          loadingInitial: false,
          loadingMore: false,
          offline: false,
          origin: DataOrigin.network,
          errorMessage: null,
          mode: ReadingFeedMode.guestDiscovery,
          queueAuthority: QueueAuthority.unknown,
          personalized: false,
          activeToReadCount: null,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(repository.lastCachedFeedCategory, 'cs.CL');
      expect(repository.lastFeedCategory, 'cs.CL');
      expect(
        find.byKey(const ValueKey('guest-category-filter-cs.CL')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('guest-category-filter-cs.AI')),
        findsOne,
      );
    },
  );

  testWidgets('persisted guest category reapplies after an auth round trip', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);
    final feedState = StateProvider<EffectiveFeedState>(
      (_) => _guestFeedState(),
    );
    await _pumpFeed(
      tester,
      repository,
      effectiveStateProvider: feedState,
      guestPreferences: GuestDiscoveryPreferences(
        onboardingComplete: true,
        categories: const ['cs.CL'],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(repository.lastFeedCategory, 'cs.CL');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    );
    container.read(feedState.notifier).state = const EffectiveFeedState(
      items: [],
      nextCursor: null,
      category: null,
      loadingInitial: true,
      loadingMore: false,
      offline: false,
      origin: null,
      errorMessage: null,
      mode: ReadingFeedMode.checkingQueue,
      queueAuthority: QueueAuthority.unknown,
      personalized: true,
      activeToReadCount: null,
    );
    await tester.pump();
    final callsBeforeSignOut = repository.feedCalls;

    container.read(feedState.notifier).state = _guestFeedState();
    await tester.pump();
    await tester.pump();

    expect(repository.feedCalls, greaterThan(callsBeforeSignOut));
    expect(repository.lastFeedCategory, 'cs.CL');
  });

  testWidgets('account transition cancels an in-flight vertical paper change', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);
    final feedState = StateProvider<EffectiveFeedState>(
      (_) => _queueFeedState(authEpoch: 7, accountGeneration: 11),
    );
    await _pumpFeed(
      tester,
      repository,
      flags: _deepReaderFlags,
      effectiveStateProvider: feedState,
    );
    await tester.pumpAndSettle();

    final firstReader = find.byKey(
      ValueKey('feed-paper-${feedReaderKey(samplePaper)}'),
    );
    final abstractStage = find.descendant(
      of: firstReader,
      matching: find.byKey(const ValueKey('stage-abstractView')),
    );
    final bounds = tester.getRect(abstractStage);
    final gesture = await tester.startGesture(
      Offset(bounds.center.dx, bounds.bottom - 36),
    );
    await gesture.moveBy(const Offset(0, -420));
    await tester.pump(const Duration(milliseconds: 32));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    );
    container.read(feedState.notifier).state = _queueFeedState(
      authEpoch: 8,
      accountGeneration: 12,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(container.read(appRestorationControllerProvider).feedIndex, 0);
    expect(find.text(samplePaper.title).hitTestable(), findsWidgets);
    expect(find.text(_secondPaper.title).hitTestable(), findsNothing);

    final abstractScroll = find.descendant(
      of: firstReader,
      matching: find.byKey(const PageStorageKey('abstract-scroll')),
    );
    final nextPaper = find.descendant(
      of: firstReader,
      matching: find.text('Next paper'),
    );
    await tester.dragUntilVisible(
      nextPaper,
      abstractScroll,
      const Offset(0, -240),
    );
    await tester.tap(nextPaper);
    await tester.pumpAndSettle();
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
    expect(find.text(_secondPaper.title).hitTestable(), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only a committed personalized card emits the closed signal', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);
    final telemetry = _RecordingTelemetrySink();
    final recommendations = [
      for (final paper in [samplePaper, _secondPaper])
        ReadingFeedItem(
          paper: paper,
          queue: null,
          source: ReadingFeedItemSource.forYouV1,
          recommendation: ReadingFeedRecommendationMetadata(
            mode: ReadingFeedRecommendationMode.forYou,
            reasonCodes: const [RecommendationExplanationCode.followedTopic],
            reasonLabel: 'Matches a followed topic',
            explanationAvailable: true,
          ),
        ),
    ];
    await _pumpFeed(
      tester,
      repository,
      flags: _recommendationFlags,
      telemetry: telemetry,
      effective: EffectiveFeedState(
        items: [samplePaper, _secondPaper],
        nextCursor: null,
        category: null,
        loadingInitial: false,
        loadingMore: false,
        offline: false,
        origin: null,
        errorMessage: null,
        mode: ReadingFeedMode.recommendations,
        queueAuthority: QueueAuthority.serverConfirmedEmpty,
        personalized: true,
        activeToReadCount: 1,
        recommendationItems: recommendations,
        recommendationBatchId: _batchId,
        recommendationMode: ReadingFeedRecommendationMode.forYou,
      ),
    );

    expect(
      telemetry.events.where(
        (event) => event.$1 == PakPerkTelemetryEvent.recommendationCardRendered,
      ),
      isEmpty,
    );
    final verticalFeed = tester.widget<PageView>(
      find.byKey(const PageStorageKey('vertical-paper-feed')),
    );
    unawaited(
      verticalFeed.controller!.animateToPage(
        1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
    await tester.pumpAndSettle();

    final rendered = telemetry.events.singleWhere(
      (event) => event.$1 == PakPerkTelemetryEvent.recommendationCardRendered,
    );
    expect(rendered.$2, const <String, Object?>{
      'queue_authority': 'server_empty',
      'server_active_count': 'nonzero',
      'policy_consistent': false,
    });
  });
}

Future<void> _pumpFeed(
  WidgetTester tester,
  FakePaperDataSource repository, {
  EffectiveFeedState? effective,
  FeatureFlags? flags,
  RecommendationInteractionRemoteDataSource? remote,
  VoidCallback? onOpenBrief,
  VoidCallback? onOpenSearch,
  TextScaler textScaler = TextScaler.noScaling,
  TelemetrySink? telemetry,
  GuestDiscoveryPreferences? guestPreferences,
  StateProvider<EffectiveFeedState>? effectiveStateProvider,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialRestorationProvider.overrideWithValue(
          const AppRestorationState(),
        ),
        guestDiscoveryPreferencesStoreProvider.overrideWithValue(
          _MemoryGuestPreferencesStore(
            guestPreferences ??
                GuestDiscoveryPreferences(onboardingComplete: true),
          ),
        ),
        if (flags != null) featureFlagsProvider.overrideWithValue(flags),
        if (remote != null)
          recommendationInteractionApiProvider.overrideWithValue(remote),
        if (telemetry != null)
          telemetrySinkProvider.overrideWithValue(telemetry),
        if (effectiveStateProvider != null)
          effectiveFeedProvider.overrideWith(
            (ref) => ref.watch(effectiveStateProvider),
          )
        else if (effective != null)
          effectiveFeedProvider.overrideWithValue(effective),
      ],
      child: MaterialApp(
        theme: PakPerkTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: FeedScreen(onOpenBrief: onOpenBrief, onOpenSearch: onOpenSearch),
      ),
    ),
  );
  await tester.pump();
}

EffectiveFeedState _guestFeedState() => EffectiveFeedState(
  items: [samplePaper],
  nextCursor: null,
  category: null,
  loadingInitial: false,
  loadingMore: false,
  offline: false,
  origin: DataOrigin.network,
  errorMessage: null,
  mode: ReadingFeedMode.guestDiscovery,
  queueAuthority: QueueAuthority.unknown,
  personalized: false,
  activeToReadCount: null,
);

final class _MemoryGuestPreferencesStore
    implements GuestDiscoveryPreferencesStore {
  _MemoryGuestPreferencesStore(this.value);

  GuestDiscoveryPreferences value;

  @override
  Future<GuestDiscoveryPreferences> load() async => value;

  @override
  Future<void> save(GuestDiscoveryPreferences preferences) async {
    value = preferences;
  }
}

final class _NoopRecommendationRemote
    implements RecommendationInteractionRemoteDataSource {
  @override
  Future<RecommendationExplanationEnvelope> explanation({
    required String batchId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnimplementedError();

  @override
  Future<RecommendationFeedbackResult> submitFeedback({
    required String batchId,
    required String paperId,
    required RecommendationFeedbackSelection selection,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => throw UnimplementedError();
}

const _batchId = '70000000-0000-7000-8000-000000000007';
const _otherBatchId = '70000000-0000-7000-8000-000000000008';
const _batchMetadata = ReadingFeedBatchMetadata(
  profileRevision: 4,
  feedbackRevision: 2,
  algorithmVersion: 'ranker-v2',
  recommendationPolicyVersion: 'policy-v2',
);

const _recommendationFlags = FeatureFlags(
  accounts: false,
  library: false,
  comments: false,
  openingMotion: false,
  recommendationsEnabled: true,
);

const _guestExploreFlags = FeatureFlags(
  accounts: false,
  library: false,
  comments: false,
  openingMotion: false,
  searchLookupEnabled: true,
  searchExploreEnabled: true,
);

const _readingBriefFlags = FeatureFlags(
  accounts: false,
  library: false,
  comments: false,
  openingMotion: false,
  readingFeed: true,
  readingBriefsEnabled: true,
);

const _deepReaderFlags = FeatureFlags(
  accounts: false,
  library: false,
  comments: false,
  openingMotion: false,
  deepReader: true,
);

EffectiveFeedState _queueFeedState({
  required int authEpoch,
  required int accountGeneration,
}) {
  final papers = [samplePaper, _secondPaper];
  return EffectiveFeedState(
    items: papers,
    nextCursor: null,
    category: null,
    loadingInitial: false,
    loadingMore: false,
    offline: false,
    origin: null,
    errorMessage: null,
    mode: ReadingFeedMode.toRead,
    queueAuthority: QueueAuthority.serverConfirmedNonEmpty,
    personalized: true,
    activeToReadCount: papers.length,
    queueItems: [
      for (final paper in papers)
        ReadingFeedQueuePresentation(
          paper: paper,
          savedAt: DateTime.utc(2026, 8, 1),
          state: LibraryItemState.inbox,
          saveSourceKind: LibrarySaveSourceKind.discovery,
          privateNote: null,
        ),
    ],
    authEpoch: authEpoch,
    accountGeneration: accountGeneration,
    libraryRevision: 19,
  );
}

final _secondPaper = PaperSummary(
  paperId: '27060376-2000-4000-8000-000000000002',
  arxivId: '2608.00002v1',
  title: 'A second recommendation',
  abstractText: 'A distinct paper for a committed vertical page.',
  authors: const ['Ada Reader'],
  primaryCategory: 'cs.LG',
  categories: const ['cs.LG'],
  publishedAt: DateTime.utc(2026, 8, 18),
  updatedAt: DateTime.utc(2026, 8, 18),
  absUrl: 'https://arxiv.org/abs/2608.00002v1',
  pdfUrl: 'https://arxiv.org/pdf/2608.00002v1',
);

final class _RecordingTelemetrySink implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map<String, Object?>.from(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}
