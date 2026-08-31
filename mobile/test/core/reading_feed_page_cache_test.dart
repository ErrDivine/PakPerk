import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/reading_feed/reading_feed_page_cache.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'queue cache round-trips provenance and expires without proving empty',
    () async {
      final now = DateTime.utc(2026, 8, 28, 8);
      final store = SharedPreferencesReadingFeedPageCache(
        queueTtl: const Duration(minutes: 10),
      );
      final page = _queuePage();

      await store.save(_accountA, page: page, requestedMode: null, now: now);

      final cached = await store.loadQueue(
        _accountA,
        now: now.add(const Duration(minutes: 9)),
      );
      expect(cached, isNotNull);
      expect(cached!.page.nextCursor, 'opaque-queue-cursor');
      expect(cached.page.decision.libraryRevision, 12);
      expect(
        cached.page.items.single.queue?.saveSourceKind,
        LibrarySaveSourceKind.titleSearch,
      );
      expect(cached.page.items.single.queue?.state, LibraryItemState.readNext);
      expect(cached.page.mode, ReadingFeedServerMode.toRead);

      final keys = (await SharedPreferences.getInstance()).getKeys();
      expect(keys, hasLength(1));
      expect(keys.single, isNot(contains(_accountA)));
      expect(
        keys.single,
        contains(readingFeedCacheScopeFingerprint(_accountA)),
      );

      expect(
        await store.loadQueue(
          _accountA,
          now: now.add(const Duration(minutes: 11)),
        ),
        isNull,
      );
    },
  );

  test(
    'recommendation cache restores reasons only for the exact live batch',
    () async {
      final now = DateTime.utc(2026, 8, 28, 8);
      final store = SharedPreferencesReadingFeedPageCache();
      final cachedPage = _recommendationPage(batchId: _batchA);
      await store.save(
        _accountA,
        page: cachedPage,
        requestedMode: ReadingFeedRecommendationMode.explore,
        now: now,
      );

      final cached = await store.loadRecommendations(
        _accountA,
        requestedMode: ReadingFeedRecommendationMode.explore,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(cached, isNotNull);
      expect(cached!.page.items.single.recommendation?.reasonCodes, [
        RecommendationExplanationCode.adjacentTopicExploration,
      ]);
      expect(
        cached.page.items.single.recommendation?.reasonLabel,
        'Adjacent method',
      );

      expect(
        cached.matchesLiveRecommendationDecision(
          _emptyRecommendationPage(batchId: _batchA),
          requestedMode: ReadingFeedRecommendationMode.explore,
        ),
        isTrue,
      );
      // Feedback/profile/policy refreshes bind a new batch. A previous batch
      // cannot be resurrected merely because the queue revision is unchanged.
      expect(
        cached.matchesLiveRecommendationDecision(
          _emptyRecommendationPage(batchId: _batchB),
          requestedMode: ReadingFeedRecommendationMode.explore,
        ),
        isFalse,
      );
      expect(
        cached.matchesLiveRecommendationDecision(
          _emptyRecommendationPage(batchId: null),
          requestedMode: ReadingFeedRecommendationMode.explore,
        ),
        isFalse,
      );
      expect(
        cached.matchesLiveRecommendationDecision(
          _emptyRecommendationPage(
            batchId: _batchA,
            enforcement: ReadingFeedEnforcement.shadow,
          ),
          requestedMode: ReadingFeedRecommendationMode.explore,
        ),
        isFalse,
      );
      expect(
        cached.matchesLiveRecommendationDecision(
          _emptyRecommendationPage(batchId: _batchA, revision: 13),
          requestedMode: ReadingFeedRecommendationMode.explore,
        ),
        isFalse,
      );
      for (final mismatchedMetadata in [
        _batchMetadata(profileRevision: 8),
        _batchMetadata(feedbackRevision: 10),
        _batchMetadata(algorithmVersion: 'ranker-v3'),
        _batchMetadata(recommendationPolicyVersion: 'policy-v3'),
      ]) {
        expect(
          cached.matchesLiveRecommendationDecision(
            _emptyRecommendationPage(
              batchId: _batchA,
              batchMetadata: mismatchedMetadata,
            ),
            requestedMode: ReadingFeedRecommendationMode.explore,
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'cache is account scoped and clear removes only the requested account',
    () async {
      final store = SharedPreferencesReadingFeedPageCache();
      await store.save(_accountA, page: _queuePage(), requestedMode: null);
      await store.save(_accountB, page: _queuePage(), requestedMode: null);

      await store.clear(_accountA);

      expect(await store.loadQueue(_accountA), isNull);
      expect(await store.loadQueue(_accountB), isNotNull);
    },
  );
}

ReadingFeedPage _queuePage() => ReadingFeedPage(
  enforcement: ReadingFeedEnforcement.strict,
  mode: ReadingFeedServerMode.toRead,
  decision: const ReadingFeedDecision(
    policyVersion: ReadingFeedDecision.supportedPolicyVersion,
    libraryRevision: 12,
    activeToReadCount: 1,
    queueProvenEmpty: false,
  ),
  items: [
    ReadingFeedItem(
      paper: samplePaper,
      queue: ReadingFeedQueueItem(
        savedAt: DateTime.utc(2026, 8, 20),
        revision: 11,
        state: LibraryItemState.readNext,
        saveSourceKind: LibrarySaveSourceKind.titleSearch,
      ),
      source: ReadingFeedItemSource.toRead,
    ),
  ],
  nextCursor: 'opaque-queue-cursor',
  serverTime: DateTime.utc(2026, 8, 28),
);

ReadingFeedPage _recommendationPage({required String batchId}) =>
    ReadingFeedPage(
      enforcement: ReadingFeedEnforcement.strict,
      mode: ReadingFeedServerMode.recommendations,
      decision: const ReadingFeedDecision(
        policyVersion: ReadingFeedDecision.supportedPolicyVersion,
        libraryRevision: 12,
        activeToReadCount: 0,
        queueProvenEmpty: true,
      ),
      batchId: batchId,
      batchMetadata: _batchMetadata(),
      items: [
        ReadingFeedItem(
          paper: samplePaper,
          queue: null,
          source: ReadingFeedItemSource.exploreV1,
          recommendation: ReadingFeedRecommendationMetadata(
            mode: ReadingFeedRecommendationMode.explore,
            reasonCodes: const [
              RecommendationExplanationCode.adjacentTopicExploration,
            ],
            reasonLabel: 'Adjacent method',
            explanationAvailable: true,
          ),
        ),
      ],
      nextCursor: null,
      serverTime: DateTime.utc(2026, 8, 28),
    );

ReadingFeedPage _emptyRecommendationPage({
  required String? batchId,
  ReadingFeedBatchMetadata? batchMetadata,
  int revision = 12,
  ReadingFeedEnforcement enforcement = ReadingFeedEnforcement.strict,
}) => ReadingFeedPage(
  enforcement: enforcement,
  mode: ReadingFeedServerMode.recommendations,
  decision: ReadingFeedDecision(
    policyVersion: ReadingFeedDecision.supportedPolicyVersion,
    libraryRevision: revision,
    activeToReadCount: 0,
    queueProvenEmpty: true,
  ),
  batchId: batchId,
  batchMetadata: batchId == null ? null : batchMetadata ?? _batchMetadata(),
  items: const [],
  nextCursor: null,
  serverTime: DateTime.utc(2026, 8, 28, 8, 1),
);

ReadingFeedBatchMetadata _batchMetadata({
  int? profileRevision = 7,
  int feedbackRevision = 9,
  String algorithmVersion = 'ranker-v2',
  String recommendationPolicyVersion = 'policy-v2',
}) => ReadingFeedBatchMetadata(
  profileRevision: profileRevision,
  feedbackRevision: feedbackRevision,
  algorithmVersion: algorithmVersion,
  recommendationPolicyVersion: recommendationPolicyVersion,
);

const _accountA = 'account-a';
const _accountB = 'account-b';
const _batchA = '70000000-0000-7000-8000-000000000007';
const _batchB = '70000000-0000-7000-8000-000000000008';
