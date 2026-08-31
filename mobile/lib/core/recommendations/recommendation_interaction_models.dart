import 'package:flutter/foundation.dart';

enum RecommendationExplanationCode {
  recentCategory('recent_category'),
  followedCategory('followed_category'),
  followedTopic('followed_topic'),
  followedAuthor('followed_author'),
  savedQueryMatch('saved_query_match'),
  feedbackCategoryAffinity('feedback_category_affinity'),
  inferredCategoryAffinity('inferred_category_affinity'),
  reviewedPaperSimilarity('reviewed_paper_similarity'),
  archivedPaperSimilarity('archived_paper_similarity'),
  reviewedPaperCitation('reviewed_paper_citation'),
  archivedPaperCitation('archived_paper_citation'),
  adjacentTopicExploration('adjacent_topic_exploration'),
  underrepresentedCategoryExploration('underrepresented_category_exploration'),
  diversitySlot('diversity_slot');

  const RecommendationExplanationCode(this.wireValue);

  final String wireValue;

  static RecommendationExplanationCode parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid recommendation explanation code.');
  }
}

enum RecommendationSource {
  recent('recent'),
  categoryFollow('category_follow'),
  topicFollow('topic_follow'),
  authorFollow('author_follow'),
  savedQuery('saved_query'),
  feedbackAffinity('feedback_affinity'),
  inferredAffinity('inferred_affinity'),
  semantic('semantic'),
  citation('citation'),
  exploration('exploration');

  const RecommendationSource(this.wireValue);

  final String wireValue;

  static RecommendationSource parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid recommendation explanation source.');
  }
}

@immutable
final class RecommendationExplanation {
  const RecommendationExplanation({
    required this.code,
    required this.title,
    required this.detail,
    required this.source,
    required this.behaviorUsed,
    required this.seedPaperId,
  });

  final RecommendationExplanationCode code;
  final String title;
  final String detail;
  final RecommendationSource source;
  final bool behaviorUsed;
  final String? seedPaperId;

  factory RecommendationExplanation.fromJson(Map<String, dynamic> json) {
    return RecommendationExplanation(
      code: RecommendationExplanationCode.parse(json['code']),
      title: _requiredDisplayString(json, 'title', maximumLength: 256),
      detail: _requiredDisplayString(json, 'detail', maximumLength: 1024),
      source: RecommendationSource.parse(json['source']),
      behaviorUsed: _requiredBool(json, 'behavior_used'),
      seedPaperId: _optionalUuid(json, 'seed_paper_id'),
    );
  }
}

@immutable
final class RecommendationExplanationEnvelope {
  RecommendationExplanationEnvelope({
    required this.batchId,
    required this.paperId,
    required Iterable<RecommendationExplanation> explanations,
  }) : explanations = List<RecommendationExplanation>.unmodifiable(
         explanations,
       );

  final String batchId;
  final String paperId;
  final List<RecommendationExplanation> explanations;

  factory RecommendationExplanationEnvelope.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawExplanations = json['explanations'];
    if (rawExplanations is! List ||
        rawExplanations.isEmpty ||
        rawExplanations.length > 16) {
      throw const FormatException('Invalid recommendation explanations.');
    }
    final explanations = rawExplanations
        .map(
          (value) => value is Map
              ? RecommendationExplanation.fromJson(
                  Map<String, dynamic>.from(value),
                )
              : throw const FormatException(
                  'Invalid recommendation explanation.',
                ),
        )
        .toList(growable: false);
    if (explanations.map((value) => value.code).toSet().length !=
        explanations.length) {
      throw const FormatException('Duplicate recommendation explanation.');
    }
    return RecommendationExplanationEnvelope(
      batchId: _requiredUuid(json, 'batch_id'),
      paperId: _requiredUuid(json, 'paper_id'),
      explanations: explanations,
    );
  }
}

enum RecommendationFeedbackType {
  relevant('relevant'),
  notRelevant('not_relevant'),
  dismissed('dismissed');

  const RecommendationFeedbackType(this.wireValue);

  final String wireValue;
}

enum RecommendationFeedbackReason {
  alreadySeen('already_seen', 'Already seen'),
  offTopic('off_topic', 'Off topic'),
  tooBasic('too_basic', 'Too basic'),
  tooAdvanced('too_advanced', 'Too advanced'),
  lowQuality('low_quality', 'Low quality'),
  other('other', 'Other');

  const RecommendationFeedbackReason(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

@immutable
final class RecommendationFeedbackSelection {
  const RecommendationFeedbackSelection({required this.type, this.reason})
    : assert(
        type != RecommendationFeedbackType.relevant || reason == null,
        'Relevant feedback cannot carry a negative reason.',
      );

  const RecommendationFeedbackSelection.relevant()
    : type = RecommendationFeedbackType.relevant,
      reason = null;

  final RecommendationFeedbackType type;
  final RecommendationFeedbackReason? reason;

  Map<String, Object?> toJson({required String paperId}) => {
    'paper_id': paperId,
    'feedback_type': type.wireValue,
    if (reason != null) 'reason': reason!.wireValue,
  };

  @override
  bool operator ==(Object other) =>
      other is RecommendationFeedbackSelection &&
      other.type == type &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(type, reason);
}

@immutable
final class RecommendationFeedbackResult {
  const RecommendationFeedbackResult({
    required this.feedbackId,
    required this.replayed,
  });

  final String feedbackId;
  final bool replayed;

  factory RecommendationFeedbackResult.fromJson(Map<String, dynamic> json) {
    final replayed = json['replayed'];
    if (replayed is! bool) {
      throw const FormatException('Invalid recommendation feedback replay.');
    }
    return RecommendationFeedbackResult(
      feedbackId: _requiredUuid(json, 'feedback_id'),
      replayed: replayed,
    );
  }
}

bool isRecommendationUuid(String value) =>
    value.length == 36 && _uuid.hasMatch(value);

String _requiredUuid(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !isRecommendationUuid(value)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String? _optionalUuid(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || !isRecommendationUuid(value)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String _requiredDisplayString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.trim() != value ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any(
        (rune) =>
            (rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
            rune == 0x7f,
      )) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
