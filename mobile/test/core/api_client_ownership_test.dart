import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';

void main() {
  test('disposing a client does not close an injected shared transport', () {
    final adapter = _TrackingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;
    final client = ApiClient(
      baseUrl: 'https://api.pakperk.app',
      sessionId: '00000000-0000-4000-8000-000000000001',
      dio: dio,
    );

    client.dispose();

    expect(adapter.closed, isFalse);
    dio.close(force: true);
    expect(adapter.closed, isTrue);
  });
}

final class _TrackingAdapter implements HttpClientAdapter {
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw UnimplementedError();

  @override
  void close({bool force = false}) => closed = true;
}
