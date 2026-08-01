import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'account_deletion_models.dart';

abstract interface class AccountDeletionRemoteDataSource {
  Future<AccountDeletionVerification> verifyCurrentSession({
    required int expectedAuthEpoch,
  });

  Future<AccountDeletionVerification> verifyRecentSession({
    required String recentBearer,
    required int expectedAuthEpoch,
  });

  Future<AccountDeletionOperation> deleteCurrentAccount({
    required String recentBearer,
    required int expectedAuthEpoch,
  });
}

/// Strict, body-free account deletion HTTP adapter.
///
/// The server keys replay by verified issuer+subject identity. The mobile app
/// intentionally sends neither a client idempotency key nor a request body.
final class AccountDeletionApi implements AccountDeletionRemoteDataSource {
  AccountDeletionApi(
    this._dio, {
    Duration responseDeadline = const Duration(seconds: 2),
  }) : _responseDeadline = _validateResponseDeadline(responseDeadline);

  final Dio _dio;
  final Duration _responseDeadline;

  @override
  Future<AccountDeletionVerification> verifyCurrentSession({
    required int expectedAuthEpoch,
  }) => _verifySession(
    options: pakPerkRequestOptions(
      auth: RequestAuthPolicy.required,
      retry: AuthRetryPolicy.safe,
      expectedAuthEpoch: expectedAuthEpoch,
      receiveTimeout: _responseDeadline,
      responseType: ResponseType.stream,
      strictRawResponseStream: true,
      validateStatus: (status) => status == 200,
    ),
  );

  @override
  Future<AccountDeletionVerification> verifyRecentSession({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) => _verifySession(
    options: pakPerkRequestOptions(
      auth: RequestAuthPolicy.recent,
      expectedAuthEpoch: expectedAuthEpoch,
      recentBearer: recentBearer,
      receiveTimeout: _responseDeadline,
      responseType: ResponseType.stream,
      strictRawResponseStream: true,
      validateStatus: (status) => status == 200,
    ),
  );

  Future<AccountDeletionVerification> _verifySession({
    required Options options,
  }) async {
    final cancelToken = CancelToken();
    try {
      final response = await _dio.get<ResponseBody>(
        '/v1/me/deletion-verification',
        options: options,
        cancelToken: cancelToken,
      );
      final root = await _readBoundedJson(
        response,
        cancelToken: cancelToken,
        deadline: _responseDeadline,
      );
      _requirePrivateNoStore(response);
      if (root is! Map || root.length != 1 || !root.containsKey('account')) {
        throw const FormatException(
          'Expected account deletion verification envelope.',
        );
      }
      final account = root['account'];
      if (account is! Map) {
        throw const FormatException(
          'Expected account deletion verification payload.',
        );
      }
      return AccountDeletionVerification.fromJson(
        Map<String, dynamic>.from(account),
      );
    } on DioException catch (error) {
      throw await _mapStreamingDioException(
        error,
        cancelToken: cancelToken,
        deadline: _responseDeadline,
      );
    } on FormatException {
      throw _invalidResponse;
    } on ArgumentError {
      rethrow;
    } on Object {
      throw _invalidResponse;
    }
  }

  @override
  Future<AccountDeletionOperation> deleteCurrentAccount({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) async {
    final cancelToken = CancelToken();
    try {
      final response = await _dio.delete<ResponseBody>(
        '/v1/me',
        cancelToken: cancelToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.recent,
          retry: AuthRetryPolicy.never,
          expectedAuthEpoch: expectedAuthEpoch,
          recentBearer: recentBearer,
          receiveTimeout: _responseDeadline,
          responseType: ResponseType.stream,
          strictRawResponseStream: true,
          validateStatus: (status) => status == 202,
        ),
      );
      final root = await _readBoundedJson(
        response,
        cancelToken: cancelToken,
        deadline: _responseDeadline,
      );
      _requirePrivateNoStore(response);
      if (root is! Map || root.length != 1 || !root.containsKey('deletion')) {
        throw const FormatException('Expected account deletion envelope.');
      }
      final operation = root['deletion'];
      if (operation is! Map) {
        throw const FormatException('Expected account deletion payload.');
      }
      return AccountDeletionOperation.fromJson(
        Map<String, dynamic>.from(operation),
      );
    } on DioException catch (error) {
      throw await _mapStreamingDioException(
        error,
        cancelToken: cancelToken,
        deadline: _responseDeadline,
        enforceExactDeleteErrors: true,
      );
    } on FormatException {
      throw _invalidResponse;
    } on ArgumentError {
      rethrow;
    } on Object {
      throw _invalidResponse;
    }
  }
}

const _maximumResponseBytes = 16 * 1024;

Future<Object?> _readBoundedJson(
  Response<ResponseBody> response, {
  required CancelToken cancelToken,
  required Duration deadline,
}) async {
  final body = response.data;
  if (body == null) {
    throw const FormatException('Expected a response body.');
  }
  final bytes = BytesBuilder(copy: false);
  final iterator = StreamIterator<Uint8List>(
    _withReceiveTimeout(body.stream, response.requestOptions),
  );
  final deadlineReached = Completer<void>();
  var deadlineExpired = false;
  final deadlineTimer = Timer(deadline, () {
    deadlineExpired = true;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('account deletion response deadline exceeded');
    }
    deadlineReached.complete();
  });
  var streamComplete = false;
  try {
    final contentTypes = response.headers[Headers.contentTypeHeader];
    final mediaType = contentTypes?.length == 1
        ? contentTypes!.single.split(';').first.trim().toLowerCase()
        : null;
    if (mediaType != Headers.jsonContentType) {
      throw const FormatException('Expected an application/json response.');
    }
    final declaredLengths = response.headers[Headers.contentLengthHeader];
    if (declaredLengths != null) {
      if (declaredLengths.length != 1) {
        throw const FormatException(
          'Ambiguous account deletion response size.',
        );
      }
      final rawDeclaredLength = declaredLengths.single;
      final declaredLength = int.tryParse(rawDeclaredLength.trim());
      if (declaredLength == null ||
          declaredLength < 0 ||
          declaredLength > _maximumResponseBytes) {
        throw const FormatException('Invalid account deletion response size.');
      }
    }
    while (await Future.any<bool>([
      iterator.moveNext(),
      deadlineReached.future.then<bool>((_) {
        throw DioException.receiveTimeout(
          timeout: deadline,
          requestOptions: response.requestOptions,
        );
      }),
    ])) {
      final chunk = iterator.current;
      if (bytes.length + chunk.length > _maximumResponseBytes) {
        throw const FormatException('Account deletion response is too large.');
      }
      bytes.add(chunk);
    }
    if (deadlineExpired) {
      throw DioException.receiveTimeout(
        timeout: deadline,
        requestOptions: response.requestOptions,
      );
    }
    streamComplete = true;
    final text = utf8.decode(bytes.takeBytes(), allowMalformed: false);
    return jsonDecode(text);
  } finally {
    deadlineTimer.cancel();
    if (!streamComplete && !cancelToken.isCancelled) {
      cancelToken.cancel('bounded account deletion response rejected');
      // The raw adapter observes CancelToken asynchronously. Let that abort
      // run before returning control, then cancel the direct subscription too.
      await Future<void>.delayed(Duration.zero);
    }
    await iterator.cancel();
  }
}

