import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import 'recommendation_interaction_models.dart';

abstract interface class RecommendationInteractionRemoteDataSource {
  Future<RecommendationExplanationEnvelope> explanation({
    required String batchId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<RecommendationFeedbackResult> submitFeedback({
    required String batchId,
    required String paperId,
    required RecommendationFeedbackSelection selection,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class RecommendationInteractionApi
    implements RecommendationInteractionRemoteDataSource {
  const RecommendationInteractionApi(this._dio);

  final Dio _dio;

  @override
  Future<RecommendationExplanationEnvelope> explanation({
    required String batchId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _validateUuid(batchId, 'batchId');
    _validateUuid(paperId, 'paperId');
    _validateAuthEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.get<Object?>(
        '/v1/discovery/batches/$batchId/papers/$paperId/explanation',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      final result = RecommendationExplanationEnvelope.fromJson(
        _jsonMap(response.data),
      );
      if (result.batchId != batchId || result.paperId != paperId) {
        throw const FormatException(
          'Recommendation explanation identity mismatch.',
        );
      }
      return result;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<RecommendationFeedbackResult> submitFeedback({
    required String batchId,
    required String paperId,
    required RecommendationFeedbackSelection selection,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _validateUuid(batchId, 'batchId');
    _validateUuid(paperId, 'paperId');
    _validateUuid(operationId, 'operationId');
    _validateAuthEpoch(expectedAuthEpoch);
    if (selection.type == RecommendationFeedbackType.relevant &&
        selection.reason != null) {
      throw ArgumentError.value(
        selection,
        'selection',
        'Relevant feedback cannot include a negative reason.',
      );
    }
    try {
      final response = await _dio.post<Object?>(
        '/v1/discovery/batches/$batchId/feedback',
        data: selection.toJson(paperId: paperId),
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {'Idempotency-Key': operationId},
        ),
        cancelToken: cancellation?.dioToken,
      );
      return RecommendationFeedbackResult.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

void _validateUuid(String value, String name) {
  if (!isRecommendationUuid(value)) {
    throw ArgumentError.value(value, name, 'Must be a canonical UUID.');
  }
}

void _validateAuthEpoch(int value) {
  if (value < 0) {
    throw ArgumentError.value(
      value,
      'expectedAuthEpoch',
      'Must not be negative.',
    );
  }
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The recommendation service returned invalid data.',
  retryable: true,
  statusCode: 502,
);
