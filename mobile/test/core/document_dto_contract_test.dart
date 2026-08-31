import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/document/document_api.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/provenance.dart';

void main() {
  test('decodes block envelope items and injects envelope identity', () {
    final page = DocumentBlockPage.fromJson({
      ..._envelope,
      'items': [_block],
      'next_cursor': 'next',
    });
    expect(page.blocks.single.paperId, _paperId);
    expect(page.blocks.single.generation, 7);
    expect(page.blocks.single.sourceLocator?.pageNumber, 3);
    expect(page.nextCursor, 'next');
  });

  test('DocumentApi pages with a backend-valid limit of 100', () async {
    final adapter = _BlockAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final api = DocumentApi(dio);
    final first = await api.fetchBlockPage(
      paperId: _paperId,
      expectedGeneration: 7,
      expectedAuthEpoch: 2,
    );
    await api.fetchBlockPage(
      paperId: _paperId,
      expectedGeneration: 7,
      expectedAuthEpoch: 2,
      cursor: first.nextCursor,
    );
    expect(adapter.requests.first.queryParameters['limit'], 100);
    expect(adapter.requests.last.queryParameters['cursor'], 'next');
  });

  test(
    'disabled enrichments never make readable blocks depend on routes',
    () async {
      final adapter = _SnapshotAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final snapshot = await DocumentApi(dio).fetchSnapshot(
        paperId: _paperId,
        versionKey: '2601.00001v7',
        expectedGeneration: 7,
        expectedAuthEpoch: 2,
        includePassport: false,
        includeSemanticFacets: false,
        includeVisualObjects: false,
      );
      expect(snapshot.blocks, hasLength(1));
      expect(snapshot.passport, isNull);
      expect(snapshot.terms, isEmpty);
      expect(snapshot.figures, isEmpty);
      expect(adapter.requests.map((request) => request.path), [
        '/v1/papers/$_paperId/document/outline',
        '/v1/papers/$_paperId/document/blocks',
      ]);
    },
  );

  test(
    'semantic capability fetches and verifies detailed spans at document entry',
    () async {
      final adapter = _SnapshotAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      final snapshot = await DocumentApi(dio).fetchSnapshot(
        paperId: _paperId,
        versionKey: '2601.00001v7',
        expectedGeneration: 7,
        expectedAuthEpoch: 2,
        includePassport: false,
        includeSemanticFacets: true,
        includeVisualObjects: false,
      );

      expect(snapshot.semanticFacetsIncluded, isTrue);
      expect(snapshot.semanticSpans.single.blockId, _blockId);
      expect(
        snapshot.terms.single.definitions.single.sourceType.wireValue,
        'current_paper',
      );
      final request = adapter.requests.singleWhere(
        (value) => value.path.endsWith('/semantic-spans'),
      );
      expect(request.queryParameters, const {'density': 'detailed'});
    },
  );

  test(
    'semantic response is generation fenced and cancellation propagates',
    () async {
      final staleDio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = _SnapshotAdapter(semanticGeneration: 8);
      await expectLater(
        DocumentApi(staleDio).fetchSnapshot(
          paperId: _paperId,
          versionKey: '2601.00001v7',
          expectedGeneration: 7,
          expectedAuthEpoch: 2,
          includePassport: false,
          includeSemanticFacets: true,
          includeVisualObjects: false,
        ),
        throwsA(
          isA<ApiException>().having(
            (value) => value.code,
            'code',
            'INVALID_DOCUMENT_RESPONSE',
          ),
        ),
      );

      final adapter = _CancelableSnapshotAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final cancellation = RequestCancellation();
      final request = DocumentApi(dio).fetchSnapshot(
        paperId: _paperId,
        versionKey: '2601.00001v7',
        expectedGeneration: 7,
        expectedAuthEpoch: 2,
        includePassport: false,
        includeSemanticFacets: true,
        includeVisualObjects: false,
        cancellation: cancellation,
      );
      await adapter.semanticStarted.future;
      cancellation.cancel('Reader scope changed.');
      await expectLater(
        request,
        throwsA(
          isA<ApiException>().having(
            (value) => value.cancelled,
            'cancelled',
            isTrue,
          ),
        ),
      );
    },
  );

  test(
    'visual metadata performs zero requests until explicitly loaded',
    () async {
      final adapter = _SnapshotAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final api = DocumentApi(dio);

      await api.fetchSnapshot(
        paperId: _paperId,
        versionKey: '2601.00001v7',
        expectedGeneration: 7,
        expectedAuthEpoch: 2,
        includePassport: false,
        includeSemanticFacets: false,
        includeVisualObjects: false,
      );
      expect(
        adapter.requests.where(
          (request) =>
              request.path.endsWith('/figures') ||
              request.path.endsWith('/tables') ||
              request.path.endsWith('/equations'),
        ),
        isEmpty,
      );

      final objects = await api.fetchVisualObjects(
        paperId: _paperId,
        expectedGeneration: 7,
        expectedAuthEpoch: 2,
      );
      expect(objects.figures, hasLength(1));
      expect(objects.tables, hasLength(1));
      expect(objects.equations, hasLength(1));
      expect(
        adapter.requests.map((request) => request.path).toList().sublist(2),
        [
          '/v1/papers/$_paperId/figures',
          '/v1/papers/$_paperId/tables',
          '/v1/papers/$_paperId/equations',
        ],
      );
    },
  );

  test('snapshot rejects an unbounded retained block collection', () {
    expect(
      () => _snapshotWithBlocks(
        List.generate(
          documentSnapshotMaximumBlocks + 1,
          (index) => _modelBlock(index, 'Text'),
        ),
      ),
      throwsFormatException,
    );
  });

  test('snapshot rejects an unbounded aggregate text payload', () {
    final oneMiB = ''.padRight(1024 * 1024, 'x');
    expect(
      () => _snapshotWithBlocks(
        List.generate(9, (index) => _modelBlock(index, oneMiB)),
      ),
      throwsFormatException,
    );
  });

  test('figure availability fails closed for hostile encoded dimensions', () {
    final figure = DocumentFigure.fromJson({
      ..._object,
      'asset_available': true,
      'asset_requestable': true,
      'asset_url':
          '/v1/papers/$_paperId/figures/o1/asset?generation=7&revision=$_assetRevision',
      'width': 100000,
      'height': 100000,
      'extraction_status': 'ready',
    });

    expect(figure.assetAvailable, isFalse);
    expect(figure.assetUrl, isNull);
  });

  test('unprobed ready figure remains requestable with a cold hint', () {
    final figure = DocumentFigure.fromJson({
      ..._object,
      'asset_available': false,
      'asset_requestable': true,
      'asset_url':
          '/v1/papers/$_paperId/figures/o1/asset?generation=7&revision=$_assetRevision',
      'width': 640,
      'height': 480,
      'extraction_status': 'ready',
    });

    expect(figure.assetAvailable, isFalse);
    expect(figure.assetRequestable, isTrue);
    expect(figure.assetUrl, isNotNull);
  });

  test('table shape is rejected before eager cell decoding', () {
    expect(
      () => DocumentTable.fromJson({
        ..._object,
        'plain_text': 'bounded',
        'extraction_status': 'partial',
        'structure': {
          'schema_version': 'table-grid-v1',
          'rows': List.generate(maximumTableRows + 1, (_) => const []),
        },
      }),
      throwsFormatException,
    );
    expect(
      () => DocumentTable.fromJson({
        ..._object,
        'plain_text': 'bounded',
        'extraction_status': 'partial',
        'structure': {
          'schema_version': 'table-grid-v1',
          'rows': [
            List.generate(
              maximumTableColumns + 1,
              (_) => {
                'text': 'x',
                'header': false,
                'row_span': 1,
                'column_span': 1,
              },
            ),
          ],
        },
      }),
      throwsFormatException,
    );
  });

  test('decodes exact outline and every object DTO shape', () {
    final outline = DocumentOutline.fromJson({
      ..._envelope,
      'items': [
        {
          'block_id': _blockId,
          'stable_key': 's1',
          'ordinal': 0,
          'section_path': ['Methods'],
          'heading': 'Methods',
          'page_start': 3,
          'page_end': 4,
        },
      ],
    });
    expect(outline.sections.single.title, 'Methods');
    final figure = DocumentFigure.fromJson({
      ..._object,
      'asset_available': true,
      'asset_requestable': true,
      'asset_url':
          '/v1/papers/$_paperId/figures/o1/asset?generation=7&revision=$_assetRevision',
      'width': 640,
      'height': 480,
      'extraction_status': 'ready',
    });
    expect(figure.assetAvailable, isTrue);
    expect(figure.assetUrl, contains('generation=7'));
    final figureRoundTrip = DocumentFigure.fromJson(figure.toJson());
    expect(figureRoundTrip.assetAvailable, isTrue);
    expect(figureRoundTrip.width, 640);
    expect(figureRoundTrip.sourceLocator?.pageNumber, 3);
    expect(
      DocumentFigure.fromJson({
        ..._object,
        'asset_available': true,
        'asset_requestable': true,
        'asset_url': 'https://untrusted.example.test/figure.png',
        'extraction_status': 'caption_only',
      }).assetUrl,
      isNull,
    );
    final table = DocumentTable.fromJson({
      ..._object,
      'plain_text': 'A',
      'extraction_status': 'partial',
      'structure': {
        'schema_version': '1',
        'rows': [
          [
            {'text': 'A', 'header': true, 'row_span': 1, 'column_span': 1},
          ],
        ],
      },
    });
    expect(table.rows.single.single, 'A');
    expect(table.schemaVersion, '1');
    expect(table.structureRows.single.single.header, isTrue);
    expect(table.structureRows.single.single.rowSpan, 1);
    expect(table.structureRows.single.single.columnSpan, 1);
    final tableRoundTrip = DocumentTable.fromJson(table.toJson());
    expect(tableRoundTrip.plainText, 'A');
    expect(tableRoundTrip.structureRows.single.single.header, isTrue);
    expect(tableRoundTrip.sourceLocator?.pageNumber, 3);
    final equation = DocumentEquation.fromJson({
      ..._object,
      'confidence_status': 'supported',
      'latex': 'x=1',
      'context_block_id': _blockId,
    });
    expect(equation.contextBlockId, _blockId);
    final equationRoundTrip = DocumentEquation.fromJson(equation.toJson());
    expect(equationRoundTrip.contextBlockId, _blockId);
    expect(equationRoundTrip.sourceLocator?.pageNumber, 3);
    final term = PaperTerm.fromJson({
      'id': _termId,
      'normalized_term': 'term',
      'display_term': 'Term',
      'kind': 'term',
      'definition_status': 'available',
      'occurrences': [
        {
          'block_id': _blockId,
          'start_offset': 0,
          'end_offset': 4,
          'occurrence_ordinal': 1,
        },
      ],
      'definitions': [
        {
          'id': _definitionId,
          'source_type': 'current_paper',
          'source_block_ids': [_blockId],
          'definition': 'Definition',
          'confidence_status': 'supported',
        },
      ],
    });
    expect(
      term.definitions.single.sourceType,
      TermDefinitionSource.currentPaper,
    );
    expect(term.occurrences.single.occurrenceOrdinal, 1);
  });
}

