import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/engagement/engagement_api.dart';
import 'package:pakperk/core/engagement/engagement_models.dart';

void main() {
  test(
    'brief progress and subscription writes preserve stable operation IDs',
    () async {
      final adapter = _EngagementAdapter();
      final api = EngagementApi(_dio(adapter));
      const operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
      const briefId = '10000000-0000-4000-8000-000000000001';
      const subscriptionId = '20000000-0000-4000-8000-000000000002';

      final brief = await api.createBrief(
        operationId: operationId,
        recommendationMode: EngagementRecommendationMode.forYou,
        category: null,
        expectedAuthEpoch: 7,
      );
      expect(brief.mode, ReadingBriefMode.queue);
      expect(adapter.requests.last.headers['Idempotency-Key'], operationId);
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'recommendation_mode': 'for_you',
        'category': null,
      });

      await api.createBrief(
        operationId: operationId,
        recommendationMode: null,
        category: null,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'category': null,
      });

      await api.updateBriefProgress(
        briefId: briefId,
        operationId: operationId,
        expectedProgressRevision: 1,
        position: 1,
        expectedAuthEpoch: 7,
      );
      expect(
        adapter.requests.last.path,
        '/v1/me/reading-briefs/$briefId/progress',
      );
      expect(adapter.requests.last.headers['Idempotency-Key'], operationId);

      await api.createSubscription(
        operationId: operationId,
        id: subscriptionId,
        kind: SubscriptionKind.topic,
        key: 'retrieval',
        label: 'Information retrieval',
        savedSearchId: null,
        frequency: SubscriptionFrequency.daily,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.path, '/v1/subscriptions');
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'kind': 'topic',
        'key': 'retrieval',
        'label': 'Information retrieval',
        'saved_search_id': null,
        'frequency': 'daily',
        'id': subscriptionId,
      });

      await api.updateSubscription(
        operationId: operationId,
        id: subscriptionId,
        kind: SubscriptionKind.topic,
        key: 'retrieval',
        label: 'Information retrieval',
        savedSearchId: null,
        frequency: SubscriptionFrequency.off,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.method, 'PATCH');
      expect(adapter.requests.last.path, '/v1/subscriptions/$subscriptionId');
      expect(
        (adapter.requests.last.data! as Map<String, dynamic>)['frequency'],
        'off',
      );

      const savedSearchId = '10000000-0000-4000-8000-000000000001';
      await api.createSubscription(
        operationId: operationId,
        id: subscriptionId,
        kind: SubscriptionKind.savedQuery,
        key: savedSearchId,
        label: 'Private saved search',
        savedSearchId: savedSearchId,
        frequency: SubscriptionFrequency.daily,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'kind': 'saved_query',
        'key': savedSearchId,
        'label': 'Private saved search',
        'saved_search_id': savedSearchId,
        'frequency': 'daily',
        'id': subscriptionId,
      });

      await api.deleteSubscription(
        operationId: operationId,
        id: subscriptionId,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.method, 'DELETE');
      expect(adapter.requests.last.headers['Idempotency-Key'], operationId);
    },
  );

  test(
    'notifications discard raw payload and preferences keep push off',
    () async {
      final adapter = _EngagementAdapter();
      final api = EngagementApi(_dio(adapter));
      const operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';

      final notifications = await api.notifications(
        expectedAuthEpoch: 7,
        limit: 25,
      );
      expect(notifications.single.type.displayTitle, 'New discovery match');
      expect(notifications.single.entityType, NotificationEntityType.paper);
      expect(notifications.single.papers.single.arxivId, '1706.03762v7');
      expect(adapter.requests.last.queryParameters, {'limit': 25});

      final preferences = await api.notificationPreferences(
        expectedAuthEpoch: 7,
      );
      expect(preferences.typeFrequencies, NotificationTypeFrequencies.defaults);
      await api.updateNotificationPreferences(
        operationId: operationId,
        preferences: preferences.copyWith(
          inAppEnabled: false,
          globalPause: true,
          quietHoursStart: '21:30:00',
          quietHoursEnd: '06:45:00',
          timezone: 'Europe/Paris',
        ),
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.headers['Idempotency-Key'], operationId);
      final body = adapter.requests.last.data! as Map<String, dynamic>;
      expect(body['push_enabled'], isFalse);
      expect(body['email_enabled'], isFalse);
      expect(body['type_frequencies'], {
        'discovery_match': 'off',
        'discovery_digest': 'daily',
        'user_selected_reminder': 'immediate',
        'active_paper_version': 'off',
        'sync_failure': 'immediate',
      });
      expect(body['discovery_frequency'], 'daily');
      expect(body['active_updates_enabled'], isFalse);
      expect(body['in_app_enabled'], isFalse);
      expect(body['global_pause'], isTrue);
      expect(body['quiet_hours_start'], '21:30:00');
      expect(body['quiet_hours_end'], '06:45:00');
      expect(body['timezone'], 'Europe/Paris');

      final cleared = preferences.copyWith(
        clearQuietHours: true,
        timezone: 'Etc/UTC',
      );
      expect(cleared.quietHoursStart, isNull);
      expect(cleared.quietHoursEnd, isNull);
      expect(cleared.timezone, 'Etc/UTC');

      expect(
        await api.markNotificationRead(
          id: '30000000-0000-4000-8000-000000000003',
          expectedAuthEpoch: 7,
        ),
        1,
      );
      expect(adapter.requests.last.headers['Idempotency-Key'], isNull);
    },
  );

  test(
    'per-type frequencies project legacy responses and reject ambiguity',
    () {
      for (final entry
          in <
                SubscriptionFrequency,
                ({SubscriptionFrequency match, SubscriptionFrequency digest})
              >{
                SubscriptionFrequency.immediate: (
                  match: SubscriptionFrequency.immediate,
                  digest: SubscriptionFrequency.off,
                ),
                SubscriptionFrequency.daily: (
                  match: SubscriptionFrequency.off,
                  digest: SubscriptionFrequency.daily,
                ),
                SubscriptionFrequency.weekly: (
                  match: SubscriptionFrequency.off,
                  digest: SubscriptionFrequency.weekly,
                ),
                SubscriptionFrequency.off: (
                  match: SubscriptionFrequency.off,
                  digest: SubscriptionFrequency.off,
                ),
              }
              .entries) {
        final legacy = _preferences()
          ..remove('type_frequencies')
          ..['discovery_frequency'] = entry.key.name
          ..['active_updates_enabled'] = true;
        final projected = NotificationPreferences.fromJson(legacy);
        expect(projected.typeFrequencies.discoveryMatch, entry.value.match);
        expect(projected.typeFrequencies.discoveryDigest, entry.value.digest);
        expect(
          projected.typeFrequencies.activePaperVersion,
          SubscriptionFrequency.immediate,
        );
        expect(
          projected.typeFrequencies.syncFailure,
          SubscriptionFrequency.immediate,
        );
        expect(
          projected.typeFrequencies.userSelectedReminder,
          SubscriptionFrequency.immediate,
        );
      }

      final inconsistentLegacy = _preferences()
        ..['discovery_frequency'] = 'weekly';
      expect(
        () => NotificationPreferences.fromJson(inconsistentLegacy),
        throwsFormatException,
      );

      final ambiguous = _preferences();
      ambiguous['type_frequencies'] = {
        ...(ambiguous['type_frequencies']! as Map<String, dynamic>),
        'discovery_match': 'immediate',
      };
      expect(
        () => NotificationPreferences.fromJson(ambiguous),
        throwsFormatException,
      );

      final missingType = _preferences();
      missingType['type_frequencies'] = {
        ...(missingType['type_frequencies']! as Map<String, dynamic>),
      }..remove('sync_failure');
      expect(
        () => NotificationPreferences.fromJson(missingType),
        throwsFormatException,
      );

      expect(NotificationTypeFrequencies.defaults.toJson(), {
        'discovery_match': 'off',
        'discovery_digest': 'daily',
        'user_selected_reminder': 'immediate',
        'active_paper_version': 'off',
        'sync_failure': 'immediate',
      });
      final canonical = NotificationPreferences.fromJson(_preferences())
          .copyWith(
            typeFrequencies: const NotificationTypeFrequencies(
              discoveryMatch: SubscriptionFrequency.weekly,
              discoveryDigest: SubscriptionFrequency.off,
              userSelectedReminder: SubscriptionFrequency.daily,
              activePaperVersion: SubscriptionFrequency.daily,
              syncFailure: SubscriptionFrequency.weekly,
            ),
          )
          .updateJson('018f47a6-4b56-7f4c-8c7a-e2656e820201');
      expect(canonical['discovery_frequency'], 'weekly');
      expect(canonical['active_updates_enabled'], isTrue);
      expect(canonical['type_frequencies'], {
        'discovery_match': 'weekly',
        'discovery_digest': 'off',
        'user_selected_reminder': 'daily',
        'active_paper_version': 'daily',
        'sync_failure': 'weekly',
      });
    },
  );

  test(
    'strict provenance, response fields, and unavailable channels fail closed',
    () async {
      final invalidBrief = _brief()..['recommendation_batch_id'] = _briefId;
      expect(() => ReadingBrief.fromJson(invalidBrief), throwsFormatException);

      final unknownReason = _discoveryBrief();
      ((unknownReason['items']! as List).single
          as Map<String, dynamic>)['reason_codes'] = [
        'future_reason',
      ];
      expect(() => ReadingBrief.fromJson(unknownReason), throwsFormatException);

      final unknownEntity = _notification()..['entity_type'] = 'future_entity';
      expect(
        () => InAppNotification.fromJson(unknownEntity),
        throwsFormatException,
      );

      final invalidPreferences = _preferences()..['push_enabled'] = true;
      expect(
        () => NotificationPreferences.fromJson(invalidPreferences),
        throwsFormatException,
      );

      final adapter = _EngagementAdapter(extraPreferenceField: true);
      final api = EngagementApi(_dio(adapter));
      await expectLater(
        api.notificationPreferences(expectedAuthEpoch: 7),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_API_RESPONSE',
          ),
        ),
      );
    },
  );
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _EngagementAdapter implements HttpClientAdapter {
  _EngagementAdapter({this.extraPreferenceField = false});

  final bool extraPreferenceField;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = switch (options.path) {
      '/v1/me/reading-briefs/current' ||
      '/v1/me/reading-briefs' => {'brief': _brief()},
      final String path when path.endsWith('/progress') => {'brief': _brief()},
      '/v1/subscriptions' when options.method == 'GET' => {
        'items': [_subscription()],
      },
      final String path when path.startsWith('/v1/subscriptions') => {
        'subscription': _subscription(),
      },
      '/v1/notifications' => {
        'items': [_notification()],
      },
      '/v1/notification-preferences' => {
        'preferences': {
          ..._preferences(),
          if (extraPreferenceField) 'unexpected': true,
        },
      },
      final String path when path.startsWith('/v1/notifications/') => {
        'affected': 1,
      },
      _ => throw StateError('Unexpected request ${options.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _briefId = '10000000-0000-4000-8000-000000000001';

Map<String, dynamic> _brief() => {
  'id': _briefId,
  'mode': 'queue',
  'recommendation_mode': null,
  'library_revision': 8,
  'recommendation_batch_id': null,
  'local_date': '2026-08-19',
  'position': 0,
  'progress_revision': 1,
  'status': 'current',
  'items': [
    {
      'ordinal': 0,
      'paper': _paper(),
      'source': 'to_read',
      'reason_codes': <String>[],
    },
  ],
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:00:00Z',
  'completed_at': null,
};

Map<String, dynamic> _discoveryBrief() => {
  ..._brief(),
  'mode': 'discovery',
  'recommendation_mode': 'for_you',
  'recommendation_batch_id': '70000000-0000-7000-8000-000000000007',
  'items': [
    {
      'ordinal': 0,
      'paper': _paper(),
      'source': 'for_you_v1',
      'reason_codes': ['followed_topic'],
    },
  ],
};

Map<String, dynamic> _subscription() => {
  'id': '20000000-0000-4000-8000-000000000002',
  'kind': 'topic',
  'key': 'retrieval',
  'label': 'Information retrieval',
  'saved_search_id': null,
  'frequency': 'daily',
  'last_evaluated_at': null,
  'revision': 1,
  'deleted': false,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:00:00Z',
};

Map<String, dynamic> _notification() => {
  'id': '30000000-0000-4000-8000-000000000003',
  'notification_type': 'discovery_match',
  'scope': 'discovery',
  'entity_type': 'paper',
  'entity_id': '40000000-0000-4000-8000-000000000004',
  'payload': {'raw_private_copy': 'must not be rendered'},
  'delivery_eligibility': 'eligible',
  'eligibility_library_revision': 8,
  'created_at': '2026-08-19T10:00:00Z',
  'read_at': null,
  'expires_at': '2026-08-26T10:00:00Z',
  'papers': [_paper()],
};

Map<String, dynamic> _preferences() => {
  'type_frequencies': {
    'discovery_match': 'off',
    'discovery_digest': 'daily',
    'user_selected_reminder': 'immediate',
    'active_paper_version': 'off',
    'sync_failure': 'immediate',
  },
  'discovery_frequency': 'daily',
  'quiet_hours_start': '22:00:00',
  'quiet_hours_end': '07:00:00',
  'timezone': 'Asia/Shanghai',
  'in_app_enabled': true,
  'push_enabled': false,
  'email_enabled': false,
  'global_pause': false,
  'active_updates_enabled': false,
  'daily_budget': 5,
  'revision': 1,
  'updated_at': '2026-08-19T10:00:00Z',
};

Map<String, dynamic> _paper() => {
  'paper_id': '40000000-0000-4000-8000-000000000004',
  'arxiv_id': '1706.03762v7',
  'title': 'Attention Is All You Need',
  'abstract': 'Transformer architecture.',
  'authors': ['Ashish Vaswani'],
  'primary_category': 'cs.CL',
  'categories': ['cs.CL', 'cs.LG'],
  'published_at': '2017-06-12T00:00:00Z',
  'updated_at': '2023-08-02T00:00:00Z',
  'capabilities': {
    'metadata': true,
    'introduction': false,
    'chat': false,
    'connections': false,
  },
};
