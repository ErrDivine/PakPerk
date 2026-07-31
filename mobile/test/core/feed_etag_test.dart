import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/feed_http_result.dart';

void main() {
  test(
    'conditional first page sends validator and parses 304 without a body',
    () async {
      final adapter = _FeedAdapter(
        statusCode: 304,
        responseHeaders: {
          'etag': ['W/"feed-opaque"'],
        },
      );
      final client = _client(adapter);

      final result = await client.getFeedConditional(
        category: 'cs.CL',
        limit: 30,
        ifNoneMatch: 'W/"feed-opaque"',
      );

      expect(result, isA<FeedHttpResult>());
      expect(result.notModified, isTrue);
      expect(result.page, isNull);
      expect(result.etag, 'W/"feed-opaque"');
      expect(adapter.lastHeaders.value('If-None-Match'), 'W/"feed-opaque"');
      expect(adapter.lastUri.queryParameters['category'], 'cs.CL');
      expect(adapter.lastUri.queryParameters['limit'], '30');
      client.dispose();
    },
  );

  test(
    'modified response carries parsed page and a bounded opaque validator',
    () async {
      final adapter = _FeedAdapter(
        statusCode: 200,
        responseHeaders: {
          'etag': ['"feed-next"'],
        },
        body: jsonEncode({
          'items': const <Object?>[],
          'next_cursor': 'opaque-cursor',
        }),
      );
      final client = _client(adapter);

      final result = await client.getFeedConditional(limit: 30);

      expect(result.notModified, isFalse);
      expect(result.page?.items, isEmpty);
      expect(result.page?.nextCursor, 'opaque-cursor');
      expect(result.etag, '"feed-next"');
      expect(adapter.lastHeaders.value('If-None-Match'), isNull);
      client.dispose();
    },
  );

  test('cursor pages never send a first-page validator', () async {
    final adapter = _FeedAdapter(
      statusCode: 200,
      body: jsonEncode({'items': const <Object?>[]}),
    );
    final client = _client(adapter);

    await client.getFeedConditional(
      cursor: 'opaque-cursor',
      ifNoneMatch: '"must-not-leak"',
    );

    expect(adapter.lastHeaders.value('If-None-Match'), isNull);
    client.dispose();
  });

  test('malformed validators are neither sent nor retained', () async {
    final adapter = _FeedAdapter(
      statusCode: 200,
      responseHeaders: {
        'etag': ['not-an-etag\r\nX-Injected: true'],
      },
      body: jsonEncode({'items': const <Object?>[]}),
    );
    final client = _client(adapter);

    final result = await client.getFeedConditional(
      ifNoneMatch: 'also-not-an-etag',
    );

    expect(adapter.lastHeaders.value('If-None-Match'), isNull);
    expect(result.etag, isNull);
    client.dispose();
  });

  test('ambiguous duplicate response validators are ignored', () async {
    final adapter = _FeedAdapter(
      statusCode: 200,
      responseHeaders: {
        'etag': ['"first"', '"second"'],
      },
      body: jsonEncode({'items': const <Object?>[]}),
    );
    final client = _client(adapter);

    final result = await client.getFeedConditional();

    expect(result.etag, isNull);
    client.dispose();
  });
}

ApiClient _client(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
    ..httpClientAdapter = adapter;
  return ApiClient(
    baseUrl: 'http://localhost:8080',
    sessionId: '00000000-0000-4000-8000-000000000001',
    dio: dio,
  );
}

class _FeedAdapter implements HttpClientAdapter {
  _FeedAdapter({
    required this.statusCode,
    this.body = '',
    this.responseHeaders = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, List<String>> responseHeaders;
  late Uri lastUri;
  late RequestOptions lastOptions;

  Headers get lastHeaders => Headers.fromMap(
    lastOptions.headers.map(
      (key, value) => MapEntry(
        key,
        value is List ? value.map((item) => '$item').toList() : ['$value'],
      ),
    ),
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    lastUri = options.uri;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        ...responseHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
