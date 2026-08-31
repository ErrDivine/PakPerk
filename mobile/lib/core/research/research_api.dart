import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../models/annotation.dart';
import '../models/evidence_card.dart';
import '../models/research_memory.dart';
import '../models/version_diff.dart';

final class AnnotationPage {
  const AnnotationPage({
    required this.items,
    required this.nextAfterRevision,
    required this.hasMore,
    required this.syncRevision,
    required this.purgedThroughRevision,
  });

  final List<Annotation> items;
  final int nextAfterRevision;
  final bool hasMore;
  final int syncRevision;
  final int purgedThroughRevision;
}

final class AnnotationConflictSyncItem {
  const AnnotationConflictSyncItem({
    required this.conflict,
    required this.paperId,
    required this.currentAnnotationRevision,
  });

  final AnnotationConflict conflict;
  final String paperId;
  final int currentAnnotationRevision;
}

final class AnnotationConflictPage {
  const AnnotationConflictPage({
    required this.items,
    required this.nextCursor,
    required this.syncRevision,
  });

  final List<AnnotationConflictSyncItem> items;
  final String? nextCursor;
  final int syncRevision;
}

sealed class AnnotationMutationResult {
  const AnnotationMutationResult();
}

final class AnnotationMutationApplied extends AnnotationMutationResult {
  const AnnotationMutationApplied(this.annotation, {required this.replayed});

  final Annotation annotation;
  final bool replayed;
}

final class AnnotationMutationConflict extends AnnotationMutationResult {
  const AnnotationMutationConflict(this.conflict);

  final AnnotationConflict conflict;
}

final class EvidenceCardPage {
  const EvidenceCardPage({
    required this.items,
    required this.nextCursor,
    required this.syncRevision,
  });

  final List<EvidenceCard> items;
  final String? nextCursor;
  final int syncRevision;
}

final class MemoryPage {
  const MemoryPage({
    required this.items,
    required this.nextCursor,
    required this.syncRevision,
  });

  final List<MemoryItem> items;
  final String? nextCursor;
  final int syncRevision;
}

enum ResearchExportFormat { json, markdown, manifest }

/// A server-bounded research export. The mobile client applies a second size
/// ceiling before exposing it to share/copy UI.
final class ResearchExportArtifact {
  const ResearchExportArtifact({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    this.nextCursor,
    this.pageNumber = 1,
  });

  final List<int> bytes;
  final String mimeType;
  final String fileName;
  final String? nextCursor;
  final int pageNumber;

  bool get isComplete => nextCursor == null;
}

final class ResearchAnnotationImportResult {
  const ResearchAnnotationImportResult({
    required this.importedAnnotations,
    required this.importedConflicts,
    required this.importedReanchorAttempts,
    required this.skippedAnnotations,
    required this.replayed,
  });

  final int importedAnnotations;
  final int importedConflicts;
  final int importedReanchorAttempts;
  final int skippedAnnotations;
  final bool replayed;
}

abstract interface class ResearchRemoteDataSource {
  Future<AnnotationPage> listAnnotations({
    required int expectedAuthEpoch,
    String? paperId,
    int afterRevision,
    int limit,
    RequestCancellation? cancellation,
  });

  Future<AnnotationConflictPage> listAnnotationConflicts({
    required int expectedAuthEpoch,
    String? cursor,
    int limit,
    RequestCancellation? cancellation,
  });