Stream<Uint8List> _withReceiveTimeout(
  Stream<Uint8List> stream,
  RequestOptions options,
) {
  final timeout = options.receiveTimeout;
  if (timeout == null || timeout <= Duration.zero) return stream;
  return stream.timeout(
    timeout,
    onTimeout: (sink) {
      sink
        ..addError(
          DioException.receiveTimeout(
            timeout: timeout,
            requestOptions: options,
          ),
        )
        ..close();
    },
  );
}

Future<ApiException> _mapStreamingDioException(
  DioException error, {
  required CancelToken cancelToken,
  required Duration deadline,
  bool enforceExactDeleteErrors = false,
}) async {
  final response = error.response;
  final body = response?.data;
  if (response == null || body is! ResponseBody) {
    return mapDioException(error);
  }
  try {
    final decoded = await _readBoundedJson(
      Response<ResponseBody>(
        data: body,
        requestOptions: response.requestOptions,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        extra: response.extra,
        headers: response.headers,
      ),
      cancelToken: cancelToken,
      deadline: deadline,
    );
    final decodedResponse = Response<Object?>(
      data: decoded,
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
      headers: response.headers,
    );
    final mapped = mapDioException(error.copyWith(response: decodedResponse));
    if (mapped.code == _accountDeletionUnavailableCode &&
        !_isExactPostCommitUnavailable(response, decoded)) {
      return mapDioException(error.copyWith(response: _withoutBody(response)));
    }
    if (enforceExactDeleteErrors &&
        _knownPreCommitDeleteCode(mapped.code) &&
        !_isExactPreCommitDeleteRejection(response, decoded)) {
      return mapDioException(error.copyWith(response: _withoutBody(response)));
    }
    return mapped;
  } on Object {
    // Invalid error payloads cannot manufacture a trusted service code. The
    // status and transport category still map through the generic boundary.
    return mapDioException(error.copyWith(response: _withoutBody(response)));
  }
}

Duration _validateResponseDeadline(Duration value) {
  if (value <= Duration.zero || value > const Duration(seconds: 10)) {
    throw ArgumentError.value(value, 'responseDeadline');
  }
  return value;
}

