import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account_deletion/account_deletion.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/auth/auth.dart';

void main() {
  test(
    'DELETE /v1/me is bodyless, one-use, and accepts only exact 202',
    () async {
      final adapter = _DeletionAdapter(status: 202, body: _deletionEnvelope());
      final api = AccountDeletionApi(_dio(adapter));

      final result = await api.deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 7,
      );

      expect(result.operationId, _operationId);
      expect(result.state, AccountDeletionServerState.requested);
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.responseType, ResponseType.stream);
      expect(adapter.requestBodies.single, isEmpty);
      expect(adapter.requests.single.headers['Idempotency-Key'], isNull);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer recent-access',
      );
    },
  );

  test(
    'DELETE rejects 200 and 204 even with an otherwise valid body',
    () async {
      for (final status in [200, 204]) {
        final api = AccountDeletionApi(
          _dio(_DeletionAdapter(status: status, body: _deletionEnvelope())),
        );

        await expectLater(
          api.deleteCurrentAccount(
            recentBearer: 'recent-access',
            expectedAuthEpoch: 7,
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.statusCode,
              'status',
              status,
            ),
          ),
          reason: '$status must not be treated as accepted',
        );
      }
    },
  );

  test('DELETE rejects malformed, extra, and oversized responses', () async {
    final invalidBodies = <Object?>[
      const {},
      {'deletion': _operationJson(), 'extra': true},
      const {'deletion': 'wrong-type'},
      {
        'deletion': {..._operationJson(), 'unknown': true},
      },
      {
        'deletion': {
          ..._operationJson(),
          'requested_at': '2029-01-01T00:00:00Z',
        },
      },
    ];
    for (final body in invalidBodies) {
      final api = AccountDeletionApi(
        _dio(_DeletionAdapter(status: 202, body: body)),
      );
      await expectLater(
        api.deleteCurrentAccount(
          recentBearer: 'recent-access',
          expectedAuthEpoch: 7,
        ),
        throwsA(_invalidResponse),
        reason: body.toString(),
      );
    }

    final oversized = AccountDeletionApi(
      _dio(
        _DeletionAdapter(
          status: 202,
          body: _deletionEnvelope(),
          declaredContentLength: 32 * 1024,
        ),
      ),
    );
    await expectLater(
      oversized.deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 7,
      ),
      throwsA(_invalidResponse),
    );
  });

  test(
    'DELETE aborts oversized streamed bodies without trusting content-length',
    () async {
      final rawBody = jsonEncode({
        'deletion': {'padding': List.filled(20 * 1024, 'x').join()},
      });
      for (final declaredLength in <int?>[null, 1]) {
        final adapter = _DeletionAdapter(
          status: 202,
          body: null,
          rawBody: rawBody,
          responseChunkSize: 1024,
          declaredContentLength: declaredLength,
        );
        final api = AccountDeletionApi(_dio(adapter));

        await expectLater(
          api.deleteCurrentAccount(
            recentBearer: 'recent-access',
            expectedAuthEpoch: 7,
          ),
          throwsA(_invalidResponse),
          reason: 'declared content length: $declaredLength',
        );

        expect(adapter.responseStreamCancelled, isTrue);
        expect(adapter.responseChunksEmitted, lessThan(adapter.totalChunks));
      }
    },
  );

  test('DELETE has a total response deadline for dribbling bodies', () async {
    final adapter = _DeletionAdapter(
      status: 202,
      body: _deletionEnvelope(),
      responseChunkSize: 1,
      responseChunkDelay: const Duration(milliseconds: 10),
    );
    final api = AccountDeletionApi(
      _dio(adapter),
      responseDeadline: const Duration(milliseconds: 35),
    );
    final stopwatch = Stopwatch()..start();

    await expectLater(
      api.deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 7,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'NETWORK_UNAVAILABLE',
        ),
      ),
    );

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(adapter.responseStreamCancelled, isTrue);
    expect(adapter.responseChunksEmitted, lessThan(adapter.totalChunks));
  });

  test('DELETE maps only a bounded JSON service error payload', () async {
    final api = AccountDeletionApi(
      _dio(
        _DeletionAdapter(
          status: 503,
          body: _unavailableEnvelope(),
          retryAfter: '30',
        ),
      ),
    );

    await expectLater(
      api.deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 7,
      ),
      throwsA(
        isA<ApiException>()
            .having(
              (error) => error.code,
              'code',
              'ACCOUNT_DELETION_UNAVAILABLE',
            )
            .having((error) => error.statusCode, 'status', 503),
      ),
    );
  });

  test('strict responses reject ambiguous singleton headers', () async {
    final cases = <_DeletionAdapter>[
      _DeletionAdapter(
        status: 202,
        body: _deletionEnvelope(),
        contentTypes: const ['application/json', 'text/plain'],
      ),
      _DeletionAdapter(
        status: 202,
        body: _deletionEnvelope(),
        declaredContentLengths: const ['256', '256'],
      ),
      _DeletionAdapter(
        status: 202,
        body: _deletionEnvelope(),
        declaredContentLengths: const ['not-a-length'],
      ),
      _DeletionAdapter(
        status: 202,
        body: _deletionEnvelope(),
        cacheControls: const ['private', 'no-store', 'public'],
      ),
    ];
    for (final adapter in cases) {
      await expectLater(
        AccountDeletionApi(_dio(adapter)).deleteCurrentAccount(
          recentBearer: 'recent-access',
          expectedAuthEpoch: 7,
        ),
        throwsA(_invalidResponse),
      );
    }
  });

  test(
    'DELETE treats near-miss post-commit 503 responses as ambiguous',
    () async {
      final cases = <({String name, _DeletionAdapter adapter})>[
        (
          name: 'missing private cache directive',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(),
            cacheControl: 'no-store',
            retryAfter: '30',
          ),
        ),
        (
          name: 'wrong retry-after',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(),
            retryAfter: '31',
          ),
        ),
        (
          name: 'ambiguous retry-after',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(),
            retryAfters: const ['30', '30'],
          ),
        ),
        (
          name: 'wrong message',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(message: 'Almost the right message.'),
            retryAfter: '30',
          ),
        ),
        (
          name: 'not retryable',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(retryable: false),
            retryAfter: '30',
          ),
        ),
        (
          name: 'invalid request id',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(requestId: 'not-a-request-id'),
            retryAfter: '30',
          ),
        ),
        (
          name: 'extra error key',
          adapter: _DeletionAdapter(
            status: 503,
            body: _unavailableEnvelope(extra: true),
            retryAfter: '30',
          ),
        ),
      ];

      for (final testCase in cases) {
        final api = AccountDeletionApi(_dio(testCase.adapter));
        await expectLater(
          api.deleteCurrentAccount(
            recentBearer: 'recent-access',
            expectedAuthEpoch: 7,
          ),
          throwsA(
            isA<ApiException>()
                .having((error) => error.code, 'code', 'HTTP_ERROR')
                .having((error) => error.statusCode, 'status', 503),
          ),
          reason: testCase.name,
        );
      }
    },
  );

  test('DELETE preserves only exact pre-commit rejection contracts', () async {
    final cases = <({int status, String code, _DeletionAdapter adapter})>[
      (
        status: 400,
        code: 'INVALID_REQUEST',
        adapter: _DeletionAdapter(
          status: 400,
          body: _errorEnvelope(code: 'INVALID_REQUEST'),
        ),
      ),
      (
        status: 401,
        code: 'REAUTHENTICATION_REQUIRED',
        adapter: _DeletionAdapter(
          status: 401,
          body: _errorEnvelope(code: 'REAUTHENTICATION_REQUIRED'),
          wwwAuthenticate: 'Bearer',
        ),
      ),
      (
        status: 404,
        code: 'FEATURE_DISABLED',
        adapter: _DeletionAdapter(
          status: 404,
          body: _errorEnvelope(code: 'FEATURE_DISABLED'),
        ),
      ),
      (
        status: 405,
        code: 'METHOD_NOT_ALLOWED',
        adapter: _DeletionAdapter(
          status: 405,
          body: _errorEnvelope(code: 'METHOD_NOT_ALLOWED'),
        ),
      ),
      (
        status: 413,
        code: 'REQUEST_BODY_TOO_LARGE',
        adapter: _DeletionAdapter(
          status: 413,
          body: _errorEnvelope(code: 'REQUEST_BODY_TOO_LARGE'),
        ),
      ),
      (
        status: 429,
        code: 'RATE_LIMITED',
        adapter: _DeletionAdapter(
          status: 429,
          body: _errorEnvelope(code: 'RATE_LIMITED', retryable: true),
          retryAfter: '30',
        ),
      ),
      (
        status: 503,
        code: 'AUTHENTICATION_UNAVAILABLE',
        adapter: _DeletionAdapter(
          status: 503,
          body: _errorEnvelope(
            code: 'AUTHENTICATION_UNAVAILABLE',
            retryable: true,
          ),
          retryAfter: '30',
        ),
      ),
    ];

    for (final testCase in cases) {
      await expectLater(
        AccountDeletionApi(_dio(testCase.adapter)).deleteCurrentAccount(
          recentBearer: 'recent-access',
          expectedAuthEpoch: 7,
        ),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'status', testCase.status)
              .having((error) => error.code, 'code', testCase.code)
              .having((error) => error.requestId, 'request ID', isNotNull),
        ),
        reason: '${testCase.status} ${testCase.code}',
      );
    }
  });

  test(
    'DELETE demotes malformed or crossed pre-commit errors to ambiguous',
    () async {
      final cases = <({String name, _DeletionAdapter adapter})>[
        (
          name: 'extra envelope key',
          adapter: _DeletionAdapter(
            status: 400,
            body: _errorEnvelope(code: 'INVALID_REQUEST', extra: true),
          ),
        ),
        (
          name: 'missing bearer challenge',
          adapter: _DeletionAdapter(
            status: 401,
            body: _errorEnvelope(code: 'UNAUTHENTICATED'),
          ),
        ),
        (
          name: 'crossed status and code',
          adapter: _DeletionAdapter(
            status: 403,
            body: _errorEnvelope(code: 'REAUTHENTICATION_REQUIRED'),
          ),
        ),
        (
          name: 'missing retry-after',
          adapter: _DeletionAdapter(
            status: 429,
            body: _errorEnvelope(code: 'RATE_LIMITED', retryable: true),
          ),
        ),
        (
          name: 'invalid request ID',
          adapter: _DeletionAdapter(
            status: 404,
            body: _errorEnvelope(
              code: 'FEATURE_DISABLED',
              requestId: 'not-a-request-id',
            ),
          ),
        ),
        (
          name: 'missing private cache policy',
          adapter: _DeletionAdapter(
            status: 503,
            body: _errorEnvelope(
              code: 'AUTHENTICATION_UNAVAILABLE',
              retryable: true,
            ),
            cacheControl: 'no-store',
            retryAfter: '30',
          ),
        ),
      ];

      for (final testCase in cases) {
        await expectLater(
          AccountDeletionApi(_dio(testCase.adapter)).deleteCurrentAccount(
            recentBearer: 'recent-access',
            expectedAuthEpoch: 7,
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'HTTP_ERROR',
            ),
          ),
          reason: testCase.name,
        );
      }
    },
  );

  test('DELETE requires private, no-store response caching policy', () async {
    for (final cacheControl in [
      null,
      'private',
      'no-store',
      'public, no-store',
    ]) {
      final api = AccountDeletionApi(
        _dio(
          _DeletionAdapter(
            status: 202,
            body: _deletionEnvelope(),
            cacheControl: cacheControl,
          ),
        ),
      );
      await expectLater(
        api.deleteCurrentAccount(
          recentBearer: 'recent-access',
          expectedAuthEpoch: 7,
        ),
        throwsA(_invalidResponse),
        reason: '$cacheControl',
      );
    }
  });

  test('GET same-account check also uses only the recent bearer', () async {
    final adapter = _DeletionAdapter(status: 200, body: _accountEnvelope());
    final api = AccountDeletionApi(_dio(adapter));

    final identity = await api.verifyRecentSession(
      recentBearer: 'recent-access',
      expectedAuthEpoch: 7,
    );

    expect(identity.accountId, _accountId);
    expect(identity.status, AccountDeletionVerificationStatus.suspended);
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.responseType, ResponseType.stream);
    expect(adapter.requests.single.path, '/v1/me/deletion-verification');
    expect(
      adapter.requests.single.headers['Authorization'],
      'Bearer recent-access',
    );
  });

  test(
    'normal bearer transport can verify a suspended unbound account',
    () async {
      final adapter = _DeletionAdapter(status: 200, body: _accountEnvelope());
      final api = AccountDeletionApi(
        _dio(adapter, tokenSource: _NormalTokenSource()),
      );

      final identity = await api.verifyCurrentSession(expectedAuthEpoch: 7);

      expect(identity.accountId, _accountId);
      expect(identity.status, AccountDeletionVerificationStatus.suspended);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer normal-session-access',
      );
    },
  );

  test('raw normal verification refreshes one 401 exactly once', () async {
    final tokens = _RefreshingTokenSource();
    final adapter = _DeletionAdapter(
      status: 200,
      body: _accountEnvelope(),
      statusSequence: const [401, 200],
      bodySequence: [
        const {
          'error': {
            'code': 'UNAUTHENTICATED',
            'message': 'Refresh required.',
            'retryable': false,
            'request_id': '00000000-0000-4000-8000-000000000111',
          },
        },
        _accountEnvelope(),
      ],
    );

    final result = await AccountDeletionApi(
      _dio(adapter, tokenSource: tokens),
    ).verifyCurrentSession(expectedAuthEpoch: 7);

    expect(result.accountId, _accountId);
    expect(tokens.refreshCalls, 1);
    expect(adapter.requests, hasLength(2));
    expect(
      adapter.requests.map((request) => request.headers['Authorization']),
      ['Bearer normal-session-access', 'Bearer refreshed-session-access'],
    );
  });

  test('recent raw requests never refresh or replay a 401', () async {
    final tokens = _RefreshingTokenSource();
    final adapter = _DeletionAdapter(
      status: 401,
      body: const {
        'error': {
          'code': 'UNAUTHENTICATED',
          'message': 'Recent sign-in required.',
          'retryable': false,
          'request_id': '00000000-0000-4000-8000-000000000111',
        },
      },
      wwwAuthenticate: 'Bearer',
    );

    await expectLater(
      AccountDeletionApi(
        _dio(adapter, tokenSource: tokens),
      ).deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 7,
      ),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'status', 401),
      ),
    );

    expect(tokens.refreshCalls, 0);
    expect(tokens.accessCalls, 0);
    expect(adapter.requests, hasLength(1));
  });

  test('recent bearer and epoch are rejected before raw dispatch', () async {
    for (final bearer in [
      'token with space',
      'token\nInjected: yes',
      'token\u0000',
    ]) {
      final adapter = _DeletionAdapter(status: 202, body: _deletionEnvelope());
      await expectLater(
        AccountDeletionApi(
          _dio(adapter),
        ).deleteCurrentAccount(recentBearer: bearer, expectedAuthEpoch: 7),
        throwsArgumentError,
      );
      expect(adapter.requests, isEmpty);
    }

    final staleAdapter = _DeletionAdapter(
      status: 202,
      body: _deletionEnvelope(),
    );
    await expectLater(
      AccountDeletionApi(_dio(staleAdapter)).deleteCurrentAccount(
        recentBearer: 'recent-access',
        expectedAuthEpoch: 8,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'AUTH_SUPERSEDED',
        ),
      ),
    );
    expect(staleAdapter.requests, isEmpty);
  });

  test('verification requires exact 200 and application/json', () async {
    final wrongStatus = AccountDeletionApi(
      _dio(
        _DeletionAdapter(status: 201, body: _accountEnvelope()),
        tokenSource: _NormalTokenSource(),
      ),
    );
    await expectLater(
      wrongStatus.verifyCurrentSession(expectedAuthEpoch: 7),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'status', 201),
      ),
    );

    final wrongMediaType = AccountDeletionApi(
      _dio(
        _DeletionAdapter(
          status: 200,
          body: _accountEnvelope(),
          contentType: 'text/plain',
        ),
        tokenSource: _NormalTokenSource(),
      ),
    );
    await expectLater(
      wrongMediaType.verifyCurrentSession(expectedAuthEpoch: 7),
      throwsA(_invalidResponse),
    );
  });

  test(
    'verification transport decodes pending and deleted fail-closed states',
    () async {
      final pendingAdapter = _DeletionAdapter(
        status: 200,
        body: const {
          'account': {
            'id': _accountId,
            'status': 'deletion_pending',
            'deletion_operation_id': _operationId,
          },
        },
      );
      final pending = await AccountDeletionApi(
        _dio(pendingAdapter, tokenSource: _NormalTokenSource()),
      ).verifyCurrentSession(expectedAuthEpoch: 7);
      expect(pending.status, AccountDeletionVerificationStatus.deletionPending);
      expect(pending.deletionOperationId, _operationId);

      final deletedAdapter = _DeletionAdapter(
        status: 200,
        body: const {
          'account': {
            'id': _accountId,
            'status': 'deleted',
            'deletion_operation_id': null,
          },
        },
      );
      final deleted = await AccountDeletionApi(
        _dio(deletedAdapter, tokenSource: _NormalTokenSource()),
      ).verifyCurrentSession(expectedAuthEpoch: 7);
      expect(deleted.status, AccountDeletionVerificationStatus.deleted);
      expect(deleted.deletionOperationId, isNull);
    },
  );
}

