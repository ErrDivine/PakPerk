import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/comments/comment_models.dart';

void main() {
  test('comment normalization mirrors the authoritative server pipeline', () {
    expect(
      normalizeCommentDraft('  Ａ useful point\r\n\r\n\r\nnext\tline  '),
      'A useful point\n\nnext line',
    );
    expect(normalizeCommentDraft('one\n \n\t\n\n two'), 'one\n\n two');
    expect(normalizeCommentDraft('  \n '), isEmpty);
  });

  test('app-owned Unicode normalization sanity vectors stay canonical', () {
    expect(normalizeCommentDraft('\u212b'), '\u00c5');
    expect(normalizeCommentDraft('\u1100\u1161'), '\uac00');
  });

  test('raw draft ceiling bounds normalization work before NFKC', () {
    final atLimit = _repeat('x', commentMaximumRawCodeUnits);
    final overLimit = '${atLimit}x';

    expect(commentDraftWithinRawLimit(atLimit), isTrue);
    expect(commentDraftWithinRawLimit(overLimit), isFalse);
    expect(validateCommentDraftInput(atLimit), isNull);
    expect(
      validateCommentDraftInput(overLimit),
      commentRawInputTooLargeMessage,
    );
    expect(validateCommentBody(overLimit), commentRawInputTooLargeMessage);
    expect(() => normalizeCommentDraft(overLimit), throwsArgumentError);
  });

  test('raw ceiling preserves widest valid scalar boundaries', () {
    final supplementary = _repeat('😀', commentMaximumScalars);
    final decomposedHangul = _repeat(
      '\u1100\u1161\u11a8',
      commentMaximumScalars,
    );

    expect(supplementary.length, commentMaximumScalars * 2);
    expect(validateCommentDraftInput(supplementary), isNull);
    expect(validateCommentBody(supplementary), isNull);
    expect(decomposedHangul.length, commentMaximumRawCodeUnits);
    expect(validateCommentDraftInput(decomposedHangul), isNull);
    expect(validateCommentBody(decomposedHangul), isNull);
    expect(normalizedCommentScalarCount(decomposedHangul), 2000);
  });

  test('pathological combining cluster fails before quadratic NFKC work', () {
    final boundaryCluster = 'a${_repeat('\u0301', 63)}';
    final overlongCluster = 'a${_repeat('\u0301', 64)}';
    final adversarial = _repeat('\u0301', commentMaximumRawCodeUnits);

    expect(boundaryCluster.length, commentMaximumRawClusterCodeUnits);
    expect(validateCommentDraftInput(boundaryCluster), isNull);
    expect(overlongCluster.length, commentMaximumRawClusterCodeUnits + 1);
    expect(
      validateCommentDraftInput(overlongCluster),
      commentComplexTextMessage,
    );
    expect(validateCommentDraftInput(adversarial), commentComplexTextMessage);
    expect(validateCommentBody(adversarial), commentComplexTextMessage);
    expect(() => normalizeCommentDraft(adversarial), throwsArgumentError);
  });

  test('lone UTF-16 surrogates are rejected before normalization', () {
    final loneHigh = String.fromCharCode(0xd800);
    final loneLow = String.fromCharCode(0xdc00);

    for (final value in ['before$loneHigh', '${loneLow}after']) {
      expect(
        validateCommentDraftInput(value),
        commentUnsupportedCharactersMessage,
      );
      expect(validateCommentBody(value), commentUnsupportedCharactersMessage);
      expect(() => normalizeCommentDraft(value), throwsArgumentError);
    }
    expect(validateCommentDraftInput('valid 😀 pair'), isNull);
  });

  test('comment limits use NFKC-normalized Unicode scalar values', () {
    final ligatures = _repeat('\ufb00', 1500);
    expect(ligatures.runes.length, 1500);
    expect(normalizedCommentScalarCount(ligatures), 3000);
    expect(
      validateCommentBody(ligatures),
      'Comments are limited to 2000 characters.',
    );

    expect(validateCommentBody(_repeat('x', 2000)), isNull);
    expect(
      validateCommentBody(_repeat('x', 2001)),
      'Comments are limited to 2000 characters.',
    );
    expect(utf8.encode(_repeat('😀', 2000)).length, commentMaximumBytes);
    expect(validateCommentBody(_repeat('😀', 2000)), isNull);
  });

  test('comment validation rejects server-forbidden format controls', () {
    for (final value in <String>[
      'direction\u202eoverride',
      'zero\u200bwidth',
      'isolate\u2066text',
      'mark\u061ctext',
      'bom\ufefftext',
      'control\u0007text',
    ]) {
      expect(
        validateCommentDraftInput(value),
        commentUnsupportedCharactersMessage,
        reason: value.runes.map((rune) => rune.toRadixString(16)).join(' '),
      );
      expect(
        validateCommentBody(value),
        commentUnsupportedCharactersMessage,
        reason: value.runes.map((rune) => rune.toRadixString(16)).join(' '),
      );
      expect(() => normalizedCommentScalarCount(value), throwsArgumentError);
    }
    expect(validateCommentDraftInput('line one\r\nline two\tvalue'), isNull);
    expect(validateCommentBody('line one\r\nline two\tvalue'), isNull);
  });

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
    expect(
      () => PaperComment.fromJson({...json, 'body': 'direction\u202eoverride'}),
      throwsFormatException,
    );
    expect(
      () => PaperComment.fromJson({...json, 'body': 'fullwidth Ａ'}),
      throwsFormatException,
    );
  });
}

String _repeat(String value, int count) => List.filled(count, value).join();

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
