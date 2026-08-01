import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/api/http_telemetry_interceptor.dart';
import 'package:pakperk/core/api/safe_retry_interceptor.dart';
import 'package:pakperk/core/api/transport_network_status.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

void main() {
  group('SafeRetryInterceptor', () {
    test('retries transient statuses and transport failures once', () async {
      for (final status in const [408, 429, 502, 503, 504]) {
        final adapter = _SequenceAdapter([
          _Attempt.response(status),
          const _Attempt.response(200),
        ]);
        final dio = _dio(adapter);

        expect((await dio.get<Object?>('/v1/feed')).statusCode, 200);
        expect(adapter.requests, 2, reason: 'status $status');
        expect(adapter.retryCounts, [0, 1]);
        dio.close(force: true);
      }

      for (final type in const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        final adapter = _SequenceAdapter([
          _Attempt.failure(type),
          const _Attempt.response(200),
        ]);
        final dio = _dio(adapter);

        expect((await dio.get<Object?>('/v1/feed')).statusCode, 200);
        expect(adapter.requests, 2, reason: 'failure $type');
        dio.close(force: true);
      }
    });

    test('never performs more than one transport retry', () async {
      final adapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final dio = _dio(adapter);

      await expectLater(
        dio.get<Object?>('/v1/feed'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requests, 2);
      expect(adapter.retryCounts, [0, 1]);
      dio.close(force: true);
    });

    test('transport retry preserves an explicit plain response type', () async {
      final adapter = _PlainRetryAdapter();
      final dio = _dio(adapter);

      final response = await dio.get<String>(
        '/v1/feed',
        options: Options(responseType: ResponseType.plain),
      );

      expect(response.data, 'plain retry response');
      expect(adapter.requests, 2);
      expect(adapter.responseTypes, [ResponseType.plain, ResponseType.plain]);
      dio.close(force: true);
    });

    test('writes require a bounded durable idempotency key', () async {
      final unsafeAdapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final unsafeDio = _dio(unsafeAdapter);
      await expectLater(
        unsafeDio.post<Object?>(
          '/v1/papers/paper-secret/comments',
          data: const {'body': 'private comment'},
        ),
        throwsA(isA<DioException>()),
      );
      expect(unsafeAdapter.requests, 1);
      unsafeDio.close(force: true);

      final oversizedAdapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final oversizedDio = _dio(oversizedAdapter);
      await expectLater(
        oversizedDio.patch<Object?>(
          '/v1/me',
          data: const {'display_name': 'Ada'},
          options: Options(headers: {'If-Match': 'x' * 513}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(oversizedAdapter.requests, 1);
      oversizedDio.close(force: true);

      // If-Match prevents applying the same versioned mutation twice, but it
      // cannot replay the canonical response after the first attempt commits
      // and its response is lost. Reporting a subsequent 412 as the result of
      // that successful edit would be false, so transport replay stays off.
      final lostResponseAdapter = _SequenceAdapter(const [
        _Attempt.failure(DioExceptionType.receiveTimeout),
        _Attempt.response(412),
      ]);
      final lostResponseDio = _dio(lostResponseAdapter);
      await expectLater(
        lostResponseDio.patch<Object?>(
          '/v1/me',
          data: const {'display_name': 'Ada'},
          options: Options(headers: const {'If-Match': '"profile-1"'}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(lostResponseAdapter.requests, 1);
      lostResponseDio.close(force: true);

      final protectedAdapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final protectedDio = _dio(protectedAdapter);
      final response = await protectedDio.post<Object?>(
        '/v1/papers/paper-secret/comments',
        data: const {'body': 'private comment'},
        options: Options(headers: const {'idempotency-key': 'operation-1'}),
      );
      expect(response.statusCode, 200);
      expect(protectedAdapter.requests, 2);
      expect(protectedAdapter.retryCounts, [0, 1]);
      protectedDio.close(force: true);
    });

    test('never replays raw responses or streaming request bodies', () async {
      final rawAdapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final rawDio = _dio(rawAdapter);
      await expectLater(
        rawDio.delete<ResponseBody>(
          '/v1/me',
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Idempotency-Key': 'deletion-operation'},
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(rawAdapter.requests, 1);
      rawDio.close(force: true);

      final streamAdapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final streamDio = _dio(streamAdapter);
      await expectLater(
        streamDio.post<Object?>(
          '/v1/upload',
          data: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
          options: Options(
            headers: const {'Idempotency-Key': 'upload-operation'},
          ),
        ),
        throwsA(isA<DioException>()),
      );
      expect(streamAdapter.requests, 1);
      streamDio.close(force: true);
    });

    test('honors seconds and HTTP-date Retry-After values', () async {
      final delays = <Duration>[];
      final now = DateTime.utc(2030, 1, 2, 3, 4, 5);
      final secondsAdapter = _SequenceAdapter(const [
        _Attempt.response(429, retryAfter: ['2']),
        _Attempt.response(200),
      ]);
      final secondsDio = _dio(
        secondsAdapter,
        maximumRetryDelay: const Duration(seconds: 5),
        delay: (duration) async => delays.add(duration),
        clock: () => now,
      );
      await secondsDio.get<Object?>('/v1/feed');
      expect(delays, [const Duration(seconds: 2)]);
      secondsDio.close(force: true);

      delays.clear();
      final dateAdapter = _SequenceAdapter([
        _Attempt.response(
          503,
          retryAfter: [HttpDate.format(now.add(const Duration(seconds: 3)))],
        ),
        const _Attempt.response(200),
      ]);
      final dateDio = _dio(
        dateAdapter,
        maximumRetryDelay: const Duration(seconds: 5),
        delay: (duration) async => delays.add(duration),
        clock: () => now,
      );
      await dateDio.get<Object?>('/v1/feed');
      expect(delays, [const Duration(seconds: 3)]);
      dateDio.close(force: true);
    });

    test('declines ambiguous, malformed, or excessive Retry-After', () async {
      for (final values in const [
        ['1', '2'],
        ['tomorrow'],
        ['31'],
      ]) {
        final adapter = _SequenceAdapter([
          _Attempt.response(429, retryAfter: values),
          const _Attempt.response(200),
        ]);
        final dio = _dio(
          adapter,
          maximumRetryDelay: const Duration(seconds: 30),
        );

        await expectLater(
          dio.get<Object?>('/v1/feed'),
          throwsA(isA<DioException>()),
        );
        expect(adapter.requests, 1, reason: 'Retry-After $values');
        dio.close(force: true);
      }
    });

    test('cancellation interrupts the wait and prevents replay', () async {
      final delayStarted = Completer<void>();
      final neverRelease = Completer<void>();
      final adapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final dio = _dio(
        adapter,
        defaultRetryDelay: const Duration(seconds: 1),
        maximumRetryDelay: const Duration(seconds: 1),
        delay: (_) {
          delayStarted.complete();
          return neverRelease.future;
        },
      );
      final cancellation = CancelToken();
      final request = dio.get<Object?>('/v1/feed', cancelToken: cancellation);
      await delayStarted.future;
      cancellation.cancel('screen disposed');

      await expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(adapter.requests, 1);
      dio.close(force: true);
    });

    test('the original CancelToken remains bound to the replay', () async {
      final adapter = _ReplayBlockingAdapter();
      final dio = _dio(adapter);
      final cancellation = CancelToken();
      final request = dio.get<Object?>('/v1/feed', cancelToken: cancellation);
      await adapter.replayStarted.future;
      cancellation.cancel('screen disposed during replay');

      await expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(adapter.requests, 2);
      expect(adapter.retryCounts, [0, 1]);
      dio.close(force: true);
    });

    test('retries only the exact configured origin', () async {
      final telemetry = _RecordingTelemetrySink();
      final adapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final dio = _dio(adapter, telemetry: RedactingTelemetrySink(telemetry));

      await expectLater(
        dio.get<Object?>('https://api.pakperk.app.evil.test/v1/feed'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requests, 1);
      await Future<void>.delayed(Duration.zero);
      expect(telemetry.events, isEmpty);
      dio.close(force: true);
    });
  });

  test(
    'network status ignores local auth failures but tracks transport outcomes',
    () async {
      final status = TransportNetworkStatus();
      addTearDown(status.dispose);
      final tokens = _MutableTokenSource('access-token');
      final adapter = _SequenceAdapter(const [
        _Attempt.failure(DioExceptionType.connectionError),
        _Attempt.response(401),
      ]);
      final dio = Dio(
        BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
      )..httpClientAdapter = adapter;
      dio.interceptors
        ..add(
          AuthInterceptor(
            dio: dio,
            apiBaseUri: Uri.parse('https://api.pakperk.app'),
            tokenSource: tokens,
          ),
        )
        ..add(TransportNetworkStatusInterceptor(status));
      addTearDown(() => dio.close(force: true));
      final changes = <bool>[];
      final subscription = status.changes.listen(changes.add);
      addTearDown(subscription.cancel);
      final options = pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        expectedAuthEpoch: 1,
      );

      await expectLater(
        dio.get<Object?>('/v1/me', options: options),
        throwsA(isA<DioException>()),
      );
      expect(status.isOffline, isTrue);
      expect(changes, [true]);

      status.observeApiException(
        const ApiException(
          code: 'UNAUTHENTICATED',
          message: 'Sign in again to continue.',
          statusCode: 401,
        ),
      );
      expect(status.isOffline, isTrue);
      expect(changes, [true]);

      tokens.token = null;
      await expectLater(
        dio.get<Object?>('/v1/me', options: options),
        throwsA(
          isA<DioException>().having(
            (error) => (error.error! as AuthRequestFailure).code,
            'safe auth code',
            'UNAUTHENTICATED',
          ),
        ),
      );
      expect(adapter.requests, 1, reason: 'auth failure must remain local');
      expect(status.isOffline, isTrue);
      expect(changes, [true]);

      tokens.token = 'access-token';
      await expectLater(
        dio.get<Object?>('/v1/me', options: options),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(status.isOffline, isFalse);
      expect(changes, [true, false]);
    },
  );

  test('post-401 local auth failure retains HTTP reachability', () async {
    final status = TransportNetworkStatus()..markOffline();
    addTearDown(status.dispose);
    final tokens = _MutableTokenSource('access-token')..rejectRefresh = true;
    final adapter = _SequenceAdapter(const [_Attempt.response(401)]);
    final dio = Dio(
      BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
    )..httpClientAdapter = adapter;
    dio.interceptors
      ..add(
        AuthInterceptor(
          dio: dio,
          apiBaseUri: Uri.parse('https://api.pakperk.app'),
          tokenSource: tokens,
        ),
      )
      ..add(TransportNetworkStatusInterceptor(status));
    addTearDown(() => dio.close(force: true));

    await expectLater(
      dio.get<Object?>(
        '/v1/me',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: 1,
        ),
      ),
      throwsA(
        isA<DioException>()
            .having(
              (error) => (error.error! as AuthRequestFailure).code,
              'safe auth code',
              'UNAUTHENTICATED',
            )
            .having(
              (error) => error.response?.statusCode,
              'original status',
              401,
            ),
      ),
    );

    expect(adapter.requests, 1);
    expect(status.isOffline, isFalse);
  });

  test(
    'HTTP telemetry emits one closed, content-free event after retry',
    () async {
      final delegate = _RecordingTelemetrySink();
      final adapter = _SequenceAdapter(const [
        _Attempt.response(503),
        _Attempt.response(200),
      ]);
      final dio = _dio(adapter, telemetry: RedactingTelemetrySink(delegate));

      await dio.post<Object?>(
        '/v1/papers/private-paper-id/comments?token=query-secret',
        data: const {'body': 'private comment body'},
        options: Options(
          headers: const {
            'Authorization': 'Bearer private-token',
            'Idempotency-Key': 'private-operation-id',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(delegate.events, hasLength(1));
      expect(
        delegate.events.single.name,
        PakPerkTelemetryEvent.httpRequestCompleted,
      );
      expect(delegate.events.single.attributes, {
        'method_class': 'write',
        'route_class': 'comments',
        'outcome': 'success',
        'status_family': '2xx',
        'elapsed_ms': isA<int>(),
        'retry_count': 1,
      });
      final encoded = jsonEncode(delegate.events.single.attributes);
      expect(encoded, isNot(contains('private')));
      expect(encoded, isNot(contains('token')));
      expect(encoded, isNot(contains('Authorization')));
      dio.close(force: true);
    },
  );

  test('strict raw dispatch emits success, error, and cancellation', () async {
    final successSink = _RecordingTelemetrySink();
    final successDio = _strictDio(
      _SequenceAdapter(const [_Attempt.response(200)]),
      successSink,
    );
    final success = await successDio.get<ResponseBody>(
      '/v1/me/deletion-verification',
      options: _strictOptions((status) => status == 200),
    );
    await success.data!.stream.drain<void>();
    await Future<void>.delayed(Duration.zero);
    expect(successSink.events.single.attributes, {
      'method_class': 'read',
      'route_class': 'account_deletion',
      'outcome': 'success',
      'status_family': '2xx',
      'elapsed_ms': isA<int>(),
      'retry_count': 0,
    });
    successDio.close(force: true);

    final errorSink = _RecordingTelemetrySink();
    final errorDio = _strictDio(
      _SequenceAdapter(const [_Attempt.response(503)]),
      errorSink,
    );
    await expectLater(
      errorDio.delete<ResponseBody>(
        '/v1/me',
        options: _strictOptions((status) => status == 202),
      ),
      throwsA(isA<DioException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(errorSink.events.single.attributes, {
      'method_class': 'delete',
      'route_class': 'account_deletion',
      'outcome': 'server_error',
      'status_family': '5xx',
      'elapsed_ms': isA<int>(),
      'retry_count': 0,
    });
    errorDio.close(force: true);

    final cancellationAdapter = _StrictCancellationAdapter();
    final cancellationSink = _RecordingTelemetrySink();
    final cancellationDio = _strictDio(cancellationAdapter, cancellationSink);
    final cancelToken = CancelToken();
    final cancelled = cancellationDio.get<ResponseBody>(
      '/v1/me/deletion-verification',
      cancelToken: cancelToken,
      options: _strictOptions((status) => status == 200),
    );
    await cancellationAdapter.started.future;
    cancelToken.cancel('verification cancellation');
    await expectLater(cancelled, throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    expect(cancellationSink.events.single.attributes, {
      'method_class': 'read',
      'route_class': 'account_deletion',
      'outcome': 'cancelled',
      'status_family': 'none',
      'elapsed_ms': isA<int>(),
      'retry_count': 0,
    });
    cancellationDio.close(force: true);
  });
}

Options _strictOptions(bool Function(int?) validateStatus) =>
    pakPerkRequestOptions(
      auth: RequestAuthPolicy.required,
      retry: AuthRetryPolicy.safe,
      expectedAuthEpoch: 1,
      responseType: ResponseType.stream,
      strictRawResponseStream: true,
      validateStatus: validateStatus,
    );

Dio _strictDio(HttpClientAdapter adapter, _RecordingTelemetrySink delegate) {
  final dio = Dio(
    BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
  )..httpClientAdapter = adapter;
  dio.interceptors
    ..add(
      AuthInterceptor(
        dio: dio,
        apiBaseUri: Uri.parse('https://api.pakperk.app'),
        tokenSource: const _StrictTokenSource(),
      ),
    )
    ..add(
      SafeRetryInterceptor(
        dio: dio,
        apiBaseUri: Uri.parse('https://api.pakperk.app'),
        defaultRetryDelay: Duration.zero,
      ),
    )
    ..add(
      HttpTelemetryInterceptor(
        apiBaseUri: Uri.parse('https://api.pakperk.app'),
        telemetry: RedactingTelemetrySink(delegate),
      ),
    );
  return dio;
}

Dio _dio(
  HttpClientAdapter adapter, {
  Duration defaultRetryDelay = Duration.zero,
  Duration maximumRetryDelay = const Duration(seconds: 2),
  RetryDelay? delay,
  RetryClock? clock,
  TelemetrySink? telemetry,
}) {
  final dio = Dio(
    BaseOptions(baseUrl: 'https://api.pakperk.app', followRedirects: false),
  )..httpClientAdapter = adapter;
  dio.interceptors.add(
    SafeRetryInterceptor(
      dio: dio,
      apiBaseUri: Uri.parse('https://api.pakperk.app'),
      defaultRetryDelay: defaultRetryDelay,
      maximumRetryDelay: maximumRetryDelay,
      delay: delay,
      clock: clock,
    ),
  );
  if (telemetry != null) {
    dio.interceptors.add(
      HttpTelemetryInterceptor(
        apiBaseUri: Uri.parse('https://api.pakperk.app'),
        telemetry: telemetry,
      ),
    );
  }
  return dio;
}

final class _Attempt {
  const _Attempt.response(this.status, {this.retryAfter}) : failureType = null;

  const _Attempt.failure(this.failureType) : status = null, retryAfter = null;

  final int? status;
  final DioExceptionType? failureType;
  final List<String>? retryAfter;
}

final class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.attempts);

  final List<_Attempt> attempts;
  final List<int> retryCounts = [];
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    retryCounts.add(pakPerkTransportRetryCount(options));
    final index = requests < attempts.length ? requests : attempts.length - 1;
    final attempt = attempts[index];
    requests += 1;
    final failureType = attempt.failureType;
    if (failureType != null) {
      throw DioException(
        requestOptions: options,
        type: failureType,
        error: const _PrivateTransportFailure(),
      );
    }
    return ResponseBody.fromString(
      jsonEncode(const {'ok': true}),
      attempt.status!,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
        if (attempt.retryAfter != null) 'retry-after': attempt.retryAfter!,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _PrivateTransportFailure implements Exception {
  const _PrivateTransportFailure();
}

final class _MutableTokenSource implements AuthTokenSource {
  _MutableTokenSource(this.token);

  String? token;
  bool rejectRefresh = false;

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 1;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async =>
      token;

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async => rejectRefresh ? null : token;
}

final class _StrictTokenSource implements AuthTokenSource {
  const _StrictTokenSource();

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 1;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async =>
      'strict-access-token';

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async => null;
}

final class _StrictCancellationAdapter implements HttpClientAdapter {
  final started = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    started.complete();
    await cancelFuture;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'cancelled',
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _PlainRetryAdapter implements HttpClientAdapter {
  int requests = 0;
  final responseTypes = <ResponseType>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests += 1;
    responseTypes.add(options.responseType);
    return ResponseBody.fromString(
      requests == 1 ? 'temporarily unavailable' : 'plain retry response',
      requests == 1 ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: const ['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _ReplayBlockingAdapter implements HttpClientAdapter {
  final Completer<void> replayStarted = Completer<void>();
  final List<int> retryCounts = [];
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests += 1;
    retryCounts.add(pakPerkTransportRetryCount(options));
    if (requests == 1) {
      return ResponseBody.fromString(
        jsonEncode(const {'ok': false}),
        503,
        headers: {
          Headers.contentTypeHeader: const ['application/json'],
        },
      );
    }
    replayStarted.complete();
    await cancelFuture;
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'cancelled',
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _RecordedEvent {
  const _RecordedEvent(this.name, this.attributes);

  final String name;
  final Map<String, Object?> attributes;
}

final class _RecordingTelemetrySink implements TelemetrySink {
  final List<_RecordedEvent> events = [];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add(_RecordedEvent(name, Map.unmodifiable(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}
