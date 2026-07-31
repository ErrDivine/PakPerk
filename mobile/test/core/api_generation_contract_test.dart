import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';

void main() {
  final requests = <(String, Future<Object> Function(ApiClient))>[
    ('prepare', (client) => client.prepare('paper-1')),
    ('processing', (client) => client.getProcessing('paper-1')),
    ('introduction', (client) => client.getIntroduction('paper-1')),
    ('connections', (client) => client.getConnections('paper-1')),
    ('chat', (client) => client.sendChat(paperId: 'paper-1', message: 'Why?')),
  ];

  for (final request in requests) {
    test(
      '${request.$1} rejects a missing or non-positive generation',
      () async {
        for (final generation in <int?>[null, 0, -1]) {
          final body = <String, Object?>{'paper_id': 'paper-1'};
          if (generation != null) body['generation'] = generation;
          final client = _client(_JsonAdapter(body));
          addTearDown(client.dispose);

          await expectLater(
            request.$2(client),
            throwsA(
              isA<ApiException>().having(
                (error) => error.code,
                'code',
                'INVALID_API_RESPONSE',
              ),
            ),
          );
        }
      },
    );
  }

  test(
    'generation-scoped endpoints retain a positive response generation',
    () async {
      final client = _client(
        _JsonAdapter(const {
          'paper_id': 'paper-1',
          'generation': 7,
          'ready': false,
        }),
      );
      addTearDown(client.dispose);

      final connections = await client.getConnections('paper-1');

      expect(connections.generation, 7);
    },
  );
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

class _JsonAdapter implements HttpClientAdapter {
  const _JsonAdapter(this.body);

  final Map<String, Object?> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
