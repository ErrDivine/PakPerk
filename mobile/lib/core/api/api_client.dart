import 'package:dio/dio.dart';

import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import 'api_exception.dart';
import 'request_cancellation.dart';

class ApiClient {
  ApiClient({required String baseUrl, required String sessionId, Dio? dio})
      : _sessionId = sessionId,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 10),
                headers: const {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                },
              ),
            );

  final Dio _dio;
  final String _sessionId;

  void dispose() => _dio.close(force: true);

  Future<void> ready({RequestCancellation? cancellation}) async {
    try {
      await _dio.get<void>(
        '/health/ready',
        cancelToken: cancellation?.dioToken,
      );
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<FeedPage> getFeed({
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/feed',
        queryParameters: {
          if (category != null && category.isNotEmpty) 'category': category,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
        cancelToken: cancellation?.dioToken,
      );
      return FeedPage.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<PaperSummary> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$paperId',
        cancelToken: cancellation?.dioToken,
      );
      final json = _jsonMap(response.data);
      final paper = json['paper'];
      return PaperSummary.fromJson(
        paper is Map ? Map<String, dynamic>.from(paper) : json,
      );
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<PaperProcessingState> prepare(
    String paperId, {
    bool retry = false,
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/$paperId/prepare',
        data: {'retry': retry},
        options: Options(headers: {'X-Session-Id': _sessionId}),
        cancelToken: cancellation?.dioToken,
      );
      return PaperProcessingState.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<PaperProcessingState> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$paperId/processing',
        cancelToken: cancellation?.dioToken,
      );
      return PaperProcessingState.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<PaperIntroduction> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$paperId/introduction',
        cancelToken: cancellation?.dioToken,
      );
      return PaperIntroduction.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<PaperConnections> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$paperId/connections',
        cancelToken: cancellation?.dioToken,
      );
      return PaperConnections.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  Future<ChatAnswer> sendChat({
    required String paperId,
    required String message,
    String? threadId,
    RequestCancellation? cancellation,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/$paperId/chat',
        data: {'thread_id': threadId, 'message': message},
        options: Options(
          headers: {'X-Session-Id': _sessionId},
          receiveTimeout: const Duration(seconds: 65),
        ),
        cancelToken: cancellation?.dioToken,
      );
      return ChatAnswer.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }
}

Map<String, dynamic> _jsonMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  throw const FormatException('Expected a JSON object from the API.');
}

ApiException _toApiException(DioException error) {
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
    DioExceptionType.sendTimeout =>
      true,
    _ => false,
  };

  return ApiException(
    code:
        (details['code'] ?? (isOffline ? 'NETWORK_UNAVAILABLE' : 'HTTP_ERROR'))
            .toString(),
    message: (details['message'] ??
            (isOffline
                ? 'The Pakperk service is unreachable.'
                : 'The request could not be completed.'))
        .toString(),
    retryable: details['retryable'] as bool? ?? isOffline,
    statusCode: statusCode,
    isOffline: isOffline,
  );
}
