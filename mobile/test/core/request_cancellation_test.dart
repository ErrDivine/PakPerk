import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';

void main() {
  test(
    'cancelling a request reaches Dio and returns a cancellation error',
    () async {
      final adapter = _HangingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
        ..httpClientAdapter = adapter;
      final client = ApiClient(
        baseUrl: 'http://localhost:8080',
        sessionId: '00000000-0000-4000-8000-000000000099',
        dio: dio,
      );
      addTearDown(client.dispose);
      final cancellation = RequestCancellation();

      final request = client.getPaper(
        '17060376-2000-4000-8000-000000000001',
        cancellation: cancellation,
      );
      await adapter.started.future;
      cancellation.cancel('Widget disposed in test.');

      await expectLater(
        request,
        throwsA(
          isA<ApiException>()
              .having((error) => error.cancelled, 'cancelled', isTrue)
              .having((error) => error.isOffline, 'isOffline', isFalse),
        ),
      );
      await adapter.cancelObserved.future;
    },
  );
}

class _HangingAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> cancelObserved = Completer<void>();
  final Completer<ResponseBody> _response = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (!started.isCompleted) started.complete();
    cancelFuture?.then((_) {
      if (!cancelObserved.isCompleted) cancelObserved.complete();
    });
    return _response.future;
  }

  @override
  void close({bool force = false}) {}
}
