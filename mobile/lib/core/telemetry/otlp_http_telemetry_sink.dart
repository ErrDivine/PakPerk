import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'telemetry.dart';

const _maximumExportBytes = 16 * 1024;
const _defaultMaximumInFlightExports = 2;
const _allowedEnvironments = {'development', 'staging', 'production'};
const _allowedErrorCategories = {
  'timeout',
  'format',
  'state',
  'argument',
  'unexpected',
};

/// Minimal OTLP/HTTP JSON log exporter for the closed mobile event boundary.
///
/// It has no persistent queue, cookies, authorization header, device ID,
/// account ID, or redirect following. At most one bounded request is attempted
/// for an event; exporter failures are allowed to be swallowed by
/// [emitTelemetry] and can never affect product behavior.
final class OtlpHttpTelemetrySink implements TelemetrySink {
  OtlpHttpTelemetrySink({
    required Uri endpoint,
    required String environment,
    OtlpHttpTransport? transport,
    DateTime Function()? clock,
    int maximumInFlightExports = _defaultMaximumInFlightExports,
  }) : _endpoint = _validateEndpoint(endpoint, environment),
       _environment = _validateEnvironment(environment),
       _transport = transport ?? DioOtlpHttpTransport(),
       _ownsTransport = transport == null,
       _clock = clock ?? DateTime.now,
       _maximumInFlightExports = _validateMaximumInFlight(
         maximumInFlightExports,
       );

  final Uri _endpoint;
  final String _environment;
  final OtlpHttpTransport _transport;
  final bool _ownsTransport;
  final DateTime Function() _clock;
  final int _maximumInFlightExports;
  int _inFlightExports = 0;

  @override
  Future<void> event(String name, Map<String, Object?> attributes) =>
      _export(name: name, attributes: attributes, severity: 'INFO');

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) {
    final category =
        error is TelemetryErrorCategory &&
            _allowedErrorCategories.contains(error.category)
        ? error.category
        : 'unexpected';
    return _export(
      name: 'mobile_error',
      attributes: {...context, 'error_category': category},
      severity: 'ERROR',
    );
  }

  Future<void> _export({
    required String name,
    required Map<String, Object?> attributes,
    required String severity,
  }) async {
    // Telemetry cannot queue behind product traffic or grow memory under an
    // outage. Saturated events are deliberately dropped.
    if (_inFlightExports >= _maximumInFlightExports) return;
    _inFlightExports += 1;
    try {
      final payload = <String, Object>{
        'resourceLogs': [
          {
            'resource': {
              'attributes': [
                _otlpAttribute('service.name', 'pakperk-mobile'),
                _otlpAttribute('deployment.environment.name', _environment),
              ],
            },
            'scopeLogs': [
              {
                'scope': {'name': 'app.pakperk.mobile'},
                'logRecords': [
                  {
                    'timeUnixNano':
                        '${_clock().toUtc().microsecondsSinceEpoch * 1000}',
                    'severityText': severity,
                    'body': {'stringValue': name},
                    'attributes': [
                      for (final entry in attributes.entries)
                        if (_otlpValue(entry.value) case final value?)
                          {'key': entry.key, 'value': value},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      };
      final body = jsonEncode(payload);
      if (utf8.encode(body).length > _maximumExportBytes) return;
      await _transport.postJson(_endpoint, body);
    } finally {
      _inFlightExports -= 1;
    }
  }

  void dispose() {
    if (_ownsTransport) _transport.close();
  }
}

abstract interface class OtlpHttpTransport {
  Future<void> postJson(Uri endpoint, String body);

  void close();
}

final class DioOtlpHttpTransport implements OtlpHttpTransport {
  DioOtlpHttpTransport({Dio? client})
    : _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 2),
              sendTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 2),
              followRedirects: false,
              maxRedirects: 0,
              responseType: ResponseType.stream,
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300,
            ),
          ),
      _ownsClient = client == null;

  final Dio _client;
  final bool _ownsClient;

  @override
  Future<void> postJson(Uri endpoint, String body) async {
    final cancelToken = CancelToken();
    final bytes = Uint8List.fromList(utf8.encode(body));
    final options = RequestOptions(
      path: endpoint.toString(),
      method: 'POST',
      headers: {
        Headers.contentTypeHeader: Headers.jsonContentType,
        Headers.acceptHeader: Headers.jsonContentType,
        Headers.contentLengthHeader: '${bytes.length}',
      },
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
      followRedirects: false,
      maxRedirects: 0,
      responseType: ResponseType.stream,
      cancelToken: cancelToken,
    );
    cancelToken.requestOptions = options;
    final response = await _client.httpClientAdapter.fetch(
      options,
      Stream<Uint8List>.value(bytes),
      cancelToken.whenCancel,
    );
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      final subscription = response.stream.listen((_) {});
      await subscription.cancel();
      throw DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: Response<ResponseBody>(
          data: response,
          requestOptions: options,
          statusCode: status,
        ),
      );
    }
    // OTLP acknowledgements have no product value. The raw adapter stream is
    // cancelled directly, with no Dio transformer/controller in between.
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }

  @override
  void close() {
    if (_ownsClient) _client.close(force: true);
  }
}

Map<String, Object> _otlpAttribute(String key, Object value) => {
  'key': key,
  'value': _otlpValue(value)!,
};

Map<String, Object>? _otlpValue(Object? value) => switch (value) {
  String value when value.length <= 64 => {'stringValue': value},
  bool value => {'boolValue': value},
  int value when value >= 0 && value <= 86_400_000 => {'intValue': '$value'},
  _ => null,
};

String _validateEnvironment(String environment) {
  if (!_allowedEnvironments.contains(environment)) {
    throw ArgumentError.value(environment, 'environment');
  }
  return environment;
}

Uri _validateEndpoint(Uri endpoint, String environment) {
  final loopback =
      endpoint.host == 'localhost' ||
      endpoint.host == '127.0.0.1' ||
      endpoint.host == '::1';
  final allowedScheme =
      endpoint.scheme == 'https' ||
      (environment == 'development' && endpoint.scheme == 'http' && loopback);
  if (!allowedScheme ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.path != '/v1/logs' ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw ArgumentError.value(endpoint, 'endpoint');
  }
  return endpoint;
}

int _validateMaximumInFlight(int value) {
  if (value < 1 || value > 8) {
    throw ArgumentError.value(value, 'maximumInFlightExports');
  }
  return value;
}
