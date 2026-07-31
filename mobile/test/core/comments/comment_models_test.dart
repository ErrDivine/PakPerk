import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/comments/comment_models.dart';

void main() {
  test('URL mirror counts punctuation-adjacent mixed-case schemes', () {
    expect(
      validateCommentBody(
        '(HTTPS://one.test),http://two.test;HTTPS://three.test!'
        'then-http://four.test',
      ),
      'Comments may contain at most three links.',
    );
    expect(
      validateCommentBody(
        '(HTTPS://one.test),http://two.test;HTTPS://three.test!',
      ),
      isNull,
    );
  });

  test('comment parser rejects unknown fields and unsafe controls', () {
    final json = _commentJson();
    expect(
      () => PaperComment.fromJson({...json, 'moderation_score': 0}),
      throwsFormatException,
    );
    expect(
      () => PaperComment.fromJson({...json, 'body': 'unsafe\u0000body'}),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _commentJson() => {
  'id': '018f47a6-4b56-7f4c-8c7a-e2656e820011',
  'paper_id': '018f47a6-4b56-7f4c-8c7a-e2656e820021',
  'author': {
    'id': '018f47a6-4b56-7f4c-8c7a-e2656e820001',
    'handle': 'ada_reader',
    'display_name': 'Ada',
    'status': 'active',
  },
  'body': 'A plain comment.',
  'status': 'published',
  'version': 1,
  'created_at': '2026-07-30T10:00:00Z',
  'updated_at': '2026-07-30T10:00:00Z',
  'edited_at': null,
};
