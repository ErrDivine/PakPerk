import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_error_mapper.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';

void main() {
  test('maps the stable error envelope and bounded response metadata', () {
    final request = RequestOptions(path: '/v1/me');
    final mapped = mapDioException(
      DioException.badResponse(
        statusCode: 429,
        requestOptions: request,
        response: Response<Object?>(
          requestOptions: request,
          statusCode: 429,
          data: const {
            'error': {
              'code': 'RATE_LIMITED',
              'message': 'Wait before trying again.',
              'retryable': true,
              'request_id': '018f47a6-4b56-7f4c-8c7a-e2656e820001',
            },
          },
          headers: Headers.fromMap({
            'retry-after': ['17'],
          }),
        ),
      ),
    );

    expect(mapped.code, 'RATE_LIMITED');
    expect(mapped.retryable, isTrue);
    expect(mapped.retryAfter, const Duration(seconds: 17));
    expect(mapped.requestId, '018f47a6-4b56-7f4c-8c7a-e2656e820001');
  });

  test(
    'malformed proxy fields fall back without throwing or growing UI data',
    () {
      final request = RequestOptions(path: '/v1/me');
      final mapped = mapDioException(
        DioException.badResponse(
          statusCode: 503,
          requestOptions: request,
          response: Response<Object?>(
            requestOptions: request,
            statusCode: 503,
            data: {
              'error': {
                'code': '<html>',
                'message': List.filled(1000, 'x').join(),
                'retryable': 'yes',
                'request_id': 'not-a-request-id',
              },
            },
            headers: Headers.fromMap({
              'x-request-id': ['018f47a6-4b56-7f4c-8c7a-e2656e820002'],
            }),
          ),
        ),
      );

      expect(mapped.code, 'HTTP_ERROR');
      expect(mapped.message, 'The request could not be completed.');
      expect(mapped.retryable, isTrue);
      expect(mapped.requestId, '018f47a6-4b56-7f4c-8c7a-e2656e820002');
    },
  );

  test('invalid refresh is represented as an unauthenticated response', () {
    final request = RequestOptions(path: '/v1/me');
    final mapped = mapDioException(
      DioException(
        requestOptions: request,
        error: const AuthRequestFailure('TOKEN_EXPIRED'),
      ),
    );

    expect(mapped.code, 'TOKEN_EXPIRED');
    expect(mapped.statusCode, 401);
    expect(mapped.isOffline, isFalse);
  });
}