Dio _dio(
  HttpClientAdapter adapter, {
  AuthTokenSource tokenSource = const _NeverReadTokenSource(),
}) {
  final dio = Dio(
    BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
  )..httpClientAdapter = adapter;
  dio.interceptors.add(
    AuthInterceptor(
      dio: dio,
      apiBaseUri: Uri.parse('https://api.pakperk.app'),
      tokenSource: tokenSource,
    ),
  );
  return dio;
}

final _invalidResponse = isA<ApiException>().having(
  (error) => error.code,
  'code',
  'INVALID_API_RESPONSE',
);

const _accountId = '00000000-0000-4000-8000-000000000123';
const _operationId = '00000000-0000-4000-8000-000000000789';

Map<String, Object?> _deletionEnvelope() => {'deletion': _operationJson()};

Map<String, Object?> _operationJson() => const {
  'operation_id': _operationId,
  'state': 'requested',
  'requested_at': '2029-01-01T00:00:00.000Z',
  'updated_at': '2029-01-01T00:00:00.000Z',
};

Map<String, Object?> _accountEnvelope() => const {
  'account': {
    'id': _accountId,
    'status': 'suspended',
    'deletion_operation_id': null,
  },
};

Map<String, Object?> _unavailableEnvelope({
  String message =
      'Your account is disabled, but durable deletion processing is '
      'temporarily unavailable. Cleanup will continue automatically.',
  bool retryable = true,
  String requestId = '00000000-0000-4000-8000-000000000456',
  bool extra = false,
}) => {
  'error': {
    'code': 'ACCOUNT_DELETION_UNAVAILABLE',
    'message': message,
    'retryable': retryable,
    'request_id': requestId,
    if (extra) 'extra': true,
  },
};

