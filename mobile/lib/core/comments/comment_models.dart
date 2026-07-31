import 'dart:convert';

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
    final body = _requiredText(json, 'body', maximumBytes: 8000);
    if (body.runes.length > 2000 || body.trim().isEmpty) {
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

String normalizeCommentDraft(String input) => input
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\t', ' ')
    .trim();

String? validateCommentBody(String input) {
  final value = normalizeCommentDraft(input);
  if (value.isEmpty) return 'Write a comment before sending.';
  if (value.runes.any(
    (rune) => (rune < 0x20 && rune != 0x0a) || (rune >= 0x7f && rune <= 0x9f),
  )) {
    return 'Remove unsupported control characters.';
  }
  if (value.runes.length > 2000 || utf8.encode(value).length > 8000) {
    return 'Comments are limited to 2,000 characters.';
  }
  final urls = RegExp(
    r'https?://',
    caseSensitive: false,
  ).allMatches(value).length;
  if (urls > 3) return 'Comments may contain at most three links.';
  return null;
}

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
