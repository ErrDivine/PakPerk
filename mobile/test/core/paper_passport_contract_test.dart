import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/paper_passport.dart';

import '../support/passport_fixtures.dart';

void main() {
  test('strict Passport retains artifact, field, and provenance identity', () {
    final passport = validPassport();

    expect(passport.id, passportId);
    expect(passport.paperId, passportPaperId);
    expect(passport.generation, 7);
    expect(passport.versionLabel, 'v7');
    expect(passport.schemaVersion, 'passport-v1');
    expect(passport.parserId, 'grobid-0.8');
    expect(passport.modelId, 'pakperk-passport-1');
    expect(passport.promptVersion, 'passport-prompt-v1');
    expect(passport.provenanceId, passportProvenanceId);
    expect(passport.provenance.recordId, passportProvenanceId);
    expect(passport.fields, hasLength(10));
    expect(passport.fields.every((field) => field.serverValidated), isTrue);
    expect(passport.createdAt, DateTime.utc(2026, 8, 31, 10));
    expect(passport.updatedAt, DateTime.utc(2026, 8, 31, 10, 5));
    expect(passport.isDisplayable, isTrue);

    final roundTrip = PaperPassport.fromJson(
      Map<String, dynamic>.from(passport.toJson()),
    );
    expect(roundTrip.id, passport.id);
    expect(
      roundTrip.fields.map((field) => field.id),
      passport.fields.map((field) => field.id),
    );
  });

  test('missing, duplicate, or contradictory fields fail closed', () {
    final missing = _copy(validPassportJson());
    (missing['fields'] as List).removeLast();
    expect(() => PaperPassport.fromJson(missing), throwsFormatException);

    final duplicate = _copy(validPassportJson());
    final fields = duplicate['fields'] as List;
    (fields.last as Map)['field_key'] = (fields.first as Map)['field_key'];
    expect(() => PaperPassport.fromJson(duplicate), throwsFormatException);

    final unsupportedWithNoEvidence = _copy(validPassportJson());
    final first = (unsupportedWithNoEvidence['fields'] as List).first as Map;
    first['source_block_ids'] = <Object?>[];
    expect(
      () => PaperPassport.fromJson(unsupportedWithNoEvidence),
      throwsFormatException,
    );
  });

  test('field text uses Unicode scalars and rejects NUL', () {
    final atLimit = _copy(validPassportJson());
    final first = (atLimit['fields'] as List).first as Map;
    first['value_text'] = List.filled(
      passportFieldTextMaximumScalars,
      '🦀',
    ).join();
    expect(() => PaperPassport.fromJson(atLimit), returnsNormally);

    first['value_text'] = '${first['value_text']}🦀';
    expect(() => PaperPassport.fromJson(atLimit), throwsFormatException);

    final nul = _copy(validPassportJson());
    ((nul['fields'] as List).first as Map)['value_text'] = 'unsafe\u0000text';
    expect(() => PaperPassport.fromJson(nul), throwsFormatException);
  });

  test('hostile nested structured values are rejected before display', () {
    final control = _copy(validPassportJson());
    final method = (control['fields'] as List).cast<Map>().firstWhere(
      (field) => field['field_key'] == 'method',
    );
    method['value_json'] = {
      'safe': [
        {'nested': 'unsafe\u0001control'},
      ],
    };
    expect(() => PaperPassport.fromJson(control), throwsFormatException);

    final nonFinite = _copy(validPassportJson());
    final nonFiniteMethod = (nonFinite['fields'] as List)
        .cast<Map>()
        .firstWhere((field) => field['field_key'] == 'method');
    nonFiniteMethod['value_json'] = {'score': double.infinity};
    expect(() => PaperPassport.fromJson(nonFinite), throwsFormatException);

    Object deep = 'leaf';
    for (var index = 0; index < 18; index += 1) {
      deep = [deep];
    }
    final excessiveDepth = _copy(validPassportJson());
    final deepMethod = (excessiveDepth['fields'] as List)
        .cast<Map>()
        .firstWhere((field) => field['field_key'] == 'method');
    deepMethod['value_json'] = deep;
    expect(() => PaperPassport.fromJson(excessiveDepth), throwsFormatException);
  });

  test('Passport version must match the selected exact arXiv version', () {
    final passport = validPassport();
    expect(passportVersionMatchesVersionKey(passport, '2601.00001v7'), isTrue);
    expect(passportVersionMatchesVersionKey(passport, '2601.00001v8'), isFalse);
    expect(passportVersionMatchesVersionKey(passport, '2601.00001'), isFalse);
  });
}

Map<String, dynamic> _copy(Map<String, Object?> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