const _paperId = '11111111-1111-4111-8111-111111111111';
const _assetRevision =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _blockId = '22222222-2222-4222-8222-222222222222';
const _termId = '33333333-3333-4333-8333-333333333333';
const _definitionId = '44444444-4444-4444-8444-444444444444';
const _semanticSpanId = '55555555-5555-4555-8555-555555555555';
const _semanticProvenanceId = '66666666-6666-4666-8666-666666666666';
const _semanticArtifactId = '77777777-7777-4777-8777-777777777777';
final _provenance = {
  'arxiv_version': 7,
  'parser_id': 'p',
  'parser_version': '1',
  'schema_version': '1',
  'document_hash': 'hash',
  'generated_at': '2026-08-31T00:00:00Z',
};
final _envelope = {
  'paper_id': _paperId,
  'generation': 7,
  'provenance': _provenance,
};
final _locator = {
  'source_element_id': 'src',
  'page_number': 3,
  'bounding_box': {'left': .1, 'top': .2, 'width': .3, 'height': .2},
};
final _block = {
  'id': _blockId,
  'stable_key': 's1',
  'ordinal': 0,
  'section_path': ['Methods'],
  'kind': 'paragraph',
  'text': 'Text',
  'page_start': 3,
  'page_end': 3,
  'source_locator': _locator,
  'content_hash': 'hash',
  'inline_spans': <Object>[],
};
final _object = {
  'id': 'o1',
  'label': 'Object 1',
  'ordinal': 0,
  'caption': 'Caption',
  'page_number': 3,
  'content_hash': 'hash',
  'source_locator': _locator,
};

