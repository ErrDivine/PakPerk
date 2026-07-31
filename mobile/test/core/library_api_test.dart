import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';

import '../support/fakes.dart';

void main() {
  test('list and changes decode the frozen sync envelopes', () async {
    final adapter = _LibraryAdapter();
    final api = LibraryApi(_dio(adapter));

    final list = await api.list(
      expectedAuthEpoch: _authEpoch,
      cursor: 'opaque-page',
      limit: 25,
    );
    expect(list.syncRevision, 42);
    expect(list.nextCursor, isNull);
    expect(list.items.single.paper?.title, samplePaper.title);
    final listRequest = adapter.requests.first;
    expect(listRequest.path, '/v1/me/library');
    expect(listRequest.queryParameters, {
      'state': 'to_read',
      'limit': 25,
      'cursor': 'opaque-page',
    });

    final changes = await api.changes(
      afterRevision: 40,
      expectedAuthEpoch: _authEpoch,
      limit: 50,
    );
    expect(changes.nextAfterRevision, 43);
    expect(changes.syncRevision, 43);
    expect(changes.hasMore, isFalse);
    expect(changes.items.single.item.removed, isTrue);
    expect(changes.items.single.paper, isNull);
    expect(adapter.requests[1].queryParameters, {
      'after_revision': 40,
      'limit': 50,
    });
  });

  test('save and remove use the same idempotency UUID', () async {
    final adapter = _LibraryAdapter();
    final api = LibraryApi(_dio(adapter));

    await api.save(
      paperId: samplePaper.paperId,
      operationId: _operationId,
      expectedAuthEpoch: _authEpoch,
    );
    await api.remove(
      paperId: samplePaper.paperId,
      operationId: _operationId,
      expectedAuthEpoch: _authEpoch,
    );

    final save = adapter.requests[0];
    expect(save.method, 'PUT');
    expect(save.headers['Idempotency-Key'], _operationId);
    expect(jsonDecode(adapter.bodies[0]), {
      'operation_id': _operationId,
      'state': 'to_read',
    });
    final remove = adapter.requests[1];
    expect(remove.method, 'DELETE');
    expect(remove.headers['Idempotency-Key'], _operationId);
    expect(adapter.bodies[1], isEmpty);
  });

  test('410 reset remains a stable actionable API error', () async {
    final api = LibraryApi(_dio(_LibraryAdapter(resetRequired: true)));

    await expectLater(
      api.changes(afterRevision: 10, expectedAuthEpoch: _authEpoch),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'status', 410)
            .having(
              (error) => error.code,
              'code',
              'LIBRARY_SYNC_RESET_REQUIRED',
            ),
      ),
    );
  });

  test('malformed list snapshots fail closed', () async {
    final api = LibraryApi(_dio(_LibraryAdapter(malformed: true)));

    await expectLater(
      api.list(expectedAuthEpoch: _authEpoch),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
  });

  test('canonical item enforces UUID and timestamp invariants', () {
    for (final malformed in [
      _item()..['paper_id'] = '00000000-0000-0000-0000-000000000000',
      _item()..['updated_at'] = '2026-07-31T11:59:59Z',
      _item(removed: true)..['removed_at'] = '2026-07-31T12:02:00Z',
    ]) {
      expect(
        () =>
            LibraryCanonicalItem.fromJson(Map<String, dynamic>.from(malformed)),
        throwsFormatException,
      );
    }
  });

  test('mutation rejects non-canonical UUIDs before transport', () async {
    final adapter = _LibraryAdapter();
    final api = LibraryApi(_dio(adapter));

    await expectLater(
      api.save(
        paperId: '00000000-0000-0000-0000-000000000000',
        operationId: _operationId,
        expectedAuthEpoch: _authEpoch,
      ),
      throwsArgumentError,
    );
    await expectLater(
      api.remove(
        paperId: samplePaper.paperId,
        operationId: _operationId.toUpperCase(),
        expectedAuthEpoch: _authEpoch,
      ),
      throwsArgumentError,
    );
    expect(adapter.requests, isEmpty);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _authEpoch = 7;

Map<String, Object?> _item({int revision = 42, bool removed = false}) => {
  'paper_id': samplePaper.paperId,
  'state': 'to_read',
  'saved_at': '2026-07-31T12:00:00Z',
  'updated_at': '2026-07-31T12:01:00Z',
  'removed': removed,
  'removed_at': removed ? '2026-07-31T12:01:00Z' : null,
  'revision': revision,
  'last_operation_id': _operationId,
};

final class _LibraryAdapter implements HttpClientAdapter {
  _LibraryAdapter({this.resetRequired = false, this.malformed = false});

  final bool resetRequired;
  final bool malformed;
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
    if (resetRequired && options.path.endsWith('/changes')) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'LIBRARY_SYNC_RESET_REQUIRED',
            'message': 'Run a full library refresh.',
            'retryable': true,
          },
        }),
        410,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    final Object response = switch ((options.method, options.path)) {
      ('GET', '/v1/me/library') =>
        malformed
            ? {
                'items': [
                  {
                    'item': _item()..['removed'] = true,
                    'paper': samplePaper.toJson(),
                  },
                ],
                'next_cursor': null,
                'sync_revision': 42,
              }
            : {
                'items': [
                  {'item': _item(), 'paper': samplePaper.toJson()},
                ],
                'next_cursor': null,
                'sync_revision': 42,
              },
      ('GET', '/v1/me/library/changes') => {
        'items': [
          {'item': _item(revision: 43, removed: true), 'paper': null},
        ],
        'next_after_revision': 43,
        'has_more': false,
        'sync_revision': 43,
      },
      ('PUT', _) || ('DELETE', _) => {'item': _item()},
      _ => throw StateError(
        'Unexpected request ${options.method} ${options.path}',
      ),
    };
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
