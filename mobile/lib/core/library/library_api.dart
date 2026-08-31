import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'library_models.dart';

abstract interface class LibraryRemoteDataSource {
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  });

  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  });

  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
    LibrarySaveSourceKind? saveSourceKind,
  });

  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  });
}

final class LibraryApi implements LibraryRemoteDataSource {
  const LibraryApi(this._dio);

  final Dio _dio;

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async {
    _validateAuthEpoch(expectedAuthEpoch);
    _validateLimit(limit);
    if (cursor != null && (cursor.isEmpty || cursor.length > 2048)) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid cursor.');
    }
    try {
      final response = await _dio.get<Object?>(
        '/v1/me/library',
        queryParameters: {
          'state': 'to_read',
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      return LibraryListPage.fromJson(_jsonMap(response.data));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async {
    _validateAuthEpoch(expectedAuthEpoch);
    if (afterRevision < 0) {
      throw ArgumentError.value(
        afterRevision,
        'afterRevision',
        'Must not be negative.',
      );
    }
    _validateLimit(limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/me/library/changes',
        queryParameters: {'after_revision': afterRevision, 'limit': limit},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      return LibraryChangesPage.fromJson(
        _jsonMap(response.data),
        afterRevision: afterRevision,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
    LibrarySaveSourceKind? saveSourceKind,
  }) => _mutate(
    paperId: paperId,
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    saveSourceKind: saveSourceKind,
    save: true,
  );

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => _mutate(
    paperId: paperId,
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    save: false,
  );

  Future<LibraryMutationResult> _mutate({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
    required bool save,
    LibrarySaveSourceKind? saveSourceKind,
  }) async {
    _validateUuid(paperId, 'paperId');
    _validateUuid(operationId, 'operationId');
    _validateAuthEpoch(expectedAuthEpoch);
    final path = '/v1/me/library/${Uri.encodeComponent(paperId)}';
    final options = pakPerkRequestOptions(
      auth: RequestAuthPolicy.required,
      retry: AuthRetryPolicy.idempotencyProtected,
      expectedAuthEpoch: expectedAuthEpoch,
      headers: {'Idempotency-Key': operationId},
    );
    try {
      final response = save
          ? await _dio.put<Object?>(
              path,
              data: {
                'operation_id': operationId,
                'state': 'to_read',
                if (saveSourceKind != null)
                  'save_source_kind': saveSourceKind.wireValue,
              },
              options: options,
            )
          : await _dio.delete<Object?>(path, options: options);
      final result = LibraryMutationResult.fromJson(_jsonMap(response.data));
      if (result.item.paperId != paperId) throw const FormatException();
      return result;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The library service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

void _validateLimit(int value) {
  if (value < 1 || value > 100) {
    throw ArgumentError.value(value, 'limit', 'Must be between 1 and 100.');
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

void _validateUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Must be a canonical UUID.');
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
