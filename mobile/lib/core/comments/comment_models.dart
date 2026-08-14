import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

const commentMaximumScalars = 2000;
const commentMaximumBytes = 8000;
const commentMaximumUrls = 3;
// This admits the widest valid boundary cases: 2,000 supplementary scalars
// need 4,000 UTF-16 units, while 2,000 decomposed Hangul syllables need 6,000.
// Anything larger cannot be a useful mobile comment without spending
// disproportionate work before the authoritative normalized limits are known.
const commentMaximumRawCodeUnits = commentMaximumScalars * 3;
const commentMaximumRawClusterCodeUnits = 64;
const commentMaximumRawClusterScalars = 64;
const commentRawInputTooLargeMessage = 'Comment input is too large.';
const commentComplexTextMessage =
    'Simplify unusually complex character sequences.';
const commentUnsupportedCharactersMessage =
    'Remove unsupported control characters.';

typedef CommentBodyMeasurement = ({int normalizedScalars, String? issue});

final class CommentBodyAnalysis {
  const CommentBodyAnalysis({
    required this.canonicalBody,
    required this.normalizedScalars,
    required this.issue,
  });

  final String? canonicalBody;
  final int normalizedScalars;
  final String? issue;
}

enum CommentStatus { pendingReview, published, hidden, deleted }

enum CommentAccountStatus { active, suspended, deletionPending, deleted }

enum CommentReportReason {
  spam('spam', 'Spam'),
  harassment('harassment', 'Harassment'),
  hate('hate', 'Hate'),
  threat('threat', 'Threat'),
  sexualContent('sexual_content', 'Sexual content'),
  privacy('privacy', 'Privacy or personal information'),
  impersonation('impersonation', 'Impersonation'),
  copyright('copyright', 'Copyright'),
  other('other', 'Other');

  const CommentReportReason(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

final class CommentAuthor {
  const CommentAuthor({
    required this.id,
    required this.status,
    this.handle,
    this.displayName,
  });

  factory CommentAuthor.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'id', 'handle', 'display_name', 'status'});
    return CommentAuthor(
      id: _requiredUuid(json, 'id'),
      handle: _optionalHandle(json['handle']),
      displayName: _optionalDisplayName(json['display_name']),
      status: switch (json['status']) {
        'active' => CommentAccountStatus.active,
        'suspended' => CommentAccountStatus.suspended,
        'deletion_pending' => CommentAccountStatus.deletionPending,
        'deleted' => CommentAccountStatus.deleted,
        _ => throw const FormatException('Invalid public account status.'),
      },
    );
  }

  final String id;
  final String? handle;
  final String? displayName;
  final CommentAccountStatus status;

  String get visibleName =>
      displayName ?? (handle == null ? 'Reader' : '@$handle');

  Map<String, Object?> toJson() => {
    'id': id,
    'handle': handle,
    'display_name': displayName,
    'status': switch (status) {
      CommentAccountStatus.active => 'active',
      CommentAccountStatus.suspended => 'suspended',
      CommentAccountStatus.deletionPending => 'deletion_pending',
      CommentAccountStatus.deleted => 'deleted',
    },
  };
}

final class PaperComment {
  const PaperComment({
    required this.id,
    required this.paperId,
    required this.author,
    required this.body,
    required this.status,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.editedAt,
  });

