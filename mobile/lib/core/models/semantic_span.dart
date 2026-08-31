const maximumSemanticSpans = 128;
const maximumSemanticProvenanceRecords = 128;

enum SemanticFacet {
  objective('objective', 'Objective'),
  method('method', 'Method'),
  result('result', 'Result'),
  limitation('limitation', 'Limitation'),
  claim('claim', 'Claim'),
  evidence('evidence', 'Evidence'),
  futureWork('future_work', 'Future work'),
  definition('definition', 'Definition');

  const SemanticFacet(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SemanticFacet fromWire(Object? value) => switch (value) {
    'objective' => SemanticFacet.objective,
    'method' => SemanticFacet.method,
    'result' => SemanticFacet.result,
    'limitation' => SemanticFacet.limitation,
    'claim' => SemanticFacet.claim,
    'evidence' => SemanticFacet.evidence,
    'future_work' => SemanticFacet.futureWork,
    'definition' => SemanticFacet.definition,
    _ => throw const FormatException('Invalid semantic facet.'),
  };
}

enum SemanticDensity {
  off('off', 'Off'),
  key('key', 'Key'),
  detailed('detailed', 'Detailed');

  const SemanticDensity(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SemanticDensity fromWire(Object? value) => switch (value) {
    'off' => SemanticDensity.off,
    'key' => SemanticDensity.key,
    'detailed' => SemanticDensity.detailed,
    _ => throw const FormatException('Invalid semantic density.'),
  };

  /// Restoration is deliberately tolerant so a malformed preference cannot
  /// block startup. Wire/API decoding remains strict through [fromWire].
  static SemanticDensity fromRestoration(Object? value) {
    try {
      return fromWire(value);
    } on FormatException {
      return SemanticDensity.key;
    }
  }

  bool includes(SemanticDensity minimum) => switch (this) {
    SemanticDensity.off => false,
    SemanticDensity.key => minimum == SemanticDensity.key,
    SemanticDensity.detailed => minimum != SemanticDensity.off,
  };
}

enum SemanticSpanSourceKind {
  deterministic('deterministic'),
  model('model');

  const SemanticSpanSourceKind(this.wireValue);

  final String wireValue;

  static SemanticSpanSourceKind fromWire(Object? value) => switch (value) {
    'deterministic' => SemanticSpanSourceKind.deterministic,
    'model' => SemanticSpanSourceKind.model,
    _ => throw const FormatException('Invalid semantic span source.'),
  };
}

enum SemanticSupportStatus {
  supported('supported', 'Supported'),
  inferred('inferred', 'Inferred');

  const SemanticSupportStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SemanticSupportStatus fromWire(Object? value) => switch (value) {
    'supported' => SemanticSupportStatus.supported,
    'inferred' => SemanticSupportStatus.inferred,
    _ => throw const FormatException('Invalid semantic support status.'),
  };
}

final class SemanticSpan {
  SemanticSpan({
    required this.id,
    required this.blockId,
    required this.ordinal,
    required this.startOffset,
    required this.endOffset,
    required this.facet,
    required this.minimumDensity,
    required this.sourceKind,
    required this.confidenceBasisPoints,
    required this.supportStatus,
    required this.provenanceId,
    required this.createdAt,
  }) {
    if (!_isUuid(id) ||
        !_isUuid(blockId) ||
        !_isUuid(provenanceId) ||
        ordinal < 0 ||
        ordinal > _maximumUint32 ||
        startOffset < 0 ||
        startOffset > _maximumUint32 ||
        endOffset <= startOffset ||
        endOffset > _maximumUint32 ||
        minimumDensity == SemanticDensity.off ||
        confidenceBasisPoints < 0 ||
        confidenceBasisPoints > 10000 ||
        !createdAt.isUtc) {
      throw const FormatException('Invalid semantic span.');
    }
  }

  final String id;
  final String blockId;
  final int ordinal;
  final int startOffset;
  final int endOffset;
  final SemanticFacet facet;
  final SemanticDensity minimumDensity;
  final SemanticSpanSourceKind sourceKind;
  final int confidenceBasisPoints;
  final SemanticSupportStatus supportStatus;
  final String provenanceId;
  final DateTime createdAt;

