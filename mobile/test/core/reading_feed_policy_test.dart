import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/reading_feed/reading_feed_policy.dart';

import '../support/fakes.dart';

void main() {
  const policy = ReadingFeedPolicy();

  test('unknown, pending, nonempty, and final-remove states fail closed', () {
    expect(
      policy
          .evaluate(_input(authentication: ReadingFeedAuthentication.unknown))
          .mode,
      ReadingFeedMode.checkingQueue,
    );
    expect(
      policy.evaluate(_input(pendingSaveCount: 1)).authority,
      QueueAuthority.pendingSave,
    );
    expect(
      policy.evaluate(_input(localActiveCount: 1)).mode,
      ReadingFeedMode.toRead,
    );
    expect(
      policy
          .evaluate(
            _input(
              authentication: ReadingFeedAuthentication.unknown,
              localActiveCount: 1,
            ),
          )
          .mode,
      ReadingFeedMode.toRead,
    );
    expect(
      policy
          .evaluate(
            _input(
              authentication: ReadingFeedAuthentication.unknown,
              pendingSaveCount: 1,
            ),
          )
          .authority,
      QueueAuthority.pendingSave,
    );
    expect(
      policy.evaluate(_input(pendingRemoveCount: 1)).mode,
      ReadingFeedMode.finishingQueue,
    );
    for (final decision in <ReadingFeedPolicyDecision>[
      policy.evaluate(
        _input(authentication: ReadingFeedAuthentication.unknown),
      ),
      policy.evaluate(_input(pendingSaveCount: 1)),
      policy.evaluate(_input(localActiveCount: 1)),
      policy.evaluate(_input(pendingRemoveCount: 1)),
      policy.evaluate(_input(syncReset: true)),
    ]) {
      expect(decision.allowRecommendationPublish, isFalse);
    }
  });

  test('only a current authoritative empty page permits recommendations', () {
    final page = _page(ReadingFeedServerMode.recommendations);
    final decision = policy.evaluate(
      _input(serverPage: page, localRevision: 4),
    );

    expect(decision.mode, ReadingFeedMode.recommendations);
    expect(decision.authority, QueueAuthority.serverConfirmedEmpty);
    expect(decision.allowRecommendationPublish, isTrue);

    final stale = policy.evaluate(_input(serverPage: page, localRevision: 6));
    expect(stale.authority, QueueAuthority.stale);
    expect(stale.allowRecommendationPublish, isFalse);
  });

  test('late account, epoch, or generation responses are discarded', () {
    final response = _page(ReadingFeedServerMode.recommendations);
    const request = ReadingFeedRequestScope(
      accountId: 'account-a',
      authEpoch: 2,
      generation: 4,
    );
    expect(
      policy.canPublishResponse(
        response: response,
        requestScope: request,
        currentScope: request,
        currentInput: _input(localRevision: 5),
      ),
      isTrue,
    );
    for (final current in <ReadingFeedRequestScope>[
      const ReadingFeedRequestScope(
        accountId: 'account-b',
        authEpoch: 2,
        generation: 4,
      ),
      const ReadingFeedRequestScope(
        accountId: 'account-a',
        authEpoch: 3,
        generation: 4,
      ),
      const ReadingFeedRequestScope(
        accountId: 'account-a',
        authEpoch: 2,
        generation: 5,
      ),
    ]) {
      expect(
        policy.canPublishResponse(
          response: response,
          requestScope: request,
          currentScope: current,
          currentInput: _input(localRevision: 5),
        ),
        isFalse,
      );
    }
  });

  test('signed-out behavior stays on public discovery', () {
    final decision = policy.evaluate(
      _input(authentication: ReadingFeedAuthentication.signedOut),
    );
    expect(decision.mode, ReadingFeedMode.guestDiscovery);
    expect(decision.allowRecommendationPublish, isFalse);
  });

  test('wire page rejects contradictory decision and item shapes', () {
    final valid = _pageJson(ReadingFeedServerMode.recommendations);
    expect(
      ReadingFeedPage.fromJson(valid).papers.single.paperId,
      samplePaper.paperId,
    );

    final contradictory = _pageJson(ReadingFeedServerMode.recommendations);
    (contradictory['decision']!
            as Map<String, Object?>)['active_to_read_count'] =
        1;
    expect(
      () => ReadingFeedPage.fromJson(contradictory),
      throwsFormatException,
    );

    final unknownEnforcement = _pageJson(ReadingFeedServerMode.recommendations)
      ..['enforcement'] = 'advisory';
    expect(
      () => ReadingFeedPage.fromJson(unknownEnforcement),
      throwsFormatException,
    );

    final outOfOrder = _pageJson(ReadingFeedServerMode.recommendations);
    final laterPaper = Map<String, dynamic>.from(samplePaper.toJson())
      ..['paper_id'] = '20000000-0000-4000-8000-000000000002'
      ..['published_at'] = '2030-01-01T00:00:00Z'
      ..['updated_at'] = '2030-01-01T00:00:00Z';
    (outOfOrder['items']! as List<Object?>).add({
      'paper': laterPaper,
      'queue': null,
      'source': 'discovery_v1',
      'recommendation': null,
    });
    expect(() => ReadingFeedPage.fromJson(outOfOrder), throwsFormatException);
  });

  test('wire decision requires the supported queue policy version', () {
    const valid = <String, Object?>{
      'policy_version': 'queue_first_v1',
      'library_revision': 5,
      'active_to_read_count': 0,
      'queue_proven_empty': true,
    };
    expect(
      ReadingFeedDecision.fromJson(
        Map<String, Object?>.from(valid),
      ).policyVersion,
      ReadingFeedDecision.supportedPolicyVersion,
    );
    for (final value in <Object?>[null, 'queue_first_v2', 1]) {
      final tampered = Map<String, Object?>.from(valid);
      if (value == null) {
        tampered.remove('policy_version');
      } else {
        tampered['policy_version'] = value;
      }
      expect(
        () => ReadingFeedDecision.fromJson(tampered),
        throwsFormatException,
        reason: 'policy_version=$value',
      );
    }
  });

  test('personalized batch provenance is closed and internally consistent', () {
    final valid = ReadingFeedPage.fromJson(_personalizedPageJson());
    expect(valid.batchId, '70000000-0000-7000-8000-000000000007');
    expect(valid.batchMetadata?.profileRevision, 4);
    expect(valid.batchMetadata?.feedbackRevision, 6);
    expect(valid.nextCursor, isNull);
    expect(valid.items.single.source, ReadingFeedItemSource.forYouV1);
    expect(
      valid.items.single.recommendation?.mode,
      ReadingFeedRecommendationMode.forYou,
    );

    final missingBatch = _personalizedPageJson()..['batch_id'] = null;
    expect(() => ReadingFeedPage.fromJson(missingBatch), throwsFormatException);

    final missingBatchMetadata = _personalizedPageJson()
      ..['batch_metadata'] = null;
    expect(
      () => ReadingFeedPage.fromJson(missingBatchMetadata),
      throwsFormatException,
    );

    final unknownBatchMetadata = _personalizedPageJson();
    (unknownBatchMetadata['batch_metadata']! as Map)['future'] = 1;
    expect(
      () => ReadingFeedPage.fromJson(unknownBatchMetadata),
      throwsFormatException,
    );

    final invalidBatchVersion = _personalizedPageJson();
    (invalidBatchVersion['batch_metadata']! as Map)['algorithm_version'] =
        'Ranker v2';
    expect(
      () => ReadingFeedPage.fromJson(invalidBatchVersion),
      throwsFormatException,
    );

    final mismatchedSource = _personalizedPageJson();
    ((mismatchedSource['items']! as List).single as Map)['source'] =
        'recent_v1';
    expect(
      () => ReadingFeedPage.fromJson(mismatchedSource),
      throwsFormatException,
    );

    final missingMetadata = _personalizedPageJson();
    ((missingMetadata['items']! as List).single as Map)['recommendation'] =
        null;
    expect(
      () => ReadingFeedPage.fromJson(missingMetadata),
      throwsFormatException,
    );

    final paginatedBatch = _personalizedPageJson()
      ..['next_cursor'] = 'opaque-batch-continuation';
    final decodedPaginatedBatch = ReadingFeedPage.fromJson(paginatedBatch);
    expect(decodedPaginatedBatch.batchId, valid.batchId);
    expect(decodedPaginatedBatch.batchMetadata, valid.batchMetadata);
    expect(decodedPaginatedBatch.nextCursor, 'opaque-batch-continuation');

    final rerankedBatch = _personalizedPageJson();
    final firstItem = Map<String, dynamic>.from(
      (rerankedBatch['items']! as List).single as Map,
    );
    final laterPaper = Map<String, dynamic>.from(samplePaper.toJson())
      ..['paper_id'] = '20000000-0000-4000-8000-000000000002'
      ..['published_at'] = '2030-01-01T00:00:00Z'
      ..['updated_at'] = '2030-01-01T00:00:00Z';
    (rerankedBatch['items']! as List).add({...firstItem, 'paper': laterPaper});
    expect(
      ReadingFeedPage.fromJson(rerankedBatch).items,
      hasLength(2),
      reason: 'persisted batches are reranked rather than chronological',
    );

    final queueWithBatch = _pageJson(ReadingFeedServerMode.toRead)
      ..['batch_id'] = '70000000-0000-7000-8000-000000000007';
    expect(
      () => ReadingFeedPage.fromJson(queueWithBatch),
      throwsFormatException,
    );
  });
}

