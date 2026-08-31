import 'annotation.dart';

const memoryPromptMaximumScalars = 10000;
const memoryAnswerMaximumScalars = 100000;

enum MemorySourceType {
  annotation,
  evidenceCard,
  passportField,
  userQuestion;

  String get wireValue => switch (this) {
    MemorySourceType.annotation => 'annotation',
    MemorySourceType.evidenceCard => 'evidence_card',
    MemorySourceType.passportField => 'passport_field',
    MemorySourceType.userQuestion => 'user_question',
  };

  static MemorySourceType fromWire(Object? value) => switch (value) {
    'annotation' => MemorySourceType.annotation,
    'evidence_card' => MemorySourceType.evidenceCard,
    'passport_field' => MemorySourceType.passportField,
    'user_question' => MemorySourceType.userQuestion,
    _ => throw const FormatException('Invalid memory source type.'),
  };
}

enum MemoryStatus {
  active,
  snoozed,
  retired;

  String get wireValue => name;

  static MemoryStatus fromWire(Object? value) => switch (value) {
    'active' => MemoryStatus.active,
    'snoozed' => MemoryStatus.snoozed,
    'retired' => MemoryStatus.retired,
    _ => throw const FormatException('Invalid memory status.'),
  };
}

final class MemoryItem {
  const MemoryItem({
    required this.id,
    required this.paperId,
    required this.generation,
    required this.sourceType,
    required this.sourceId,
    required this.status,
    required this.reviewCount,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.promptText,
    this.answerText,
    this.nextReviewAt,
    this.deletedAt,
    this.syncState = ResearchSyncState.clean,
    this.activeOperationId,
  });

  final String id;
  final String paperId;
  final int generation;
  final MemorySourceType sourceType;
  final String sourceId;
  final String? promptText;
  final String? answerText;
  final MemoryStatus status;
  final DateTime? nextReviewAt;
  final int reviewCount;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ResearchSyncState syncState;
  final String? activeOperationId;

  bool get isDeleted => deletedAt != null;
  bool get isReviewable => !isDeleted && status != MemoryStatus.retired;

  factory MemoryItem.fromJson(
    Map<String, dynamic> json, {
    ResearchSyncState syncState = ResearchSyncState.clean,
    String? activeOperationId,
  }) {
    final status = MemoryStatus.fromWire(json['status']);
    final nextReviewAt = _date(json['next_review_at']);
    if ((status == MemoryStatus.snoozed) != (nextReviewAt != null)) {
      throw const FormatException('Invalid memory review schedule.');
    }
    return MemoryItem(
      id: _id(json['id'], 'memory.id'),
      paperId: _id(json['paper_id'], 'memory.paper_id'),
      generation: _positive(json['generation'], 'memory.generation'),
      sourceType: MemorySourceType.fromWire(json['source_type']),
      sourceId: _id(json['source_id'], 'memory.source_id'),
      promptText: _text(
        json['prompt_text'],
        'memory.prompt_text',
        maximumScalars: memoryPromptMaximumScalars,
      ),
      answerText: _text(
        json['answer_text'],
        'memory.answer_text',
        maximumScalars: memoryAnswerMaximumScalars,
      ),
      status: status,
      nextReviewAt: nextReviewAt,
      reviewCount: _nonNegative(json['review_count'], 'memory.review_count'),
      revision: _nonNegative(json['revision'], 'memory.revision'),
      deletedAt: _date(json['deleted_at']),
      createdAt: _date(json['created_at'], required: true)!,
      updatedAt: _date(json['updated_at'], required: true)!,
      syncState: syncState,
      activeOperationId: activeOperationId,
    );
  }

  MemoryItem copyWith({
    String? promptText,
    bool clearPromptText = false,
    String? answerText,
    bool clearAnswerText = false,
    MemoryStatus? status,
    DateTime? nextReviewAt,
    bool clearNextReviewAt = false,
    int? reviewCount,
    int? revision,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    DateTime? updatedAt,
    ResearchSyncState? syncState,
    String? activeOperationId,
    bool clearActiveOperationId = false,
  }) => MemoryItem(
    id: id,
    paperId: paperId,
    generation: generation,
    sourceType: sourceType,
    sourceId: sourceId,
    promptText: clearPromptText ? null : promptText ?? this.promptText,
    answerText: clearAnswerText ? null : answerText ?? this.answerText,
    status: status ?? this.status,
    nextReviewAt: clearNextReviewAt ? null : nextReviewAt ?? this.nextReviewAt,
    reviewCount: reviewCount ?? this.reviewCount,
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
    'source_type': sourceType.wireValue,
    'source_id': sourceId,
    'prompt_text': promptText,
    'answer_text': answerText,
    'status': status.wireValue,
    'next_review_at': nextReviewAt?.toUtc().toIso8601String(),
    'review_count': reviewCount,
    'revision': revision,
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class MemoryItemWrite {
  const MemoryItemWrite({
    required this.item,
    required this.operationId,
    required this.baseRevision,
  });

  final MemoryItem item;
  final String operationId;
  final int baseRevision;

  Map<String, Object?> toJson() => {
    'id': item.id,
    'operation_id': operationId,
    'paper_id': item.paperId,
    'generation': item.generation,
    'source_type': item.sourceType.wireValue,
    'source_id': item.sourceId,
    'prompt_text': item.promptText,
    'answer_text': item.answerText,
    'status': item.status.wireValue,
    'next_review_at': item.nextReviewAt?.toUtc().toIso8601String(),
    'base_revision': baseRevision,
  };
}

final class MemoryReviewWrite {
  const MemoryReviewWrite({
    required this.operationId,
    required this.baseRevision,
    required this.status,
    required this.reviewedAt,
    this.nextReviewAt,
  });

  final String operationId;
  final int baseRevision;
  final MemoryStatus status;
  final DateTime? nextReviewAt;
  final DateTime reviewedAt;

  Map<String, Object?> toJson() => {
    'operation_id': operationId,
    'base_revision': baseRevision,
    'status': status.wireValue,
    'next_review_at': nextReviewAt?.toUtc().toIso8601String(),
    'reviewed_at': reviewedAt.toUtc().toIso8601String(),
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

String? _text(Object? value, String field, {required int maximumScalars}) {
  if (value == null) return null;
  if (value is! String ||
      value.contains('\u0000') ||
      value.trim().isEmpty ||
      value.runes.length > maximumScalars) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

DateTime? _date(Object? value, {bool required = false}) {
  if (value == null && !required) return null;
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toUtc();
  if (parsed == null) throw const FormatException('Invalid memory date.');
  return parsed;
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
