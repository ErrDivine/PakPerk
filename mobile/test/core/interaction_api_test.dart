import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/interactions/interaction_api.dart';
import 'package:pakperk/core/interactions/interaction_models.dart';

void main() {
  test('event types and feed modes are closed', () {
    expect(PaperInteractionEventType.values, hasLength(12));
    expect(InteractionFeedMode.values, hasLength(5));
    expect(
      () => PaperInteractionEventType.parse('future_event'),
      throwsFormatException,
    );
    expect(
      () => InteractionFeedMode.parse('future_mode'),
      throwsFormatException,
    );
  });

  test('account batch is strict, content-free, and auth-epoch bound', () async {
    final adapter = _InteractionAdapter();
    final api = InteractionApi(_dio(adapter));
    final event = _event();

    final result = await api.sendBatch(
      scope: AccountInteractionScope(accountId: 'account-a', authEpoch: 7),
      events: [event],
    );

    expect(result.accepted, 1);
    expect(adapter.request!.path, '/v1/events/batch');
    final body = jsonDecode(adapter.body!) as Map<String, dynamic>;
    expect((body['events'] as List).single, {
      'event_id': _eventId,
      'event_type': 'impression_qualified',
      'paper_id': _paperId,
      'feed_mode': 'for_you',
      'batch_id': _batchId,
      'position': 4,
      'occurred_at': '2026-08-28T08:00:00.000Z',
    });
    expect(adapter.request!.headers['X-Session-Id'], isNull);
  });

  test(
    'anonymous batches use session scope and reject private modes',
    () async {
      final adapter = _InteractionAdapter();
      final api = InteractionApi(_dio(adapter));
      await api.sendBatch(
        scope: AnonymousInteractionScope(sessionId: _sessionId),
        events: [_event(feedMode: InteractionFeedMode.recent, batchId: null)],
      );
      expect(adapter.request!.headers['X-Session-Id'], _sessionId);

      expect(
        () => validateInteractionBatch(
          AnonymousInteractionScope(sessionId: _sessionId),
          [_event(feedMode: InteractionFeedMode.following, batchId: null)],
        ),
        throwsArgumentError,
      );
    },
  );

  test('unknown response fields fail closed', () async {
    final api = InteractionApi(_dio(_InteractionAdapter(extraField: true)));
    await expectLater(
      api.sendBatch(
        scope: AccountInteractionScope(accountId: 'account-a', authEpoch: 7),
        events: [_event()],
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
  });

  test('partial acknowledgements fail closed', () {
    expect(
      () => InteractionBatchResult.fromJson({
        'accepted': 0,
        'duplicates': 0,
      }, submitted: 1),
      throwsFormatException,
    );
  });
}

PaperInteractionEvent _event({
  InteractionFeedMode feedMode = InteractionFeedMode.forYou,
  String? batchId = _batchId,
}) => PaperInteractionEvent(
  eventId: _eventId,
  eventType: PaperInteractionEventType.impressionQualified,
  paperId: _paperId,
  feedMode: feedMode,
  batchId: batchId,
  position: 4,
  occurredAt: DateTime.utc(2026, 8, 28, 8),
);

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _InteractionAdapter implements HttpClientAdapter {
  _InteractionAdapter({this.extraField = false});

  final bool extraField;
  RequestOptions? request;
  String? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    body = utf8.decode(bytes);
    return ResponseBody.fromString(
      jsonEncode({
        'accepted': 1,
        'duplicates': 0,
        if (extraField) 'future': true,
      }),
      202,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _eventId = '70000000-0000-7000-8000-000000000001';
const _paperId = '40000000-0000-4000-8000-000000000004';
const _batchId = '70000000-0000-7000-8000-000000000007';
const _sessionId = '70000000-0000-7000-8000-000000000009';
