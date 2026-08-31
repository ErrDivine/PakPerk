enum AssistantAnswerStatus { supported, partial, notFound }

enum AssistantClaimSupport { direct, inferred }

enum AssistantAnswerStyle {
  concise,
  detailed,
  beginner,
  expert;

  String get wireValue => name;

  String get displayLabel => switch (this) {
    AssistantAnswerStyle.concise => 'Concise',
    AssistantAnswerStyle.detailed => 'Detailed',
    AssistantAnswerStyle.beginner => 'Beginner',
    AssistantAnswerStyle.expert => 'Expert',
  };
}

enum AssistantScopeKind {
  paper,
  section,
  selection,
  figure,
  table,
  equation,
  passportField;

  String get wireValue => switch (this) {
    AssistantScopeKind.passportField => 'passport_field',
    _ => name,
  };
}

enum AssistantSectionKind {
  abstract,
  introduction,
  background,
  relatedWork,
  method,
  experiment,
  result,
  discussion,
  limitation,
  conclusion,
  appendix,
  acknowledgment,
  references,
  other;

  String get wireValue => switch (this) {
    AssistantSectionKind.relatedWork => 'related_work',
    _ => name,
  };

  String get displayLabel => switch (this) {
    AssistantSectionKind.abstract => 'Abstract',
    AssistantSectionKind.introduction => 'Introduction',
    AssistantSectionKind.background => 'Background',
    AssistantSectionKind.relatedWork => 'Related work',
    AssistantSectionKind.method => 'Methods',
    AssistantSectionKind.experiment => 'Experiments',
    AssistantSectionKind.result => 'Results',
    AssistantSectionKind.discussion => 'Discussion',
    AssistantSectionKind.limitation => 'Limitations',
    AssistantSectionKind.conclusion => 'Conclusion',
    AssistantSectionKind.appendix => 'Appendix',
    AssistantSectionKind.acknowledgment => 'Acknowledgments',
    AssistantSectionKind.references => 'References',
    AssistantSectionKind.other => 'Other',
  };
}

final class AssistantTextSelection {
  AssistantTextSelection({
    required this.blockId,
    required this.start,
    required this.end,
  }) {
    if (!isValidAssistantUuid(blockId) ||
        start < 0 ||
        end <= start ||
        end > _unsigned32Maximum) {
      throw ArgumentError('Invalid assistant text selection.');
    }
  }

  final String blockId;
  final int start;
  final int end;

  Map<String, Object?> toJson() => {
    'block_id': blockId,
    'start': start,
    'end': end,
  };
}

final class AssistantRequestScope {
  const AssistantRequestScope.paper()
    : kind = AssistantScopeKind.paper,
      sectionKinds = const [],
      objectIds = const [],
      selection = null,
      passportField = null;

  AssistantRequestScope.section({required Iterable<AssistantSectionKind> kinds})
    : kind = AssistantScopeKind.section,
      sectionKinds = List.unmodifiable(kinds),
      objectIds = const [],
      selection = null,
      passportField = null {
    if (sectionKinds.isEmpty ||
        sectionKinds.length > 12 ||
        sectionKinds.toSet().length != sectionKinds.length) {
      throw ArgumentError.value(sectionKinds, 'kinds');
    }
  }

  AssistantRequestScope.selection({
    required String blockId,
    required int start,
    required int end,
  }) : kind = AssistantScopeKind.selection,
       sectionKinds = const [],
       objectIds = const [],
       selection = AssistantTextSelection(
         blockId: blockId,
         start: start,
         end: end,
       ),
       passportField = null;

  AssistantRequestScope.object({required this.kind, required String objectId})
    : sectionKinds = const [],
      objectIds = List.unmodifiable([objectId]),
      selection = null,
      passportField = null {
    if (kind != AssistantScopeKind.figure &&
        kind != AssistantScopeKind.table &&
        kind != AssistantScopeKind.equation) {
      throw ArgumentError.value(kind, 'kind');
    }
    if (!isValidAssistantUuid(objectId)) {
      throw ArgumentError.value(objectId, 'objectId');
    }
  }

  AssistantRequestScope.passportField(String fieldKey)
    : kind = AssistantScopeKind.passportField,
      sectionKinds = const [],
      objectIds = const [],
      selection = null,
      passportField = fieldKey {
    if (!_passportFieldKey.hasMatch(fieldKey)) {
      throw ArgumentError.value(fieldKey, 'fieldKey');
    }
  }

  final AssistantScopeKind kind;
  final List<AssistantSectionKind> sectionKinds;
  final List<String> objectIds;
  final AssistantTextSelection? selection;
  final String? passportField;