ReadingFeedPolicyInput _input({
  ReadingFeedAuthentication authentication = ReadingFeedAuthentication.verified,
  int localActiveCount = 0,
  int pendingSaveCount = 0,
  int pendingRemoveCount = 0,
  int pendingImportCount = 0,
  bool syncReset = false,
  bool offline = false,
  int? localRevision,
  ReadingFeedPage? serverPage,
}) => ReadingFeedPolicyInput(
  authentication: authentication,
  localActiveCount: localActiveCount,
  pendingSaveCount: pendingSaveCount,
  pendingRemoveCount: pendingRemoveCount,
  pendingImportCount: pendingImportCount,
  syncReset: syncReset,
  offline: offline,
  localRevision: localRevision,
  serverPage: serverPage,
);

ReadingFeedPage _page(ReadingFeedServerMode mode) =>
    ReadingFeedPage.fromJson(_pageJson(mode));

Map<String, dynamic> _pageJson(ReadingFeedServerMode mode) {
  final recommendations = mode == ReadingFeedServerMode.recommendations;
  return {
    'enforcement': 'strict',
    'mode': recommendations ? 'recommendations' : 'to_read',
    'decision': {
      'policy_version': 'queue_first_v1',
      'library_revision': 5,
      'active_to_read_count': recommendations ? 0 : 1,
      'queue_proven_empty': recommendations,
    },
    'batch_id': null,
    'batch_metadata': null,
    'items': [
      {
        'paper': samplePaper.toJson(),
        'queue': recommendations
            ? null
            : {
                'state': 'to_read',
                'saved_at': '2026-07-31T12:00:00Z',
                'revision': 5,
                'save_source_kind': null,
              },
        'source': recommendations ? 'discovery_v1' : 'to_read',
        'recommendation': null,
      },
    ],
    'next_cursor': null,
    'brief': null,
    'server_time': '2026-08-19T12:00:00Z',
  };
}

Map<String, dynamic> _personalizedPageJson() => {
  'enforcement': 'strict',
  'mode': 'recommendations',
  'decision': {
    'policy_version': 'queue_first_v1',
    'library_revision': 5,
    'active_to_read_count': 0,
    'queue_proven_empty': true,
  },
  'batch_id': '70000000-0000-7000-8000-000000000007',
  'batch_metadata': {
    'profile_revision': 4,
    'feedback_revision': 6,
    'algorithm_version': 'ranker-v2',
    'recommendation_policy_version': 'policy-v2',
  },
  'items': [
    {
      'paper': samplePaper.toJson(),
      'queue': null,
      'source': 'for_you_v1',
      'recommendation': {
        'mode': 'for_you',
        'reason_codes': ['followed_topic', 'diversity_slot'],
        'reason_label': 'Because you follow this topic',
        'explanation_available': true,
      },
    },
  ],
  'next_cursor': null,
  'brief': null,
  'server_time': '2026-08-19T12:00:00Z',
};
