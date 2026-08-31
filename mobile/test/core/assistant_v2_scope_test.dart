import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/assistant_v2.dart';

void main() {
  test('closed Assistant scopes serialize to the exact server contract', () {
    expect(const AssistantRequestScope.paper().toJson(), {
      'kind': 'paper',
      'section_kinds': <String>[],
      'object_ids': <String>[],
    });
    expect(
      AssistantRequestScope.section(
        kinds: const [
          AssistantSectionKind.relatedWork,
          AssistantSectionKind.result,
        ],
      ).toJson(),
      {
        'kind': 'section',
        'section_kinds': ['related_work', 'result'],
        'object_ids': <String>[],
      },
    );
    expect(
      AssistantRequestScope.selection(
        blockId: _blockId,
        start: 4,
        end: 11,
      ).toJson(),
      {
        'kind': 'selection',
        'section_kinds': <String>[],
        'object_ids': <String>[],
        'selection': {'block_id': _blockId, 'start': 4, 'end': 11},
      },
    );
    expect(AssistantRequestScope.passportField('main_result').toJson(), {
      'kind': 'passport_field',
      'section_kinds': <String>[],
      'object_ids': <String>[],
      'passport_field': 'main_result',
    });
    expect(
      AssistantRequestScope.object(
        kind: AssistantScopeKind.equation,
        objectId: _objectId,
      ).toJson(),
      {
        'kind': 'equation',
        'section_kinds': <String>[],
        'object_ids': [_objectId],
      },
    );
    expect(AssistantAnswerStyle.beginner.wireValue, 'beginner');
    expect(AssistantAnswerStyle.expert.wireValue, 'expert');
  });

  test('Assistant scopes fail closed before transport', () {
    expect(
      () => AssistantRequestScope.section(kinds: const []),
      throwsArgumentError,
    );
    expect(
      () => AssistantRequestScope.section(
        kinds: const [AssistantSectionKind.method, AssistantSectionKind.method],
      ),
      throwsArgumentError,
    );
    expect(
      () => AssistantRequestScope.section(
        kinds: AssistantSectionKind.values.take(13),
      ),
      throwsArgumentError,
    );
    expect(
      () =>
          AssistantRequestScope.selection(blockId: _blockId, start: 8, end: 8),
      throwsArgumentError,
    );
    expect(
      () => AssistantRequestScope.selection(
        blockId: 'not-a-uuid',
        start: 1,
        end: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => AssistantRequestScope.passportField('Main Result'),
      throwsArgumentError,
    );
    expect(
      () => AssistantRequestScope.object(
        kind: AssistantScopeKind.passportField,
        objectId: _objectId,
      ),
      throwsArgumentError,
    );
  });
}

const _blockId = '11111111-1111-4111-8111-111111111111';
const _objectId = '22222222-2222-4222-8222-222222222222';