  factory SemanticSpan.fromJson(Map<String, dynamic> json) {
    final createdAt = _requiredTimestamp(json['created_at']);
    return SemanticSpan(
      id: _requiredUuid(json['id']),
      blockId: _requiredUuid(json['block_id']),
      ordinal: _requiredInteger(json['ordinal']),
      startOffset: _requiredInteger(json['start_offset']),
      endOffset: _requiredInteger(json['end_offset']),
      facet: SemanticFacet.fromWire(json['facet']),
      minimumDensity: SemanticDensity.fromWire(json['minimum_density']),
      sourceKind: SemanticSpanSourceKind.fromWire(json['source_kind']),
      confidenceBasisPoints: _requiredInteger(json['confidence_basis_points']),
      supportStatus: SemanticSupportStatus.fromWire(json['support_status']),
      provenanceId: _requiredUuid(json['provenance_id']),
      createdAt: createdAt,
    );
  }

  bool isValidForBlock({required String blockId, required int scalarLength}) =>
      this.blockId == blockId &&
      scalarLength >= 0 &&
      startOffset >= 0 &&
      endOffset > startOffset &&
      endOffset <= scalarLength;

  bool visibleAt(SemanticDensity density) => density.includes(minimumDensity);

  Map<String, Object?> toJson() => {
    'id': id,
    'block_id': blockId,
    'ordinal': ordinal,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'facet': facet.wireValue,
    'minimum_density': minimumDensity.wireValue,
    'source_kind': sourceKind.wireValue,
    'confidence_basis_points': confidenceBasisPoints,
    'support_status': supportStatus.wireValue,
    'provenance_id': provenanceId,
    'created_at': createdAt.toIso8601String(),
  };
}

final class SemanticSpansEnvelope {
  SemanticSpansEnvelope({
    required this.paperId,
    required this.generation,
    required this.density,
    required Iterable<SemanticSpan> spans,
  }) : spans = List<SemanticSpan>.unmodifiable(spans) {
    if (!_isUuid(paperId) || generation <= 0 || generation > _maximumInt32) {
      throw const FormatException('Invalid semantic span envelope.');
    }
    _validateSpanCollection(this.spans);
  }

  final String paperId;
  final int generation;
  final SemanticDensity density;
  final List<SemanticSpan> spans;

