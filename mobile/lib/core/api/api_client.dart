import 'package:dio/dio.dart';

import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import 'api_exception.dart';
import 'feed_http_result.dart';
import 'request_cancellation.dart';

class ApiClient {
  ApiClient({required String baseUrl, required String sessionId, Dio? dio})
    : _sessionId = sessionId,
      _dio =
          dio ??
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
    final result = await getFeedConditional(
      category: category,
      cursor: cursor,
      limit: limit,
      cancellation: cancellation,
    );
    final page = result.page;
    if (page == null) {
      throw const ApiException(
        code: 'UNEXPECTED_NOT_MODIFIED',
        message: 'The feed was not modified but no validator was supplied.',
        retryable: true,
        statusCode: 502,
      );
    }
    return page;
  }

  /// Fetches a feed page and exposes HTTP validator semantics to the
  /// repository. [ifNoneMatch] is used only for a first page; cursor pages must
  /// carry bodies so their entries can be merged transactionally.
  Future<FeedHttpResult> getFeedConditional({
    String? category,
    String? cursor,
    int limit = 20,
    String? ifNoneMatch,
    RequestCancellation? cancellation,
  }) async {
    final validator = cursor == null ? _safeEtag(ifNoneMatch) : null;
    try {
      final response = await _dio.get<Object?>(
        '/v1/feed',
        queryParameters: {
          if (category != null && category.isNotEmpty) 'category': category,
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
        options: Options(
          headers: {if (validator != null) 'If-None-Match': validator},
          validateStatus: (status) =>
              status == 304 ||
              (status != null && status >= 200 && status < 300),
        ),
        cancelToken: cancellation?.dioToken,
      );
      final responseEtags = response.headers['etag'];
      final responseEtag = switch (responseEtags) {
        [final only] => _safeEtag(only),
        _ => null,
      };
      if (response.statusCode == 304) {
        return FeedHttpResult.notModified(etag: responseEtag ?? validator);
      }
      return FeedHttpResult.modified(
        page: FeedPage.fromJson(_jsonMap(response.data)),
        etag: responseEtag,
      );
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

  Future<PaperSummary> getPaperByArxiv(
    String arxivId, {
    RequestCancellation? cancellation,
  }) async {
    final normalized = ArxivIdentifier.tryParse(arxivId);
    if (normalized == null) {
      throw const ApiException(
        code: 'INVALID_ARXIV_ID',
        message: 'The arXiv identifier is malformed.',
        statusCode: 400,
      );
    }
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/by-arxiv/${normalized.encodedRouteSegment}',
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
      return PaperProcessingState.fromJson(
        _generationScopedJson(response.data),
      );
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
      return PaperProcessingState.fromJson(
        _generationScopedJson(response.data),
      );
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
      return PaperIntroduction.fromJson(_generationScopedJson(response.data));
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
      return PaperConnections.fromJson(_generationScopedJson(response.data));
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
      return ChatAnswer.fromJson(_generationScopedJson(response.data));
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }
}

String? _safeEtag(String? value) {
  if (value == null || value.isEmpty || value.length > 512) return null;
  return RegExp(r'^(?:W/)?"[!#-~]*"$').hasMatch(value) ? value : null;
}

Map<String, dynamic> _jsonMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  throw const FormatException('Expected a JSON object from the API.');
}

Map<String, dynamic> _generationScopedJson(Object? data) {
  final json = _jsonMap(data);
  final generation = json['generation'];
  if (generation is! int || generation <= 0) {
    throw const ApiException(
      code: 'INVALID_API_RESPONSE',
      message: 'The service omitted a valid paper processing generation.',
      retryable: true,
      statusCode: 502,
    );
  }
  return json;
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
    DioExceptionType.sendTimeout => true,
    _ => false,
  };

  return ApiException(
    code:
        (details['code'] ?? (isOffline ? 'NETWORK_UNAVAILABLE' : 'HTTP_ERROR'))
            .toString(),
    message:
        (details['message'] ??
                (isOffline
                    ? 'The Pakperk service is unreachable.'
                    : 'The request could not be completed.'))
            .toString(),
    retryable: details['retryable'] as bool? ?? isOffline,
    statusCode: statusCode,
    isOffline: isOffline,
  );
}