Response<Object?> _withoutBody(Response<dynamic> response) => Response<Object?>(
  requestOptions: response.requestOptions,
  statusCode: response.statusCode,
  statusMessage: response.statusMessage,
  isRedirect: response.isRedirect,
  redirects: response.redirects,
  extra: response.extra,
  headers: response.headers,
);

void _requirePrivateNoStore(Response<dynamic> response) {
  if (!_hasPrivateNoStore(response)) {
    throw const FormatException('Missing private no-store policy.');
  }
}

bool _hasPrivateNoStore(Response<dynamic> response) {
  final values = response.headers['cache-control'];
  if (values == null) return false;
  final directives = values
      .expand((value) => value.split(','))
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .toSet();
  return directives.length == 2 &&
      directives.contains('private') &&
      directives.contains('no-store');
}

const _accountDeletionUnavailableCode = 'ACCOUNT_DELETION_UNAVAILABLE';
const _accountDeletionUnavailableMessage =
    'Your account is disabled, but durable deletion processing is temporarily '
    'unavailable. Cleanup will continue automatically.';
final _strictRequestId = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

bool _isExactPostCommitUnavailable(
  Response<dynamic> response,
  Object? payload,
) {
  final retryAfter = response.headers['retry-after'];
  final error = _exactErrorPayload(payload);
  if (response.statusCode != 503 ||
      retryAfter?.length != 1 ||
      retryAfter!.single != '30' ||
      !_hasPrivateNoStore(response) ||
      error == null) {
    return false;
  }
  return error['code'] == _accountDeletionUnavailableCode &&
      error['message'] == _accountDeletionUnavailableMessage &&
      error['retryable'] == true &&
      _strictRequestId.hasMatch(error['request_id']! as String);
}

bool _knownPreCommitDeleteCode(String code) => const {
  'INVALID_REQUEST',
  'UNAUTHENTICATED',
  'TOKEN_EXPIRED',
  'REAUTHENTICATION_REQUIRED',
  'FEATURE_DISABLED',
  'ROUTE_NOT_FOUND',
  'METHOD_NOT_ALLOWED',
  'REQUEST_BODY_TOO_LARGE',
  'RATE_LIMITED',
  'AUTHENTICATION_UNAVAILABLE',
}.contains(code);

bool _isExactPreCommitDeleteRejection(
  Response<dynamic> response,
  Object? payload,
) {
  final error = _exactErrorPayload(payload);
  if (error == null || !_hasPrivateNoStore(response)) return false;
  final code = error['code']! as String;
  final retryable = error['retryable']! as bool;
  final tupleIsPreCommit = switch ((response.statusCode, code, retryable)) {
    (400, 'INVALID_REQUEST', false) ||
    (401, 'UNAUTHENTICATED', false) ||
    (401, 'TOKEN_EXPIRED', false) ||
    (401, 'REAUTHENTICATION_REQUIRED', false) ||
    (404, 'FEATURE_DISABLED', false) ||
    (404, 'ROUTE_NOT_FOUND', false) ||
    (405, 'METHOD_NOT_ALLOWED', false) ||
    (413, 'REQUEST_BODY_TOO_LARGE', false) ||
    (429, 'RATE_LIMITED', true) ||
    (503, 'AUTHENTICATION_UNAVAILABLE', true) => true,
    _ => false,
  };
  if (!tupleIsPreCommit) return false;

  final retryAfter = response.headers['retry-after'];
  if (response.statusCode == 429 || response.statusCode == 503) {
    if (retryAfter?.length != 1) return false;
    final seconds = int.tryParse(retryAfter!.single);
    if (seconds == null || seconds <= 0 || seconds > 30 * 24 * 60 * 60) {
      return false;
    }
  } else if (retryAfter != null) {
    return false;
  }
  if (response.statusCode == 401) {
    final challenge = response.headers['www-authenticate'];
    if (challenge?.length != 1 || challenge!.single != 'Bearer') return false;
  }
  return true;
}

Map<Object?, Object?>? _exactErrorPayload(Object? payload) {
  if (payload is! Map || payload.length != 1 || !payload.containsKey('error')) {
    return null;
  }
  final error = payload['error'];
  if (error is! Map ||
      error.length != 4 ||
      !error.containsKey('code') ||
      !error.containsKey('message') ||
      !error.containsKey('retryable') ||
      !error.containsKey('request_id') ||
      error['code'] is! String ||
      error['message'] is! String ||
      (error['message']! as String).isEmpty ||
      (error['message']! as String).length > 512 ||
      error['retryable'] is! bool ||
      error['request_id'] is! String ||
      !_strictRequestId.hasMatch(error['request_id']! as String)) {
    return null;
  }
  return error;
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The account deletion service returned an invalid response.',
  retryable: false,
  statusCode: 502,
);