  Future<AnnotationMutationResult> putAnnotation({
    required AnnotationWrite write,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<Annotation> deleteAnnotation({
    required String annotationId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<Annotation> reanchorAnnotation({
    required String annotationId,
    required String operationId,
    required int baseRevision,
    required int toGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<EvidenceCardPage> listEvidenceCards({
    required int expectedAuthEpoch,
    String? paperId,
    String? cursor,
    int limit,
    RequestCancellation? cancellation,
  });

  Future<EvidenceCard> putEvidenceCard({
    required EvidenceCardWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<EvidenceCard> deleteEvidenceCard({
    required String cardId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<MemoryPage> listMemoryReview({
    required int expectedAuthEpoch,
    String? cursor,
    int limit,
    RequestCancellation? cancellation,
  });

  Future<MemoryItem> putMemoryItem({
    required MemoryItemWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<MemoryItem> reviewMemoryItem({
    required String itemId,
    required MemoryReviewWrite write,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<MemoryItem> deleteMemoryItem({
    required String itemId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<List<DocumentVersion>> listVersions({
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<PaperVersionDiff> getVersionDiff({
    required String paperId,
    required int fromGeneration,
    required int toGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ResearchExportArtifact> exportResearch({
    required ResearchExportFormat format,
    required int expectedAuthEpoch,
    String? paperId,
    String? cursor,
    RequestCancellation? cancellation,
  });

  Future<ResearchAnnotationImportResult> importAnnotations({
    required Map<String, dynamic> archive,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class ResearchApi implements ResearchRemoteDataSource {
  const ResearchApi(this._dio);

  static const maximumClientExportBytes = 8 * 1024 * 1024;
  final Dio _dio;

  @override
  Future<AnnotationPage> listAnnotations({
    required int expectedAuthEpoch,
    String? paperId,
    int afterRevision = 0,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    _page(afterRevision, limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/annotations',
        queryParameters: {
          if (paperId != null) 'paper_id': _uuidPath(paperId, 'paperId'),
          'after_revision': afterRevision,
          'limit': limit,
        },
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      return AnnotationPage(
        items: _items(json['items'], Annotation.fromJson, maximum: limit),
        nextAfterRevision: _nonNegative(
          json['next_after_revision'],
          'next_after_revision',
        ),
        hasMore: json['has_more'] as bool? ?? false,
        syncRevision: _nonNegative(json['sync_revision'], 'sync_revision'),
        purgedThroughRevision: _nonNegative(
          json['purged_through_revision'],
          'purged_through_revision',
        ),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<AnnotationConflictPage> listAnnotationConflicts({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    _page(0, limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/annotation-conflicts',
        queryParameters: {
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      return AnnotationConflictPage(
        items: _items(
          json['items'],
          (item) => AnnotationConflictSyncItem(
            conflict: AnnotationConflict.fromJson(_map(item['conflict'])),
            paperId: _responseUuid(item['paper_id'], 'paper_id'),
            currentAnnotationRevision: _positive(
              item['current_annotation_revision'],
              'current_annotation_revision',
            ),
          ),
          maximum: limit,
        ),
        nextCursor: _cursor(json['next_cursor']),
        syncRevision: _nonNegative(json['sync_revision'], 'sync_revision'),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<AnnotationMutationResult> putAnnotation({
    required AnnotationWrite write,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final id = _uuidPath(write.annotation.id, 'annotationId');
    final operationId = _uuidPath(write.operationId, 'operationId');
    try {
      final response = await _dio.put<Object?>(
        '/v1/annotations/$id',
        data: write.toJson(),
        options: _mutation(expectedAuthEpoch, operationId).copyWith(
          validateStatus: (status) =>
              status == 409 ||
              (status != null && status >= 200 && status < 300),
        ),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      if (response.statusCode == 409) {
        return AnnotationMutationConflict(
          AnnotationConflict.fromJson(_map(json['conflict'])),
        );
      }
      return AnnotationMutationApplied(
        Annotation.fromJson(_map(json['annotation'])),
        replayed: json['replayed'] as bool? ?? false,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<Annotation> deleteAnnotation({
    required String annotationId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _deleteMutation(
    path: '/v1/annotations/${_uuidPath(annotationId, 'annotationId')}',
    operationId: operationId,
    baseRevision: baseRevision,
    expectedAuthEpoch: expectedAuthEpoch,
    envelopeKey: 'annotation',
    decode: Annotation.fromJson,
    cancellation: cancellation,
  );

  @override
  Future<Annotation> reanchorAnnotation({
    required String annotationId,
    required String operationId,
    required int baseRevision,
    required int toGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    if (toGeneration <= 0) {
      throw ArgumentError.value(toGeneration, 'toGeneration');
    }
    final id = _uuidPath(annotationId, 'annotationId');
    final operation = _uuidPath(operationId, 'operationId');
    try {
      final response = await _dio.post<Object?>(
        '/v1/annotations/$id/reanchor',
        data: {
          'operation_id': operation,
          'base_revision': baseRevision,
          'to_generation': toGeneration,
        },
        options: _mutation(expectedAuthEpoch, operation),
        cancelToken: cancellation?.dioToken,
      );
      return Annotation.fromJson(_map(_map(response.data)['annotation']));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<EvidenceCardPage> listEvidenceCards({
    required int expectedAuthEpoch,
    String? paperId,
    String? cursor,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    _page(0, limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/evidence-cards',
        queryParameters: {
          if (paperId != null) 'paper_id': _uuidPath(paperId, 'paperId'),
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      return EvidenceCardPage(
        items: _items(json['items'], EvidenceCard.fromJson, maximum: limit),
        nextCursor: _cursor(json['next_cursor']),
        syncRevision: _nonNegative(json['sync_revision'], 'sync_revision'),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<EvidenceCard> putEvidenceCard({
    required EvidenceCardWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _putPostMutation(
    path: create
        ? '/v1/evidence-cards'
        : '/v1/evidence-cards/${_uuidPath(write.card.id, 'cardId')}',
    create: create,
    operationId: write.operationId,
    body: write.toJson(),
    expectedAuthEpoch: expectedAuthEpoch,
    envelopeKey: 'evidence_card',
    decode: EvidenceCard.fromJson,
    cancellation: cancellation,
  );

  @override
  Future<EvidenceCard> deleteEvidenceCard({
    required String cardId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _deleteMutation(
    path: '/v1/evidence-cards/${_uuidPath(cardId, 'cardId')}',
    operationId: operationId,
    baseRevision: baseRevision,
    expectedAuthEpoch: expectedAuthEpoch,
    envelopeKey: 'evidence_card',
    decode: EvidenceCard.fromJson,
    cancellation: cancellation,
  );

  @override
  Future<MemoryPage> listMemoryReview({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    _page(0, limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/memory/review',
        queryParameters: {
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': limit,
        },
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      return MemoryPage(
        items: _items(json['items'], MemoryItem.fromJson, maximum: limit),
        nextCursor: _cursor(json['next_cursor']),
        syncRevision: _nonNegative(json['sync_revision'], 'sync_revision'),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<MemoryItem> putMemoryItem({
    required MemoryItemWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _putPostMutation(
    path: create
        ? '/v1/memory/items'
        : '/v1/memory/items/${_uuidPath(write.item.id, 'itemId')}',
    create: create,
    operationId: write.operationId,
    body: write.toJson(),
    expectedAuthEpoch: expectedAuthEpoch,
    envelopeKey: 'memory_item',
    decode: MemoryItem.fromJson,
    cancellation: cancellation,
  );

  @override
  Future<MemoryItem> reviewMemoryItem({
    required String itemId,
    required MemoryReviewWrite write,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final id = _uuidPath(itemId, 'itemId');
    final operation = _uuidPath(write.operationId, 'operationId');
    try {
      final response = await _dio.post<Object?>(
        '/v1/memory/items/$id/review',
        data: write.toJson(),
        options: _mutation(expectedAuthEpoch, operation),
        cancelToken: cancellation?.dioToken,
      );
      return MemoryItem.fromJson(_map(_map(response.data)['memory_item']));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<MemoryItem> deleteMemoryItem({
    required String itemId,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _deleteMutation(
    path: '/v1/memory/items/${_uuidPath(itemId, 'itemId')}',
    operationId: operationId,
    baseRevision: baseRevision,
    expectedAuthEpoch: expectedAuthEpoch,
    envelopeKey: 'memory_item',
    decode: MemoryItem.fromJson,
    cancellation: cancellation,
  );

  @override
  Future<List<DocumentVersion>> listVersions({
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final id = _uuidPath(paperId, 'paperId');
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$id/versions',
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      if (json['paper_id'] != id) {
        throw const FormatException('Paper mismatch.');
      }
      return _items(json['items'], DocumentVersion.fromJson, maximum: 128);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<PaperVersionDiff> getVersionDiff({
    required String paperId,
    required int fromGeneration,
    required int toGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    if (fromGeneration <= 0 || toGeneration <= 0) {
      throw ArgumentError('Version generations must be positive.');
    }
    final id = _uuidPath(paperId, 'paperId');
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$id/version-diff',
        queryParameters: {'from': fromGeneration, 'to': toGeneration},
        options: _safe(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final diff = PaperVersionDiff.fromJson(_map(response.data));
      if (diff.paperId != id ||
          diff.fromGeneration != fromGeneration ||
          diff.toGeneration != toGeneration) {
        throw const FormatException('Version diff scope mismatch.');
      }
      return diff;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<ResearchExportArtifact> exportResearch({
    required ResearchExportFormat format,
    required int expectedAuthEpoch,
    String? paperId,
    String? cursor,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.get<List<int>>(
        '/v1/annotations/export',
        queryParameters: {
          'format': format.name,
          if (paperId != null) 'paper_id': _uuidPath(paperId, 'paperId'),
          if (format != ResearchExportFormat.manifest) 'paged': true,
          if (cursor != null) 'cursor': _exportCursor(cursor),
        },
        options: _safe(
          expectedAuthEpoch,
        ).copyWith(responseType: ResponseType.bytes),
        cancelToken: cancellation?.dioToken,
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.length > maximumClientExportBytes) {
        throw const ApiException(
          code: 'EXPORT_TOO_LARGE',
          message: 'This export is too large to share from a phone.',
          statusCode: 413,
        );
      }
      final contentType = response.headers.value('content-type');
      final disposition = response.headers.value('content-disposition');
      final nextCursor = _optionalExportCursor(
        response.headers.value('x-pakperk-export-next-cursor'),
      );
      final pageNumber = _exportPageNumber(
        response.headers.value('x-pakperk-export-page'),
      );
      return ResearchExportArtifact(
        bytes: bytes,
        mimeType: _safeMime(contentType, format),
        fileName: _safeFileName(disposition, format),
        nextCursor: nextCursor,
        pageNumber: pageNumber,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<ResearchAnnotationImportResult> importAnnotations({
    required Map<String, dynamic> archive,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final operation = _uuidPath(operationId, 'operationId');
    try {
      final response = await _dio.post<Object?>(
        '/v1/annotations/import',
        data: archive,
        options: _mutation(expectedAuthEpoch, operation),
        cancelToken: cancellation?.dioToken,
      );
      final json = _map(response.data);
      return ResearchAnnotationImportResult(
        importedAnnotations: _nonNegative(
          json['imported_annotations'],
          'imported_annotations',
        ),
        importedConflicts: _nonNegative(
          json['imported_conflicts'],
          'imported_conflicts',
        ),
        importedReanchorAttempts: _nonNegative(
          json['imported_reanchor_attempts'],
          'imported_reanchor_attempts',
        ),
        skippedAnnotations: _nonNegative(
          json['skipped_annotations'],
          'skipped_annotations',
        ),
        replayed: json['replayed'] as bool? ?? false,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<T> _putPostMutation<T>({
    required String path,
    required bool create,
    required String operationId,
    required Map<String, Object?> body,
    required int expectedAuthEpoch,
    required String envelopeKey,
    required T Function(Map<String, dynamic>) decode,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final operation = _uuidPath(operationId, 'operationId');
    try {
      final response = create
          ? await _dio.post<Object?>(
              path,
              data: body,
              options: _mutation(expectedAuthEpoch, operation),
              cancelToken: cancellation?.dioToken,
            )
          : await _dio.put<Object?>(
              path,
              data: body,
              options: _mutation(expectedAuthEpoch, operation),
              cancelToken: cancellation?.dioToken,
            );
      return decode(_map(_map(response.data)[envelopeKey]));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<T> _deleteMutation<T>({
    required String path,
    required String operationId,
    required int baseRevision,
    required int expectedAuthEpoch,
    required String envelopeKey,
    required T Function(Map<String, dynamic>) decode,
    RequestCancellation? cancellation,
  }) async {
    _authEpoch(expectedAuthEpoch);
    final operation = _uuidPath(operationId, 'operationId');
    if (baseRevision < 0) throw ArgumentError.value(baseRevision);
    try {
      final response = await _dio.delete<Object?>(
        path,
        queryParameters: {
          'operation_id': operation,
          'base_revision': baseRevision,
        },
        options: _mutation(expectedAuthEpoch, operation),
        cancelToken: cancellation?.dioToken,
      );
      return decode(_map(_map(response.data)[envelopeKey]));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

Options _safe(int expectedAuthEpoch) => pakPerkRequestOptions(
  auth: RequestAuthPolicy.required,
  retry: AuthRetryPolicy.safe,
  expectedAuthEpoch: expectedAuthEpoch,
);

Options _mutation(int expectedAuthEpoch, String operationId) =>
    pakPerkRequestOptions(
      auth: RequestAuthPolicy.required,
      retry: AuthRetryPolicy.idempotencyProtected,
      expectedAuthEpoch: expectedAuthEpoch,
      headers: {'Idempotency-Key': operationId},
    );

void _authEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _page(int afterRevision, int limit) {
  if (afterRevision < 0 || limit < 1 || limit > 250) {
    throw ArgumentError('Invalid research page request.');
  }
}

String _uuidPath(String value, String name) {
  final text = value.trim().toLowerCase();
  if (!_uuid.hasMatch(text)) throw ArgumentError.value(value, name);
  return text;
}

String _responseUuid(Object? value, String field) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (!_uuid.hasMatch(text)) throw FormatException('Invalid $field.');
  return text;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected JSON object.');
}

List<T> _items<T>(
  Object? value,
  T Function(Map<String, dynamic>) decode, {
  required int maximum,
}) {
  if (value is! List || value.length > maximum) {
    throw const FormatException('Invalid research collection.');
  }
  return value.map((item) => decode(_map(item))).toList(growable: false);
}

int _nonNegative(Object? value, String field) {
  final parsed = (value as num?)?.toInt();
  if (parsed == null || parsed < 0) throw FormatException('Invalid $field.');
  return parsed;
}

int _positive(Object? value, String field) {
  final parsed = _nonNegative(value, field);
  if (parsed == 0) throw FormatException('Invalid $field.');
  return parsed;
}

String? _cursor(Object? value) {
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw const FormatException('Invalid cursor.');
  }
  return value;
}

String _safeMime(String? raw, ResearchExportFormat format) {
  final expected = format == ResearchExportFormat.markdown
      ? 'text/markdown'
      : 'application/json';
  if (raw == null) return expected;
  final value = raw.split(';').first.trim().toLowerCase();
  if (value != expected) {
    throw const FormatException('Research export content type mismatch.');
  }
  return expected;
}

String _safeFileName(String? disposition, ResearchExportFormat format) {
  final match = RegExp(
    r'filename=([A-Za-z0-9._-]{1,128})',
  ).firstMatch(disposition ?? '');
  if (match case RegExpMatch()) return match.group(1)!;
  return switch (format) {
    ResearchExportFormat.markdown => 'pakperk-research-export.md',
    ResearchExportFormat.json => 'pakperk-research-export.json',
    ResearchExportFormat.manifest => 'pakperk-research-export-manifest.json',
  };
}

String _exportCursor(String value) {
  if (value.isEmpty ||
      value.length > 2048 ||
      value.codeUnits.any((c) => c < 33 || c > 126)) {
    throw const FormatException('Invalid research export cursor.');
  }
  return value;
}

String? _optionalExportCursor(String? value) {
  if (value == null) return null;
  return _exportCursor(value);
}

int _exportPageNumber(String? value) {
  if (value == null) return 1;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1 || parsed > 0x7fffffff) {
    throw const FormatException('Invalid research export page number.');
  }
  return parsed;
}

const _invalidResponse = ApiException(
  code: 'INVALID_RESEARCH_RESPONSE',
  message: 'The research service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
