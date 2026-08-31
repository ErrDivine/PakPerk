enum AnnotationKind {
  highlight,
  note,
  question,
  evidence;

  String get wireValue => name;

  static AnnotationKind fromWire(Object? value) => switch (value) {
    'highlight' => AnnotationKind.highlight,
    'note' => AnnotationKind.note,
    'question' => AnnotationKind.question,
    'evidence' => AnnotationKind.evidence,
    _ => throw const FormatException('Invalid annotation kind.'),
  };
}

enum AnnotationColorRole {
  yellow,
  blue,
  green,
  pink,
  purple;

  String get wireValue => name;

  static AnnotationColorRole? fromWire(Object? value) => switch (value) {
    null => null,
    'yellow' => AnnotationColorRole.yellow,
    'blue' => AnnotationColorRole.blue,
    'green' => AnnotationColorRole.green,
    'pink' => AnnotationColorRole.pink,
    'purple' => AnnotationColorRole.purple,
    _ => throw const FormatException('Invalid annotation color role.'),
  };
}

enum AnnotationAnchorStatus {
  anchored,
  uncertain,
  orphaned;

  String get wireValue => name;

  static AnnotationAnchorStatus fromWire(Object? value) => switch (value) {
    'anchored' => AnnotationAnchorStatus.anchored,
    'uncertain' => AnnotationAnchorStatus.uncertain,
    'orphaned' => AnnotationAnchorStatus.orphaned,
    _ => throw const FormatException('Invalid annotation anchor status.'),
  };
}

enum ResearchSyncState {
  clean,
  pending,
  conflict,
  failed;

  String get wireValue => name;

  static ResearchSyncState fromWire(Object? value) => switch (value) {
    'clean' => ResearchSyncState.clean,
    'pending' => ResearchSyncState.pending,
    'conflict' => ResearchSyncState.conflict,
    'failed' => ResearchSyncState.failed,
    _ => throw const FormatException('Invalid research sync state.'),
  };
}

enum AnnotationMergeState {
  unresolved,
  resolved;

  String get wireValue => name;

  static AnnotationMergeState fromWire(Object? value) => switch (value) {
    'unresolved' => AnnotationMergeState.unresolved,
    'resolved' => AnnotationMergeState.resolved,
    _ => throw const FormatException('Invalid annotation merge state.'),
  };
}

/// A W3C-style quote selector plus optional character offsets.
///
/// The quote and surrounding context are retained even after a document is
/// regenerated so uncertain anchors can be reviewed instead of silently moved.
final class TextQuotePositionSelector {
  const TextQuotePositionSelector({
    required this.exact,
    this.prefix,
    this.suffix,
    this.start,
    this.end,
  });

  final String exact;
  final String? prefix;
  final String? suffix;
  final int? start;
  final int? end;

  factory TextQuotePositionSelector.fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'TextQuoteAndPosition') {
      throw const FormatException('Unsupported text selector type.');
    }
    final exact = _boundedText(json['exact'], 'selector.exact', 1, 20000)!;
    final start = _optionalNonNegativeInt(json['start'], 'selector.start');
    final end = _optionalNonNegativeInt(json['end'], 'selector.end');
    if ((start == null) != (end == null) ||
        (start != null && end != null && end <= start)) {
      throw const FormatException('Invalid selector offsets.');
    }
    return TextQuotePositionSelector(
      exact: exact,
      prefix: _boundedText(json['prefix'], 'selector.prefix', 1, 2000),
      suffix: _boundedText(json['suffix'], 'selector.suffix', 1, 2000),
      start: start,
      end: end,
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'TextQuoteAndPosition',
    'exact': exact,
    if (prefix != null) 'prefix': prefix,
    if (suffix != null) 'suffix': suffix,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
  };
}

final class Annotation {
  const Annotation({
    required this.id,
    required this.paperId,
    required this.generation,
    required this.kind,
    required this.anchorStatus,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.blockId,
    this.body,
    this.colorRole,
    this.selector,
    this.sectionHint = const [],
    this.pageHint,
    this.deletedAt,
    this.syncState = ResearchSyncState.clean,
    this.activeOperationId,
  });

  final String id;
  final String paperId;
  final int generation;
  final String? blockId;
  final AnnotationKind kind;
  final String? body;
  final AnnotationColorRole? colorRole;
  final TextQuotePositionSelector? selector;
  final List<String> sectionHint;
  final int? pageHint;
  final AnnotationAnchorStatus anchorStatus;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ResearchSyncState syncState;
  final String? activeOperationId;

  bool get isDeleted => deletedAt != null;
  bool get needsAnchorReview =>
      anchorStatus == AnnotationAnchorStatus.uncertain ||
      anchorStatus == AnnotationAnchorStatus.orphaned;

