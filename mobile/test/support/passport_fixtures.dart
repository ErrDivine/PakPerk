import 'package:pakperk/core/models/paper_passport.dart';

const passportPaperId = '11111111-1111-4111-8111-111111111111';
const passportId = '22222222-2222-4222-8222-222222222222';
const passportProvenanceId = '33333333-3333-4333-8333-333333333333';
const passportOperationId = '44444444-4444-4444-8444-444444444444';
const passportEvaluationId = '55555555-5555-4555-8555-555555555555';
const passportAnonymousSessionId = '66666666-6666-4666-8666-666666666666';

Map<String, Object?> validPassportJson({String versionLabel = 'v7'}) {
  const generated = <String>{
    'research_question',
    'contribution',
    'method',
    'evaluation',
    'main_result',
    'limitations',
    'publication_status',
  };
  const inferred = <String>{'method', 'limitations'};
  const notApplicable = <String>{'code_resources'};
  final keys = passportFieldKeys.toList(growable: false);
  return {
    'id': passportId,
    'paper_id': passportPaperId,
    'generation': 7,
    'version_label': versionLabel,
    'schema_version': 'passport-v1',
    'status': 'ready',
    'parser_id': 'grobid-0.8',
    'model_id': 'pakperk-passport-1',
    'prompt_version': 'passport-prompt-v1',
    'provenance_id': passportProvenanceId,
    'fields': [
      for (final (index, key) in keys.indexed)
        {
          'id': '77777777-7777-4777-8777-${index.toString().padLeft(12, '0')}',
          'field_key': key,
          if (generated.contains(key))
            'value_text': key == 'method' ? null : 'Value for $key',
          if (key == 'method')
            'value_json': {
              'summary': 'A source-linked method',
              'steps': [1, 2],
            },
          'status': generated.contains(key)
              ? inferred.contains(key)
                    ? 'inferred'
                    : 'supported'
              : notApplicable.contains(key)
              ? 'not_applicable'
              : 'not_found',
          'source_block_ids': generated.contains(key)
              ? ['88888888-8888-4888-8888-${index.toString().padLeft(12, '0')}']
              : <String>[],
          'confidence_status': generated.contains(key)
              ? inferred.contains(key)
                    ? 'inferred'
                    : 'supported'
              : 'uncertain',
          'provenance_id':
              '99999999-9999-4999-8999-${index.toString().padLeft(12, '0')}',
          'created_at': '2026-08-31T10:00:00Z',
        },
    ],
    'provenance': {
      'id': passportProvenanceId,
      'status': 'ready',
      'parser_id': 'grobid-0.8',
      'model_id': 'pakperk-passport-1',
      'schema_version': 'passport-v1',
      'prompt_version': 'passport-prompt-v1',
      'created_at': '2026-08-31T10:00:00Z',
    },
    'created_at': '2026-08-31T10:00:00Z',
    'updated_at': '2026-08-31T10:05:00Z',
  };
}

PaperPassport validPassport({String versionLabel = 'v7'}) =>
    PaperPassport.fromJson(validPassportJson(versionLabel: versionLabel));