final class _BlockAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        ..._envelope,
        'items': [_block],
        'next_cursor': options.queryParameters['cursor'] == null
            ? 'next'
            : null,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SnapshotAdapter implements HttpClientAdapter {
  _SnapshotAdapter({this.semanticGeneration = 7});

  final int semanticGeneration;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final payload = switch (options.path.split('/').last) {
      'outline' => {
        ..._envelope,
        'items': [
          {
            'block_id': _blockId,
            'stable_key': 's1',
            'ordinal': 0,
            'section_path': ['Methods'],
            'heading': 'Methods',
            'page_start': 3,
            'page_end': 3,
          },
        ],
      },
      'figures' => {
        ..._envelope,
        'items': [
          {
            ..._object,
            'asset_available': false,
            'asset_url': null,
            'extraction_status': 'caption_only',
          },
        ],
      },
      'tables' => {
        ..._envelope,
        'items': [
          {
            ..._object,
            'plain_text': 'A',
            'extraction_status': 'partial',
            'structure': {
              'schema_version': '1',
              'rows': [
                [
                  {
                    'text': 'A',
                    'header': true,
                    'row_span': 1,
                    'column_span': 1,
                  },
                ],
              ],
            },
          },
        ],
      },
      'equations' => {
        ..._envelope,
        'items': [
          {
            ..._object,
            'confidence_status': 'supported',
            'latex': 'x=1',
            'context_block_id': _blockId,
          },
        ],
      },
      'terms' => {
        ..._envelope,
        'items': [
          {
            'id': _termId,
            'normalized_term': 'text',
            'display_term': 'Text',
            'kind': 'term',
            'canonical_topic_id': null,
            'definition_status': 'available',
            'occurrences': [
              {
                'block_id': _blockId,
                'start_offset': 0,
                'end_offset': 4,
                'occurrence_ordinal': 0,
              },
            ],
            'definitions': [
              {
                'id': _definitionId,
                'source_type': 'current_paper',
                'source_block_ids': [_blockId],
                'definition': 'Prepared definition.',
                'model_id': null,
                'prompt_version': null,
                'confidence_status': 'supported',
              },
            ],
          },
        ],
      },
      'semantic-spans' => {
        ..._envelope,
        'generation': semanticGeneration,
        'density': 'detailed',
        'document_provenance': _provenance,
        'spans': [
          {
            'id': _semanticSpanId,
            'block_id': _blockId,
            'ordinal': 0,
            'start_offset': 0,
            'end_offset': 4,
            'facet': 'method',
            'minimum_density': 'key',
            'source_kind': 'deterministic',
            'confidence_basis_points': 8000,
            'support_status': 'supported',
            'provenance_id': _semanticProvenanceId,
            'created_at': '2026-08-31T00:00:00Z',
          },
        ],
        'provenance_records': [
          {
            'id': _semanticProvenanceId,
            'artifact_type': 'semantic_spans',
            'artifact_id': _semanticArtifactId,
            'paper_id': _paperId,
            'generation': 7,
            'activity_type': 'semantic_classification',
            'parser_id': 'p',
            'parser_version': '1',
            'model_provider': null,
            'model_id': null,
            'prompt_or_schema_version': '1',
            'input_entity_ids': [_blockId],
            'parameters': <String, Object?>{},
            'created_at': '2026-08-31T00:00:00Z',
            'superseded_by': null,
          },
        ],
      },
      _ => {
        ..._envelope,
        'items': [_block],
        'next_cursor': null,
      },
    };
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _CancelableSnapshotAdapter implements HttpClientAdapter {
  final semanticStarted = Completer<void>();
  final _delegate = _SnapshotAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/semantic-spans')) {
      if (!semanticStarted.isCompleted) semanticStarted.complete();
      await cancelFuture!;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error: 'cancelled',
      );
    }
    return _delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);
}

DocumentSnapshot _snapshotWithBlocks(Iterable<DocumentBlock> blocks) {
  const provenance = ProvenanceSummary(status: 'ready');
  return DocumentSnapshot(
    paperId: _paperId,
    versionKey: '2601.00001v7',
    generation: 7,
    outline: DocumentOutline(
      paperId: _paperId,
      generation: 7,
      sections: [],
      provenance: provenance,
    ),
    blocks: blocks,
    figures: const [],
    tables: const [],
    equations: const [],
    terms: const [],
    passport: null,
    provenance: provenance,
    fetchedAt: DateTime.utc(2026, 8, 31),
  );
}

DocumentBlock _modelBlock(int ordinal, String text) => DocumentBlock(
  id: 'block-$ordinal',
  paperId: _paperId,
  generation: 7,
  stableKey: 'section:paragraph:$ordinal',
  ordinal: ordinal,
  sectionPath: const ['Methods'],
  kind: DocumentBlockKind.paragraph,
  text: text,
  contentHash: 'hash-$ordinal',
);
