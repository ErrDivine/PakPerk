import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/document_reader/queue_navigation_coordinator.dart';
import 'package:pakperk/features/document_reader/reader_entry_context.dart';
import 'package:pakperk/features/document_reader/reader_interaction_state.dart';

void main() {
  const coordinator = QueueNavigationCoordinator();
  const noPending = LibraryPendingIntentCounts.empty();
  const interaction = ReaderInteractionState();
  const entry = ReaderEntryContext.queue(
    expectedAuthEpoch: 7,
    accountGeneration: 3,
    libraryRevision: 11,
  );

  test('queue next can only resolve another canonical active item', () {
    final decision = coordinator.decide(
      feed: _queueState(),
      pendingIntents: noPending,
      entry: entry,
      interaction: interaction,
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );

    expect(decision.disposition, QueueNavigationDisposition.navigate);
    expect(decision.targetIndex, 1);
  });

  test('queue advance telemetry contains only the closed outcome', () async {
    final telemetry = _RecordingTelemetrySink();
    final measured = QueueNavigationCoordinator(
      telemetry: RedactingTelemetrySink(telemetry),
    );

    final decision = measured.decide(
      feed: _queueState(),
      pendingIntents: noPending,
      entry: entry,
      interaction: interaction,
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );
    await Future<void>.delayed(Duration.zero);

    expect(decision.disposition, QueueNavigationDisposition.navigate);
    expect(telemetry.events.single.$1, PakPerkTelemetryEvent.queueAutoAdvance);
    expect(telemetry.events.single.$2, const <String, Object?>{
      'outcome': 'succeeded',
      'offline': false,
    });
  });

  test('queue entry never crosses into recommendation presentation', () {
    final decision = coordinator.decide(
      feed: _recommendationState(),
      pendingIntents: noPending,
      entry: entry,
      interaction: interaction,
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );

    expect(decision.disposition, QueueNavigationDisposition.unavailable);
  });

  test(
    'explicit final mutation enters checking instead of recommendations',
    () {
      final state = _queueState(
        papers: [_paper(1)],
        mode: ReadingFeedMode.finishingQueue,
      );
      final decision = coordinator.decide(
        feed: state,
        pendingIntents: const LibraryPendingIntentCounts(saves: 0, removes: 1),
        entry: entry,
        interaction: interaction,
        currentAuthEpoch: 7,
        currentAccountGeneration: 3,
        currentIndex: 0,
        targetIndex: 1,
        explicitActiveStateMutation: true,
      );

      expect(decision.disposition, QueueNavigationDisposition.checkingQueue);
    },
  );

  test('offline unknown final queue state requires connection', () {
    final state = _queueState(
      papers: [_paper(1)],
      mode: ReadingFeedMode.unavailable,
      authority: QueueAuthority.unknown,
      offline: true,
    );
    final decision = coordinator.decide(
      feed: state,
      pendingIntents: const LibraryPendingIntentCounts(saves: 0, removes: 1),
      entry: entry,
      interaction: interaction,
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
      explicitActiveStateMutation: true,
    );

    expect(
      decision.disposition,
      QueueNavigationDisposition.verificationRequiresConnection,
    );
  });

  test('pending save cancels recommendation navigation immediately', () {
    final decision = coordinator.decide(
      feed: _recommendationState(),
      pendingIntents: const LibraryPendingIntentCounts(saves: 1, removes: 0),
      entry: const ReaderEntryContext(
        source: ReaderEntrySource.recommendation,
        queueMembership: ReaderQueueMembership.outsideToRead,
        expectedAuthEpoch: 7,
        accountGeneration: 3,
      ),
      interaction: interaction,
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );

    expect(
      decision.disposition,
      QueueNavigationDisposition.cancelRecommendationNavigation,
    );
  });

  test('interaction and auth fences fail closed', () {
    final interactionDecision = coordinator.decide(
      feed: _queueState(),
      pendingIntents: noPending,
      entry: entry,
      interaction: const ReaderInteractionState(selectionActive: true),
      currentAuthEpoch: 7,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );
    final staleDecision = coordinator.decide(
      feed: _queueState(),
      pendingIntents: noPending,
      entry: entry,
      interaction: interaction,
      currentAuthEpoch: 8,
      currentAccountGeneration: 3,
      currentIndex: 0,
      targetIndex: 1,
    );

    expect(
      interactionDecision.disposition,
      QueueNavigationDisposition.blockedByInteraction,
    );
    expect(
      staleDecision.disposition,
      QueueNavigationDisposition.staleAccountScope,
    );
  });
}

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

ReadingFeedState _queueState({
  List<PaperSummary>? papers,
  ReadingFeedMode mode = ReadingFeedMode.toRead,
  QueueAuthority authority = QueueAuthority.serverConfirmedNonEmpty,
  bool offline = false,
}) {
  final values = papers ?? [_paper(1), _paper(2)];
  return ReadingFeedState(
    mode: mode,
    queueAuthority: authority,
    items: values,
    queueItems: [
      for (var index = 0; index < values.length; index++)
        ReadingFeedQueuePresentation(
          paper: values[index],
          savedAt: DateTime.utc(2026, 1, index + 1),
          state: LibraryItemState.inbox,
          saveSourceKind: null,
          privateNote: null,
        ),
    ],
    activeToReadCount: values.length,
    libraryRevision: 11,
    loadingInitial: false,
    offline: offline,
    authEpoch: 7,
    accountGeneration: 3,
  );
}

ReadingFeedState _recommendationState() {
  final values = [_paper(1), _paper(2)];
  return ReadingFeedState(
    mode: ReadingFeedMode.recommendations,
    queueAuthority: QueueAuthority.serverConfirmedEmpty,
    items: values,
    recommendationItems: [
      for (final paper in values)
        ReadingFeedItem(
          paper: paper,
          queue: null,
          source: ReadingFeedItemSource.discoveryV1,
        ),
    ],
    activeToReadCount: 0,
    libraryRevision: 11,
    loadingInitial: false,
    authEpoch: 7,
    accountGeneration: 3,
  );
}

PaperSummary _paper(int suffix) => PaperSummary(
  paperId: '00000000-0000-4000-8000-00000000000$suffix',
  arxivId: '2601.0000${suffix}v1',
  title: 'Paper $suffix',
  abstractText: 'Abstract $suffix',
  authors: const ['Researcher'],
  primaryCategory: 'cs.HC',
  categories: const ['cs.HC'],
  publishedAt: DateTime.utc(2026, 1, suffix),
  updatedAt: DateTime.utc(2026, 1, suffix),
  absUrl: 'https://arxiv.org/abs/2601.0000$suffix',
  pdfUrl: 'https://arxiv.org/pdf/2601.0000$suffix',
);
