import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import 'research_profile_models.dart';

final class ResearchProfileApiResult<T> {
  const ResearchProfileApiResult({required this.value, required this.revision});

  final T value;
  final int revision;
}

abstract interface class ResearchProfileRemoteDataSource {
  Future<ResearchProfileApiResult<ResearchProfile>> profile({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfileInterests>> interests({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> update({
    required String operationId,
    required int expectedRevision,
    required ResearchProfilePatch patch,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> upsertTopic({
    required String topicId,
    required ResearchTopicPolarity polarity,
    required double strength,
    required String? userAlias,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> deleteTopic({
    required String topicId,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> upsertAuthor({
    required String authorKey,
    required String displayName,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> deleteAuthor({
    required String authorKey,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileApiResult<ResearchProfile>> reset({
    required ResearchProfileResetScope scope,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchProfileExport> export({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class ResearchProfileApi implements ResearchProfileRemoteDataSource {
  const ResearchProfileApi(this._dio);

  final Dio _dio;

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> profile({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _profileRequest(
    () => _dio.get<Object?>(
      '/v1/discovery/profile',
      cancelToken: cancellation?.dioToken,
      options: _readOptions(expectedAuthEpoch),
    ),
  );

  @override
  Future<ResearchProfileApiResult<ResearchProfileInterests>> interests({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/discovery/profile/interests',
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      final interests = ResearchProfileInterests.fromJson(_map(response.data));
      _requireEtag(response, interests.profileRevision);
      return ResearchProfileApiResult(
        value: interests,
        revision: interests.profileRevision,
      );
    });
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> update({
    required String operationId,
    required int expectedRevision,
    required ResearchProfilePatch patch,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.put<Object?>(
        '/v1/discovery/profile',
        data: patch.toJson(operationId),
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> upsertTopic({
    required String topicId,
    required ResearchTopicPolarity polarity,
    required double strength,
    required String? userAlias,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateUuid(topicId, 'topicId');
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.put<Object?>(
        '/v1/discovery/profile/topics/$topicId',
        data: {
          'operation_id': operationId,
          'polarity': polarity.name,
          'strength': strength,
          'user_alias': userAlias,
        },
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> deleteTopic({
    required String topicId,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateUuid(topicId, 'topicId');
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.delete<Object?>(
        '/v1/discovery/profile/topics/$topicId',
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> upsertAuthor({
    required String authorKey,
    required String displayName,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateAuthor(authorKey, displayName);
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.put<Object?>(
        '/v1/discovery/profile/authors/${Uri.encodeComponent(authorKey)}',
        data: {'operation_id': operationId, 'display_name': displayName},
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> deleteAuthor({
    required String authorKey,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateAuthor(authorKey, 'author');
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.delete<Object?>(
        '/v1/discovery/profile/authors/${Uri.encodeComponent(authorKey)}',
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> reset({
    required ResearchProfileResetScope scope,
    required String operationId,
    required int expectedRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateMutation(operationId, expectedRevision, expectedAuthEpoch);
    return _profileRequest(
      () => _dio.post<Object?>(
        '/v1/discovery/profile/reset',
        data: {'operation_id': operationId, 'scope': scope.name},
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(
          operationId,
          expectedRevision,
          expectedAuthEpoch,
        ),
      ),
    );
  }

  @override
  Future<ResearchProfileExport> export({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/discovery/profile/export',
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      return ResearchProfileExport.fromJson(_map(response.data));
    });
  }

  Future<ResearchProfileApiResult<ResearchProfile>> _profileRequest(
    Future<Response<Object?>> Function() action,
  ) => _request(() async {
    final response = await action();
    final json = _map(response.data);
    _exactEnvelope(json, 'profile');
    final profile = ResearchProfile.fromJson(_map(json['profile']));
    _requireEtag(response, profile.profileRevision);
    return ResearchProfileApiResult(
      value: profile,
      revision: profile.profileRevision,
    );
  });
}

Options _readOptions(int expectedAuthEpoch) {
  _validateEpoch(expectedAuthEpoch);
  return pakPerkRequestOptions(
    auth: RequestAuthPolicy.required,
    retry: AuthRetryPolicy.safe,
    expectedAuthEpoch: expectedAuthEpoch,
  );
}

Options _mutationOptions(
  String operationId,
  int expectedRevision,
  int expectedAuthEpoch,
) => pakPerkRequestOptions(
  auth: RequestAuthPolicy.required,
  retry: AuthRetryPolicy.idempotencyProtected,
  expectedAuthEpoch: expectedAuthEpoch,
  headers: {
    'If-Match': '"research-profile-$expectedRevision"',
    'Idempotency-Key': operationId,
  },
);

Future<T> _request<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on DioException catch (error) {
    throw mapDioException(error);
  } on FormatException {
    throw _invalidResponse;
  }
}

void _requireEtag(Response<Object?> response, int revision) {
  final values = response.headers.map['etag'];
  if (values?.length != 1 || values!.single != '"research-profile-$revision"') {
    throw const FormatException('Invalid research profile ETag.');
  }
}

void _exactEnvelope(Map<String, dynamic> json, String key) {
  if (json.length != 1 || !json.containsKey(key)) {
    throw const FormatException('Invalid response envelope.');
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

void _validateMutation(
  String operationId,
  int expectedRevision,
  int expectedAuthEpoch,
) {
  _validateUuid(operationId, 'operationId');
  if (expectedRevision < 0) {
    throw ArgumentError.value(expectedRevision, 'expectedRevision');
  }
  _validateEpoch(expectedAuthEpoch);
}

void _validateEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _validateUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) throw ArgumentError.value(value, name);
}

void _validateAuthor(String authorKey, String displayName) {
  if (authorKey.isEmpty ||
      authorKey.length > 200 ||
      displayName.isEmpty ||
      displayName.length > 200) {
    throw ArgumentError.value(authorKey, 'authorKey');
  }
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The research profile service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
