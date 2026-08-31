import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/research_profiles/research_profile_api.dart';
import 'package:pakperk/core/research_profiles/research_profile_models.dart';

void main() {
  test(
    'profile, interests, mutation, reset, and export use exact contracts',
    () async {
      final adapter = _ResearchProfileAdapter();
      final api = ResearchProfileApi(_dio(adapter));

      final profile = await api.profile(expectedAuthEpoch: 7);
      expect(profile.revision, 3);
      expect(profile.value.personalizationEnabled, isTrue);

      final interests = await api.interests(expectedAuthEpoch: 7);
      expect(interests.value.explicit.categories.single.category, 'cs.AI');
      expect(interests.value.feedback.categories.single.category, 'cs.CL');
      expect(interests.value.inferred.categories.single.category, 'cs.IR');

      const operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
      await api.update(
        operationId: operationId,
        expectedRevision: 3,
        patch: const ResearchProfilePatch(personalizationEnabled: false),
        expectedAuthEpoch: 7,
      );
      final update = adapter.requests.last;
      expect(update.path, '/v1/discovery/profile');
      expect(update.headers['If-Match'], '"research-profile-3"');
      expect(update.headers['Idempotency-Key'], operationId);
      expect(update.data, {
        'operation_id': operationId,
        'personalization_enabled': false,
      });

      await api.reset(
        scope: ResearchProfileResetScope.inferred,
        operationId: operationId,
        expectedRevision: 3,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'scope': 'inferred',
      });

      const topicId = '10000000-0000-4000-8000-000000000001';
      await api.upsertTopic(
        topicId: topicId,
        polarity: ResearchTopicPolarity.positive,
        strength: .75,
        userAlias: null,
        operationId: operationId,
        expectedRevision: 3,
        expectedAuthEpoch: 7,
      );
      expect(
        adapter.requests.last.path,
        '/v1/discovery/profile/topics/$topicId',
      );
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'polarity': 'positive',
        'strength': .75,
        'user_alias': null,
      });
      await api.deleteTopic(
        topicId: topicId,
        operationId: operationId,
        expectedRevision: 3,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.method, 'DELETE');

      await api.upsertAuthor(
        authorKey: 'orcid:0000-0001',
        displayName: 'Ada Researcher',
        operationId: operationId,
        expectedRevision: 3,
        expectedAuthEpoch: 7,
      );
      expect(
        adapter.requests.last.path,
        '/v1/discovery/profile/authors/orcid%3A0000-0001',
      );
      expect(adapter.requests.last.data, {
        'operation_id': operationId,
        'display_name': 'Ada Researcher',
      });
      await api.deleteAuthor(
        authorKey: 'orcid:0000-0001',
        operationId: operationId,
        expectedRevision: 3,
        expectedAuthEpoch: 7,
      );
      expect(adapter.requests.last.method, 'DELETE');

      final export = await api.export(expectedAuthEpoch: 7);
      expect(export.interests.profileRevision, 3);
      expect(export.toJson()['operation_ledger_included'], isFalse);
      expect(export.toJson()['raw_interaction_history_included'], isFalse);
    },
  );

  test('interest groups reject mislabeled inferred-as-explicit data', () {
    final json = _interests();
    (((json['explicit']! as Map)['categories']! as List).single
            as Map)['source'] =
        'inferred';
    expect(
      () => ResearchProfileInterests.fromJson(json),
      throwsFormatException,
    );
  });

  test('queue override and export privacy claims fail closed', () {
    final profile = _profile()..['queue_override'] = true;
    expect(() => ResearchProfile.fromJson(profile), throwsFormatException);
    final export = _export()..['raw_interaction_history_included'] = true;
    expect(() => ResearchProfileExport.fromJson(export), throwsFormatException);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _ResearchProfileAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = switch (options.path) {
      '/v1/discovery/profile/interests' => _interests(),
      '/v1/discovery/profile/export' => _export(),
      _ => {'profile': _profile()},
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"research-profile-3"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _profile() => {
  'personalization_enabled': true,
  'preferred_discovery_mode': 'for_you',
  'discovery_mode': 'balanced',
  'brief_size': 20,
  'recency_weight': .4,
  'novelty_weight': .3,
  'diversity_weight': .3,
  'profile_revision': 3,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T12:00:00Z',
  'queue_override': false,
};

Map<String, dynamic> _interests() => {
  'profile_revision': 3,
  'explicit': _group('explicit', 'cs.AI'),
  'feedback': _group('feedback', 'cs.CL'),
  'inferred': _group('inferred', 'cs.IR'),
};

Map<String, dynamic> _group(String source, String category) => {
  'categories': [
    {
      'category': category,
      'weight': .8,
      'source': source,
      'created_at': '2026-08-19T10:00:00Z',
      'updated_at': '2026-08-19T12:00:00Z',
    },
  ],
  'topics': <Object?>[],
  'authors': <Object?>[],
};

Map<String, dynamic> _export() => {
  'schema_version': 1,
  'exported_at': '2026-08-19T12:30:00Z',
  'profile': _profile(),
  'interests': _interests(),
  'operation_ledger_included': false,
  'raw_interaction_history_included': false,
};
