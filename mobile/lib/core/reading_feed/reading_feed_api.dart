import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import 'reading_feed_models.dart';

abstract interface class ReadingFeedRemoteDataSource {
  Future<ReadingFeedPage> page({
    required int expectedAuthEpoch,
    ReadingFeedRecommendationMode? recommendationMode,
    String? briefId,
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  });
}

final class ReadingFeedApi implements ReadingFeedRemoteDataSource {
  const ReadingFeedApi(this._dio);

  final Dio _dio;

  @override
  Future<ReadingFeedPage> page({
    required int expectedAuthEpoch,
    ReadingFeedRecommendationMode? recommendationMode,
    String? briefId,
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) async {
    if (expectedAuthEpoch < 0) {
      throw ArgumentError.value(
        expectedAuthEpoch,
        'expectedAuthEpoch',
        'Must not be negative.',
      );
    }
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 50.');
    }
    if (category != null && !_category.hasMatch(category)) {
      throw ArgumentError.value(category, 'category', 'Invalid category.');
    }
    if (cursor != null && (cursor.isEmpty || cursor.length > 512)) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid cursor.');
    }
    if (briefId != null && !_uuid.hasMatch(briefId)) {
      throw ArgumentError.value(briefId, 'briefId', 'Invalid brief ID.');
    }
    try {
      final response = await _dio.get<Object?>(
        '/v1/me/reading-feed',
        queryParameters: {
          'limit': limit,
          if (recommendationMode != null)
            'recommendation_mode': recommendationMode.wireValue,
          if (category != null) 'category': category,
          if (cursor != null) 'cursor': cursor,
          if (briefId != null) 'brief_id': briefId,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      final page = ReadingFeedPage.fromJson(_jsonMap(response.data));
      if (page.brief != null && page.brief!.id != briefId) {
        throw const FormatException('Reading-feed brief binding mismatch.');
      }
      return page;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The reading-feed service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _category = RegExp(
  r'^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)?$',
);
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
