import 'package:dio/dio.dart';

import '../telemetry/telemetry.dart';
import 'safe_retry_interceptor.dart';

const _traceExtraKey = 'pakperk.http_telemetry_trace';

/// Starts the content-free timer for paths that dispatch before this
/// interceptor's request hook, notably strict account-deletion streams.
void startPakPerkHttpTelemetryTrace(RequestOptions options) {
  if (options.extra[_traceExtraKey] is _Trace) return;
  options.extra[_traceExtraKey] = _Trace()..stopwatch.start();
}

/// Emits one content-free completion event for a Pakperk API operation.
///
/// The route classifier returns only a fixed enum-like value. URI text,
/// headers, identifiers, payloads, response bodies, and exception strings are
/// never handed to the telemetry boundary.
final class HttpTelemetryInterceptor extends Interceptor {
  HttpTelemetryInterceptor({
    required Uri apiBaseUri,
    required TelemetrySink telemetry,
  }) : _apiOrigin = _Origin.fromUri(apiBaseUri),
       _telemetry = telemetry;

  final _Origin _apiOrigin;
  final TelemetrySink _telemetry;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_isApiRequest(options) && options.extra[_traceExtraKey] is! _Trace) {
      startPakPerkHttpTelemetryTrace(options);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _emitOnce(
      response.requestOptions,
      outcome: _responseOutcome(response.statusCode),
      statusCode: response.statusCode,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _emitOnce(
      err.requestOptions,
      outcome: _outcomeFor(err),
      statusCode: err.response?.statusCode,
    );
    handler.next(err);
  }

  void _emitOnce(
    RequestOptions options, {
    required String outcome,
    required int? statusCode,
  }) {
    if (!_isApiRequest(options)) return;
    final trace = options.extra[_traceExtraKey];
    if (trace is! _Trace || trace.emitted) return;
    trace.emitted = true;
    trace.stopwatch.stop();
    final elapsed = trace.stopwatch.elapsedMilliseconds;
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.httpRequestCompleted, {
      'method_class': _methodClass(options.method),
      'route_class': _routeClass(options.method, options.uri.pathSegments),
      'outcome': outcome,
      'status_family': _statusFamily(statusCode),
      'elapsed_ms': elapsed > 86_400_000 ? 86_400_000 : elapsed,
      'retry_count': pakPerkTransportRetryCount(options),
    });
  }

  bool _isApiRequest(RequestOptions options) =>
      _Origin.fromUri(options.uri) == _apiOrigin;
}

final class _Trace {
  final Stopwatch stopwatch = Stopwatch();
  bool emitted = false;
}

String _methodClass(String method) => switch (method.toUpperCase()) {
  'GET' || 'HEAD' || 'OPTIONS' => 'read',
  'POST' || 'PUT' || 'PATCH' => 'write',
  'DELETE' => 'delete',
  _ => 'other',
};

String _routeClass(String method, List<String> segments) {
  if (_matches(segments, const ['health', 'ready'])) return 'health';
  if (segments.isEmpty || segments.first != 'v1') return 'unknown';
  if (segments.length >= 2 && segments[1] == 'feed') return 'feed';
  if (segments.length >= 2 && segments[1] == 'papers') {
    if (segments.length >= 3 && segments[2] == 'by-arxiv') {
      return 'paper';
    }
    if (segments.length >= 4) {
      return switch (segments[3]) {
        'prepare' => 'paper_prepare',
        'chat' => 'paper_chat',
        'comments' => 'comments',
        _ => 'paper',
      };
    }
    return 'paper';
  }
  if (segments.length >= 2 && segments[1] == 'me') {
    if (method.toUpperCase() == 'DELETE' && segments.length == 2) {
      return 'account_deletion';
    }
    if (segments.length < 3) return 'account';
    return switch (segments[2]) {
      'library' => 'library',
      'comments' => 'comments',
      'blocked-users' => 'moderation',
      'deletion-verification' => 'account_deletion',
      _ => 'account',
    };
  }
  if (segments.length >= 2 && segments[1] == 'comments') {
    return segments.contains('reports') ? 'moderation' : 'comments';
  }
  return 'unknown';
}

bool _matches(List<String> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index += 1) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

String _statusFamily(int? statusCode) {
  if (statusCode == null || statusCode < 100 || statusCode > 599) {
    return 'none';
  }
  return '${statusCode ~/ 100}xx';
}

String _responseOutcome(int? statusCode) => switch (statusCode) {
  final status when status != null && status >= 400 && status < 500 =>
    'client_error',
  final status when status != null && status >= 500 && status < 600 =>
    'server_error',
  _ => 'success',
};

String _outcomeFor(DioException error) => switch (error.type) {
  DioExceptionType.cancel => 'cancelled',
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout => 'timeout',
  DioExceptionType.connectionError => 'unavailable',
  DioExceptionType.badResponse => switch (error.response?.statusCode) {
    final status when status != null && status >= 400 && status < 500 =>
      'client_error',
    final status when status != null && status >= 500 && status < 600 =>
      'server_error',
    _ => 'http_error',
  },
  _ => 'transport_error',
};

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
