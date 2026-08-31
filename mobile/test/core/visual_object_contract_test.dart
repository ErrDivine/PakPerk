import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/assistant_v2.dart';
import 'package:pakperk/core/models/document_block.dart';

void main() {
  test(
    'object assistant scope is explicit and rejects non-UUID object IDs',
    () {
      final scope = AssistantRequestScope.object(
        kind: AssistantScopeKind.table,
        objectId: _objectId,
      );

      expect(scope.displayLabel, 'Table');
      expect(scope.toJson(), {
        'kind': 'table',
        'section_kinds': <String>[],
        'object_ids': [_objectId],
      });
      expect(
        () => AssistantRequestScope.object(
          kind: AssistantScopeKind.figure,
          objectId: '../private/asset',
        ),
        throwsArgumentError,
      );
      expect(
        () => AssistantRequestScope.object(
          kind: AssistantScopeKind.paper,
          objectId: _objectId,
        ),
        throwsArgumentError,
      );
    },
  );

  test('visual DTO retains exact referenced-by and typed table metadata', () {
    final table = DocumentTable.fromJson({
      'id': _objectId,
      'label': 'Table 1',
      'caption': 'Scores.',
      'page_number': 7,
      'source_block_ids': [_blockId],
      'referenced_by': [
        {
          'block_id': _blockId,
          'start_offset': 11,
          'end_offset': 18,
          'marker': 'Table 1',
          'context': 'Results in Table 1 support the conclusion.',
          'section_path': ['Results'],
          'page_number': 8,
        },
      ],
      'extraction_status': 'ready',
      'plain_text': 'Model\tScore\nA\t9\nNote: exact reported values.',
      'structure': {
        'schema_version': '1',
        'rows': [
          [
            {
              'text': 'Model and score',
              'header': true,
              'row_span': 1,
              'column_span': 2,
            },
          ],
          [
            {'text': 'A', 'header': false, 'row_span': 1, 'column_span': 1},
            {'text': '9', 'header': false, 'row_span': 1, 'column_span': 1},
          ],
        ],
      },
    });

    expect(table.sourceBlockIds, [_blockId]);
    expect(table.referencedBy.single.blockId, _blockId);
    expect(table.referencedBy.single.startOffset, 11);
    expect(table.referencedBy.single.endOffset, 18);
    expect(table.referencedBy.single.sectionLabel, 'Results');
    expect(table.referencedBy.single.pageNumber, 8);
    expect(table.structureRows.first.single.header, isTrue);
    expect(table.structureRows.first.single.columnSpan, 2);
    expect(table.plainText, contains('Note: exact reported values.'));
  });
}

const _objectId = '11111111-1111-4111-8111-111111111111';
const _blockId = '22222222-2222-4222-8222-222222222222';
