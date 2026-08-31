import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/discovery_search/discovery_search_api.dart';
import 'package:pakperk/core/discovery_search/discovery_search_models.dart';

import '../support/fakes.dart';

void main() {
  test('typed search routes preserve intent and idempotency', () async {
    final adapter = _SearchAdapter();
    final api = DiscoverySearchApi(_dio(adapter));

    final suggestions = await api.suggestions(query: 'retrieval systems');
    expect(suggestions.items.single.label, 'Information retrieval');
    expect(adapter.requests.last.path, '/v1/search/suggestions');
    expect(adapter.requests.last.queryParameters, {'q': 'retrieval systems'});

    final lookup = await api.lookup(query: 'retrieval systems', limit: 10);
    expect(lookup.items.single.paper.arxivId, samplePaper.arxivId);
    expect(lookup.disclaimer, isNull);
    expect(adapter.requests.last.method, 'GET');

    final explore = await api.explore(
      query: 'retrieval systems',
      filters: DiscoverySearchFilters(categories: const ['cs.IR']),
      sort: DiscoverySearchSort.recency,
      limit: 12,
    );
    expect(explore.disclaimer, _disclaimer);
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data, {
      'query': 'retrieval systems',
      'filters': {
        'categories': ['cs.IR'],
        'topics': <String>[],
        'published_after': null,
        'published_before': null,
        'sources': ['arxiv'],
      },
      'sort': 'recency',
      'cursor': null,
      'limit': 12,
    });

    final saved = await api.listSaved(expectedAuthEpoch: 7);
    expect(saved.single.query, 'retrieval systems');
    const operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
    await api.save(
      operationId: operationId,
      query: 'retrieval systems',
      filters: DiscoverySearchFilters(),
      sort: DiscoverySearchSort.relevance,
      expectedAuthEpoch: 7,
    );
    expect(adapter.requests.last.headers['Idempotency-Key'], operationId);
    expect((adapter.requests.last.data as Map)['operation_id'], operationId);

    const savedSearchId = '20000000-0000-4000-8000-000000000002';
    await api.deleteSaved(savedSearchId: savedSearchId, expectedAuthEpoch: 7);
    expect(adapter.requests.last.method, 'DELETE');
    expect(adapter.requests.last.path, '/v1/search/saved/$savedSearchId');
    expect(adapter.requests.last.data, isNull);
    expect(adapter.requests.last.headers, isNot(contains('Idempotency-Key')));
  });

  test('suggestion bounds and Explore disclaimer fail closed', () async {
    final malformedSuggestions = DiscoverySearchApi(
      _dio(_SearchAdapter(tamperSuggestions: true)),
    );
    await expectLater(
      malformedSuggestions.suggestions(query: 'retrieval systems'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );

    final malformedExplore = DiscoverySearchApi(
      _dio(_SearchAdapter(tamperDisclaimer: true)),
    );
    await expectLater(
      malformedExplore.explore(
        query: 'retrieval systems',
        filters: DiscoverySearchFilters(),
        sort: DiscoverySearchSort.relevance,
      ),
      throwsA(isA<ApiException>()),
    );
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _SearchAdapter implements HttpClientAdapter {
  _SearchAdapter({
    this.tamperSuggestions = false,
    this.tamperDisclaimer = false,
  });

  final bool tamperSuggestions;
  final bool tamperDisclaimer;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'DELETE' &&
        options.path.startsWith('/v1/search/saved/')) {
      return ResponseBody.fromString('', 204);
    }
    final body = switch (options.path) {
      '/v1/search/suggestions' => {
        'normalized_query': 'retrieval systems',
        'items': [
          for (var index = 0; index < (tamperSuggestions ? 9 : 1); index += 1)
            {
              'topic_id': '10000000-0000-4000-8000-00000000000$index',
              'label': 'Information retrieval',
              'source_vocabulary': 'pakperk_topics_v1',
            },
        ],
      },
      '/v1/search/lookup' => _page(explore: false),
      '/v1/search/explore' => _page(
        explore: true,
        disclaimer: tamperDisclaimer ? 'Unbounded search.' : _disclaimer,
      ),
      '/v1/search/saved' when options.method == 'GET' => {
        'items': [_savedSearch],
      },
      '/v1/search/saved' => {'saved_search': _savedSearch},
      _ => throw StateError('Unexpected route ${options.path}'),
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

Map<String, Object?> _page({required bool explore, String? disclaimer}) => {
  'normalized_query': 'retrieval systems',
  'items': [
    {
      'paper': samplePaper.toJson(),
      'match_kind': 'phrase',
      'relevance_bucket': 8,
      'source': 'arxiv',
    },
  ],
  'next_cursor': null,
  'diagnostics': [
    {
      'source': 'arxiv',
      'status': 'queried',
      'coverage': 'partial',
      'matches_returned': 1,
    },
  ],
  'related_topics': const <Object?>[],
  if (explore) 'disclaimer': disclaimer,
};

const _savedSearch = <String, Object?>{
  'id': '20000000-0000-4000-8000-000000000002',
  'query': 'retrieval systems',
  'filters': {
    'categories': <String>[],
    'topics': <String>[],
    'published_after': null,
    'published_before': null,
    'sources': ['arxiv'],
  },
  'sort': 'relevance',
  'revision': 1,
  'created_at': '2026-08-19T12:00:00Z',
  'updated_at': '2026-08-19T12:00:00Z',
};

const _disclaimer =
    "Explore searches Pakperk's bounded local arXiv metadata cache. "
    'It is not a systematic or complete literature search.';
