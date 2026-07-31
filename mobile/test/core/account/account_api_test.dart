import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/auth/auth.dart';

void main() {
  test('GET /v1/me requires an exact strong version ETag', () async {
    final adapter = _RecordingAdapter(etag: '"profile-1"');
    final api = AccountApi(_dio(adapter));

    final result = await api.getCurrent(expectedAuthEpoch: _authEpoch);

    expect(result.profile.id, _accountId);
    expect(result.etag, '"profile-1"');
    expect(adapter.requests.single.path, '/v1/me');

    final invalid = AccountApi(_dio(_RecordingAdapter(etag: 'W/"profile-1"')));
    await expectLater(
      invalid.getCurrent(expectedAuthEpoch: _authEpoch),
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
      expectedAuthEpoch: _authEpoch,
      expectedProfileVersion: 3,
      patch: const AccountProfilePatch(handle: 'ada_reader'),
    );
    await api.update(
      expectedAuthEpoch: _authEpoch,
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
      api.update(
        expectedAuthEpoch: _authEpoch,
        expectedProfileVersion: 1,
        patch: const AccountProfilePatch(),
      ),
      throwsArgumentError,
    );
    expect(adapter.requests, isEmpty);
  });

  test(
    'GET is rejected before transport when its account epoch changes',
    () async {
      final accessStarted = Completer<void>();
      final releaseAccess = Completer<void>();
      final tokens = _EpochTokenSource(
        epoch: _authEpoch,
        token: 'account-a-access',
        accessStarted: accessStarted,
        releaseAccess: releaseAccess,
      );
      final adapter = _RecordingAdapter(etag: '"profile-1"');
      final api = AccountApi(_authenticatedDio(tokens, adapter));

      final request = api.getCurrent(expectedAuthEpoch: _authEpoch);
      final rejected = expectLater(
        request,
        throwsA(_apiError('AUTH_SUPERSEDED')),
      );
      await accessStarted.future;
      tokens.switchSession(epoch: _authEpoch + 1, token: 'account-b-access');
      releaseAccess.complete();

      await rejected;
      expect(adapter.requests, isEmpty);
    },
  );

  test('PATCH 401 is not replayed after an account epoch change', () async {
    final tokens = _EpochTokenSource(
      epoch: _authEpoch,
      token: 'account-a-access',
    );
    final adapter = _DelayedUnauthorizedAdapter();
    final api = AccountApi(_authenticatedDio(tokens, adapter));

    final request = api.update(
      expectedAuthEpoch: _authEpoch,
      expectedProfileVersion: 1,
      patch: const AccountProfilePatch(displayName: ProfileField.value('Ada')),
    );
    final rejected = expectLater(
      request,
      throwsA(_apiError('AUTH_SUPERSEDED')),
    );
    await adapter.firstFetchStarted.future;
    tokens.switchSession(epoch: _authEpoch + 1, token: 'account-b-access');
    adapter.releaseUnauthorized.complete();

    await rejected;
    expect(adapter.requests, 1);
    expect(adapter.authorizationHeaders, ['Bearer account-a-access']);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

Dio _authenticatedDio(AuthTokenSource tokens, HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(
    AuthInterceptor(
      dio: dio,
      apiBaseUri: Uri.parse('https://api.pakperk.app'),
      tokenSource: tokens,
    ),
  );
  return dio;
}

Matcher _apiError(String code) =>
    isA<ApiException>().having((error) => error.code, 'safe code', code);

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _authEpoch = 7;

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
    'community_guidelines_version': null,
    'community_guidelines_accepted_at': null,
    'current_community_guidelines_version': '2026-07',
    'community_guidelines_current': false,
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

  void switchSession({required int epoch, required String token}) {
    this.epoch = epoch;
    this.token = token;
  }

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
      jsonEncode(_responseJson()),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"profile-1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
