import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../models/document_block.dart';
import '../models/paper_passport.dart';
import '../models/provenance.dart';
import '../models/reader_state.dart';
import '../models/reading_checkpoint.dart';
import '../models/semantic_span.dart';

const documentBlockPageSize = 100;

abstract interface class DocumentRemoteDataSource {
  Future<DocumentSnapshot> fetchSnapshot({
    required String paperId,
    required String versionKey,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    RequestCancellation? cancellation,
  });

  Future<ReadingCheckpoint?> getCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ReadingCheckpoint> putCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

abstract interface class PagedDocumentRemoteDataSource {
  Future<DocumentBlockPage> fetchBlockPage({
    required String paperId,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    String? cursor,
    RequestCancellation? cancellation,
  });
}

final class DocumentVisualObjects {
  DocumentVisualObjects({
    required this.paperId,
    required this.generation,
    required Iterable<DocumentFigure> figures,
    required Iterable<DocumentTable> tables,
    required Iterable<DocumentEquation> equations,
  }) : figures = List.unmodifiable(figures),
       tables = List.unmodifiable(tables),
       equations = List.unmodifiable(equations);

  final String paperId;
  final int generation;
  final List<DocumentFigure> figures;
  final List<DocumentTable> tables;
  final List<DocumentEquation> equations;
}

abstract interface class VisualDocumentRemoteDataSource {
  Future<DocumentVisualObjects> fetchVisualObjects({
    required String paperId,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class DocumentApi
    implements
        DocumentRemoteDataSource,
        PagedDocumentRemoteDataSource,
        VisualDocumentRemoteDataSource {
  const DocumentApi(this._dio);

  final Dio _dio;

  @override
  Future<DocumentSnapshot> fetchSnapshot({
    required String paperId,
    required String versionKey,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuidPath(paperId, 'paperId');
    _validateGeneration(expectedGeneration);
    _validateAuthEpoch(expectedAuthEpoch);
    try {
      final outlineJson = await _getJson(
        '/v1/papers/$safePaperId/document/outline',
        expectedAuthEpoch,
        cancellation,
      );
      final outline = DocumentOutline.fromJson(outlineJson);
      _validateEnvelope(
        outline.paperId,
        outline.generation,
        paperId,
        expectedGeneration,
      );

      final firstPage = await fetchBlockPage(
        paperId: paperId,
        expectedGeneration: expectedGeneration,
        expectedAuthEpoch: expectedAuthEpoch,
        cancellation: cancellation,
      );
      final blocks = firstPage.blocks;

      PaperPassport? passport;
      if (includePassport) {
        final passportJson = await _getJson(
          '/v1/papers/$safePaperId/passport',
          expectedAuthEpoch,
          cancellation,
        );
        final passportPayload = passportJson['passport'] is Map
            ? Map<String, dynamic>.from(passportJson['passport'] as Map)
            : passportJson;
        passport = PaperPassport.fromJson(passportPayload);
        _validateEnvelope(
          passport.paperId,
          passport.generation,
          paperId,
          expectedGeneration,
        );
        if (!passportVersionMatchesVersionKey(passport, versionKey)) {
          throw const FormatException('Stale Passport version.');
        }
      }

      var terms = <PaperTerm>[];
      var semanticSpans = <SemanticSpan>[];
      var semanticFacetsVerified = false;
      if (includeSemanticFacets) {
        final envelopes = await Future.wait([
          _getJson(
            '/v1/papers/$safePaperId/terms',
            expectedAuthEpoch,
            cancellation,
          ),
          _getJson(
            '/v1/papers/$safePaperId/semantic-spans',
            expectedAuthEpoch,
            cancellation,
            query: const {'density': 'detailed'},
          ),
        ]);
        final [termsEnvelope, semanticEnvelopeJson] = envelopes;
        _validateJsonEnvelope(termsEnvelope, paperId, expectedGeneration);
        terms = _decodeList(
          termsEnvelope['items'],
          PaperTerm.fromJson,
          maximum: 10000,
        );
        final semanticEnvelope = SemanticSpansEnvelope.fromJson(
          semanticEnvelopeJson,
        );
        _validateEnvelope(
          semanticEnvelope.paperId,
          semanticEnvelope.generation,
          paperId,
          expectedGeneration,
        );
        if (semanticEnvelope.density != SemanticDensity.detailed) {
          throw const FormatException(
            'Semantic response omitted detailed spans.',
          );
        }
        semanticSpans = semanticEnvelope.spans;
        semanticFacetsVerified = true;
      }

      var figures = const <DocumentFigure>[];
      var tables = const <DocumentTable>[];
      var equations = const <DocumentEquation>[];
      if (includeVisualObjects) {
        final visualObjects = await fetchVisualObjects(
          paperId: paperId,
          expectedGeneration: expectedGeneration,
          expectedAuthEpoch: expectedAuthEpoch,
          cancellation: cancellation,
        );
        figures = visualObjects.figures;
        tables = visualObjects.tables;
        equations = visualObjects.equations;
      }

      return DocumentSnapshot(
        paperId: paperId,
        versionKey: versionKey,
        generation: expectedGeneration,
        outline: outline,
        blocks: blocks,
        figures: figures,
        tables: tables,
        equations: equations,
        terms: terms,
        semanticSpans: semanticSpans,
        passport: passport,
        provenance: ProvenanceSummary.fromJson(
          _jsonMap(outlineJson['provenance']),
        ),
        fetchedAt: DateTime.now().toUtc(),
        nextCursor: firstPage.nextCursor,
        passportIncluded: includePassport,
        semanticFacetsIncluded: semanticFacetsVerified,
        visualObjectsIncluded: includeVisualObjects,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<DocumentVisualObjects> fetchVisualObjects({
    required String paperId,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuidPath(paperId, 'paperId');
    _validateGeneration(expectedGeneration);
    _validateAuthEpoch(expectedAuthEpoch);
    try {
      final envelopes = await Future.wait([
        _getJson(
          '/v1/papers/$safePaperId/figures',
          expectedAuthEpoch,
          cancellation,
        ),
        _getJson(
          '/v1/papers/$safePaperId/tables',
          expectedAuthEpoch,
          cancellation,
        ),
        _getJson(
          '/v1/papers/$safePaperId/equations',
          expectedAuthEpoch,
          cancellation,
        ),
      ]);
      final [figuresEnvelope, tablesEnvelope, equationsEnvelope] = envelopes;
      for (final envelope in [
        figuresEnvelope,
        tablesEnvelope,
        equationsEnvelope,
      ]) {
        _validateJsonEnvelope(envelope, paperId, expectedGeneration);
      }
      return DocumentVisualObjects(
        paperId: paperId,
        generation: expectedGeneration,
        figures: _decodeList(
          figuresEnvelope['items'],
          DocumentFigure.fromJson,
          maximum: maximumDocumentFigures,
        ),
        tables: _decodeList(
          tablesEnvelope['items'],
          DocumentTable.fromJson,
          maximum: maximumDocumentTables,
        ),
        equations: _decodeList(
          equationsEnvelope['items'],
          DocumentEquation.fromJson,
          maximum: maximumDocumentEquations,
        ),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<DocumentBlockPage> fetchBlockPage({
    required String paperId,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    String? cursor,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuidPath(paperId, 'paperId');
    final pageJson = await _getJson(
      '/v1/papers/$safePaperId/document/blocks',
      expectedAuthEpoch,
      cancellation,
      query: {
        if (cursor != null) 'cursor': cursor,
        'limit': documentBlockPageSize,
      },
    );
    final page = DocumentBlockPage.fromJson(pageJson);
    _validateEnvelope(
      page.paperId,
      page.generation,
      paperId,
      expectedGeneration,
    );
    return page;
  }

  @override
  Future<ReadingCheckpoint?> getCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuidPath(paperId, 'paperId');
    _validateAuthEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.get<Object?>(
        '/v1/reading/checkpoints',
        queryParameters: {'paper_id': safePaperId},
        options: _options(expectedAuthEpoch),
        cancelToken: cancellation?.dioToken,
      );
      final envelope = _jsonMap(response.data);
      final items = envelope['items'];
      if (items is! List || items.length > 1) {
        throw const FormatException('Invalid checkpoints.');
      }
      final raw = items.whereType<Map>().firstWhere(
        (value) => value['paper_id'] == paperId,
        orElse: () => const <String, dynamic>{},
      );
      if (raw.isEmpty) return null;
      final checkpoint = ReadingCheckpoint.fromJson(
        Map<String, dynamic>.from(raw),
        accountId: accountId,
      );
      if (checkpoint.paperId != paperId) {
        throw const FormatException('Checkpoint paper mismatch.');
      }
      return checkpoint;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<ReadingCheckpoint> putCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuidPath(checkpoint.paperId, 'paperId');
    _validateAuthEpoch(expectedAuthEpoch);
    try {
      final operationId = checkpoint.operationId;
      if (operationId == null || !_uuid.hasMatch(operationId)) {
        throw ArgumentError.value(operationId, 'checkpoint.operationId');
      }
      final response = await _dio.put<Object?>(
        '/v1/reading/checkpoints/$safePaperId',
        data: {
          'operation_id': operationId,
          'base_revision': checkpoint.revision,
          'generation': checkpoint.generation,
          'mode': checkpoint.mode.wireValue,
          'stage': switch (checkpoint.stage) {
            PaperStage.abstractView => 'abstract',
            PaperStage.introduction => 'introduction',
            PaperStage.connections => 'connections',
          },
          'block_id': checkpoint.blockId,
          'scroll_fraction': checkpoint.scrollFraction,
          'last_read_at': checkpoint.lastReadAt.toUtc().toIso8601String(),
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {'Idempotency-Key': operationId},
        ),
        cancelToken: cancellation?.dioToken,
      );
      final envelope = _jsonMap(response.data);
      final raw = envelope['checkpoint'] ?? envelope;
      if (raw is! Map) throw const FormatException('Invalid checkpoint.');
      final result = ReadingCheckpoint.fromJson(
        Map<String, dynamic>.from(raw),
        accountId: checkpoint.accountId,
        pendingSync: false,
      );
      if (result.paperId != checkpoint.paperId ||
          result.generation != checkpoint.generation) {
        throw const FormatException('Checkpoint scope mismatch.');
      }
      return result.copyWith(operationId: operationId);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    int expectedAuthEpoch,
    RequestCancellation? cancellation, {
    Map<String, Object?>? query,
  }) async {
    final response = await _dio.get<Object?>(
      path,
      queryParameters: query,
      options: _options(expectedAuthEpoch),
      cancelToken: cancellation?.dioToken,
    );
    return _jsonMap(response.data);
  }
}

Options _options(int expectedAuthEpoch) => pakPerkRequestOptions(
  auth: RequestAuthPolicy.required,
  retry: AuthRetryPolicy.safe,
  expectedAuthEpoch: expectedAuthEpoch,
);

void _validateAuthEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _validateGeneration(int value) {
  if (value <= 0) throw ArgumentError.value(value, 'expectedGeneration');
}

String _uuidPath(String value, String name) {
  final normalized = value.trim().toLowerCase();
  if (!_uuid.hasMatch(normalized)) throw ArgumentError.value(value, name);
  return normalized;
}

void _validateJsonEnvelope(
  Map<String, dynamic> json,
  String paperId,
  int generation,
) {
  final responseGeneration = (json['generation'] as num?)?.toInt() ?? 0;
  _validateEnvelope(
    json['paper_id']?.toString() ?? '',
    responseGeneration,
    paperId,
    generation,
  );
}

void _validateEnvelope(
  String responsePaperId,
  int responseGeneration,
  String expectedPaperId,
  int expectedGeneration,
) {
  if (responsePaperId != expectedPaperId ||
      responseGeneration != expectedGeneration) {
    throw const FormatException('Stale document response.');
  }
}

List<T> _decodeList<T>(
  Object? raw,
  T Function(Map<String, dynamic>) decode, {
  required int maximum,
}) {
  if (raw == null) return <T>[];
  if (raw is! List || raw.length > maximum) {
    throw const FormatException('Invalid document collection.');
  }
  return raw
      .map((value) {
        if (value is! Map) {
          throw const FormatException('Invalid document item.');
        }
        return decode(Map<String, dynamic>.from(value));
      })
      .toList(growable: false);
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_DOCUMENT_RESPONSE',
  message: 'The document service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
