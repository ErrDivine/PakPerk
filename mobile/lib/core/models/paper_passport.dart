import 'dart:convert';

import 'provenance.dart';

const passportFieldTextMaximumScalars = 10000;
const passportFeedbackMaximumScalars = 2000;
const passportMaximumSourceBlocks = 64;

enum PassportStatus {
  draft,
  ready,
  partial,
  failed;

  String get wireValue => name;

  static PassportStatus fromWire(Object? value) => switch (value) {
    'draft' => PassportStatus.draft,
    'ready' => PassportStatus.ready,
    'partial' => PassportStatus.partial,
    'failed' => PassportStatus.failed,
    _ => throw const FormatException('Invalid Passport status.'),
  };
}

enum PassportFieldStatus {
  supported,
  inferred,
  notFound,
  notApplicable,
  conflicting;

  String get wireValue => switch (this) {
    PassportFieldStatus.supported => 'supported',
    PassportFieldStatus.inferred => 'inferred',
    PassportFieldStatus.notFound => 'not_found',
    PassportFieldStatus.notApplicable => 'not_applicable',
    PassportFieldStatus.conflicting => 'conflicting',
  };

  static PassportFieldStatus fromWire(Object? value) => switch (value) {
    'supported' => PassportFieldStatus.supported,
    'inferred' => PassportFieldStatus.inferred,
    'not_found' => PassportFieldStatus.notFound,
    'not_applicable' => PassportFieldStatus.notApplicable,
    'conflicting' => PassportFieldStatus.conflicting,
    _ => throw const FormatException('Invalid Passport field status.'),
  };
}

enum PassportConfidenceStatus {
  supported,
  inferred,
  uncertain;

  String get wireValue => name;

  static PassportConfidenceStatus fromWire(Object? value) => switch (value) {
    'supported' => PassportConfidenceStatus.supported,
    'inferred' => PassportConfidenceStatus.inferred,
    'uncertain' => PassportConfidenceStatus.uncertain,
    _ => throw const FormatException('Invalid Passport confidence status.'),
  };
}

enum PassportFeedbackType {
  wrongField,
  misleadingCompression,
  wrongEvidence,
  missingLimitation,
  parserIssue;

  String get wireValue => switch (this) {
    PassportFeedbackType.wrongField => 'wrong_field',
    PassportFeedbackType.misleadingCompression => 'misleading_compression',
    PassportFeedbackType.wrongEvidence => 'wrong_evidence',
    PassportFeedbackType.missingLimitation => 'missing_limitation',
    PassportFeedbackType.parserIssue => 'parser_issue',
  };

  String get displayLabel => switch (this) {
    PassportFeedbackType.wrongField => 'Wrong field',
    PassportFeedbackType.misleadingCompression => 'Misleading summary',
    PassportFeedbackType.wrongEvidence => 'Wrong evidence',
    PassportFeedbackType.missingLimitation => 'Missing limitation',
    PassportFeedbackType.parserIssue => 'Parser issue',
  };
}

const passportFieldKeys = <String>{
  'research_question',
  'contribution',
  'method',
  'data_or_sample',
  'evaluation',
  'main_result',
  'limitations',
  'assumptions_scope',
  'code_resources',
  'publication_status',
};