  factory PaperComment.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'paper_id',
      'author',
      'body',
      'status',
      'version',
      'created_at',
      'updated_at',
      'edited_at',
    });
    final rawAuthor = json['author'];
    if (rawAuthor is! Map) {
      throw const FormatException('Invalid comment author.');
    }
    final body = _requiredText(json, 'body', maximumBytes: commentMaximumBytes);
    final bodyAnalysis = analyzeCommentBody(body);
    if (bodyAnalysis.issue != null || bodyAnalysis.canonicalBody != body) {
      throw const FormatException('Invalid comment body.');
    }
    final createdAt = _requiredDate(json, 'created_at');
    final updatedAt = _requiredDate(json, 'updated_at');
    final editedAt = _optionalDate(json, 'edited_at');
    if (updatedAt.isBefore(createdAt) ||
        (editedAt != null &&
            (editedAt.isBefore(createdAt) || editedAt.isAfter(updatedAt)))) {
      throw const FormatException('Invalid comment timestamps.');
    }
    final version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('Invalid comment version.');
    }
    return PaperComment(
      id: _requiredUuid(json, 'id'),
      paperId: _requiredUuid(json, 'paper_id'),
      author: CommentAuthor.fromJson(Map<String, dynamic>.from(rawAuthor)),
      body: body,
      status: switch (json['status']) {
        'pending_review' => CommentStatus.pendingReview,
        'published' => CommentStatus.published,
        'hidden' => CommentStatus.hidden,
        'deleted' => CommentStatus.deleted,
        _ => throw const FormatException('Invalid comment status.'),
      },
      version: version,
      createdAt: createdAt,
      updatedAt: updatedAt,
      editedAt: editedAt,
    );
  }

  final String id;
  final String paperId;
  final CommentAuthor author;
  final String body;
  final CommentStatus status;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? editedAt;

  bool get publiclyVisible => status == CommentStatus.published;
  bool get underReview => status == CommentStatus.pendingReview;

  Map<String, Object?> toJson() => {
    'id': id,
    'paper_id': paperId,
    'author': author.toJson(),
    'body': body,
    'status': switch (status) {
      CommentStatus.pendingReview => 'pending_review',
      CommentStatus.published => 'published',
      CommentStatus.hidden => 'hidden',
      CommentStatus.deleted => 'deleted',
    },
    'version': version,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'edited_at': editedAt?.toUtc().toIso8601String(),
  };
}

final class CommentPage {
  const CommentPage({required this.items, required this.nextCursor});

  factory CommentPage.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'items', 'next_cursor'});
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 100) {
      throw const FormatException('Invalid comment page items.');
    }
    final items = rawItems
        .map(
          (value) => value is Map
              ? PaperComment.fromJson(Map<String, dynamic>.from(value))
              : throw const FormatException('Invalid comment page item.'),
        )
        .toList(growable: false);
    final seen = <String>{};
    DateTime? previousCreatedAt;
    String? previousId;
    for (final item in items) {
      if (!seen.add(item.id)) {
        throw const FormatException('Duplicate comment in page.');
      }
      if (previousCreatedAt != null &&
          (item.createdAt.isAfter(previousCreatedAt) ||
              (item.createdAt == previousCreatedAt &&
                  item.id.compareTo(previousId!) >= 0))) {
        throw const FormatException('Comment page is not newest first.');
      }
      previousCreatedAt = item.createdAt;
      previousId = item.id;
    }
    return CommentPage(
      items: items,
      nextCursor: _optionalCursor(json['next_cursor']),
    );
  }

  final List<PaperComment> items;
  final String? nextCursor;

  Map<String, Object?> toJson() => {
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'next_cursor': nextCursor,
  };
}

final class BlockedUser {
  const BlockedUser({required this.user, required this.createdAt});

  factory BlockedUser.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'user', 'created_at'});
    final user = json['user'];
    if (user is! Map) throw const FormatException('Invalid blocked user.');
    return BlockedUser(
      user: CommentAuthor.fromJson(Map<String, dynamic>.from(user)),
      createdAt: _requiredDate(json, 'created_at'),
    );
  }

  final CommentAuthor user;
  final DateTime createdAt;
}

final class BlockedUserPage {
  const BlockedUserPage({required this.items, required this.nextCursor});

