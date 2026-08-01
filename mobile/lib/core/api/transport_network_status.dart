import 'dart:async';

import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Process-wide view of whether the Pakperk transport is currently reachable.
///
/// The latest completed transport outcome wins. HTTP failures still prove the
/// service was reached, while cancellations and failures without a network or
/// HTTP classification leave the previous state unchanged.
final class TransportNetworkStatus {
  final StreamController<bool> _changes = StreamController<bool>.broadcast(
    sync: true,
  );
  bool _offline = false;
  bool _disposed = false;

  bool get isOffline => _offline;

  Stream<bool> get changes => _changes.stream;

  void markOnline() => _setOffline(false);

  void markOffline() => _setOffline(true);

  void observeApiException(ApiException error) {
    if (error.cancelled) return;
    // ApiException status codes can be synthesized locally (for example by
    // authentication or input validation). Only the Dio interceptor can prove
    // that an HTTP response was received, so repository-level exceptions may
    // move the state offline but never recover it to online.
    if (error.isOffline) markOffline();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _changes.close();
  }

  void _setOffline(bool value) {
    if (_disposed || _offline == value) return;
    _offline = value;
    _changes.add(value);
  }
}

/// Records the final outcome after authentication and safe-retry interceptors.
final class TransportNetworkStatusInterceptor extends Interceptor {
  TransportNetworkStatusInterceptor(this._status);

  final TransportNetworkStatus _status;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _status.markOnline();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type == DioExceptionType.cancel || CancelToken.isCancel(err)) {
      handler.next(err);
      return;
    }
    if (err.response != null) {
      _status.markOnline();
    } else if (switch (err.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => true,
      _ => false,
    }) {
      _status.markOffline();
    }
    handler.next(err);
  }
}