final class PassportField {
  PassportField({
    required this.key,
    required this.status,
    required this.value,
    required Iterable<String> sourceBlockIds,
    this.id = _legacyFieldId,
    this.valueJson,
    this.confidenceStatus = PassportConfidenceStatus.uncertain,
    this.provenanceId = _legacyProvenanceId,
    DateTime? createdAt,
    this.serverValidated = false,
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds),
       createdAt = (createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
           .toUtc();

  final String id;
  final String key;
  final PassportFieldStatus status;
  final String? value;
  final Object? valueJson;
  final List<String> sourceBlockIds;
  final PassportConfidenceStatus confidenceStatus;
  final String provenanceId;
  final DateTime createdAt;

  /// Only strict server DTOs may become feedback or memory mutation inputs.
  final bool serverValidated;

  bool get hasDisplayValue => displayValue != null;
  bool get hasEvidence => sourceBlockIds.isNotEmpty;
  bool get isRememberable =>
      serverValidated &&
      (status == PassportFieldStatus.supported ||
          status == PassportFieldStatus.inferred);
  bool get isGenerated =>
      status == PassportFieldStatus.supported ||
      status == PassportFieldStatus.inferred ||
      status == PassportFieldStatus.conflicting;

  String get displayLabel => passportFieldLabel(key);

  String? get displayValue {
    final text = value?.trim();
    if (text?.isNotEmpty == true) return text;
    final structured = valueJson;
    if (structured == null) return null;
    return jsonEncode(structured);
  }

  factory PassportField.fromJson(Map<String, dynamic> json) {
    final key = _fieldKey(json['field_key']);
    final status = PassportFieldStatus.fromWire(json['status']);
    final value = _optionalText(
      json['value_text'],
      'value_text',
      maximumScalars: passportFieldTextMaximumScalars,
    );
    final valueJson = _structuredValue(json['value_json']);
    final sourceIds = _uuidList(
      json['source_block_ids'],
      'source_block_ids',
      maximum: passportMaximumSourceBlocks,
    );
    final generated = switch (status) {
      PassportFieldStatus.supported ||
      PassportFieldStatus.inferred ||
      PassportFieldStatus.conflicting => true,
      PassportFieldStatus.notFound ||
      PassportFieldStatus.notApplicable => false,
    };
    if (generated) {
      if (sourceIds.isEmpty || (value == null) == (valueJson == null)) {
        throw const FormatException(
          'Generated Passport fields require one value and exact evidence.',
        );
      }
    } else if (sourceIds.isNotEmpty || value != null || valueJson != null) {
      throw const FormatException(
        'Unavailable Passport fields cannot retain generated content.',
      );
    }
    return PassportField(
      id: _uuidValue(json['id'], 'field.id'),
      key: key,
      status: status,
      value: value,
      valueJson: valueJson,
      sourceBlockIds: sourceIds,
      confidenceStatus: PassportConfidenceStatus.fromWire(
        json['confidence_status'],
      ),
      provenanceId: _uuidValue(json['provenance_id'], 'field.provenance_id'),
      createdAt: _requiredDate(json['created_at'], 'field.created_at'),
      serverValidated: true,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'field_key': key,
    'status': status.wireValue,
    'value_text': value,
    'value_json': valueJson,
    'source_block_ids': sourceBlockIds,
    'confidence_status': confidenceStatus.wireValue,
    'provenance_id': provenanceId,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

final class PaperPassport {
  PaperPassport({
    required this.paperId,
    required this.generation,
    required this.status,
    required this.versionLabel,
    required Iterable<PassportField> fields,
    required this.provenance,
    this.id = _legacyPassportId,
    this.schemaVersion = 'unknown',
    this.parserId = 'unknown',
    this.modelId,
    this.promptVersion,
    this.provenanceId = _legacyProvenanceId,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.serverValidated = false,
  }) : fields = List.unmodifiable(fields),
       createdAt = (createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
           .toUtc(),
       updatedAt =
           (updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
               .toUtc();

  final String id;
  final String paperId;
  final int generation;
  final PassportStatus status;
  final String versionLabel;
  final String schemaVersion;
  final String parserId;
  final String? modelId;
  final String? promptVersion;
  final String provenanceId;
  final List<PassportField> fields;
  final ProvenanceSummary provenance;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool serverValidated;

  bool get isDisplayable =>
      serverValidated &&
      (status == PassportStatus.ready || status == PassportStatus.partial);

  factory PaperPassport.fromJson(Map<String, dynamic> json) {
    final generation = _positiveInteger(json['generation'], 'generation');
    final rawFields = json['fields'];
    if (rawFields is! List || rawFields.length != passportFieldKeys.length) {
      throw const FormatException(
        'A Passport must contain every canonical field exactly once.',
      );
    }
    final fields = rawFields
        .map((raw) {
          if (raw is! Map) {
            throw const FormatException('Invalid Passport field.');
          }
          return PassportField.fromJson(Map<String, dynamic>.from(raw));
        })
        .toList(growable: false);
    final keys = fields.map((field) => field.key).toSet();
    if (keys.length != passportFieldKeys.length ||
        !keys.containsAll(passportFieldKeys)) {
      throw const FormatException('Passport fields are missing or duplicated.');
    }

    final id = _uuidValue(json['id'], 'id');
    final paperId = _uuidValue(json['paper_id'], 'paper_id');
    final status = PassportStatus.fromWire(json['status']);
    final versionLabel = _requiredText(
      json['version_label'],
      'version_label',
      maximumScalars: 128,
    );
    if (!_versionLabel.hasMatch(versionLabel)) {
      throw const FormatException('Invalid Passport version label.');
    }
    final schemaVersion = _requiredText(
      json['schema_version'],
      'schema_version',
      maximumScalars: 64,
    );
    final parserId = _requiredText(
      json['parser_id'],
      'parser_id',
      maximumScalars: 64,
    );
    final modelId = _optionalText(
      json['model_id'],
      'model_id',
      maximumScalars: 128,
    );
    final promptVersion = _optionalText(
      json['prompt_version'],
      'prompt_version',
      maximumScalars: 128,
    );
    final provenanceId = _uuidValue(json['provenance_id'], 'provenance_id');
    final createdAt = _requiredDate(json['created_at'], 'created_at');
    final updatedAt = _requiredDate(json['updated_at'], 'updated_at');
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('Passport timestamps are out of order.');
    }
    final provenance = _passportProvenance(
      _requiredMap(json['provenance'], 'provenance'),
      expectedId: provenanceId,
      expectedStatus: status,
      expectedParserId: parserId,
      expectedModelId: modelId,
      expectedSchemaVersion: schemaVersion,
      expectedPromptVersion: promptVersion,
      expectedCreatedAt: createdAt,
    );

    return PaperPassport(
      id: id,
      paperId: paperId,
      generation: generation,
      status: status,
      versionLabel: versionLabel,
      schemaVersion: schemaVersion,
      parserId: parserId,
      modelId: modelId,
      promptVersion: promptVersion,
      provenanceId: provenanceId,
      fields: fields,
      provenance: provenance,
      createdAt: createdAt,
      updatedAt: updatedAt,
      serverValidated: true,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'paper_id': paperId,
    'generation': generation,
    'status': status.wireValue,
    'version_label': versionLabel,
    'schema_version': schemaVersion,
    'parser_id': parserId,
    'model_id': modelId,
    'prompt_version': promptVersion,
    'provenance_id': provenanceId,
    'fields': fields.map((field) => field.toJson()).toList(growable: false),
    'provenance': {
      'id': provenanceId,
      'status': status.wireValue,
      'parser_id': parserId,
      'model_id': modelId,
      'schema_version': schemaVersion,
      'prompt_version': promptVersion,
      'created_at': createdAt.toUtc().toIso8601String(),
    },
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

bool isValidPassportUuid(String value) => _uuid.hasMatch(value.toLowerCase());

bool passportVersionMatchesVersionKey(
  PaperPassport passport,
  String versionKey,
) {
  final match = _versionKeySuffix.firstMatch(versionKey.trim());
  return match != null && passport.versionLabel == 'v${match.group(1)}';
}

String passportFieldLabel(String key) => key
    .split('_')
    .where((word) => word.isNotEmpty)
    .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
    .join(' ');

String _fieldKey(Object? value) {
  final key = _requiredText(
    value,
    'field_key',
    maximumScalars: 64,
  ).toLowerCase();
  if (!passportFieldKeys.contains(key)) {
    throw const FormatException('Unknown Passport field key.');
  }
  return key;
}

ProvenanceSummary _passportProvenance(
  Map<String, dynamic> json, {
  required String expectedId,
  required PassportStatus expectedStatus,
  required String expectedParserId,
  required String? expectedModelId,
  required String expectedSchemaVersion,
  required String? expectedPromptVersion,
  required DateTime expectedCreatedAt,
}) {
  final id = _uuidValue(json['id'], 'provenance.id');
  final status = PassportStatus.fromWire(json['status']);
  final parserId = _requiredText(
    json['parser_id'],
    'provenance.parser_id',
    maximumScalars: 64,
  );
  final modelId = _optionalText(
    json['model_id'],
    'provenance.model_id',
    maximumScalars: 128,
  );
  final schemaVersion = _requiredText(
    json['schema_version'],
    'provenance.schema_version',
    maximumScalars: 64,
  );
  final promptVersion = _optionalText(
    json['prompt_version'],
    'provenance.prompt_version',
    maximumScalars: 128,
  );
  final createdAt = _requiredDate(json['created_at'], 'provenance.created_at');
  if (id != expectedId ||
      status != expectedStatus ||
      parserId != expectedParserId ||
      modelId != expectedModelId ||
      schemaVersion != expectedSchemaVersion ||
      promptVersion != expectedPromptVersion ||
      createdAt != expectedCreatedAt) {
    throw const FormatException('Passport provenance does not match artifact.');
  }
  return ProvenanceSummary(
    status: status.wireValue,
    recordId: id,
    parserId: parserId,
    modelId: modelId,
    schemaVersion: schemaVersion,
    createdAt: createdAt,
  );
}

Object? _structuredValue(Object? value) {
  if (value == null) return null;
  if (value is! Map && value is! List) {
    throw const FormatException('Invalid Passport structured value.');
  }
  _validateStructuredValue(value, depth: 0, budget: _StructuredValueBudget());
  late final List<int> encoded;
  try {
    encoded = utf8.encode(jsonEncode(value));
  } on Object {
    throw const FormatException('Invalid Passport structured value.');
  }
  if (encoded.length > 32768) {
    throw const FormatException('Passport structured value is too large.');
  }
  return jsonDecode(utf8.decode(encoded));
}

void _validateStructuredValue(
  Object? value, {
  required int depth,
  required _StructuredValueBudget budget,
}) {
  if (depth > 16 || ++budget.nodes > 2048) {
    throw const FormatException('Passport structured value is too complex.');
  }
  switch (value) {
    case null || bool() || int():
      return;
    case double() when value.isFinite:
      return;
    case double():
      throw const FormatException('Passport structured number is not finite.');
    case String():
      if (!_safeStructuredText(value, maximumScalars: 10000)) {
        throw const FormatException('Passport structured text is invalid.');
      }
      return;
    case List():
      if (value.length > 1024) {
        throw const FormatException('Passport structured list is too large.');
      }
      for (final item in value) {
        _validateStructuredValue(item, depth: depth + 1, budget: budget);
      }
      return;
    case Map():
      if (value.length > 1024) {
        throw const FormatException('Passport structured object is too large.');
      }
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String ||
            key.isEmpty ||
            !_safeStructuredText(key, maximumScalars: 256)) {
          throw const FormatException('Passport structured key is invalid.');
        }
        _validateStructuredValue(entry.value, depth: depth + 1, budget: budget);
      }
      return;
    default:
      throw const FormatException('Passport structured value is invalid.');
  }
}

bool _safeStructuredText(String value, {required int maximumScalars}) {
  final scalars = value.runes;
  if (scalars.length > maximumScalars) return false;
  for (final scalar in scalars) {
    if (scalar < 0x20 ||
        (scalar >= 0x7f && scalar <= 0x9f) ||
        (scalar >= 0xfdd0 && scalar <= 0xfdef) ||
        (scalar & 0xffff) == 0xfffe ||
        (scalar & 0xffff) == 0xffff) {
      return false;
    }
  }
  return true;
}

final class _StructuredValueBudget {
  int nodes = 0;
}

List<String> _uuidList(Object? value, String field, {required int maximum}) {
  if (value is! List || value.length > maximum) {
    throw FormatException('Invalid $field.');
  }
  final values = value
      .map((item) => _uuidValue(item, field))
      .toList(growable: false);
  if (values.toSet().length != values.length) {
    throw FormatException('Duplicate $field.');
  }
  return values;
}

String _uuidValue(Object? value, String field) {
  if (value is! String) throw FormatException('Invalid $field.');
  final text = value.trim().toLowerCase();
  if (!isValidPassportUuid(text)) throw FormatException('Invalid $field.');
  return text;
}

int _positiveInteger(Object? value, String field) {
  if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
    throw FormatException('Invalid $field.');
  }
  final result = value.toInt();
  if (result <= 0 || result > 0x7fffffff) {
    throw FormatException('Invalid $field.');
  }
  return result;
}

String _requiredText(
  Object? value,
  String field, {
  required int maximumScalars,
}) {
  if (value is! String ||
      value.contains('\u0000') ||
      value.trim().isEmpty ||
      value.runes.length > maximumScalars) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

String? _optionalText(
  Object? value,
  String field, {
  required int maximumScalars,
}) => value == null
    ? null
    : _requiredText(value, field, maximumScalars: maximumScalars);

DateTime _requiredDate(Object? value, String field) {
  if (value is! String || value.contains('\u0000')) {
    throw FormatException('Invalid $field.');
  }
  final parsed = DateTime.tryParse(value)?.toUtc();
  if (parsed == null) throw FormatException('Invalid $field.');
  return parsed;
}

Map<String, dynamic> _requiredMap(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('Invalid $field.');
}

const _legacyPassportId = 'ffffffff-ffff-4fff-8fff-fffffffffff1';
const _legacyFieldId = 'ffffffff-ffff-4fff-8fff-fffffffffff2';
const _legacyProvenanceId = 'ffffffff-ffff-4fff-8fff-fffffffffff3';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _versionLabel = RegExp(r'^v[1-9][0-9]{0,9}$');
final _versionKeySuffix = RegExp(r'v([1-9][0-9]{0,9})$');