  factory Annotation.fromJson(
    Map<String, dynamic> json, {
    ResearchSyncState syncState = ResearchSyncState.clean,
    String? activeOperationId,
  }) {
    final selector = json['selector'];
    return Annotation(
      id: _requiredId(json['id'], 'annotation.id'),
      paperId: _requiredId(json['paper_id'], 'annotation.paper_id'),
      generation: _positiveInt(json['generation'], 'annotation.generation'),
      blockId: _optionalId(json['block_id'], 'annotation.block_id'),
      kind: AnnotationKind.fromWire(json['kind']),
      body: _boundedText(json['body'], 'annotation.body', 1, 100000),
      colorRole: AnnotationColorRole.fromWire(json['color_role']),
      selector: selector == null
          ? null
          : TextQuotePositionSelector.fromJson(_jsonMap(selector)),
      sectionHint: _stringList(json['section_hint'], maximum: 64),
      pageHint: _optionalNonNegativeInt(json['page_hint'], 'page_hint'),
      anchorStatus: AnnotationAnchorStatus.fromWire(json['anchor_status']),
      revision: _nonNegativeInt(json['revision'], 'annotation.revision'),
      deletedAt: _optionalDate(json['deleted_at']),
      createdAt: _requiredDate(json['created_at'], 'annotation.created_at'),
      updatedAt: _requiredDate(json['updated_at'], 'annotation.updated_at'),
      syncState: syncState,
      activeOperationId: activeOperationId,
    );
  }

