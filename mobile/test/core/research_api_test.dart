import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/evidence_card.dart';
import 'package:pakperk/core/models/research_memory.dart';
import 'package:pakperk/core/models/version_diff.dart';
import 'package:pakperk/core/research/research_api.dart';

void main() {
  test(
    'annotation conflict uses exact idempotency contract and retains bodies',
    () async {
      final adapter = _ResearchAdapter(annotationConflict: true);
      final api = ResearchApi(_dio(adapter));
      final annotation = Annotation.fromJson(_annotation());
      final result = await api.putAnnotation(
        write: AnnotationWrite(
          annotation: annotation,
          operationId: operationId,
          baseRevision: 3,
          resolvesConflictId: conflictId,
        ),
        expectedAuthEpoch: 9,
      );

      expect(adapter.requests.single.path, '/v1/annotations/$annotationId');
      expect(adapter.requests.single.headers['Idempotency-Key'], operationId);
      expect(
        (adapter.requests.single.data as Map)['operation_id'],
        operationId,
      );
      expect(
        (adapter.requests.single.data as Map)['resolves_conflict_id'],
        conflictId,
      );
      expect(result, isA<AnnotationMutationConflict>());
      final conflict = (result as AnnotationMutationConflict).conflict;
      expect(conflict.attemptedBody, 'my note');
      expect(conflict.serverBody, 'server note');
    },
  );

  test(
    'typed pages, versions, diff, and bounded export decode exact routes',
    () async {
      final adapter = _ResearchAdapter();
      final api = ResearchApi(_dio(adapter));

      final annotations = await api.listAnnotations(
        expectedAuthEpoch: 9,
        paperId: paperId,
      );
      expect(annotations.items.single.selector!.exact, 'exact source');
      expect(annotations.syncRevision, 4);

      final conflicts = await api.listAnnotationConflicts(expectedAuthEpoch: 9);
      expect(conflicts.items.single.conflict.serverRevision, 4);
      expect(conflicts.items.single.currentAnnotationRevision, 8);
      expect(conflicts.items.single.paperId, paperId);
      expect(conflicts.syncRevision, 8);

      final evidence = await api.listEvidenceCards(
        expectedAuthEpoch: 9,
        paperId: paperId,
      );
      expect(
        evidence.items.single.verificationStatus,
        EvidenceVerificationStatus.userReviewed,
      );

      final memory = await api.listMemoryReview(expectedAuthEpoch: 9);
      expect(memory.items.single.sourceType, MemorySourceType.evidenceCard);

      final versions = await api.listVersions(
        paperId: paperId,
        expectedAuthEpoch: 9,
      );
      expect(versions, hasLength(2));
      expect(
        versions.last.sourceAbsUrl.toString(),
        'https://arxiv.org/abs/2601.00001v2',
      );

      final diff = await api.getVersionDiff(
        paperId: paperId,
        fromGeneration: 1,
        toGeneration: 2,
        expectedAuthEpoch: 9,
      );
      expect(diff.parserChangeUncertainty, isTrue);
      expect(diff.items.single.confidenceStatus.name, 'uncertain');
      expect(
        diff.fromSourceAbsUrl.toString(),
        'https://arxiv.org/abs/2601.00001v1',
      );
      expect(
        diff.toSourceAbsUrl.toString(),
        'https://arxiv.org/abs/2601.00001v2',
      );
      expect(diff.items.single.oldSource?.generation, 1);
      expect(diff.items.single.oldSource?.exactPageNumber, 3);
      expect(
        diff.items.single.oldSource?.preferredSourceUrl.toString(),
        'https://arxiv.org/pdf/2601.00001v1#page=3',
      );
      expect(diff.items.single.newSource?.generation, 2);
      expect(diff.items.single.newSource?.exactPageNumber, 4);

      final export = await api.exportResearch(
        format: ResearchExportFormat.markdown,
        expectedAuthEpoch: 9,
        paperId: paperId,
      );
      expect(utf8.decode(export.bytes), '# Bounded research export');
      expect(export.fileName, 'pakperk-research-export.md');
      expect(export.mimeType, 'text/markdown');

      final imported = await api.importAnnotations(
        archive: const {
          'schema_version': 'pakperk.research-export.v1',
          'annotations': <Object?>[],
          'annotation_conflicts': <Object?>[],
          'annotation_reanchor_attempts': <Object?>[],
        },
        operationId: operationId,
        expectedAuthEpoch: 9,
      );
      expect(imported.importedAnnotations, 2);
      expect(imported.importedConflicts, 1);
      final importRequest = adapter.requests.last;
      expect(importRequest.path, '/v1/annotations/import');
      expect(importRequest.headers['Idempotency-Key'], operationId);
    },
  );

  test(
    'retained-version source URLs reject hostile authority and suffixes',
    () {
      final cases = <(String, String, bool)>[
        (
          'https://attacker@arxiv.org/abs/2601.00001v1',
          'source_abs_url',
          false,
        ),
        ('https://arxiv.org:444/abs/2601.00001v1', 'source_abs_url', false),
        (
          'https://arxiv.org/abs/2601.00001v1?download=1',
          'source_abs_url',
          false,
        ),
        ('https://arxiv.org/abs/2601.00001v1#page=3', 'source_abs_url', false),
        ('https://attacker@arxiv.org/pdf/2601.00001v1', 'source_pdf_url', true),
        ('https://arxiv.org:444/pdf/2601.00001v1', 'source_pdf_url', true),
        (
          'https://arxiv.org/pdf/2601.00001v1?download=1',
          'source_pdf_url',
          true,
        ),
        ('https://arxiv.org/pdf/2601.00001v1#page=3', 'source_pdf_url', true),
        (
          'https://attacker@arxiv.org/pdf/2601.00001v1#page=3',
          'source_page_url',
          true,
        ),
        (
          'https://arxiv.org:444/pdf/2601.00001v1#page=3',
          'source_page_url',
          true,
        ),
        (
          'https://arxiv.org/pdf/2601.00001v1?download=1#page=3',
          'source_page_url',
          true,
        ),
        (
          'https://arxiv.org/pdf/2601.00001v1#page=3&object=1',
          'source_page_url',
          true,
        ),
      ];

      for (final (url, field, nested) in cases) {
        final payload = _diff();
        if (nested) {
          final items = payload['items']! as List<Object?>;
          final item = items.single as Map<String, Object?>;
          final source = item['old_source']! as Map<String, Object?>;
          source[field] = url;
        } else {
          payload['from_$field'] = url;
        }
        expect(
          () => PaperVersionDiff.fromJson(payload),
          throwsFormatException,
          reason: '$field must reject $url',
        );
      }
    },
  );

  test(
    'export content type defaults only when absent and rejects mismatch',
    () async {
      final withoutHeader = ResearchApi(
        _dio(_ResearchAdapter(exportContentType: null)),
      );
      final defaulted = await withoutHeader.exportResearch(
        format: ResearchExportFormat.json,
        expectedAuthEpoch: 9,
      );
      expect(defaulted.mimeType, 'application/json');

      final mismatched = ResearchApi(_dio(_ResearchAdapter()));
      await expectLater(
        () => mismatched.exportResearch(
          format: ResearchExportFormat.json,
          expectedAuthEpoch: 9,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_RESEARCH_RESPONSE',
          ),
        ),
      );
    },
  );

  test('paged export preserves the opaque continuation contract', () async {
    final adapter = _ResearchAdapter(
      exportNextCursor: 'opaque-next-token',
      exportPageNumber: 4,
    );
    final api = ResearchApi(_dio(adapter));

    final page = await api.exportResearch(
      format: ResearchExportFormat.markdown,
      expectedAuthEpoch: 9,
      paperId: paperId,
      cursor: 'opaque-current-token',
    );

    expect(adapter.requests.single.queryParameters, {
      'format': 'markdown',
      'paper_id': paperId,
      'paged': true,
      'cursor': 'opaque-current-token',
    });
    expect(page.nextCursor, 'opaque-next-token');
    expect(page.pageNumber, 4);
    expect(page.isComplete, isFalse);
  });

  test('retained-version source identities must match exact versions', () {
    final mismatchedPdf = _version(1);
    mismatchedPdf['source_pdf_url'] = 'https://arxiv.org/pdf/2601.00001v2';
    expect(
      () => DocumentVersion.fromJson(mismatchedPdf),
      throwsFormatException,
    );

    final mismatchedOldVersion = _diff();
    mismatchedOldVersion['from_source_abs_url'] =
        'https://arxiv.org/abs/2601.00001v9';
    expect(
      () => PaperVersionDiff.fromJson(mismatchedOldVersion),
      throwsFormatException,
    );

    final differentPaper = _diff();
    differentPaper['to_source_abs_url'] = 'https://arxiv.org/abs/2601.99999v2';
    expect(
      () => PaperVersionDiff.fromJson(differentPaper),
      throwsFormatException,
    );
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _ResearchAdapter implements HttpClientAdapter {
  _ResearchAdapter({
    this.annotationConflict = false,
    this.exportContentType = 'text/markdown; charset=utf-8',
    this.exportNextCursor,
    this.exportPageNumber,
  });

  final bool annotationConflict;
  final String? exportContentType;
  final String? exportNextCursor;
  final int? exportPageNumber;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path == '/v1/annotations/export') {
      return ResponseBody.fromBytes(
        utf8.encode('# Bounded research export'),
        200,
        headers: {
          if (exportContentType case final value?)
            Headers.contentTypeHeader: [value],
          'content-disposition': [
            'attachment; filename=pakperk-research-export.md',
          ],
          if (exportNextCursor case final value?)
            'x-pakperk-export-next-cursor': [value],
          if (exportPageNumber case final value?)
            'x-pakperk-export-page': ['$value'],
        },
      );
    }
    final (status, body) = switch ((options.method, options.path)) {
      ('PUT', '/v1/annotations/$annotationId') when annotationConflict => (
        409,
        {
          'conflict': {
            'conflict_id': conflictId,
            'annotation_id': annotationId,
            'attempted_operation_id': operationId,
            'base_revision': 3,
            'server_revision': 4,
            'attempted_body': 'my note',
            'server_body': 'server note',
            'created_at': timestamp,
          },
        },
      ),
      ('GET', '/v1/annotations') => (
        200,
        {
          'items': [_annotation()],
          'next_after_revision': 4,
          'has_more': false,
          'sync_revision': 4,
          'purged_through_revision': 0,
        },
      ),
      ('GET', '/v1/annotation-conflicts') => (
        200,
        {
          'items': [
            {
              'conflict': {
                'conflict_id': conflictId,
                'annotation_id': annotationId,
                'attempted_operation_id': operationId,
                'base_revision': 3,
                'server_revision': 4,
                'attempted_body': 'my note',
                'server_body': 'server note',
                'created_at': timestamp,
                'resolution': null,
                'merged_body': null,
                'resolved_at': null,
              },
              'paper_id': paperId,
              'current_annotation_revision': 8,
            },
          ],
          'next_cursor': null,
          'sync_revision': 8,
        },
      ),
      ('GET', '/v1/evidence-cards') => (
        200,
        {
          'items': [_evidence()],
          'next_cursor': null,
          'sync_revision': 2,
        },
      ),
      ('GET', '/v1/memory/review') => (
        200,
        {
          'items': [_memory()],
          'next_cursor': null,
          'sync_revision': 1,
        },
      ),
      ('GET', '/v1/papers/$paperId/versions') => (
        200,
        {
          'paper_id': paperId,
          'items': [_version(1), _version(2)],
        },
      ),
      ('POST', '/v1/annotations/import') => (
        200,
        {
          'imported_annotations': 2,
          'imported_conflicts': 1,
          'imported_reanchor_attempts': 1,
          'skipped_annotations': 3,
          'replayed': false,
        },
      ),
      ('GET', '/v1/papers/$paperId/version-diff') => (200, _diff()),
      _ => throw StateError('Unexpected ${options.method} ${options.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _annotation() => {
  'id': annotationId,
  'paper_id': paperId,
  'generation': 2,
  'block_id': blockId,
  'kind': 'note',
  'body': 'my note',
  'color_role': 'blue',
  'selector': {
    'type': 'TextQuoteAndPosition',
    'exact': 'exact source',
    'prefix': 'before ',
    'suffix': ' after',
    'start': 7,
    'end': 19,
  },
  'section_hint': ['Methods'],
  'page_hint': 2,
  'anchor_status': 'anchored',
  'revision': 3,
  'deleted_at': null,
  'created_at': timestamp,
  'updated_at': timestamp,
};

Map<String, Object?> _evidence() => {
  'id': evidenceId,
  'paper_id': paperId,
  'generation': 2,
  'title': 'Supported result',
  'claim_or_question': 'exact source',
  'user_note': 'Reviewed against the source.',
  'source_block_ids': [blockId],
  'figure_ids': <String>[],
  'table_ids': <String>[],
  'citation_context_ids': <String>[],
  'verification_status': 'user_reviewed',
  'revision': 2,
  'deleted_at': null,
  'created_at': timestamp,
  'updated_at': timestamp,
};

Map<String, Object?> _memory() => {
  'id': memoryId,
  'paper_id': paperId,
  'generation': 2,
  'source_type': 'evidence_card',
  'source_id': evidenceId,
  'prompt_text': 'Which result was supported?',
  'answer_text': 'The selected result.',
  'status': 'active',
  'next_review_at': null,
  'review_count': 1,
  'revision': 1,
  'deleted_at': null,
  'created_at': timestamp,
  'updated_at': timestamp,
};

Map<String, Object?> _version(int version) => {
  'generation': version,
  'arxiv_version': version,
  'arxiv_id': '2601.00001v$version',
  'source_abs_url': 'https://arxiv.org/abs/2601.00001v$version',
  'source_pdf_url': 'https://arxiv.org/pdf/2601.00001v$version',
  'schema_version': 'document.v1',
  'parser_id': version == 1 ? 'parser-a' : 'parser-b',
  'parser_version': '1.$version',
  'document_hash': 'hash-$version',
  'is_current': version == 2,
  'generated_at': timestamp,
};

Map<String, Object?> _diff() => {
  'id': diffId,
  'paper_id': paperId,
  'from_generation': 1,
  'to_generation': 2,
  'from_arxiv_version': 1,
  'to_arxiv_version': 2,
  'from_source_abs_url': 'https://arxiv.org/abs/2601.00001v1',
  'to_source_abs_url': 'https://arxiv.org/abs/2601.00001v2',
  'algorithm_version': 'diff.v1',
  'schema_version': 'document.v1',
  'from_parser_id': 'parser-a',
  'from_parser_version': '1.1',
  'to_parser_id': 'parser-b',
  'to_parser_version': '1.2',
  'parser_change_uncertainty': true,
  'status': 'ready',
  'summary': {
    'added': 0,
    'removed': 0,
    'modified': 1,
    'moved': 0,
    'warnings': ['Parser changed'],
  },
  'failure_code': null,
  'items': [
    {
      'id': diffItemId,
      'ordinal': 0,
      'kind': 'block',
      'old_object_id': blockId,
      'new_object_id': newBlockId,
      'change_type': 'modified',
      'similarity': .82,
      'old_content_hash': 'old-hash',
      'new_content_hash': 'new-hash',
      'confidence_status': 'uncertain',
      'old_source': _diffSource(
        objectId: blockId,
        generation: 1,
        version: 1,
        page: 3,
      ),
      'new_source': _diffSource(
        objectId: newBlockId,
        generation: 2,
        version: 2,
        page: 4,
      ),
    },
  ],
  'created_at': timestamp,
  'completed_at': timestamp,
};

Map<String, Object?> _diffSource({
  required String objectId,
  required int generation,
  required int version,
  required int page,
}) => {
  'object_id': objectId,
  'generation': generation,
  'page_start': page,
  'page_end': page,
  'source_locator': {
    'source_element_id': 'page-$page-object',
    'page_number': page,
    'bounding_box': null,
  },
  'source_abs_url': 'https://arxiv.org/abs/2601.00001v$version',
  'source_pdf_url': 'https://arxiv.org/pdf/2601.00001v$version',
  'source_page_url': 'https://arxiv.org/pdf/2601.00001v$version#page=$page',
};

const timestamp = '2026-08-31T12:00:00Z';
const paperId = '00000000-0000-4000-8000-000000000001';
const annotationId = '00000000-0000-4000-8000-000000000002';
const evidenceId = '00000000-0000-4000-8000-000000000003';
const memoryId = '00000000-0000-4000-8000-000000000004';
const blockId = '00000000-0000-4000-8000-000000000005';
const newBlockId = '00000000-0000-4000-8000-000000000006';
const operationId = '00000000-0000-7000-8000-000000000007';
const conflictId = '00000000-0000-4000-8000-000000000008';
const diffId = '00000000-0000-4000-8000-000000000009';
const diffItemId = '00000000-0000-4000-8000-000000000010';
