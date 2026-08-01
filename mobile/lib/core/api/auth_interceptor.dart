import 'package:dio/dio.dart';

import '../auth/auth.dart';
import 'http_telemetry_interceptor.dart';

enum RequestAuthPolicy { none, optional, required, recent }

enum AuthRetryPolicy { safe, idempotencyProtected, never }

const _authPolicyKey = 'pakperk.auth_policy';
const _authRetryPolicyKey = 'pakperk.auth_retry_policy';
const _authRetriedKey = 'pakperk.auth_retried';
const _expectedAuthEpochKey = 'pakperk.expected_auth_epoch';
const _strictRawResponseStreamKey = 'pakperk.strict_raw_response_stream';
const _authorizationHeader = 'Authorization';
final _bearerToken = RegExp(r'^[A-Za-z0-9\-._~+/]+=*$');

typedef AccountDeletionPendingHandler =
    Future<void> Function(int expectedAuthEpoch, String? requestId);

/// Builds request metadata consumed only by [AuthInterceptor].
///
/// Public calls use [RequestAuthPolicy.none] or `optional`; neither waits for
/// secure storage or token refresh. Account-owned calls use `required` and
/// must bind the auth epoch that created the operation and declare whether
/// replay after one 401 is safe.
Options pakPerkRequestOptions({
  required RequestAuthPolicy auth,
  AuthRetryPolicy retry = AuthRetryPolicy.never,
  int? expectedAuthEpoch,
  String? recentBearer,
  Map<String, Object?>? headers,
  Duration? receiveTimeout,
  ResponseType? responseType,
  bool strictRawResponseStream = false,
  bool Function(int?)? validateStatus,
}) {
  final validEpoch = expectedAuthEpoch != null && expectedAuthEpoch >= 0;
  final authenticated =
      auth == RequestAuthPolicy.required || auth == RequestAuthPolicy.recent;
  final validRecentBearer =
      recentBearer != null &&
      recentBearer.isNotEmpty &&
      recentBearer.length <= 64 * 1024 &&
      _bearerToken.hasMatch(recentBearer);
  if ((authenticated && !validEpoch) ||
      (!authenticated && expectedAuthEpoch != null) ||
      (auth == RequestAuthPolicy.recent && !validRecentBearer) ||
      (auth != RequestAuthPolicy.recent && recentBearer != null) ||
      (strictRawResponseStream &&
          (authenticated == false || responseType != ResponseType.stream)) ||
      headers?.keys.any(
            (key) => key.toLowerCase() == _authorizationHeader.toLowerCase(),
          ) ==
          true) {
    throw ArgumentError.value(
      expectedAuthEpoch,
      'expectedAuthEpoch',
      'Authenticated requests require a non-negative epoch; recent-auth '
          'requests also require a bounded dedicated bearer.',
    );
  }
  return Options(
    headers: {
      ...?headers,
      if (recentBearer != null) _authorizationHeader: 'Bearer $recentBearer',
    },
    receiveTimeout: receiveTimeout,
    responseType: responseType,
    validateStatus: validateStatus,
    extra: {
      _authPolicyKey: auth,
      _authRetryPolicyKey: retry,
      if (strictRawResponseStream) _strictRawResponseStreamKey: true,
      if (expectedAuthEpoch != null) _expectedAuthEpochKey: expectedAuthEpoch,
    },
  );
}

