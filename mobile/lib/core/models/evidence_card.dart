import 'annotation.dart';

const evidenceCardTitleMaximumScalars = 500;
const evidenceCardClaimMaximumScalars = 10000;
const evidenceCardNoteMaximumScalars = 100000;

enum EvidenceVerificationStatus {
  userSelected,
  userReviewed,
  superseded;

  String get wireValue => switch (this) {
    EvidenceVerificationStatus.userSelected => 'user_selected',
    EvidenceVerificationStatus.userReviewed => 'user_reviewed',
    EvidenceVerificationStatus.superseded => 'superseded',
  };

  static EvidenceVerificationStatus fromWire(Object? value) => switch (value) {
    'user_selected' => EvidenceVerificationStatus.userSelected,
    'user_reviewed' => EvidenceVerificationStatus.userReviewed,
    'superseded' => EvidenceVerificationStatus.superseded,
    _ => throw const FormatException('Invalid evidence verification status.'),
  };
}

final class EvidenceCard {
  const EvidenceCard({
    required this.id,
    required this.paperId,
    required this.generation,
    required this.title,
    required this.verificationStatus,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.claimOrQuestion,
    this.userNote,
    this.sourceBlockIds = const [],
    this.figureIds = const [],
    this.tableIds = const [],
    this.citationContextIds = const [],
    this.deletedAt,
    this.syncState = ResearchSyncState.clean,
    this.activeOperationId,
  });

  final String id;
  final String paperId;
  final int generation;
  final String title;
  final String? claimOrQuestion;
  final String? userNote;
  final List<String> sourceBlockIds;
  final List<String> figureIds;
  final List<String> tableIds;
  final List<String> citationContextIds;
  final EvidenceVerificationStatus verificationStatus;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ResearchSyncState syncState;
  final String? activeOperationId;

  bool get isDeleted => deletedAt != null;

  factory EvidenceCard.fromJson(
    Map<String, dynamic> json, {
    ResearchSyncState syncState = ResearchSyncState.clean,
    String? activeOperationId,
  }) => EvidenceCard(
    id: _id(json['id'], 'evidence.id'),
    paperId: _id(json['paper_id'], 'evidence.paper_id'),
    generation: _positive(json['generation'], 'evidence.generation'),
    title: _text(
      json['title'],
      'evidence.title',
      required: true,
      maximumScalars: evidenceCardTitleMaximumScalars,
    )!,
    claimOrQuestion: _text(
      json['claim_or_question'],
      'evidence.claim_or_question',
      required: false,
      maximumScalars: evidenceCardClaimMaximumScalars,
    ),
    userNote: _text(
      json['user_note'],
      'evidence.user_note',
      required: false,
      maximumScalars: evidenceCardNoteMaximumScalars,
    ),
    sourceBlockIds: _ids(json['source_block_ids'], 'source_block_ids'),
    figureIds: _ids(json['figure_ids'], 'figure_ids'),
    tableIds: _ids(json['table_ids'], 'table_ids'),
    citationContextIds: _ids(
      json['citation_context_ids'],
      'citation_context_ids',
    ),
    verificationStatus: EvidenceVerificationStatus.fromWire(
      json['verification_status'],
    ),
    revision: _nonNegative(json['revision'], 'evidence.revision'),
    deletedAt: _date(json['deleted_at'], required: false),
    createdAt: _date(json['created_at'])!,
    updatedAt: _date(json['updated_at'])!,
    syncState: syncState,
    activeOperationId: activeOperationId,
  );

  EvidenceCard copyWith({
    String? title,
    String? claimOrQuestion,
    bool clearClaimOrQuestion = false,
    String? userNote,
    bool clearUserNote = false,
    EvidenceVerificationStatus? verificationStatus,
    int? revision,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    DateTime? updatedAt,
    ResearchSyncState? syncState,
    String? activeOperationId,
    bool clearActiveOperationId = false,
  }) => EvidenceCard(
    id: id,
    paperId: paperId,
    generation: generation,
    title: title ?? this.title,
    claimOrQuestion: clearClaimOrQuestion
        ? null
        : claimOrQuestion ?? this.claimOrQuestion,
    userNote: clearUserNote ? null : userNote ?? this.userNote,
    sourceBlockIds: sourceBlockIds,
    figureIds: figureIds,
    tableIds: tableIds,
    citationContextIds: citationContextIds,
    verificationStatus: verificationStatus ?? this.verificationStatus,
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
    'title': title,
    'claim_or_question': claimOrQuestion,
    'user_note': userNote,
    'source_block_ids': sourceBlockIds,
    'figure_ids': figureIds,
    'table_ids': tableIds,
    'citation_context_ids': citationContextIds,
    'verification_status': verificationStatus.wireValue,
    'revision': revision,
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class EvidenceCardWrite {
  const EvidenceCardWrite({
    required this.card,
    required this.operationId,
    required this.baseRevision,
  });

  final EvidenceCard card;
  final String operationId;
  final int baseRevision;

  Map<String, Object?> toJson() => {
    'id': card.id,
    'operation_id': operationId,
    'paper_id': card.paperId,
    'generation': card.generation,
    'title': card.title,
    'claim_or_question': card.claimOrQuestion,
    'user_note': card.userNote,
    'source_block_ids': card.sourceBlockIds,
    'figure_ids': card.figureIds,
    'table_ids': card.tableIds,
    'citation_context_ids': card.citationContextIds,
    'verification_status': card.verificationStatus.wireValue,
    'base_revision': baseRevision,
  };
}

String _id(Object? value, String field) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (!_uuid.hasMatch(text)) throw FormatException('Invalid $field.');
  return text;
}

int _positive(Object? value, String field) {
  final parsed = (value as num?)?.toInt();
  if (parsed == null || parsed <= 0) throw FormatException('Invalid $field.');
  return parsed;
}

int _nonNegative(Object? value, String field) {
  final parsed = (value as num?)?.toInt();
  if (parsed == null || parsed < 0) throw FormatException('Invalid $field.');
  return parsed;
}

String? _text(
  Object? value,
  String field, {
  required bool required,
  required int maximumScalars,
}) {
  if (value == null && !required) return null;
  if (value is! String ||
      value.contains('\u0000') ||
      value.runes.length > maximumScalars ||
      value.trim().isEmpty) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

DateTime? _date(Object? value, {bool required = true}) {
  if (value == null && !required) return null;
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toUtc();
  if (parsed == null) throw const FormatException('Invalid evidence date.');
  return parsed;
}

List<String> _ids(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List || value.length > 2048) {
    throw FormatException('Invalid $field.');
  }
  return value.map((item) => _id(item, field)).toList(growable: false);
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