  String get displayLabel => switch (kind) {
    AssistantScopeKind.paper => 'Whole paper',
    AssistantScopeKind.section when sectionKinds.length == 1 =>
      '${sectionKinds.single.displayLabel} section',
    AssistantScopeKind.section =>
      sectionKinds.map((value) => value.displayLabel).join(', '),
    AssistantScopeKind.selection =>
      'Selected text · characters ${selection!.start + 1}–${selection!.end}',
    AssistantScopeKind.figure => 'Figure',
    AssistantScopeKind.table => 'Table',
    AssistantScopeKind.equation => 'Equation',
    AssistantScopeKind.passportField =>
      'Passport · ${_fieldLabel(passportField!)}',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.wireValue,
    'section_kinds': sectionKinds
        .map((value) => value.wireValue)
        .toList(growable: false),
    'object_ids': objectIds,
    if (selection case final value?) 'selection': value.toJson(),
    if (passportField case final value?) 'passport_field': value,
  };
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _passportFieldKey = RegExp(r'^[a-z0-9_]{1,64}$');
const _nilUuid = '00000000-0000-0000-0000-000000000000';
const _assistantNotFoundAnswer = 'Not found in this paper.';
const _assistantClaimSeparator = '\n\n';
const _assistantPartialLimitation =
    'Only claim-backed portions of the requested answer are shown.';
const _unsigned32Maximum = 0xffffffff;
const _signed32Maximum = 0x7fffffff;

bool isValidAssistantUuid(String value) =>
    value != _nilUuid && value.length == 36 && _uuid.hasMatch(value);

String _fieldLabel(String key) => key
    .split('_')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

final class AssistantEvidence {
  const AssistantEvidence({
    required this.blockId,
    required this.start,
    required this.end,
    this.pageStart,
    this.section,
  });
  final String blockId;
  final int start;
  final int end;
  final int? pageStart;
  final String? section;
  factory AssistantEvidence.fromJson(Map<String, dynamic> json) {
    final start = _responseInteger(json['start'], 'evidence.start');
    final end = _responseInteger(json['end'], 'evidence.end');
    if (end <= start) {
      throw const FormatException('Invalid assistant evidence range.');
    }
    return AssistantEvidence(
      blockId: _responseAssistantUuid(json['block_id'], 'evidence.block_id'),
      start: start,
      end: end,
      pageStart: json['page_start'] == null
          ? null
          : _responseInteger(json['page_start'], 'evidence.page_start'),
      section: _optionalBoundedResponseString(
        json['section'],
        'evidence.section',
        maximumScalars: 512,
      ),
    );
  }
}

final class AssistantClaim {
  AssistantClaim({
    required this.text,
    required this.support,
    required Iterable<AssistantEvidence> evidence,
  }) : evidence = List.unmodifiable(evidence);
  final String text;
  final AssistantClaimSupport support;
  final List<AssistantEvidence> evidence;
  factory AssistantClaim.fromJson(Map<String, dynamic> json) {
    final evidence = _responseList(
      json['evidence'],
      'claim.evidence',
      minimum: 1,
      maximum: 8,
      decode: AssistantEvidence.fromJson,
    );
    return AssistantClaim(
      text: _providerAuthoredResponseString(
        json['text'],
        'claim.text',
        maximumScalars: 1200,
      ),
      support: switch (json['support']) {
        'direct' => AssistantClaimSupport.direct,
        'inferred' => AssistantClaimSupport.inferred,
        _ => throw const FormatException('Invalid assistant claim support.'),
      },
      evidence: evidence,
    );
  }
}

final class AssistantAnswer {
  AssistantAnswer({
    required this.threadId,
    required this.responseId,
    required this.generation,
    required this.answer,
    required this.status,
    required Iterable<AssistantClaim> claims,
    required Iterable<String> limitations,
    required this.provenanceId,
    required this.promptVersion,
    this.modelId,
  }) : claims = List.unmodifiable(claims),
       limitations = List.unmodifiable(limitations);
  final String threadId;
  final String responseId;
  final int generation;
  final String answer;
  final AssistantAnswerStatus status;
  final List<AssistantClaim> claims;
  final List<String> limitations;
  final String provenanceId;
  final String? modelId;
  final String promptVersion;
  factory AssistantAnswer.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'supported' => AssistantAnswerStatus.supported,
      'partial' => AssistantAnswerStatus.partial,
      'not_found' => AssistantAnswerStatus.notFound,
      _ => throw const FormatException('Invalid assistant answer status.'),
    };
    final claims = _responseList(
      json['claims'],
      'claims',
      minimum: 0,
      maximum: 16,
      decode: AssistantClaim.fromJson,
    );
    if ((status == AssistantAnswerStatus.notFound && claims.isNotEmpty) ||
        (status != AssistantAnswerStatus.notFound && claims.isEmpty)) {
      throw const FormatException('Invalid assistant answer support shape.');
    }
    final answer = _providerAuthoredResponseString(
      json['answer'],
      'answer',
      maximumScalars: 6000,
    );
    final canonicalAnswer = status == AssistantAnswerStatus.notFound
        ? _assistantNotFoundAnswer
        : claims.map((claim) => claim.text).join(_assistantClaimSeparator);
    if (answer != canonicalAnswer) {
      throw const FormatException(
        'Assistant answer contains prose outside its claim records.',
      );
    }
    final limitations = _responseStringList(
      json['limitations'],
      'limitations',
      maximumItems: 1,
      maximumScalars: 600,
    );
    if (!_limitationsAreCanonical(status, limitations)) {
      throw const FormatException(
        'Assistant limitations contain non-canonical prose.',
      );
    }
    return AssistantAnswer(
      threadId: _responseAssistantUuid(json['thread_id'], 'thread_id'),
      responseId: _responseAssistantUuid(json['response_id'], 'response_id'),
      generation: _responseInteger(
        json['generation'],
        'generation',
        minimum: 1,
        maximum: _signed32Maximum,
      ),
      answer: answer,
      status: status,
      claims: claims,
      limitations: limitations,
      provenanceId: _responseAssistantUuid(
        json['provenance_id'],
        'provenance_id',
      ),
      modelId: _optionalBoundedResponseString(
        json['model_id'],
        'model_id',
        maximumScalars: 512,
      ),
      promptVersion: _boundedResponseString(
        json['prompt_version'],
        'prompt_version',
        maximumScalars: 128,
      ),
    );
  }
}

