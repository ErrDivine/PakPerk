import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/provenance.dart';
import 'package:pakperk/core/models/semantic_span.dart';
import 'package:pakperk/features/semantic/definition_sheet.dart';
import 'package:pakperk/features/semantic/faceted_text.dart';

void main() {
  test('semantic envelope strictly accepts bounded detailed provenance', () {
    final envelope = SemanticSpansEnvelope.fromJson(
      _semanticEnvelope(spans: [_spanJson()]),
    );

    expect(envelope.paperId, _paperId);
    expect(envelope.density, SemanticDensity.detailed);
    expect(envelope.spans.single.facet, SemanticFacet.method);
    expect(
      envelope.spans.single.isValidForBlock(
        blockId: _blockId,
        scalarLength: 'A😀BC'.runes.length,
      ),
      isTrue,
    );
  });

  test(
    'semantic envelope rejects unknown enums, NULs, and fractional ranges',
    () {
      expect(
        () => SemanticSpansEnvelope.fromJson(
          _semanticEnvelope(spans: [_spanJson(facet: 'sentiment')]),
        ),
        throwsFormatException,
      );
      expect(
        () => SemanticSpansEnvelope.fromJson(
          _semanticEnvelope(spans: [_spanJson(startOffset: 0.5)]),
        ),
        throwsFormatException,
      );
      final nul = _semanticEnvelope(spans: [_spanJson()]);
      (nul['document_provenance']! as Map<String, Object?>)['parser_id'] =
          'parser\u0000hidden';
      expect(() => SemanticSpansEnvelope.fromJson(nul), throwsFormatException);
    },
  );

  test(
    'overlap resolution is deterministic and fails closed on bad ranges',
    () {
      final keyInferred = _span(
        id: _spanId,
        end: 8,
        facet: SemanticFacet.method,
        density: SemanticDensity.key,
        support: SemanticSupportStatus.inferred,
        confidence: 9000,
        ordinal: 0,
      );
      final detailedSupported = _span(
        id: _otherSpanId,
        end: 4,
        facet: SemanticFacet.limitation,
        density: SemanticDensity.detailed,
        support: SemanticSupportStatus.supported,
        confidence: 7000,
        ordinal: 1,
      );
      final invalidForBlock = _span(
        id: _thirdSpanId,
        end: 99,
        facet: SemanticFacet.evidence,
        density: SemanticDensity.key,
        support: SemanticSupportStatus.supported,
        confidence: 10000,
        ordinal: 2,
      );

      final detailed = resolveSemanticFacetSegments(
        blockId: _blockId,
        scalarLength: 8,
        spans: [keyInferred, detailedSupported, invalidForBlock],
        density: SemanticDensity.detailed,
      );
      expect(
        detailed
            .map((value) => (value.start, value.end, value.span.facet))
            .toList(),
        [(0, 4, SemanticFacet.limitation), (4, 8, SemanticFacet.method)],
      );

      final key = resolveSemanticFacetSegments(
        blockId: _blockId,
        scalarLength: 8,
        spans: [keyInferred, detailedSupported, invalidForBlock],
        density: SemanticDensity.key,
      );
      expect(key.single.span.facet, SemanticFacet.method);
      expect(
        resolveSemanticFacetSegments(
          blockId: _blockId,
          scalarLength: 8,
          spans: [keyInferred],
          density: SemanticDensity.off,
        ),
        isEmpty,
      );
    },
  );

  test(
    'snapshot cache preserves facets and all ordered definition sources',
    () {
      final snapshot = _snapshot();
      final restored = DocumentSnapshot.fromJson(snapshot.toJson());

      expect(restored.semanticFacetsIncluded, isTrue);
      expect(restored.semanticSpans.single.id, _spanId);
      expect(restored.terms.single.normalizedTerm, 'alpha');
      expect(restored.terms.single.canonicalTopicId, _topicId);
      expect(restored.terms.single.definitions, hasLength(4));
      expect(
        orderedTermDefinitions(
          restored.terms.single,
        ).map((value) => value.sourceType).toList(),
        [
          TermDefinitionSource.currentPaper,
          TermDefinitionSource.citedPaper,
          TermDefinitionSource.glossary,
          TermDefinitionSource.generated,
        ],
      );

      final legacy = Map<String, Object?>.from(snapshot.toJson())
        ..remove('semantic_spans');
      expect(
        DocumentSnapshot.fromJson(legacy).semanticFacetsIncluded,
        isFalse,
        reason: 'an old cache flag cannot claim a verified span payload',
      );
    },
  );
}

Map<String, dynamic> _semanticEnvelope({required List<Object?> spans}) => {
  'paper_id': _paperId,
  'generation': 7,
  'density': 'detailed',
  'document_provenance': {
    'arxiv_version': 7,
    'parser_id': 'grobid',
    'parser_version': '1.0',
    'schema_version': 'document-v2',
    'document_hash': 'abc123',
    'generated_at': '2026-08-31T00:00:00Z',
  },
  'spans': spans,
  'provenance_records': spans.isEmpty
      ? <Object?>[]
      : [
          {
            'id': _provenanceId,
            'artifact_type': 'semantic_spans',
            'artifact_id': _artifactId,
            'paper_id': _paperId,
            'generation': 7,
            'activity_type': 'semantic_classification',
            'parser_id': 'grobid',
            'parser_version': '1.0',
            'model_provider': null,
            'model_id': null,
            'prompt_or_schema_version': 'semantic-v1',
            'input_entity_ids': [_blockId],
            'parameters': <String, Object?>{},
            'created_at': '2026-08-31T00:00:00Z',
            'superseded_by': null,
          },
        ],
};