  factory BlockedUserPage.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'items', 'next_cursor'});
    final raw = json['items'];
    if (raw is! List || raw.length > 100) {
      throw const FormatException('Invalid blocked-user page.');
    }
    final items = raw
        .map(
          (value) => value is Map
              ? BlockedUser.fromJson(Map<String, dynamic>.from(value))
              : throw const FormatException('Invalid blocked user.'),
        )
        .toList(growable: false);
    if (items.map((item) => item.user.id).toSet().length != items.length) {
      throw const FormatException('Duplicate blocked user.');
    }
    return BlockedUserPage(
      items: items,
      nextCursor: _optionalCursor(json['next_cursor']),
    );
  }

  final List<BlockedUser> items;
  final String? nextCursor;
}

final class CommentReportReceipt {
  const CommentReportReceipt({
    required this.id,
    required this.commentId,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  factory CommentReportReceipt.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'comment_id',
      'reason',
      'status',
      'created_at',
    });
    final reason = CommentReportReason.values.where(
      (value) => value.wireValue == json['reason'],
    );
    final status = json['status'];
    if (reason.length != 1 ||
        status is! String ||
        !const {'open', 'reviewed', 'actioned', 'dismissed'}.contains(status)) {
      throw const FormatException('Invalid report receipt.');
    }
    return CommentReportReceipt(
      id: _requiredUuid(json, 'id'),
      commentId: _requiredUuid(json, 'comment_id'),
      reason: reason.single,
      status: status,
      createdAt: _requiredDate(json, 'created_at'),
    );
  }

  final String id;
  final String commentId;
  final CommentReportReason reason;
  final String status;
  final DateTime createdAt;
}

final class UserReportReceipt {
  const UserReportReceipt({
    required this.id,
    required this.reportedUserId,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  factory UserReportReceipt.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'reported_user_id',
      'reason',
      'status',
      'created_at',
    });
    final reason = CommentReportReason.values.where(
      (value) => value.wireValue == json['reason'],
    );
    final status = json['status'];
    if (reason.length != 1 ||
        status is! String ||
        !const {'open', 'reviewed', 'actioned', 'dismissed'}.contains(status)) {
      throw const FormatException('Invalid user-report receipt.');
    }
    return UserReportReceipt(
      id: _requiredUuid(json, 'id'),
      reportedUserId: _requiredUuid(json, 'reported_user_id'),
      reason: reason.single,
      status: status,
      createdAt: _requiredDate(json, 'created_at'),
    );
  }

  final String id;
  final String reportedUserId;
  final CommentReportReason reason;
  final String status;
  final DateTime createdAt;
}

bool commentDraftWithinRawLimit(String input) =>
    input.length <= commentMaximumRawCodeUnits;

String? validateCommentDraftInput(String input) {
  if (!commentDraftWithinRawLimit(input)) {
    return commentRawInputTooLargeMessage;
  }
  if (_containsUnsupportedRawCommentInput(input)) {
    return commentUnsupportedCharactersMessage;
  }
  for (final cluster in input.characters) {
    if (cluster.length > commentMaximumRawClusterCodeUnits) {
      return commentComplexTextMessage;
    }
    var scalarCount = 0;
    for (final _ in cluster.runes) {
      scalarCount += 1;
      if (scalarCount > commentMaximumRawClusterScalars) {
        return commentComplexTextMessage;
      }
    }
  }
  return null;
}

String normalizeCommentDraft(String input) {
  final issue = validateCommentDraftInput(input);
  if (issue != null) {
    throw ArgumentError.value(input.length, 'input', issue);
  }
  return _normalizeCommentDraftUnchecked(input);
}

String _normalizeCommentDraftUnchecked(String input) {
  final normalized = unicode
      .nfkc(input.replaceAll('\r\n', '\n').replaceAll('\r', '\n'))
      .replaceAll('\t', ' ')
      .trim();
  final lines = <String>[];
  var previousWasBlank = false;
  for (final rawLine in normalized.split('\n')) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) {
      if (!previousWasBlank) lines.add('');
      previousWasBlank = true;
    } else {
      lines.add(line);
      previousWasBlank = false;
    }
  }
  return lines.join('\n');
}

