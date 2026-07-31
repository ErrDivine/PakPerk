import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account.dart';
import 'package:pakperk/core/api/api_exception.dart';

void main() {
  test('GET /v1/me requires an exact strong version ETag', () async {
    final adapter = _RecordingAdapter(etag: '"profile-1"');
    final api = AccountApi(_dio(adapter));

    final result = await api.getCurrent();

    expect(result.profile.id, _accountId);
    expect(result.etag, '"profile-1"');
    expect(adapter.requests.single.path, '/v1/me');

    final invalid = AccountApi(_dio(_RecordingAdapter(etag: 'W/"profile-1"')));
    await expectLater(
      invalid.getCurrent(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_API_RESPONSE',
        ),
      ),
    );
  });

  test('PATCH carries If-Match and preserves omitted/null fields', () async {
    final adapter = _RecordingAdapter(etag: '"profile-1"');
    final api = AccountApi(_dio(adapter));

    await api.update(
      expectedProfileVersion: 3,
      patch: const AccountProfilePatch(handle: 'ada_reader'),
    );
    await api.update(
      expectedProfileVersion: 4,
      patch: const AccountProfilePatch(displayName: ProfileField.clear()),
    );

    expect(adapter.requests[0].method, 'PATCH');
    expect(adapter.requests[0].headers['If-Match'], '"profile-3"');
    expect(jsonDecode(adapter.requestBodies[0]), {'handle': 'ada_reader'});
    expect(adapter.requests[1].headers['If-Match'], '"profile-4"');
    expect(jsonDecode(adapter.requestBodies[1]), {'display_name': null});
  });

  test('PATCH rejects empty updates before making a request', () async {
    final adapter = _RecordingAdapter(etag: '"profile-1"');
    final api = AccountApi(_dio(adapter));

    await expectLater(
      api.update(expectedProfileVersion: 1, patch: const AccountProfilePatch()),
      throwsArgumentError,
    );
    expect(adapter.requests, isEmpty);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

Map<String, Object?> _responseJson() => <String, Object?>{
  'account': <String, Object?>{
    'id': _accountId,
    'handle': null,
    'display_name': null,
    'status': 'active',
    'profile_version': 1,
    'profile_complete': false,
    'terms_version': null,
    'terms_accepted_at': null,
    'current_terms_version': '2026-07',
    'terms_current': false,
    'created_at': '2026-07-30T10:00:00Z',
    'updated_at': '2026-07-30T11:00:00Z',
  },
};

final class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.etag});

  final String? etag;
  final List<RequestOptions> requests = [];
  final List<String> requestBodies = [];

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
    requestBodies.add(utf8.decode(bytes));
    return ResponseBody.fromString(
      jsonEncode(_responseJson()),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (etag != null) 'etag': [etag!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
