import 'package:dio/dio.dart';

import '../auth/auth.dart';

enum RequestAuthPolicy { none, optional, required }

enum AuthRetryPolicy { safe, idempotencyProtected, never }

const _authPolicyKey = 'pakperk.auth_policy';
const _authRetryPolicyKey = 'pakperk.auth_retry_policy';
const _authRetriedKey = 'pakperk.auth_retried';
const _expectedAuthEpochKey = 'pakperk.expected_auth_epoch';
const _authorizationHeader = 'Authorization';

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
  Map<String, Object?>? headers,
  Duration? receiveTimeout,
  bool Function(int?)? validateStatus,
}) {
  final validEpoch = expectedAuthEpoch != null && expectedAuthEpoch >= 0;
  if ((auth == RequestAuthPolicy.required && !validEpoch) ||
      (auth != RequestAuthPolicy.required && expectedAuthEpoch != null)) {
    throw ArgumentError.value(
      expectedAuthEpoch,
      'expectedAuthEpoch',
      'Authenticated requests require a non-negative expected epoch.',
    );
  }
  return Options(
    headers: headers,
    receiveTimeout: receiveTimeout,
    validateStatus: validateStatus,
    extra: {
      _authPolicyKey: auth,
      _authRetryPolicyKey: retry,
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
  }) : _dio = dio,
       _apiOrigin = _Origin.fromUri(apiBaseUri),
       _tokenSource = tokenSource;

  final Dio _dio;
  final _Origin _apiOrigin;
  final AuthTokenSource _tokenSource;

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
        handler.next(options);
      } on AuthFailure catch (failure) {
        handler.reject(_authFailure(options, _safeAuthCode(failure)));
      } on Object {
        handler.reject(_authFailure(options, 'AUTH_UNAVAILABLE'));
      }
      return;
    }
    if (policy != RequestAuthPolicy.required) {
      // Optional public requests deliberately remain anonymous so a readable
      // feed can never wait for Keychain/Keystore or OIDC availability.
      options.headers.remove(_authorizationHeader);
      handler.next(options);
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
      handler.next(options);
    } on AuthFailure catch (failure) {
      handler.reject(_authFailure(options, _safeAuthCode(failure)));
    } on Object {
      handler.reject(_authFailure(options, 'AUTH_UNAVAILABLE'));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
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
      handler.reject(_authFailure(options, 'AUTH_EPOCH_REQUIRED'));
      return;
    }
    try {
      final token = await _tokenSource.refreshAfterUnauthorized(
        rejectedAccessToken: rejectedToken,
        expectedAuthEpoch: expectedAuthEpoch,
      );
      if (token == null || token.isEmpty) {
        handler.reject(_authFailure(options, 'UNAUTHENTICATED'));
        return;
      }
      final retried = options.copyWith(
        headers: {...options.headers, _authorizationHeader: 'Bearer $token'},
        extra: {...options.extra, _authRetriedKey: true},
      );
      handler.resolve(await _dio.fetch<Object?>(retried));
    } on AuthFailure catch (failure) {
      handler.reject(_authFailure(options, _safeAuthCode(failure)));
    } on DioException catch (retryError) {
      handler.next(retryError);
    } on Object {
      handler.reject(_authFailure(options, 'AUTH_UNAVAILABLE'));
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

final class AuthRequestFailure implements Exception {
  const AuthRequestFailure(this.code);

  final String code;

  bool get isOffline => code == 'AUTH_UNAVAILABLE';

  @override
  String toString() => 'AuthRequestFailure($code)';
}

DioException _authFailure(RequestOptions request, String code) => DioException(
  requestOptions: request,
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
