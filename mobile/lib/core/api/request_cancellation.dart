import 'package:dio/dio.dart';

/// Owns the Dio cancellation token for one UI request lifecycle.
///
/// Controllers cancel this object when their screen is abandoned or disposed,
/// so the underlying socket/request work is released instead of merely
/// ignoring a late response.
class RequestCancellation {
  final CancelToken _token = CancelToken();

  bool get isCancelled => _token.isCancelled;

  CancelToken get dioToken => _token;

  void cancel([String reason = 'The requesting view was abandoned.']) {
    if (!_token.isCancelled) _token.cancel(reason);
  }
}