  factory SemanticSpansEnvelope.fromJson(Map<String, dynamic> json) {
    final paperId = _requiredUuid(json['paper_id']);
    final generation = _requiredInteger(json['generation']);
    if (generation <= 0 || generation > _maximumInt32) {
      throw const FormatException('Invalid semantic span generation.');
    }
    _validateDocumentProvenance(json['document_provenance']);
    final rawSpans = json['spans'];
    if (rawSpans is! List || rawSpans.length > maximumSemanticSpans) {
      throw const FormatException('Invalid semantic span collection.');
    }
    final spans = rawSpans
        .map((value) {
          if (value is! Map) {
            throw const FormatException('Invalid semantic span item.');
          }
          return SemanticSpan.fromJson(Map<String, dynamic>.from(value));
        })
        .toList(growable: false);
    final provenanceIds = _validateProvenanceRecords(
      json['provenance_records'],
      paperId: paperId,
      generation: generation,
    );
    if (spans.any((span) => !provenanceIds.contains(span.provenanceId)) ||
        provenanceIds.any(
          (id) => spans.every((span) => span.provenanceId != id),
        )) {
      throw const FormatException('Semantic span provenance is incomplete.');
    }
    return SemanticSpansEnvelope(
      paperId: paperId,
      generation: generation,
      density: SemanticDensity.fromWire(json['density']),
      spans: spans,
    );
  }
}

void _validateSpanCollection(List<SemanticSpan> spans) {
  if (spans.length > maximumSemanticSpans) {
    throw const FormatException('Semantic span limit exceeded.');
  }
  final ids = <String>{};
  final ordinals = <int>{};
  for (final span in spans) {
    if (!ids.add(span.id) || !ordinals.add(span.ordinal)) {
      throw const FormatException('Duplicate semantic span identity.');
    }
  }
}

void _validateDocumentProvenance(Object? raw) {
  if (raw is! Map) {
    throw const FormatException('Missing semantic document provenance.');
  }
  final json = Map<String, dynamic>.from(raw);
  final arxivVersion = _requiredInteger(json['arxiv_version']);
  if (arxivVersion <= 0 || arxivVersion > _maximumUint32) {
    throw const FormatException('Invalid semantic document version.');
  }
  _requiredBoundedText(json['parser_id'], 64);
  _requiredBoundedText(json['parser_version'], 128);
  _requiredBoundedText(json['schema_version'], 128);
  _requiredBoundedText(json['document_hash'], 256);
  _requiredTimestamp(json['generated_at']);
}

Set<String> _validateProvenanceRecords(
  Object? raw, {
  required String paperId,
  required int generation,
}) {
  if (raw is! List || raw.length > maximumSemanticProvenanceRecords) {
    throw const FormatException('Invalid semantic provenance collection.');
  }
  final ids = <String>{};
  for (final value in raw) {
    if (value is! Map) {
      throw const FormatException('Invalid semantic provenance record.');
    }
    final json = Map<String, dynamic>.from(value);
    final id = _requiredUuid(json['id']);
    if (!ids.add(id) ||
        _requiredUuid(json['paper_id']) != paperId ||
        _requiredInteger(json['generation']) != generation ||
        json['artifact_type'] != 'semantic_spans' ||
        json['activity_type'] != 'semantic_classification') {
      throw const FormatException('Semantic provenance scope mismatch.');
    }
    _requiredUuid(json['artifact_id']);
    _optionalUuid(json['superseded_by']);
    _optionalBoundedText(json['parser_id'], 64);
    _optionalBoundedText(json['parser_version'], 128);
    _optionalBoundedText(json['model_provider'], 64);
    _optionalBoundedText(json['model_id'], 128);
    _optionalBoundedText(json['prompt_or_schema_version'], 128);
    _requiredTimestamp(json['created_at']);
    final inputs = json['input_entity_ids'];
    if (inputs is! List || inputs.length > 128) {
      throw const FormatException('Invalid semantic provenance inputs.');
    }
    final inputIds = <String>{};
    for (final input in inputs) {
      if (!inputIds.add(_requiredUuid(input))) {
        throw const FormatException('Duplicate semantic provenance input.');
      }
    }
    final parameters = json['parameters'];
    if (parameters is! Map || parameters.length > 32) {
      throw const FormatException('Invalid semantic provenance parameters.');
    }
    for (final entry in parameters.entries) {
      final key = entry.key;
      final parameter = entry.value;
      if (key is! String ||
          !_provenanceKey.hasMatch(key) ||
          key.runes.length > 64 ||
          parameter is! bool && parameter is! int) {
        throw const FormatException('Invalid semantic provenance parameter.');
      }
    }
  }
  return ids;
}

int _requiredInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw const FormatException('Invalid semantic integer.');
}

DateTime _requiredTimestamp(Object? value) {
  final text = _requiredBoundedText(value, 64);
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      (!text.endsWith('Z') && !RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(text))) {
    throw const FormatException('Invalid semantic timestamp.');
  }
  return parsed.toUtc();
}

String _requiredUuid(Object? value) {
  final text = _requiredBoundedText(value, 36).toLowerCase();
  if (!_isUuid(text)) throw const FormatException('Invalid semantic UUID.');
  return text;
}

String? _optionalUuid(Object? value) =>
    value == null ? null : _requiredUuid(value);

String _requiredBoundedText(Object? value, int maximumScalars) {
  if (value is! String || value.contains('\u0000')) {
    throw const FormatException('Invalid semantic text.');
  }
  final text = value.trim();
  if (text.isEmpty || text.runes.length > maximumScalars) {
    throw const FormatException('Invalid semantic text.');
  }
  return text;
}

String? _optionalBoundedText(Object? value, int maximumScalars) =>
    value == null ? null : _requiredBoundedText(value, maximumScalars);

bool _isUuid(String value) => _uuid.hasMatch(value) && value != _nilUuid;

const _maximumUint32 = 0xffffffff;
const _maximumInt32 = 0x7fffffff;
const _nilUuid = '00000000-0000-0000-0000-000000000000';
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _provenanceKey = RegExp(r'^[a-z0-9_]+$');