/// Adds a bearer only to the exact configured Pakperk origin and performs at
/// most one policy-authorized replay after a 401 challenge.
final class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required Dio dio,
    required Uri apiBaseUri,
    required AuthTokenSource tokenSource,
    AccountDeletionPendingHandler? onAccountDeletionPending,
  }) : _dio = dio,
       _apiOrigin = _Origin.fromUri(apiBaseUri),
       _tokenSource = tokenSource,
       _onAccountDeletionPending = onAccountDeletionPending;

  final Dio _dio;
  final _Origin _apiOrigin;
  final AuthTokenSource _tokenSource;
  final AccountDeletionPendingHandler? _onAccountDeletionPending;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final policy = _authPolicy(options);
    if (options.extra[_authRetriedKey] == true) {
      if (policy != RequestAuthPolicy.required || !_isApiRequest(options)) {
        handler.reject(_authFailure(options, 'AUTH_ORIGIN_REJECTED'));
        return;
      }
      final expectedAuthEpoch = _expectedAuthEpoch(options);
      if (expectedAuthEpoch == null) {
        handler.reject(_authFailure(options, 'AUTH_EPOCH_REQUIRED'));
        return;
      }
      try {
        final token = await _tokenSource.accessTokenForRequest(
          expectedAuthEpoch: expectedAuthEpoch,
        );
        if (token == null || token.isEmpty) {
          handler.reject(_authFailure(options, 'UNAUTHENTICATED'));
          return;
        }
        options.headers[_authorizationHeader] = 'Bearer $token';
        await _dispatchOrContinue(options, handler);
      } on AuthFailure catch (failure) {
        handler.reject(_authFailure(options, _safeAuthCode(failure)));
      } on Object {
        handler.reject(_authFailure(options, 'AUTH_UNAVAILABLE'));
      }
      return;
    }
    if (policy == RequestAuthPolicy.recent) {
      final expectedAuthEpoch = _expectedAuthEpoch(options);
      if (!_isApiRequest(options) ||
          expectedAuthEpoch == null ||
          !_tokenSource.isCurrentEpoch(expectedAuthEpoch) ||
          _bearerValue(options.headers[_authorizationHeader]) == null) {
        handler.reject(
          _authFailure(
            options,
            expectedAuthEpoch != null &&
                    !_tokenSource.isCurrentEpoch(expectedAuthEpoch)
                ? 'AUTH_SUPERSEDED'
                : 'AUTH_ORIGIN_REJECTED',
          ),
        );
        return;
      }
      await _dispatchOrContinue(options, handler);
      return;
    }
    if (policy != RequestAuthPolicy.required) {
      // Optional public requests deliberately remain anonymous so a readable
      // feed can never wait for Keychain/Keystore or OIDC availability.
      options.headers.remove(_authorizationHeader);
      await _dispatchOrContinue(options, handler);
      return;
    }
    if (!_isApiRequest(options)) {
      handler.reject(_authFailure(options, 'AUTH_ORIGIN_REJECTED'));
      return;
    }
    final expectedAuthEpoch = _expectedAuthEpoch(options);
    if (expectedAuthEpoch == null) {
      handler.reject(_authFailure(options, 'AUTH_EPOCH_REQUIRED'));
      return;
    }
    try {
      final token = await _tokenSource.accessTokenForRequest(
        expectedAuthEpoch: expectedAuthEpoch,
      );
      if (token == null || token.isEmpty) {
        handler.reject(_authFailure(options, 'UNAUTHENTICATED'));
        return;
      }
      options.headers[_authorizationHeader] = 'Bearer $token';
      await _dispatchOrContinue(options, handler);
    } on AuthFailure catch (failure) {
      handler.reject(_authFailure(options, _safeAuthCode(failure)));
    } on Object {
      handler.reject(_authFailure(options, 'AUTH_UNAVAILABLE'));
    }
  }

  /// Sends strict bodyless authenticated calls directly through Dio's adapter.
  ///
  /// Dio 5's public `ResponseType.stream` path eagerly subscribes an
  /// unbounded intermediate controller and does not propagate consumer
  /// cancellation upstream. These deletion-only requests therefore bypass
  /// that wrapper after authentication has populated the final headers.
  Future<void> _dispatchOrContinue(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_strictRawResponseStreamKey] != true) {
      handler.next(options);
      return;
    }
    if (options.responseType != ResponseType.stream || options.data != null) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: const FormatException(
            'Strict raw requests must be bodyless response streams.',
          ),
        ),
        true,
      );
      return;
    }
    startPakPerkHttpTelemetryTrace(options);
    try {
      final responseBody = await _dio.httpClientAdapter.fetch(
        options,
        null,
        options.cancelToken?.whenCancel,
      );
      final response = Response<ResponseBody>(
        data: responseBody,
        requestOptions: options,
        headers: Headers.fromMap(
          responseBody.headers,
          preserveHeaderCase: options.preserveHeaderCase,
        ),
        redirects: responseBody.redirects ?? const [],
        isRedirect: responseBody.isRedirect,
        statusCode: responseBody.statusCode,
        statusMessage: responseBody.statusMessage,
        extra: responseBody.extra,
      );
      if (options.validateStatus(responseBody.statusCode)) {
        handler.resolve(response, true);
      } else {
        handler.reject(
          DioException.badResponse(
            statusCode: responseBody.statusCode,
            requestOptions: options,
            response: response,
          ),
          true,
        );
      }
    } on DioException catch (error) {
      handler.reject(error, true);
    } on Object catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stackTrace,
        ),
        true,
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final pendingHandler = _onAccountDeletionPending;
    if (_accountDeletionPending(err) && pendingHandler != null) {
      final expectedAuthEpoch = _expectedAuthEpoch(options);
      if (expectedAuthEpoch != null) {
        try {
          await pendingHandler(
            expectedAuthEpoch,
            _safeResponseRequestId(err.response?.data),
          );
        } on Object {
          // The handler is itself fail-closed and records local failures. The
          // stable server error remains the result of this HTTP request.
        }
      }
      handler.next(err);
      return;
    }
    if (err.response?.statusCode != 401 ||
        _authPolicy(options) != RequestAuthPolicy.required ||
        options.extra[_authRetriedKey] == true ||
        !_isReplayAllowed(options) ||
        !_isApiRequest(options)) {
      handler.next(err);
      return;
    }
    final authorization = options.headers[_authorizationHeader];
    final rejectedToken = _bearerValue(authorization);
    if (rejectedToken == null) {
      handler.next(err);
      return;
    }
    final expectedAuthEpoch = _expectedAuthEpoch(options);
    if (expectedAuthEpoch == null) {
      handler.reject(
        _authFailure(options, 'AUTH_EPOCH_REQUIRED', response: err.response),
        true,
      );
      return;
    }
    try {
      final token = await _tokenSource.refreshAfterUnauthorized(
        rejectedAccessToken: rejectedToken,
        expectedAuthEpoch: expectedAuthEpoch,
      );
      if (token == null || token.isEmpty) {
        handler.reject(
          _authFailure(options, 'UNAUTHENTICATED', response: err.response),
          true,
        );
        return;
      }
      final retried = options.copyWith(
        headers: {...options.headers, _authorizationHeader: 'Bearer $token'},
        extra: {...options.extra, _authRetriedKey: true},
      );
      // Preserve the original plain/bytes/JSON response mode on auth replay.
      handler.resolve(await _dio.fetch<dynamic>(retried));
    } on AuthFailure catch (failure) {
      handler.reject(
        _authFailure(options, _safeAuthCode(failure), response: err.response),
        true,
      );
    } on DioException catch (retryError) {
      handler.next(retryError);
    } on Object {
      handler.reject(
        _authFailure(options, 'AUTH_UNAVAILABLE', response: err.response),
        true,
      );
    }
  }

  RequestAuthPolicy _authPolicy(RequestOptions options) =>
      options.extra[_authPolicyKey] as RequestAuthPolicy? ??
      RequestAuthPolicy.none;

  int? _expectedAuthEpoch(RequestOptions options) {
    final value = options.extra[_expectedAuthEpochKey];
    return value is int && value >= 0 ? value : null;
  }

  bool _isApiRequest(RequestOptions options) =>
      _Origin.fromUri(options.uri) == _apiOrigin;

  bool _isReplayAllowed(RequestOptions options) {
    final policy =
        options.extra[_authRetryPolicyKey] as AuthRetryPolicy? ??
        AuthRetryPolicy.never;
    return switch (policy) {
      AuthRetryPolicy.safe => const {
        'GET',
        'HEAD',
        'OPTIONS',
      }.contains(options.method.toUpperCase()),
      AuthRetryPolicy.idempotencyProtected =>
        _hasBoundedHeader(options, 'Idempotency-Key') ||
            _hasBoundedHeader(options, 'If-Match'),
      AuthRetryPolicy.never => false,
    };
  }
}