  Annotation copyWith({
    int? generation,
    String? blockId,
    bool clearBlockId = false,
    AnnotationKind? kind,
    String? body,
    bool clearBody = false,
    AnnotationColorRole? colorRole,
    bool clearColorRole = false,
    TextQuotePositionSelector? selector,
    AnnotationAnchorStatus? anchorStatus,
    int? revision,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    DateTime? updatedAt,
    ResearchSyncState? syncState,
    String? activeOperationId,
    bool clearActiveOperationId = false,
  }) => Annotation(
    id: id,
    paperId: paperId,
    generation: generation ?? this.generation,
    blockId: clearBlockId ? null : blockId ?? this.blockId,
    kind: kind ?? this.kind,
    body: clearBody ? null : body ?? this.body,
    colorRole: clearColorRole ? null : colorRole ?? this.colorRole,
    selector: selector ?? this.selector,
    sectionHint: sectionHint,
    pageHint: pageHint,
    anchorStatus: anchorStatus ?? this.anchorStatus,
    revision: revision ?? this.revision,
    deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    syncState: syncState ?? this.syncState,
    activeOperationId: clearActiveOperationId
        ? null
        : activeOperationId ?? this.activeOperationId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'paper_id': paperId,
    'generation': generation,
    'block_id': blockId,
    'kind': kind.wireValue,
    'body': body,
    'color_role': colorRole?.wireValue,
    'selector': selector?.toJson(),
    'section_hint': sectionHint,
    'page_hint': pageHint,
    'anchor_status': anchorStatus.wireValue,
    'revision': revision,
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class AnnotationWrite {
  const AnnotationWrite({
    required this.annotation,
    required this.operationId,
    required this.baseRevision,
    this.resolvesConflictId,
  });

  final Annotation annotation;
  final String operationId;
  final int baseRevision;
  final String? resolvesConflictId;

  Map<String, Object?> toJson() => {
    'operation_id': operationId,
    'paper_id': annotation.paperId,
    'generation': annotation.generation,
    'block_id': annotation.blockId,
    'kind': annotation.kind.wireValue,
    'body': annotation.body,
    'color_role': annotation.colorRole?.wireValue,
    'selector': annotation.selector?.toJson(),
    'section_hint': annotation.sectionHint,
    'page_hint': annotation.pageHint,
    'base_revision': baseRevision,
    if (resolvesConflictId != null) 'resolves_conflict_id': resolvesConflictId,
  };
}

final class AnnotationConflict {
  const AnnotationConflict({
    required this.conflictId,
    required this.annotationId,
    required this.attemptedOperationId,
    required this.baseRevision,
    required this.serverRevision,
    required this.createdAt,
    required this.mergeState,
    this.attemptedBody,
    this.serverBody,
    this.mergedBody,
    this.resolvedAt,
  });

  final String conflictId;
  final String annotationId;
  final String attemptedOperationId;
  final int baseRevision;
  final int serverRevision;
  final String? attemptedBody;
  final String? serverBody;
  final DateTime createdAt;
  final AnnotationMergeState mergeState;
  final String? mergedBody;
  final DateTime? resolvedAt;

  factory AnnotationConflict.fromJson(Map<String, dynamic> json) {
    final resolution = json['resolution'];
    if (resolution != null &&
        !const {
          'keep_server',
          'keep_attempted',
          'merged',
          'dismissed',
        }.contains(resolution)) {
      throw const FormatException('Invalid conflict resolution.');
    }
    final mergedBody = _boundedText(
      json['merged_body'],
      'merged_body',
      1,
      100000,
    );
    final resolvedAt = _optionalDate(json['resolved_at']);
    if ((resolution == null) != (resolvedAt == null) ||
        (resolution == 'merged') != (mergedBody != null)) {
      throw const FormatException('Invalid conflict resolution state.');
    }
    return AnnotationConflict(
      conflictId: _requiredId(json['conflict_id'], 'conflict.id'),
      annotationId: _requiredId(json['annotation_id'], 'conflict.annotation'),
      attemptedOperationId: _requiredId(
        json['attempted_operation_id'],
        'conflict.operation',
      ),
      baseRevision: _nonNegativeInt(json['base_revision'], 'base_revision'),
      serverRevision: _nonNegativeInt(
        json['server_revision'],
        'server_revision',
      ),
      attemptedBody: _boundedText(
        json['attempted_body'],
        'attempted_body',
        1,
        100000,
      ),
      serverBody: _boundedText(json['server_body'], 'server_body', 1, 100000),
      createdAt: _requiredDate(json['created_at'], 'conflict.created_at'),
      mergeState: resolution == null
          ? AnnotationMergeState.unresolved
          : AnnotationMergeState.resolved,
      mergedBody: mergedBody,
      resolvedAt: resolvedAt,
    );
  }

  AnnotationConflict resolve(String? mergedBody, DateTime now) =>
      AnnotationConflict(
        conflictId: conflictId,
        annotationId: annotationId,
        attemptedOperationId: attemptedOperationId,
        baseRevision: baseRevision,
        serverRevision: serverRevision,
        attemptedBody: attemptedBody,
        serverBody: serverBody,
        createdAt: createdAt,
        mergeState: AnnotationMergeState.resolved,
        mergedBody: mergedBody,
        resolvedAt: now.toUtc(),
      );

  /// Projects immutable conflict history onto the annotation revision that
  /// the server currently requires for resolution. Imported conflicts retain
  /// their archived server revision remotely, so this local precondition can
  /// legitimately differ after restore.
  AnnotationConflict atCurrentAnnotationRevision(int revision) {
    if (revision <= 0) throw ArgumentError.value(revision, 'revision');
    return AnnotationConflict(
      conflictId: conflictId,
      annotationId: annotationId,
      attemptedOperationId: attemptedOperationId,
      baseRevision: baseRevision,
      serverRevision: revision,
      attemptedBody: attemptedBody,
      serverBody: serverBody,
      createdAt: createdAt,
      mergeState: mergeState,
      mergedBody: mergedBody,
      resolvedAt: resolvedAt,
    );
  }
}

String _requiredId(Object? value, String field) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (!_uuid.hasMatch(text)) throw FormatException('Invalid $field.');
  return text;
}

String? _optionalId(Object? value, String field) =>
    value == null ? null : _requiredId(value, field);

int _positiveInt(Object? value, String field) {
  final number = (value as num?)?.toInt();
  if (number == null || number <= 0) throw FormatException('Invalid $field.');
  return number;
}

int _nonNegativeInt(Object? value, String field) {
  final number = (value as num?)?.toInt();
  if (number == null || number < 0) throw FormatException('Invalid $field.');
  return number;
}

int? _optionalNonNegativeInt(Object? value, String field) =>
    value == null ? null : _nonNegativeInt(value, field);

String? _boundedText(Object? value, String field, int minimum, int maximum) {
  if (value == null) return null;
  if (value is! String ||
      value.contains('\u0000') ||
      value.runes.length < minimum ||
      value.runes.length > maximum) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

DateTime _requiredDate(Object? value, String field) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toUtc();
  if (parsed == null) throw FormatException('Invalid $field.');
  return parsed;
}

DateTime? _optionalDate(Object? value) =>
    value == null ? null : _requiredDate(value, 'date');

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

List<String> _stringList(Object? value, {required int maximum}) {
  if (value == null) return const [];
  if (value is! List || value.length > maximum) {
    throw const FormatException('Invalid string list.');
  }
  return value
      .map((item) {
        if (item is! String || item.isEmpty || item.length > 512) {
          throw const FormatException('Invalid string list item.');
        }
        return item;
      })
      .toList(growable: false);
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