enum AssistantEvidenceFeedbackType {
  incorrectCitation,
  evidenceDoesNotSupportClaim,
  missingEvidence,
  incorrectSupportLabel,
  incorrectSourceLocation;

  String get wireValue => switch (this) {
    AssistantEvidenceFeedbackType.incorrectCitation => 'incorrect_citation',
    AssistantEvidenceFeedbackType.evidenceDoesNotSupportClaim =>
      'evidence_does_not_support_claim',
    AssistantEvidenceFeedbackType.missingEvidence => 'missing_evidence',
    AssistantEvidenceFeedbackType.incorrectSupportLabel =>
      'incorrect_support_label',
    AssistantEvidenceFeedbackType.incorrectSourceLocation =>
      'incorrect_source_location',
  };

  String get displayLabel => switch (this) {
    AssistantEvidenceFeedbackType.incorrectCitation => 'Wrong citation',
    AssistantEvidenceFeedbackType.evidenceDoesNotSupportClaim =>
      'Evidence does not support the claim',
    AssistantEvidenceFeedbackType.missingEvidence => 'Evidence is missing',
    AssistantEvidenceFeedbackType.incorrectSupportLabel =>
      'Direct or inferred label is wrong',
    AssistantEvidenceFeedbackType.incorrectSourceLocation =>
      'Wrong source location',
  };

  bool get requiresClaim =>
      this != AssistantEvidenceFeedbackType.missingEvidence;

  bool get requiresEvidenceBlock => switch (this) {
    AssistantEvidenceFeedbackType.incorrectCitation ||
    AssistantEvidenceFeedbackType.evidenceDoesNotSupportClaim ||
    AssistantEvidenceFeedbackType.incorrectSourceLocation => true,
    _ => false,
  };
}

final class AssistantEvidenceFeedbackDraft {
  AssistantEvidenceFeedbackDraft({
    required this.operationId,
    required this.type,
    required this.claimIndex,
    required this.evidenceBlockId,
    required this.detail,
  }) {
    final normalizedDetail = detail?.trim();
    if (!isValidAssistantUuid(operationId) ||
        (type.requiresClaim != (claimIndex != null)) ||
        (type.requiresEvidenceBlock != (evidenceBlockId != null)) ||
        claimIndex != null && (claimIndex! < 0 || claimIndex! >= 16) ||
        evidenceBlockId != null && !isValidAssistantUuid(evidenceBlockId!) ||
        normalizedDetail != detail ||
        (detail != null &&
            (detail!.isEmpty ||
                detail!.runes.length > 1000 ||
                detail!.contains('\u0000')))) {
      throw ArgumentError('Invalid assistant evidence feedback.');
    }
  }

  final String operationId;
  final AssistantEvidenceFeedbackType type;
  final int? claimIndex;
  final String? evidenceBlockId;
  final String? detail;
}

enum AssistantEvidenceFeedbackReceiptStatus { stored, replayed }

final class AssistantEvidenceFeedbackReceipt {
  const AssistantEvidenceFeedbackReceipt({
    required this.feedbackId,
    required this.status,
  });

  final String feedbackId;
  final AssistantEvidenceFeedbackReceiptStatus status;