bool _accountDeletionPending(DioException error) {
  final data = error.response?.data;
  if (data is! Map) return false;
  final root = Map<String, Object?>.from(data);
  final nested = root['error'];
  final details = nested is Map ? Map<String, Object?>.from(nested) : root;
  return details['code'] == 'ACCOUNT_DELETION_PENDING';
}

String? _safeResponseRequestId(Object? data) {
  if (data is! Map) return null;
  final root = Map<String, Object?>.from(data);
  final nested = root['error'];
  final details = nested is Map ? Map<String, Object?>.from(nested) : root;
  final value = details['request_id'];
  return value is String &&
          RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
            r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
          ).hasMatch(value)
      ? value.toLowerCase()
      : null;
}

final class AuthRequestFailure implements Exception {
  const AuthRequestFailure(this.code);

  final String code;

  bool get isOffline => code == 'AUTH_UNAVAILABLE';

  @override
  String toString() => 'AuthRequestFailure($code)';
}

DioException _authFailure(
  RequestOptions request,
  String code, {
  Response<dynamic>? response,
}) => DioException(
  requestOptions: request,
  response: response,
  type: DioExceptionType.unknown,
  error: AuthRequestFailure(code),
);

String _safeAuthCode(AuthFailure failure) => switch (failure.kind) {
  AuthFailureKind.invalidGrant => 'TOKEN_EXPIRED',
  AuthFailureKind.network => 'AUTH_UNAVAILABLE',
  AuthFailureKind.cancelled => 'AUTH_CANCELLED',
  AuthFailureKind.superseded => 'AUTH_SUPERSEDED',
  _ => 'AUTH_UNAVAILABLE',
};

String? _bearerValue(Object? authorization) {
  if (authorization is! String || authorization.length > 64 * 1024) {
    return null;
  }
  const prefix = 'Bearer ';
  if (!authorization.startsWith(prefix)) return null;
  final value = authorization.substring(prefix.length);
  return value.isEmpty ? null : value;
}

bool _hasBoundedHeader(RequestOptions options, String name) {
  final value = options.headers[name];
  return value is String && value.isNotEmpty && value.length <= 512;
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
