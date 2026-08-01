import 'dart:async';
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

  test('authenticated request metadata requires an epoch binding', () {
    expect(
      () => pakPerkRequestOptions(auth: RequestAuthPolicy.required),
      throwsArgumentError,
    );
    expect(
      () => pakPerkRequestOptions(
        auth: RequestAuthPolicy.optional,
        expectedAuthEpoch: 1,
      ),
      throwsArgumentError,
    );
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
        expectedAuthEpoch: 1,
      ),
    );
    expect(adapter.authorizationHeaders, ['Bearer access-one']);

    await expectLater(
      dio.get<Object?>(
        'https://arxiv.org/v1/me',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: 1,
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

  test(
    'recent auth uses only its supplied bearer and never replays 401',
    () async {
      final tokens = _TokenSource();
      final adapter = _SequenceAdapter([401, 200]);
      final dio = _dio(tokens, adapter);

      await expectLater(
        dio.delete<Object?>(
          '/v1/me',
          options: pakPerkRequestOptions(
            auth: RequestAuthPolicy.recent,
            retry: AuthRetryPolicy.never,
            expectedAuthEpoch: 1,
            recentBearer: 'one-use-recent',
          ),
        ),
        throwsA(isA<DioException>()),
      );

      expect(tokens.accessCalls, 0);
      expect(tokens.refreshCalls, 0);
      expect(adapter.requests, 1);
      expect(adapter.authorizationHeaders, ['Bearer one-use-recent']);
    },
  );

  test(
    'recent auth synchronously rejects a stale epoch before transport',
    () async {
      final tokens = _EpochTokenSource(epoch: 8, token: 'account-b-access');
      final adapter = _SequenceAdapter([200]);
      final dio = _dio(tokens, adapter);

      await expectLater(
        dio.delete<Object?>(
          '/v1/me',
          options: pakPerkRequestOptions(
            auth: RequestAuthPolicy.recent,
            expectedAuthEpoch: 7,
            recentBearer: 'account-a-recent',
          ),
        ),
        throwsA(_authError('AUTH_SUPERSEDED')),
      );

      expect(adapter.requests, 0);
    },
  );

  test('a safe 401 refreshes and replays exactly once', () async {
    final tokens = _TokenSource();
    final adapter = _SequenceAdapter([401, 200]);
    final dio = _dio(tokens, adapter);

    final response = await dio.get<Object?>(
      '/v1/me',
      options: pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        retry: AuthRetryPolicy.safe,
        expectedAuthEpoch: 1,
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
            expectedAuthEpoch: 1,
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
          expectedAuthEpoch: 1,
          headers: const {'If-Match': '"profile-3"'},
        ),
      );
      expect(allowedTokens.refreshCalls, 1);
      expect(allowedAdapter.requests, 2);
    },
  );

  test(
    'epoch-bound request is rejected before transport after account switch',
    () async {
      final accessStarted = Completer<void>();
      final releaseAccess = Completer<void>();
      final tokens = _EpochTokenSource(
        epoch: 7,
        token: 'account-a-access',
        accessStarted: accessStarted,
        releaseAccess: releaseAccess,
      );
      final adapter = _SequenceAdapter([200]);
      final dio = _dio(tokens, adapter);

      final request = dio.get<Object?>(
        '/v1/me/library',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: 7,
        ),
      );
      final rejected = expectLater(
        request,
        throwsA(_authError('AUTH_SUPERSEDED')),
      );
      await accessStarted.future;
      tokens.switchSession(epoch: 8, token: 'account-b-access');
      releaseAccess.complete();

      await rejected;
      expect(adapter.requests, 0);
      expect(adapter.authorizationHeaders, isEmpty);
    },
  );

  test('epoch-bound 401 is not replayed after account switch', () async {
    final tokens = _EpochTokenSource(epoch: 7, token: 'account-a-access');
    final adapter = _DelayedUnauthorizedAdapter();
    final dio = _dio(tokens, adapter);

    final request = dio.patch<Object?>(
      '/v1/me',
      data: const {'display_name': 'Ada'},
      options: pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        retry: AuthRetryPolicy.idempotencyProtected,
        expectedAuthEpoch: 7,
        headers: const {'If-Match': '"profile-3"'},
      ),
    );
    final rejected = expectLater(
      request,
      throwsA(_authError('AUTH_SUPERSEDED')),
    );
    await adapter.firstFetchStarted.future;
    tokens.switchSession(epoch: 8, token: 'account-b-access');
    adapter.releaseUnauthorized.complete();

    await rejected;
    expect(adapter.requests, 1);
    expect(adapter.authorizationHeaders, ['Bearer account-a-access']);
    expect(tokens.refreshCalls, 1);
  });
}

Dio _dio(AuthTokenSource tokens, HttpClientAdapter adapter) {
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

Matcher _authError(String code) => isA<DioException>().having(
  (error) => (error.error! as AuthRequestFailure).code,
  'safe code',
  code,
);

final class _TokenSource implements AuthTokenSource {
  int accessCalls = 0;
  int refreshCalls = 0;
  String currentToken = 'access-one';

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch >= 0;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    accessCalls += 1;
    return currentToken;
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    refreshCalls += 1;
    expect(rejectedAccessToken, 'access-one');
    return currentToken = 'access-two';
  }
}

final class _EpochTokenSource implements AuthTokenSource {
  _EpochTokenSource({
    required this.epoch,
    required this.token,
    this.accessStarted,
    this.releaseAccess,
  });

  int epoch;
  String token;
  final Completer<void>? accessStarted;
  final Completer<void>? releaseAccess;
  int refreshCalls = 0;

  void switchSession({required int epoch, required String token}) {
    this.epoch = epoch;
    this.token = token;
  }

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == epoch;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    accessStarted?.complete();
    _requireEpoch(expectedAuthEpoch);
    await releaseAccess?.future;
    _requireEpoch(expectedAuthEpoch);
    return token;
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    refreshCalls += 1;
    _requireEpoch(expectedAuthEpoch);
    return token;
  }

  void _requireEpoch(int? expectedAuthEpoch) {
    if (expectedAuthEpoch != null && expectedAuthEpoch != epoch) {
      throw AuthFailure(
        AuthFailureKind.superseded,
        AuthFailureCode.operationSuperseded,
        sessionEpoch: expectedAuthEpoch,
      );
    }
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

final class _DelayedUnauthorizedAdapter implements HttpClientAdapter {
  final firstFetchStarted = Completer<void>();
  final releaseUnauthorized = Completer<void>();
  final List<String?> authorizationHeaders = [];
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests += 1;
    authorizationHeaders.add(options.headers['Authorization'] as String?);
    if (requests == 1) {
      firstFetchStarted.complete();
      await releaseUnauthorized.future;
      return ResponseBody.fromString(
        jsonEncode(const {'error': 'unauthorized'}),
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(const {}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
