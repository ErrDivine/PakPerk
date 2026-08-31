import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/document/document_api.dart';

void main() {
  test(
    'checkpoint read requests and accepts exactly one scoped paper',
    () async {
      final adapter = _CheckpointAdapter(items: const [_checkpoint]);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      final checkpoint = await DocumentApi(dio).getCheckpoint(
        accountId: 'account-a',
        paperId: _paperId,
        expectedAuthEpoch: 8,
      );

      expect(adapter.path, '/v1/reading/checkpoints');
      expect(adapter.query, {'paper_id': _paperId});
      expect(checkpoint?.paperId, _paperId);
      expect(checkpoint?.revision, 17);
    },
  );

  test('checkpoint read rejects an unscoped multi-row response', () async {
    final adapter = _CheckpointAdapter(items: const [_checkpoint, _checkpoint]);
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await expectLater(
      DocumentApi(dio).getCheckpoint(
        accountId: 'account-a',
        paperId: _paperId,
        expectedAuthEpoch: 8,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_DOCUMENT_RESPONSE',
        ),
      ),
    );
  });
}

final class _CheckpointAdapter implements HttpClientAdapter {
  _CheckpointAdapter({required this.items});

  final List<Map<String, Object?>> items;
  String? path;
  Map<String, dynamic>? query;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.path;
    query = options.queryParameters;
    return ResponseBody.fromString(
      jsonEncode({'items': items, 'sync_revision': 17}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _paperId = '11111111-1111-4111-8111-111111111111';
const _checkpoint = <String, Object?>{
  'paper_id': _paperId,
  'generation': 3,
  'mode': 'read',
  'stage': 'introduction',
  'block_id': 'block-7',
  'scroll_fraction': .4,
  'last_read_at': '2026-08-31T08:30:00Z',
  'revision': 17,
};
