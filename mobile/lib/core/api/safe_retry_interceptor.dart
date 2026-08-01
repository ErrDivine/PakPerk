import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

const pakPerkTransportRetryCountExtraKey = 'pakperk.transport_retry_count';

typedef RetryDelay = Future<void> Function(Duration duration);
typedef RetryClock = DateTime Function();

/// Replays one transient request only when both its destination and payload
/// are safe to replay.
///
/// Retry eligibility is deliberately derived from the final composed
/// [RequestOptions]. Call sites cannot opt an unsafe request into replay with
/// an unreviewed boolean flag.
final class SafeRetryInterceptor extends Interceptor {
  SafeRetryInterceptor({
    required Dio dio,
    required Uri apiBaseUri,
    Duration defaultRetryDelay = const Duration(milliseconds: 200),
    Duration maximumRetryDelay = const Duration(seconds: 2),
    RetryDelay? delay,
    RetryClock? clock,
  }) : _dio = dio,
       _apiOrigin = _Origin.fromUri(apiBaseUri),
       _defaultRetryDelay = _validDelay(defaultRetryDelay, maximumRetryDelay),
       _maximumRetryDelay = _validMaximumDelay(maximumRetryDelay),
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final Dio _dio;
  final _Origin _apiOrigin;
  final Duration _defaultRetryDelay;
  final Duration _maximumRetryDelay;
  final RetryDelay _delay;
  final RetryClock _clock;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final retryDelay = _delayFor(err);
    if (retryDelay == null || !_isReplayEligible(options)) {
      handler.next(err);
      return;
    }

    try {
      await _waitUnlessCancelled(options, retryDelay);
      final cancelToken = options.cancelToken;
      if (cancelToken?.isCancelled == true) {
        throw cancelToken!.cancelError!;
      }
      final retried = options.copyWith(
        extra: {...options.extra, pakPerkTransportRetryCountExtraKey: 1},
      );
      // `dynamic` preserves the responseType already composed by the caller.
      // A concrete generic makes Dio coerce plain responses back to JSON.
      handler.resolve(await _dio.fetch<dynamic>(retried));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  bool _isReplayEligible(RequestOptions options) {
    if (_Origin.fromUri(options.uri) != _apiOrigin ||
        pakPerkTransportRetryCount(options) != 0 ||
        options.responseType == ResponseType.stream ||
        !_isReplayableData(options.data)) {
      return false;
    }
    final method = options.method.toUpperCase();
    return const {'GET', 'HEAD', 'OPTIONS'}.contains(method) ||
        _hasBoundedHeader(options, 'Idempotency-Key');
  }

  Duration? _delayFor(DioException error) {
    if (!_isTransient(error)) return null;
    final retryAfterValues = error.response?.headers['retry-after'];
    if (retryAfterValues == null) return _defaultRetryDelay;
    if (retryAfterValues.length != 1) return null;
    return _parseRetryAfter(retryAfterValues.single);
  }

  Duration? _parseRetryAfter(String rawValue) {
    final value = rawValue.trim();
    if (value.isEmpty || value.length > 128) return null;
    if (RegExp(r'^\d{1,10}$').hasMatch(value)) {
      final seconds = int.tryParse(value);
      if (seconds == null) return null;
      final delay = Duration(seconds: seconds);
      return delay <= _maximumRetryDelay ? delay : null;
    }
    try {
      final retryAt = HttpDate.parse(value).toUtc();
      final now = _clock().toUtc();
      final delay = retryAt.isAfter(now)
          ? retryAt.difference(now)
          : Duration.zero;
      return delay <= _maximumRetryDelay ? delay : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _waitUnlessCancelled(
    RequestOptions options,
    Duration duration,
  ) async {
    final cancelToken = options.cancelToken;
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (duration == Duration.zero) return;

    final delayed = _delay(duration).then<Object?>((_) => null);
    if (cancelToken == null) {
      await delayed;
      return;
    }
    final result = await Future.any<Object?>([delayed, cancelToken.whenCancel]);
    if (result is DioException) throw result;
  }
}

int pakPerkTransportRetryCount(RequestOptions options) {
  final value = options.extra[pakPerkTransportRetryCountExtraKey];
  return value is int && value > 0 ? 1 : 0;
}

bool _isTransient(DioException error) => switch (error.type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.connectionError => true,
  DioExceptionType.badResponse => const {
    408,
    429,
    502,
    503,
    504,
  }.contains(error.response?.statusCode),
  _ => false,
};

bool _hasBoundedHeader(RequestOptions options, String expectedName) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() != expectedName.toLowerCase()) continue;
    final value = entry.value;
    return value is String && value.isNotEmpty && value.length <= 512;
  }
  return false;
}

bool _isReplayableData(Object? data, [int depth = 0]) {
  if (data == null || data is String || data is num || data is bool) {
    return true;
  }
  if (data is Stream || data is FormData || data is MultipartFile) {
    return false;
  }
  if (depth >= 8) return false;
  if (data is Uint8List) return data.length <= 1024 * 1024;
  if (data is List) {
    return data.length <= 1024 &&
        data.every((value) => _isReplayableData(value, depth + 1));
  }
  if (data is Map) {
    return data.length <= 1024 &&
        data.entries.every(
          (entry) =>
              entry.key is String && _isReplayableData(entry.value, depth + 1),
        );
  }
  return false;
}

Duration _validMaximumDelay(Duration value) {
  if (value.isNegative || value > const Duration(seconds: 30)) {
    throw ArgumentError.value(
      value,
      'maximumRetryDelay',
      'Must be between zero and 30 seconds.',
    );
  }
  return value;
}

Duration _validDelay(Duration value, Duration maximum) {
  _validMaximumDelay(maximum);
  if (value.isNegative || value > maximum) {
    throw ArgumentError.value(
      value,
      'defaultRetryDelay',
      'Must be non-negative and no greater than maximumRetryDelay.',
    );
  }
  return value;
}

final class _Origin {
  const _Origin(this.scheme, this.host, this.port);

  factory _Origin.fromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort
        ? uri.port
        : switch (scheme) {
            'https' => 443,
            'http' => 80,
            _ => -1,
          };
    return _Origin(scheme, uri.host.toLowerCase(), port);
  }

  final String scheme;
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is _Origin &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(scheme, host, port);
}
