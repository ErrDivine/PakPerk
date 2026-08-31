import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/evidence_card.dart';
import 'package:pakperk/core/models/research_memory.dart';

void main() {
  test('evidence decoder matches server Unicode-scalar bounds', () {
    final note = _scalar.repeat(evidenceCardNoteMaximumScalars);
    final card = EvidenceCard.fromJson({
      ..._evidenceJson,
      'title': _scalar.repeat(evidenceCardTitleMaximumScalars),
      'user_note': note,
    });

    expect(card.title.runes.length, evidenceCardTitleMaximumScalars);
    expect(card.userNote, note);
    expect(
      () => EvidenceCard.fromJson({
        ..._evidenceJson,
        'title': _scalar.repeat(evidenceCardTitleMaximumScalars + 1),
      }),
      throwsFormatException,
    );
    expect(
      () => EvidenceCard.fromJson({
        ..._evidenceJson,
        'user_note': _scalar.repeat(evidenceCardNoteMaximumScalars + 1),
      }),
      throwsFormatException,
    );
  });

  test('memory decoder accepts the complete server answer bound', () {
    final answer = _scalar.repeat(memoryAnswerMaximumScalars);
    final item = MemoryItem.fromJson({..._memoryJson, 'answer_text': answer});

    expect(item.answerText, answer);
    expect(item.answerText!.runes.length, memoryAnswerMaximumScalars);
    expect(
      () => MemoryItem.fromJson({
        ..._memoryJson,
        'answer_text': _scalar.repeat(memoryAnswerMaximumScalars + 1),
      }),
      throwsFormatException,
    );
  });

  test('memory decoder enforces the status and review-date invariant', () {
    for (final invalid in [
      {..._memoryJson, 'status': 'active', 'next_review_at': _timestamp},
      {..._memoryJson, 'status': 'retired', 'next_review_at': _timestamp},
      {..._memoryJson, 'status': 'snoozed', 'next_review_at': null},
    ]) {
      expect(() => MemoryItem.fromJson(invalid), throwsFormatException);
    }

    for (final date in ['2020-01-01T09:00:00Z', '2030-01-01T09:00:00Z']) {
      final item = MemoryItem.fromJson({
        ..._memoryJson,
        'status': 'snoozed',
        'next_review_at': date,
      });
      expect(item.status, MemoryStatus.snoozed);
      expect(item.nextReviewAt, DateTime.parse(date));
    }
  });
}

extension on String {
  String repeat(int count) => List.filled(count, this, growable: false).join();
}

const _scalar = '🧪';
const _paperId = '11111111-1111-4111-8111-111111111111';
const _artifactId = '22222222-2222-4222-8222-222222222222';
const _sourceId = '33333333-3333-4333-8333-333333333333';
const _timestamp = '2026-08-31T08:30:00Z';

const _evidenceJson = <String, Object?>{
  'id': _artifactId,
  'paper_id': _paperId,
  'generation': 3,
  'title': 'Verified source',
  'claim_or_question': null,
  'user_note': null,
  'source_block_ids': <String>[_sourceId],
  'figure_ids': <String>[],
  'table_ids': <String>[],
  'citation_context_ids': <String>[],
  'verification_status': 'user_selected',
  'revision': 9,
  'deleted_at': null,
  'created_at': _timestamp,
  'updated_at': _timestamp,
};

const _memoryJson = <String, Object?>{
  'id': _artifactId,
  'paper_id': _paperId,
  'generation': 3,
  'source_type': 'evidence_card',
  'source_id': _sourceId,
  'prompt_text': 'What should I remember?',
  'answer_text': 'The verified result.',
  'status': 'active',
  'next_review_at': null,
  'review_count': 1,
  'revision': 9,
  'deleted_at': null,
  'created_at': _timestamp,
  'updated_at': _timestamp,
};