int normalizedCommentScalarCount(String input) {
  final analysis = analyzeCommentBody(input);
  if (analysis.canonicalBody == null) {
    throw ArgumentError.value(input.length, 'input', analysis.issue);
  }
  return analysis.normalizedScalars;
}

CommentBodyAnalysis analyzeCommentBody(String input) {
  final draftIssue = validateCommentDraftInput(input);
  if (draftIssue != null) {
    return CommentBodyAnalysis(
      canonicalBody: null,
      normalizedScalars: 0,
      issue: draftIssue,
    );
  }
  final value = _normalizeCommentDraftUnchecked(input);
  final normalizedScalars = value.runes.length;
  String? issue;
  if (value.isEmpty) {
    issue = 'Write a comment before sending.';
  }
  if (value.runes.any((rune) => _isUnsafeCommentRune(rune) && rune != 0x0a)) {
    issue = commentUnsupportedCharactersMessage;
  } else if (normalizedScalars > commentMaximumScalars ||
      utf8.encode(value).length > commentMaximumBytes) {
    issue = 'Comments are limited to $commentMaximumScalars characters.';
  } else {
    final urls = RegExp(
      r'https?://',
      caseSensitive: false,
    ).allMatches(value).length;
    if (urls > commentMaximumUrls) {
      issue = 'Comments may contain at most three links.';
    }
  }
  return CommentBodyAnalysis(
    canonicalBody: value,
    normalizedScalars: normalizedScalars,
    issue: issue,
  );
}

String? validateCommentBody(String input) => analyzeCommentBody(input).issue;

CommentBodyMeasurement measureCommentBody(String input) {
  final analysis = analyzeCommentBody(input);
  return (normalizedScalars: analysis.normalizedScalars, issue: analysis.issue);
}

bool _containsUnsupportedRawCommentInput(String input) {
  for (var index = 0; index < input.length; index += 1) {
    final codeUnit = input.codeUnitAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= input.length) return true;
      final next = input.codeUnitAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return true;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    } else if (_isUnsafeCommentRune(codeUnit) &&
        codeUnit != 0x0a &&
        codeUnit != 0x0d &&
        codeUnit != 0x09) {
      return true;
    }
  }
  return false;
}

bool _isUnsafeCommentRune(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x061c ||
    (rune >= 0x200b && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x2069) ||
    rune == 0xfeff;

void _expectKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.length != expected.length ||
      json.keys.any((key) => !expected.contains(key))) {
    throw const FormatException('Unexpected comment response fields.');
  }
}

String _requiredUuid(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !_uuid.hasMatch(value)) {
    throw FormatException('Invalid $key.');
  }
  return value.toLowerCase();
}

String _requiredText(
  Map<String, dynamic> json,
  String key, {
  required int maximumBytes,
}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      utf8.encode(value).length > maximumBytes ||
      value.runes.any(
        (rune) =>
            (rune < 0x20 && rune != 0x0a && rune != 0x09) ||
            (rune >= 0x7f && rune <= 0x9f),
      )) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String? _optionalHandle(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(value)) {
    throw const FormatException('Invalid public handle.');
  }
  return value;
}

String? _optionalDisplayName(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.runes.length > 80 ||
      value.runes.any(
        (rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f),
      )) {
    throw const FormatException('Invalid public display name.');
  }
  return value;
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = _optionalDate(json, key);
  if (value == null) throw FormatException('Invalid $key.');
  return value;
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw == null) return null;
  if (raw is! String || raw.length > 64 || !raw.endsWith('Z')) {
    throw FormatException('Invalid $key.');
  }
  final value = DateTime.tryParse(raw);
  if (value == null) throw FormatException('Invalid $key.');
  return value.toUtc();
}

String? _optionalCursor(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > 512 ||
      value.runes.any((rune) => rune < 0x21 || rune > 0x7e)) {
    throw const FormatException('Invalid comment cursor.');
  }
  return value;
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
