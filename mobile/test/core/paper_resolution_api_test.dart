import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/paper_resolution/paper_input_classifier.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_api.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';

import '../support/fakes.dart';

void main() {
  test('title search posts a bounded query and decodes candidates', () async {
    final adapter = _PaperResolutionAdapter();
    final api = PaperResolutionApi(_dio(adapter));

    final result = await api.searchByTitle(
      query: '  Attention\n Is All You Need ',
      expectedAuthEpoch: 7,
      limit: 8,
    );

    expect(result.normalizedQuery, 'Attention Is All You Need');
    expect(result.candidates.single.arxivId, '1706.03762v7');
    expect(result.candidates.single.rank, 1);
    expect(adapter.requests.single.path, '/v1/me/paper-searches');
    expect(jsonDecode(adapter.bodies.single), {
      'query': 'Attention Is All You Need',
      'limit': 8,
    });
  });

  test(
    'exact import uses one idempotency identity and canonical source',
    () async {
      final adapter = _PaperResolutionAdapter();
      final api = PaperResolutionApi(_dio(adapter));
      const classifier = PaperInputClassifier();
      final source = PaperImportSource.fromClassification(
        classifier.classify('https://arxiv.org/pdf/1706.03762v7.pdf'),
      );

      final result = await api.importPaper(
        source: source,
        saveSourceKind: LibrarySaveSourceKind.arxivUrl,
        operationId: _operationId,
        expectedAuthEpoch: 7,
      );

      expect(result.paper.paperId, samplePaper.paperId);
      expect(result.item.lastOperationId, _operationId);
      final request = adapter.requests.single;
      expect(request.path, '/v1/me/library/imports');
      expect(request.headers['Idempotency-Key'], _operationId);
      expect(jsonDecode(adapter.bodies.single), {
        'operation_id': _operationId,
        'source': {
          'kind': 'arxiv_url',
          'value': 'https://arxiv.org/abs/1706.03762v7',
        },
        'target_state': 'inbox',
        'save_source_kind': 'arxiv_url',
      });
    },
  );

  test('malformed or mismatched responses fail closed', () async {
    final api = PaperResolutionApi(
      _dio(_PaperResolutionAdapter(malformed: true)),
    );

    await expectLater(
      api.searchByTitle(query: 'Attention', expectedAuthEpoch: 7),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
  });

  test('invalid queries and operation IDs never reach transport', () async {
    final adapter = _PaperResolutionAdapter();
    final api = PaperResolutionApi(_dio(adapter));

    await expectLater(
      api.searchByTitle(query: 'AI', expectedAuthEpoch: 7),
      throwsArgumentError,
    );
    await expectLater(
      api.importPaper(
        source: const PaperImportSource(
          kind: PaperImportSourceKind.arxivId,
          value: '1706.03762v7',
        ),
        saveSourceKind: LibrarySaveSourceKind.arxivId,
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

const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';

final class _PaperResolutionAdapter implements HttpClientAdapter {
  _PaperResolutionAdapter({this.malformed = false});

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

    final Object response = switch (options.path) {
      '/v1/me/paper-searches' =>
        malformed
            ? {
                'query_id': _operationId,
                'normalized_query': 'different query',
                'candidates': const [],
              }
            : {
                'query_id': _operationId,
                'normalized_query': 'Attention Is All You Need',
                'candidates': [
                  {
                    'arxiv_id': '1706.03762v7',
                    'title': 'Attention Is All You Need',
                    'authors': ['Ashish Vaswani'],
                    'abstract': 'A candidate abstract.',
                    'primary_category': 'cs.CL',
                    'categories': ['cs.CL', 'cs.LG'],
                    'published_at': '2017-06-12T00:00:00Z',
                    'updated_at': '2023-08-02T00:00:00Z',
                    'abs_url': 'https://arxiv.org/abs/1706.03762v7',
                    'match': {'kind': 'title', 'rank': 1},
                  },
                ],
              },
      '/v1/me/library/imports' => {
        'result': 'saved',
        'resolution': {
          'input_kind': 'arxiv_url',
          'canonical_arxiv_id': samplePaper.arxivId,
        },
        'item': {
          'paper_id': samplePaper.paperId,
          'state': 'inbox',
          'private_note': null,
          'save_source_kind': 'arxiv_url',
          'reminder_at': null,
          'saved_at': '2026-07-31T12:00:00Z',
          'updated_at': '2026-07-31T12:01:00Z',
          'reviewed_at': null,
          'archived_at': null,
          'removed': false,
          'removed_at': null,
          'revision': 42,
          'last_operation_id': _operationId,
        },
        'paper': samplePaper.toJson(),
        'sync_revision': 42,
      },
      _ => throw StateError('Unexpected request ${options.path}'),
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
