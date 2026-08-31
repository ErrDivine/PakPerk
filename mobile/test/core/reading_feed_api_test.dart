import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/reading_feed/reading_feed_api.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';

import '../support/fakes.dart';

void main() {
  test('authenticated reading feed decodes its decision and query', () async {
    final adapter = _ReadingFeedAdapter();
    final api = ReadingFeedApi(_dio(adapter));

    final page = await api.page(
      expectedAuthEpoch: 7,
      recommendationMode: ReadingFeedRecommendationMode.forYou,
      category: 'cs.AI',
      cursor: 'opaque-cursor',
      limit: 25,
    );

    expect(page.mode, ReadingFeedServerMode.toRead);
    expect(page.enforcement, ReadingFeedEnforcement.strict);
    expect(page.decision.libraryRevision, 42);
    expect(page.papers.single.paperId, samplePaper.paperId);
    expect(adapter.request?.path, '/v1/me/reading-feed');
    expect(adapter.request?.queryParameters, {
      'limit': 25,
      'recommendation_mode': 'for_you',
      'category': 'cs.AI',
      'cursor': 'opaque-cursor',
    });

    await api.page(expectedAuthEpoch: 7);
    expect(adapter.request?.queryParameters, {'limit': 20});
  });

  test('stale cursor remains a typed restart signal', () async {
    final api = ReadingFeedApi(_dio(_ReadingFeedAdapter(stale: true)));

    await expectLater(
      api.page(expectedAuthEpoch: 7, cursor: 'stale'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'status', 409)
            .having((error) => error.code, 'code', 'READING_FEED_CURSOR_STALE'),
      ),
    );
  });

  test('matched read-only brief progress is decoded and query bound', () async {
    final adapter = _ReadingFeedAdapter(brief: _briefSummary(_briefId));
    final api = ReadingFeedApi(_dio(adapter));

    final page = await api.page(expectedAuthEpoch: 7, briefId: _briefId);

    expect(page.brief?.id, _briefId);
    expect(page.brief?.position, 3);
    expect(page.brief?.total, 12);
    expect(page.brief?.complete, isFalse);
    expect(adapter.request?.queryParameters, {
      'limit': 20,
      'brief_id': _briefId,
    });
  });

  test('missing and invalid brief bindings fail closed', () async {
    for (final adapter in [
      _ReadingFeedAdapter(omitBrief: true),
      _ReadingFeedAdapter(brief: {..._briefSummary(_briefId), 'total': 0}),
      _ReadingFeedAdapter(brief: _briefSummary(_otherBriefId)),
    ]) {
      final api = ReadingFeedApi(_dio(adapter));
      await expectLater(
        api.page(expectedAuthEpoch: 7, briefId: _briefId),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_API_RESPONSE',
          ),
        ),
      );
    }
  });

  test('contradictory server pages fail closed', () async {
    final api = ReadingFeedApi(_dio(_ReadingFeedAdapter(malformed: true)));

    await expectLater(
      api.page(expectedAuthEpoch: 7),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
  });

  test('invalid request policy is rejected before transport', () async {
    final adapter = _ReadingFeedAdapter();
    final api = ReadingFeedApi(_dio(adapter));

    await expectLater(api.page(expectedAuthEpoch: -1), throwsArgumentError);
    await expectLater(
      api.page(expectedAuthEpoch: 7, category: 'cs.AI OR all:*'),
      throwsArgumentError,
    );
    await expectLater(
      api.page(expectedAuthEpoch: 7, cursor: 'x' * 513),
      throwsArgumentError,
    );
    expect(adapter.request, isNull);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _ReadingFeedAdapter implements HttpClientAdapter {
  _ReadingFeedAdapter({
    this.stale = false,
    this.malformed = false,
    this.brief,
    this.omitBrief = false,
  });

  final bool stale;
  final bool malformed;
  final Map<String, Object?>? brief;
  final bool omitBrief;
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    if (stale) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'READING_FEED_CURSOR_STALE',
            'message': 'Restart from the first page.',
            'retryable': true,
          },
        }),
        409,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    final decision = <String, Object?>{
      'policy_version': 'queue_first_v1',
      'library_revision': 42,
      'active_to_read_count': malformed ? 0 : 1,
      'queue_proven_empty': malformed,
    };
    final envelope = <String, Object?>{
      'enforcement': 'strict',
      'mode': 'to_read',
      'decision': decision,
      'batch_id': null,
      'batch_metadata': null,
      'items': [
        {
          'paper': samplePaper.toJson(),
          'queue': {
            'state': 'reading',
            'saved_at': '2026-07-31T12:00:00Z',
            'revision': 42,
            'save_source_kind': 'arxiv_id',
          },
          'source': 'to_read',
          'recommendation': null,
        },
      ],
      'next_cursor': null,
      if (!omitBrief) 'brief': brief,
      'server_time': '2026-08-19T12:00:00Z',
    };
    return ResponseBody.fromString(
      jsonEncode(envelope),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _briefSummary(String id) => {
  'id': id,
  'position': 3,
  'total': 12,
  'complete': false,
};

const _briefId = '10000000-0000-4000-8000-000000000001';
const _otherBriefId = '10000000-0000-4000-8000-000000000002';
