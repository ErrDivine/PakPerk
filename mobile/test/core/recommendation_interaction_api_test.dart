import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_api.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_models.dart';

void main() {
  test('GET decodes a closed explanation bound to batch and paper', () async {
    final adapter = _RecommendationAdapter();
    final api = RecommendationInteractionApi(_dio(adapter));

    final result = await api.explanation(
      batchId: _batchId,
      paperId: _paperId,
      expectedAuthEpoch: 7,
    );

    expect(result.batchId, _batchId);
    expect(result.paperId, _paperId);
    expect(
      result.explanations.single.code,
      RecommendationExplanationCode.followedTopic,
    );
    expect(result.explanations.single.source, RecommendationSource.topicFollow);
    expect(result.explanations.single.behaviorUsed, isTrue);
    final request = adapter.requests.single;
    expect(
      request.path,
      '/v1/discovery/batches/$_batchId/papers/$_paperId/explanation',
    );
    expect(request.method, 'GET');
    expect(request.extra.values, contains(RequestAuthPolicy.required));
  });

  test('POST uses the batch route and one idempotency identity', () async {
    final adapter = _RecommendationAdapter();
    final api = RecommendationInteractionApi(_dio(adapter));
    const selection = RecommendationFeedbackSelection(
      type: RecommendationFeedbackType.notRelevant,
      reason: RecommendationFeedbackReason.offTopic,
    );

    final result = await api.submitFeedback(
      batchId: _batchId,
      paperId: _paperId,
      selection: selection,
      operationId: _operationId,
      expectedAuthEpoch: 7,
    );

    expect(result.feedbackId, _feedbackId);
    expect(result.replayed, isFalse);
    final request = adapter.requests.single;
    expect(request.path, '/v1/discovery/batches/$_batchId/feedback');
    expect(request.method, 'POST');
    expect(request.headers['Idempotency-Key'], _operationId);
    expect(jsonDecode(adapter.bodies.single), {
      'paper_id': _paperId,
      'feedback_type': 'not_relevant',
      'reason': 'off_topic',
    });
    expect(
      request.extra.values,
      contains(AuthRetryPolicy.idempotencyProtected),
    );
  });

  test('saved-query recommendation explanation uses the closed contract', () {
    final explanation = RecommendationExplanation.fromJson(const {
      'code': 'saved_query_match',
      'title': 'Matches a saved search',
      'detail': 'This paper matches one of your saved searches.',
      'source': 'saved_query',
      'behavior_used': false,
      'seed_paper_id': null,
    });

    expect(explanation.code, RecommendationExplanationCode.savedQueryMatch);
    expect(explanation.source, RecommendationSource.savedQuery);
    expect(explanation.behaviorUsed, isFalse);
  });

  test('behavior-used evidence is required and boolean', () {
    const explanation = {
      'code': 'recent_category',
      'title': 'Recently published',
      'detail': 'This paper is recent in a selected category.',
      'source': 'recent',
      'seed_paper_id': null,
    };

    expect(
      () => RecommendationExplanation.fromJson(explanation),
      throwsFormatException,
    );
    expect(
      () => RecommendationExplanation.fromJson({
        ...explanation,
        'behavior_used': 'false',
      }),
      throwsFormatException,
    );
  });

  test('relevant feedback omits the negative-reason field', () async {
    final adapter = _RecommendationAdapter(replayed: true);
    final api = RecommendationInteractionApi(_dio(adapter));

    final result = await api.submitFeedback(
      batchId: _batchId,
      paperId: _paperId,
      selection: const RecommendationFeedbackSelection.relevant(),
      operationId: _operationId,
      expectedAuthEpoch: 7,
    );

    expect(result.replayed, isTrue);
    expect(jsonDecode(adapter.bodies.single), {
      'paper_id': _paperId,
      'feedback_type': 'relevant',
    });
  });

  test('unknown explanation code or identity mismatch fails closed', () async {
    await expectLater(
      RecommendationInteractionApi(
        _dio(_RecommendationAdapter(unknownExplanation: true)),
      ).explanation(batchId: _batchId, paperId: _paperId, expectedAuthEpoch: 7),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
    await expectLater(
      RecommendationInteractionApi(
        _dio(_RecommendationAdapter(mismatchedIdentity: true)),
      ).explanation(batchId: _batchId, paperId: _paperId, expectedAuthEpoch: 7),
      throwsA(isA<ApiException>()),
    );
  });

  test('invalid identities never reach transport', () async {
    final adapter = _RecommendationAdapter();
    final api = RecommendationInteractionApi(_dio(adapter));

    await expectLater(
      api.explanation(
        batchId: '../feedback',
        paperId: _paperId,
        expectedAuthEpoch: 7,
      ),
      throwsArgumentError,
    );
    await expectLater(
      api.submitFeedback(
        batchId: _batchId,
        paperId: _paperId,
        selection: const RecommendationFeedbackSelection.relevant(),
        operationId: _operationId.toUpperCase(),
        expectedAuthEpoch: 7,
      ),
      throwsArgumentError,
    );
    expect(adapter.requests, isEmpty);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _RecommendationAdapter implements HttpClientAdapter {
  _RecommendationAdapter({
    this.replayed = false,
    this.unknownExplanation = false,
    this.mismatchedIdentity = false,
  });

  final bool replayed;
  final bool unknownExplanation;
  final bool mismatchedIdentity;
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    final Object response;
    if (options.method == 'GET') {
      response = {
        'batch_id': mismatchedIdentity ? _otherId : _batchId,
        'paper_id': _paperId,
        'explanations': [
          {
            'code': unknownExplanation ? 'invented_reason' : 'followed_topic',
            'title': 'Matches a followed topic',
            'detail': 'It matches your followed topic efficient ML.',
            'source': 'topic_follow',
            'behavior_used': true,
            'seed_paper_id': null,
          },
        ],
      };
    } else {
      response = {'feedback_id': _feedbackId, 'replayed': replayed};
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      options.method == 'POST' && !replayed ? 201 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _batchId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _paperId = '17060376-2000-4000-8000-000000000001';
const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _feedbackId = '018f47a6-4b56-7f4c-8c7a-e2656e820203';
const _otherId = '018f47a6-4b56-7f4c-8c7a-e2656e820204';