Map<String, Object?> _spanJson({
  Object startOffset = 1,
  Object endOffset = 2,
  String facet = 'method',
}) => {
  'id': _spanId,
  'block_id': _blockId,
  'ordinal': 0,
  'start_offset': startOffset,
  'end_offset': endOffset,
  'facet': facet,
  'minimum_density': 'key',
  'source_kind': 'deterministic',
  'confidence_basis_points': 8000,
  'support_status': 'supported',
  'provenance_id': _provenanceId,
  'created_at': '2026-08-31T00:00:00Z',
};

SemanticSpan _span({
  required String id,
  required int end,
  required SemanticFacet facet,
  required SemanticDensity density,
  required SemanticSupportStatus support,
  required int confidence,
  required int ordinal,
}) => SemanticSpan(
  id: id,
  blockId: _blockId,
  ordinal: ordinal,
  startOffset: 0,
  endOffset: end,
  facet: facet,
  minimumDensity: density,
  sourceKind: SemanticSpanSourceKind.deterministic,
  confidenceBasisPoints: confidence,
  supportStatus: support,
  provenanceId: _provenanceId,
  createdAt: DateTime.utc(2026, 8, 31),
);

DocumentSnapshot _snapshot() {
  const provenance = ProvenanceSummary(status: 'ready');
  final term = PaperTerm(
    id: _termId,
    displayTerm: 'Alpha',
    kind: PaperTermKind.term,
    definitionStatus: TermDefinitionStatus.available,
    sourceBlockIds: const [],
    occurrences: [
      TermOccurrence(blockId: _blockId, startOffset: 0, endOffset: 5),
    ],
    normalizedTerm: 'alpha',
    canonicalTopicId: _topicId,
    definitions: [
      _definition(
        _generatedDefinitionId,
        TermDefinitionSource.generated,
        const [],
      ),
      _definition(_glossaryDefinitionId, TermDefinitionSource.glossary, const [
        _blockId,
      ]),
      _definition(_citedDefinitionId, TermDefinitionSource.citedPaper, const [
        _blockId,
      ]),
      _definition(
        _currentDefinitionId,
        TermDefinitionSource.currentPaper,
        const [_blockId],
      ),
    ],
  );
  return DocumentSnapshot(
    paperId: _paperId,
    versionKey: '2608.00001v7',
    generation: 7,
    outline: DocumentOutline(
      paperId: _paperId,
      generation: 7,
      sections: const [],
      provenance: provenance,
    ),
    blocks: [
      DocumentBlock(
        id: _blockId,
        paperId: _paperId,
        generation: 7,
        stableKey: 'section:paragraph:0',
        ordinal: 0,
        sectionPath: const ['Methods'],
        kind: DocumentBlockKind.paragraph,
        text: 'Alpha 😀 result',
        contentHash: 'hash',
      ),
    ],
    figures: const [],
    tables: const [],
    equations: const [],
    terms: [term],
    semanticSpans: [
      _span(
        id: _spanId,
        end: 5,
        facet: SemanticFacet.method,
        density: SemanticDensity.key,
        support: SemanticSupportStatus.supported,
        confidence: 8000,
        ordinal: 0,
      ),
    ],
    passport: null,
    provenance: provenance,
    fetchedAt: DateTime.utc(2026, 8, 31),
    semanticFacetsIncluded: true,
  );
}

TermDefinition _definition(
  String id,
  TermDefinitionSource source,
  List<String> sourceIds,
) => TermDefinition(
  id: id,
  sourceType: source,
  sourceBlockIds: sourceIds,
  definition: '${source.label} definition.',
  confidenceStatus: source == TermDefinitionSource.generated
      ? TermDefinitionConfidence.inferred
      : TermDefinitionConfidence.supported,
  modelId: source == TermDefinitionSource.generated ? 'model' : null,
  promptVersion: source == TermDefinitionSource.generated ? 'v1' : null,
);

const _paperId = '11111111-1111-4111-8111-111111111111';
const _blockId = '22222222-2222-4222-8222-222222222222';
const _spanId = '33333333-3333-4333-8333-333333333333';
const _otherSpanId = '44444444-4444-4444-8444-444444444444';
const _thirdSpanId = '55555555-5555-4555-8555-555555555555';
const _provenanceId = '66666666-6666-4666-8666-666666666666';
const _artifactId = '77777777-7777-4777-8777-777777777777';
const _termId = '88888888-8888-4888-8888-888888888888';
const _topicId = '99999999-9999-4999-8999-999999999999';
const _currentDefinitionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _citedDefinitionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _glossaryDefinitionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _generatedDefinitionId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
