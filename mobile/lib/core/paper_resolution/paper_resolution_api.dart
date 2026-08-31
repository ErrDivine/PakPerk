import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../library/library_models.dart';
import 'paper_resolution_models.dart';

abstract interface class PaperResolutionRemoteDataSource {
  Future<PaperSearchResult> searchByTitle({
    required String query,
    required int expectedAuthEpoch,
    int limit = 8,
    RequestCancellation? cancellation,
  });

  Future<PaperImportResult> importPaper({
    required PaperImportSource source,
    required String operationId,
    required LibrarySaveSourceKind saveSourceKind,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class PaperResolutionApi implements PaperResolutionRemoteDataSource {
  const PaperResolutionApi(this._dio);

  final Dio _dio;

  @override
  Future<PaperSearchResult> searchByTitle({
    required String query,
    required int expectedAuthEpoch,
    int limit = 8,
    RequestCancellation? cancellation,
  }) async {
    _validateAuthEpoch(expectedAuthEpoch);
    if (limit < 1 || limit > 10) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 10.');
    }
    final normalizedQuery = _normalizeQuery(query);
    try {
      final response = await _dio.post<Object?>(
        '/v1/me/paper-searches',
        data: {'query': normalizedQuery, 'limit': limit},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      final result = PaperSearchResult.fromJson(_jsonMap(response.data));
      if (result.normalizedQuery != normalizedQuery) {
        throw const FormatException('Search query identity mismatch.');
      }
      return result;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<PaperImportResult> importPaper({
    required PaperImportSource source,
    required String operationId,
    required LibrarySaveSourceKind saveSourceKind,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _validateAuthEpoch(expectedAuthEpoch);
    _validateUuid(operationId, 'operationId');
    if (source.value.isEmpty || source.value.length > 2048) {
      throw ArgumentError.value(source.value, 'source', 'Invalid paper input.');
    }
    if (saveSourceKind != LibrarySaveSourceKind.titleSearch &&
        saveSourceKind != source.directSaveSourceKind) {
      throw ArgumentError.value(
        saveSourceKind,
        'saveSourceKind',
        'Import provenance does not match its canonical input.',
      );
    }
    try {
      final response = await _dio.post<Object?>(
        '/v1/me/library/imports',
        data: {
          'operation_id': operationId,
          'source': source.toJson(),
          'target_state': LibraryItemState.inbox.storageValue,
          'save_source_kind': saveSourceKind.wireValue,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {'Idempotency-Key': operationId},
        ),
        cancelToken: cancellation?.dioToken,
      );
      final result = PaperImportResult.fromJson(_jsonMap(response.data));
      if (result.item.lastOperationId != operationId ||
          result.resolution.inputKind != source.kind) {
        throw const FormatException('Import operation identity mismatch.');
      }
      return result;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

String _normalizeQuery(String value) {
  final normalized = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .join(' ');
  if (normalized.runes.length < 3 ||
      normalized.runes.length > 300 ||
      normalized.runes.any(
        (rune) =>
            (rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
            rune == 0x7f,
      )) {
    throw ArgumentError.value(value, 'query', 'Invalid paper title query.');
  }
  return normalized;
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

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The paper service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