Map<String, Object?> _errorEnvelope({
  required String code,
  bool retryable = false,
  String requestId = '00000000-0000-4000-8000-000000000456',
  bool extra = false,
}) => {
  'error': {
    'code': code,
    'message': 'A stable bounded API error.',
    'retryable': retryable,
    'request_id': requestId,
    if (extra) 'extra': true,
  },
};

final class _NeverReadTokenSource implements AuthTokenSource {
  const _NeverReadTokenSource();

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 7;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) =>
      throw StateError('recent auth must not read the normal session token');

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) => throw StateError('recent auth must never refresh');
}

final class _NormalTokenSource implements AuthTokenSource {
  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 7;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async =>
      'normal-session-access';

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async => 'normal-session-refreshed';
}

final class _RefreshingTokenSource implements AuthTokenSource {
  int accessCalls = 0;
  int refreshCalls = 0;
  String token = 'normal-session-access';

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 7;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    accessCalls += 1;
    return token;
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    refreshCalls += 1;
    token = 'refreshed-session-access';
    return token;
  }
}

final class _DeletionAdapter implements HttpClientAdapter {
  _DeletionAdapter({
    required this.status,
    required this.body,
    this.cacheControl = 'private, no-store',
    this.contentType = 'application/json',
    this.declaredContentLength,
    this.rawBody,
    this.responseChunkSize,
    this.retryAfter,
    this.retryAfters,
    this.wwwAuthenticate,
    this.responseChunkDelay,
    this.contentTypes,
    this.declaredContentLengths,
    this.cacheControls,
    this.statusSequence,
    this.bodySequence,
  });

