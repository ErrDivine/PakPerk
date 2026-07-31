import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/auth/auth.dart';

void main() {
  test('public requests never read auth state or attach a bearer', () async {
    final tokens = _TokenSource();
    final adapter = _SequenceAdapter([200]);
    final dio = _dio(tokens, adapter);

    await dio.get<Object?>(
      '/v1/feed',
      options: pakPerkRequestOptions(auth: RequestAuthPolicy.optional),
    );

    expect(tokens.accessCalls, 0);
    expect(adapter.authorizationHeaders, [null]);
  });

  test('required auth is attached only to the exact API origin', () async {
    final tokens = _TokenSource();
    final adapter = _SequenceAdapter([200]);
    final dio = _dio(tokens, adapter);

    await dio.get<Object?>(
      '/v1/me',
      options: pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        retry: AuthRetryPolicy.safe,
      ),
    );
    expect(adapter.authorizationHeaders, ['Bearer access-one']);

    await expectLater(
      dio.get<Object?>(
        'https://arxiv.org/v1/me',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
        ),
      ),
      throwsA(
        isA<DioException>().having(
          (error) => (error.error! as AuthRequestFailure).code,
          'safe code',
          'AUTH_ORIGIN_REJECTED',
        ),
      ),
    );
    expect(adapter.requests, 1);
  });

  test('a safe 401 refreshes and replays exactly once', () async {
    final tokens = _TokenSource();
    final adapter = _SequenceAdapter([401, 200]);
    final dio = _dio(tokens, adapter);

    final response = await dio.get<Object?>(
      '/v1/me',
      options: pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        retry: AuthRetryPolicy.safe,
      ),
    );

    expect(response.statusCode, 200);
    expect(tokens.refreshCalls, 1);
    expect(adapter.authorizationHeaders, [
      'Bearer access-one',
      'Bearer access-two',
    ]);
  });

  test(
    'writes replay only with a bounded concurrency/idempotency key',
    () async {
      final deniedTokens = _TokenSource();
      final deniedAdapter = _SequenceAdapter([401, 200]);
      final deniedDio = _dio(deniedTokens, deniedAdapter);
      await expectLater(
        deniedDio.patch<Object?>(
          '/v1/me',
          data: const {'display_name': 'Ada'},
          options: pakPerkRequestOptions(
            auth: RequestAuthPolicy.required,
            retry: AuthRetryPolicy.idempotencyProtected,
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(deniedTokens.refreshCalls, 0);
      expect(deniedAdapter.requests, 1);

      final allowedTokens = _TokenSource();
      final allowedAdapter = _SequenceAdapter([401, 200]);
      final allowedDio = _dio(allowedTokens, allowedAdapter);
      await allowedDio.patch<Object?>(
        '/v1/me',
        data: const {'display_name': 'Ada'},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          headers: const {'If-Match': '"profile-3"'},
        ),
      );
      expect(allowedTokens.refreshCalls, 1);
      expect(allowedAdapter.requests, 2);
    },
  );
}

Dio _dio(_TokenSource tokens, _SequenceAdapter adapter) {
  final dio = Dio(
    BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
  )..httpClientAdapter = adapter;
  dio.interceptors.add(
    AuthInterceptor(
      dio: dio,
      apiBaseUri: Uri.parse('https://api.pakperk.app'),
      tokenSource: tokens,
    ),
  );
  return dio;
}

final class _TokenSource implements AuthTokenSource {
  int accessCalls = 0;
  int refreshCalls = 0;

  @override
  Future<String?> accessTokenForRequest() async {
    accessCalls += 1;
    return 'access-one';
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
  }) async {
    refreshCalls += 1;
    expect(rejectedAccessToken, 'access-one');
    return 'access-two';
  }
}

final class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.statuses);

  final List<int> statuses;
  final List<String?> authorizationHeaders = [];
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorizationHeaders.add(options.headers['Authorization'] as String?);
    final index = requests < statuses.length ? requests : statuses.length - 1;
    final status = statuses[index];
    requests += 1;
    return ResponseBody.fromString(
      jsonEncode(status == 401 ? const {'error': 'unauthorized'} : const {}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
