import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'auth_interceptor.dart';

ApiException mapDioException(DioException error) {
  if (error.error case final AuthRequestFailure authFailure) {
    return ApiException(
      code: authFailure.code,
      message: switch (authFailure.code) {
        'UNAUTHENTICATED' || 'TOKEN_EXPIRED' => 'Sign in again to continue.',
        'AUTH_ORIGIN_REJECTED' =>
          'Pakperk refused to send credentials to an untrusted origin.',
        'AUTH_CANCELLED' => 'Sign in was cancelled.',
        _ => 'Account services are temporarily unavailable.',
      },
      retryable: authFailure.isOffline,
      statusCode: switch (authFailure.code) {
        'UNAUTHENTICATED' || 'TOKEN_EXPIRED' => 401,
        'AUTH_UNAVAILABLE' => 503,
        _ => null,
      },
      isOffline: authFailure.isOffline,
    );
  }
  if (error.type == DioExceptionType.cancel || CancelToken.isCancel(error)) {
    return const ApiException(
      code: 'REQUEST_CANCELLED',
      message:
          'The request was cancelled because its view is no longer active.',
    );
  }
  final statusCode = error.response?.statusCode;
  final responseData = error.response?.data;
  final root = responseData is Map
      ? Map<String, dynamic>.from(responseData)
      : const <String, dynamic>{};
  final nested = root['error'];
  final details = nested is Map ? Map<String, dynamic>.from(nested) : root;

  final isOffline = switch (error.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => true,
    _ => false,
  };
  final retryAfter = _retryAfter(
    _singleHeader(error.response?.headers, 'retry-after'),
  );
  final defaultRetryable =
      isOffline ||
      statusCode == 429 ||
      (statusCode != null && statusCode >= 500);
  return ApiException(
    code:
        _safeCode(details['code']) ??
        (isOffline ? 'NETWORK_UNAVAILABLE' : 'HTTP_ERROR'),
    message:
        _safeMessage(details['message']) ??
        (isOffline
            ? 'The Pakperk service is unreachable.'
            : 'The request could not be completed.'),
    retryable: switch (details['retryable']) {
      final bool value => value,
      _ => defaultRetryable,
    },
    statusCode: statusCode,
    isOffline: isOffline,
    requestId:
        _safeRequestId(details['request_id']) ??
        _safeRequestId(_singleHeader(error.response?.headers, 'x-request-id')),
    retryAfter: retryAfter,
  );
}

final _errorCode = RegExp(r'^[A-Z][A-Z0-9_]{0,63}$');
final _requestId = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String? _safeCode(Object? value) =>
    value is String && _errorCode.hasMatch(value) ? value : null;

String? _safeMessage(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 512 ||
      value.runes.any((rune) => rune < 0x20 && rune != 0x0a)) {
    return null;
  }
  return value;
}

String? _safeRequestId(Object? value) =>
    value is String && _requestId.hasMatch(value) ? value.toLowerCase() : null;

Duration? _retryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  if (seconds == null || seconds <= 0 || seconds > 30 * 24 * 60 * 60) {
    return null;
  }
  return Duration(seconds: seconds);
}

String? _singleHeader(Headers? headers, String name) {
  final values = headers?[name];
  return values?.length == 1 ? values!.single : null;
}