  final int status;
  final Object? body;
  final String? cacheControl;
  final String contentType;
  final int? declaredContentLength;
  final String? rawBody;
  final int? responseChunkSize;
  final String? retryAfter;
  final List<String>? retryAfters;
  final String? wwwAuthenticate;
  final Duration? responseChunkDelay;
  final List<String>? contentTypes;
  final List<String>? declaredContentLengths;
  final List<String>? cacheControls;
  final List<int>? statusSequence;
  final List<Object?>? bodySequence;
  final List<RequestOptions> requests = [];
  final List<List<int>> requestBodies = [];
  int responseChunksEmitted = 0;
  bool responseStreamCancelled = false;

  int get totalChunks {
    final length = utf8.encode(rawBody ?? jsonEncode(body)).length;
    final size = responseChunkSize ?? length;
    return (length / size).ceil();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final responseIndex = requests.length;
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    requestBodies.add(bytes);
    final responseBody =
        bodySequence != null && responseIndex < bodySequence!.length
        ? bodySequence![responseIndex]
        : body;
    final responseStatus =
        statusSequence != null && responseIndex < statusSequence!.length
        ? statusSequence![responseIndex]
        : status;
    final responseBytes = Uint8List.fromList(
      utf8.encode(rawBody ?? jsonEncode(responseBody)),
    );
    return ResponseBody(
      _responseChunks(responseBytes),
      responseStatus,
      headers: {
        Headers.contentTypeHeader: contentTypes ?? [contentType],
        if (cacheControls != null)
          'cache-control': cacheControls!
        else if (cacheControl != null)
          'cache-control': [cacheControl!],
        if (declaredContentLengths != null)
          Headers.contentLengthHeader: declaredContentLengths!
        else if (declaredContentLength != null)
          Headers.contentLengthHeader: ['$declaredContentLength'],
        if (retryAfters != null)
          'retry-after': retryAfters!
        else if (retryAfter != null)
          'retry-after': [retryAfter!],
        if (wwwAuthenticate != null) 'www-authenticate': [wwwAuthenticate!],
      },
    );
  }

  Stream<Uint8List> _responseChunks(Uint8List bytes) async* {
    final chunkSize = responseChunkSize ?? bytes.length;
    try {
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        if (responseChunkDelay case final delay?) {
          await Future<void>.delayed(delay);
        }
        responseChunksEmitted += 1;
        final end = offset + chunkSize < bytes.length
            ? offset + chunkSize
            : bytes.length;
        yield Uint8List.sublistView(bytes, offset, end);
      }
    } finally {
      responseStreamCancelled = true;
    }
  }

  @override
  void close({bool force = false}) {}
}
