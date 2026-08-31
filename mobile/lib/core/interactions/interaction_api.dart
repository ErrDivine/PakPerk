import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'interaction_models.dart';

abstract interface class InteractionRemoteDataSource {
  Future<InteractionBatchResult> sendBatch({
    required InteractionScope scope,
    required List<PaperInteractionEvent> events,
  });
}

final class InteractionApi implements InteractionRemoteDataSource {
  const InteractionApi(this._dio);

  final Dio _dio;

  @override
  Future<InteractionBatchResult> sendBatch({
    required InteractionScope scope,
    required List<PaperInteractionEvent> events,
  }) async {
    validateInteractionBatch(scope, events);
    final options = switch (scope) {
      AccountInteractionScope(:final authEpoch) => pakPerkRequestOptions(
        auth: RequestAuthPolicy.required,
        retry: AuthRetryPolicy.never,
        expectedAuthEpoch: authEpoch,
      ),
      AnonymousInteractionScope(:final sessionId) => pakPerkRequestOptions(
        auth: RequestAuthPolicy.none,
        retry: AuthRetryPolicy.never,
        headers: {'X-Session-Id': sessionId},
      ),
    };
    try {
      final response = await _dio.post<Object?>(
        '/v1/events/batch',
        data: {
          'events': events
              .map((event) => event.toJson())
              .toList(growable: false),
        },
        options: options,
      );
      return InteractionBatchResult.fromJson(
        _jsonMap(response.data),
        submitted: events.length,
      );
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
  message: 'The interaction service returned invalid data.',
  retryable: false,
  statusCode: 502,
);
