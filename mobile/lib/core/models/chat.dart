enum ChatRole {
  user,
  assistant;

  static ChatRole fromWire(Object? value) =>
      value?.toString() == 'assistant' ? assistant : user;
}

class ChatEvidence {
  const ChatEvidence({
    required this.sectionKind,
    required this.sectionHeading,
    required this.chunkId,
    this.pageStart,
    this.pageEnd,
  });

  final String sectionKind;
  final String sectionHeading;
  final int? pageStart;
  final int? pageEnd;
  final String chunkId;

  String get badgeLabel {
    final heading = sectionHeading.trim().isEmpty
        ? sectionKind
        : sectionHeading.trim();
    if (pageStart == null) return heading;
    final pages = pageEnd != null && pageEnd != pageStart
        ? 'pp. $pageStart–$pageEnd'
        : 'p. $pageStart';
    return '$heading, $pages';
  }

  factory ChatEvidence.fromJson(Map<String, dynamic> json) => ChatEvidence(
    sectionKind: (json['section_kind'] ?? '').toString(),
    sectionHeading: (json['section_heading'] ?? '').toString(),
    pageStart: (json['page_start'] as num?)?.toInt(),
    pageEnd: (json['page_end'] as num?)?.toInt(),
    chunkId: (json['chunk_id'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'section_kind': sectionKind,
    'section_heading': sectionHeading,
    if (pageStart != null) 'page_start': pageStart,
    if (pageEnd != null) 'page_end': pageEnd,
    'chunk_id': chunkId,
  };
}

class ChatAnswer {
  const ChatAnswer({
    required this.answerMarkdown,
    required this.insufficientEvidence,
    required this.evidence,
    required this.suggestedFollowUps,
    this.generation = 1,
    this.threadId,
  });

  final String answerMarkdown;
  final bool insufficientEvidence;
  final List<ChatEvidence> evidence;
  final List<String> suggestedFollowUps;
  final int generation;
  final String? threadId;

  factory ChatAnswer.fromJson(Map<String, dynamic> raw) {
    final nested = raw['answer'];
    final json = nested is Map
        ? <String, dynamic>{...Map<String, dynamic>.from(nested), ...raw}
        : raw;
    return ChatAnswer(
      answerMarkdown: (json['answer_markdown'] ?? json['content'] ?? '')
          .toString()
          .trim(),
      insufficientEvidence: json['insufficient_evidence'] as bool? ?? false,
      evidence: (json['evidence'] as List<dynamic>? ?? const [])
          .map(
            (value) =>
                ChatEvidence.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(growable: false),
      suggestedFollowUps:
          (json['suggested_follow_ups'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
      generation: switch ((json['generation'] as num?)?.toInt()) {
        final value? when value > 0 => value,
        _ => 1,
      },
      threadId: json['thread_id']?.toString(),
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.evidence = const [],
    this.insufficientEvidence = false,
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final List<ChatEvidence> evidence;
  final bool insufficientEvidence;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: (json['id'] ?? '').toString(),
    role: ChatRole.fromWire(json['role']),
    content: (json['content'] ?? '').toString(),
    createdAt:
        DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    evidence: (json['evidence'] as List<dynamic>? ?? const [])
        .map(
          (value) =>
              ChatEvidence.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(growable: false),
    insufficientEvidence: json['insufficient_evidence'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    'content': content,
    'created_at': createdAt.toUtc().toIso8601String(),
    'evidence': evidence.map((source) => source.toJson()).toList(),
    'insufficient_evidence': insufficientEvidence,
  };
}

class ChatSnapshot {
  const ChatSnapshot({
    this.threadId,
    this.messages = const [],
    this.generation,
  });

  final String? threadId;
  final List<ChatMessage> messages;
  final int? generation;

  factory ChatSnapshot.fromJson(Map<String, dynamic> json) => ChatSnapshot(
    threadId: json['thread_id']?.toString(),
    messages: (json['messages'] as List<dynamic>? ?? const [])
        .map(
          (value) =>
              ChatMessage.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(growable: false),
    generation: switch ((json['generation'] as num?)?.toInt()) {
      final value? when value > 0 => value,
      _ => null,
    },
  );

  Map<String, dynamic> toJson() => {
    if (threadId != null) 'thread_id': threadId,
    if (generation != null) 'generation': generation,
    'messages': messages.map((message) => message.toJson()).toList(),
  };
}