  factory AssistantEvidenceFeedbackReceipt.fromJson(
    Map<String, dynamic> json,
  ) => AssistantEvidenceFeedbackReceipt(
    feedbackId: _responseAssistantUuid(json['feedback_id'], 'feedback_id'),
    status: switch (json['status']) {
      'stored' => AssistantEvidenceFeedbackReceiptStatus.stored,
      'replayed' => AssistantEvidenceFeedbackReceiptStatus.replayed,
      _ => throw const FormatException('Invalid assistant feedback status.'),
    },
  );
}

final class AssistantProvenance {
  const AssistantProvenance({
    required this.id,
    required this.paperId,
    required this.generation,
    required this.activityType,
    required this.inputEntityIds,
    required this.parameters,
    required this.createdAt,
    this.parserId,
    this.parserVersion,
    this.modelProvider,
    this.modelId,
    this.promptOrSchemaVersion,
  });
  final String id, paperId, activityType;
  final int generation;
  final List<String> inputEntityIds;
  final Map<String, dynamic> parameters;
  final DateTime createdAt;
  final String? parserId,
      parserVersion,
      modelProvider,
      modelId,
      promptOrSchemaVersion;
  factory AssistantProvenance.fromJson(Map<String, dynamic> json) =>
      AssistantProvenance(
        id: json['id'] as String,
        paperId: json['paper_id'] as String,
        generation: (json['generation'] as num).toInt(),
        activityType: json['activity_type'] as String,
        inputEntityIds: List<String>.from(json['input_entity_ids'] as List),
        parameters: Map<String, dynamic>.from(json['parameters'] as Map),
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        parserId: json['parser_id'] as String?,
        parserVersion: json['parser_version'] as String?,
        modelProvider: json['model_provider'] as String?,
        modelId: json['model_id'] as String?,
        promptOrSchemaVersion: json['prompt_or_schema_version'] as String?,
      );
}

int _responseInteger(
  Object? value,
  String field, {
  int minimum = 0,
  int maximum = _unsigned32Maximum,
}) {
  if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
    throw FormatException('Invalid assistant $field.');
  }
  final result = value.toInt();
  if (result < minimum || result > maximum) {
    throw FormatException('Invalid assistant $field.');
  }
  return result;
}

String _responseAssistantUuid(Object? value, String field) {
  if (value is! String || !isValidAssistantUuid(value)) {
    throw FormatException('Invalid assistant $field.');
  }
  return value;
}

String _boundedResponseString(
  Object? value,
  String field, {
  required int maximumScalars,
}) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.runes.length > maximumScalars ||
      value.contains('\u0000')) {
    throw FormatException('Invalid assistant $field.');
  }
  return value;
}

String? _optionalBoundedResponseString(
  Object? value,
  String field, {
  required int maximumScalars,
}) => value == null
    ? null
    : _boundedResponseString(value, field, maximumScalars: maximumScalars);

String _providerAuthoredResponseString(
  Object? value,
  String field, {
  required int maximumScalars,
}) {
  final result = _boundedResponseString(
    value,
    field,
    maximumScalars: maximumScalars,
  );
  if (result.trim() != result || _containsProviderAuthoredLink(result)) {
    throw FormatException('Invalid assistant $field.');
  }
  return result;
}

bool _containsProviderAuthoredLink(String value) {
  final lowercase = value.toLowerCase();
  return const [
    '://',
    'www.',
    '](',
    'mailto:',
    'tel:',
    'file:',
    'data:',
    'javascript:',
    'vbscript:',
  ].any(lowercase.contains);
}

bool _limitationsAreCanonical(
  AssistantAnswerStatus status,
  List<String> limitations,
) => switch (status) {
  AssistantAnswerStatus.partial =>
    limitations.length == 1 &&
        limitations.single == _assistantPartialLimitation,
  AssistantAnswerStatus.supported ||
  AssistantAnswerStatus.notFound => limitations.isEmpty,
};

List<T> _responseList<T>(
  Object? value,
  String field, {
  required int minimum,
  required int maximum,
  required T Function(Map<String, dynamic>) decode,
}) {
  if (value is! List || value.length < minimum || value.length > maximum) {
    throw FormatException('Invalid assistant $field.');
  }
  return value
      .map((item) {
        if (item is! Map || item.keys.any((key) => key is! String)) {
          throw FormatException('Invalid assistant $field item.');
        }
        return decode(Map<String, dynamic>.from(item));
      })
      .toList(growable: false);
}

List<String> _responseStringList(
  Object? value,
  String field, {
  required int maximumItems,
  required int maximumScalars,
}) {
  if (value is! List || value.length > maximumItems) {
    throw FormatException('Invalid assistant $field.');
  }
  return value
      .map(
        (item) => _providerAuthoredResponseString(
          item,
          field,
          maximumScalars: maximumScalars,
        ),
      )
      .toList(growable: false);
}
