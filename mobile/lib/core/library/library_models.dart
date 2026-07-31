import '../models/paper.dart';

enum LibraryMutationIntent { save, remove }

enum LibraryOutboxState { queued, recovery, inFlight, failed }

final class LibraryCanonicalItem {
  const LibraryCanonicalItem({
    required this.paperId,
    required this.state,
    required this.savedAt,
    required this.updatedAt,
    required this.removed,
    required this.removedAt,
    required this.revision,
    required this.lastOperationId,
  });

  final String paperId;
  final String state;
  final DateTime savedAt;
  final DateTime updatedAt;
  final bool removed;
  final DateTime? removedAt;
  final int revision;
  final String lastOperationId;

  factory LibraryCanonicalItem.fromJson(Map<String, dynamic> json) {
    final paperId = _requiredUuid(json, 'paper_id');
    final state = _requiredString(json, 'state', maximumLength: 32);
    if (state != 'to_read') {
      throw const FormatException('Unsupported library state.');
    }
    final savedAt = _requiredDate(json, 'saved_at');
    final updatedAt = _requiredDate(json, 'updated_at');
    if (updatedAt.isBefore(savedAt)) {
      throw const FormatException('Library update predates its save.');
    }
    final removed = json['removed'];
    if (removed is! bool) {
      throw const FormatException('Invalid library removal marker.');
    }
    final removedAt = _optionalDate(json, 'removed_at');
    if (removed != (removedAt != null) ||
        (removed && !removedAt!.isAtSameMomentAs(updatedAt))) {
      throw const FormatException('Inconsistent library removal timestamp.');
    }
    final revision = json['revision'];
    if (revision is! int || revision <= 0) {
      throw const FormatException('Invalid library revision.');
    }
    return LibraryCanonicalItem(
      paperId: paperId,
      state: state,
      savedAt: savedAt,
      updatedAt: updatedAt,
      removed: removed,
      removedAt: removedAt,
      revision: revision,
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }
}

final class LibraryRemoteEntry {
  const LibraryRemoteEntry({required this.item, required this.paper});

  final LibraryCanonicalItem item;
  final PaperSummary? paper;

  factory LibraryRemoteEntry.fromJson(
    Map<String, dynamic> json, {
    required bool paperRequired,
  }) {
    final rawItem = json['item'];
    if (rawItem is! Map) {
      throw const FormatException('Missing library item.');
    }
    final item = LibraryCanonicalItem.fromJson(
      Map<String, dynamic>.from(rawItem),
    );
    final rawPaper = json['paper'];
    final paper = switch (rawPaper) {
      final Map value => PaperSummary.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException('Invalid library paper summary.'),
    };
    if ((paperRequired || !item.removed) && paper == null) {
      throw const FormatException('Active library item omitted its paper.');
    }
    if (paper != null && paper.paperId != item.paperId) {
      throw const FormatException('Library paper identity mismatch.');
    }
    return LibraryRemoteEntry(item: item, paper: paper);
  }
}

final class LibraryListPage {
  const LibraryListPage({
    required this.items,
    required this.nextCursor,
    required this.syncRevision,
  });

  final List<LibraryRemoteEntry> items;
  final String? nextCursor;
  final int syncRevision;

  factory LibraryListPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final syncRevision = json['sync_revision'];
    if (rawItems is! List || syncRevision is! int || syncRevision < 0) {
      throw const FormatException('Invalid library list envelope.');
    }
    final nextCursor = _optionalBoundedString(
      json,
      'next_cursor',
      maximumLength: 2048,
    );
    final items = rawItems
        .map(
          (raw) => raw is Map
              ? LibraryRemoteEntry.fromJson(
                  Map<String, dynamic>.from(raw),
                  paperRequired: true,
                )
              : throw const FormatException('Invalid library list entry.'),
        )
        .toList(growable: false);
    if (items.any(
      (entry) => entry.item.removed || entry.item.revision > syncRevision,
    )) {
      throw const FormatException('Invalid library list snapshot.');
    }
    return LibraryListPage(
      items: items,
      nextCursor: nextCursor,
      syncRevision: syncRevision,
    );
  }
}

final class LibraryChangesPage {
  const LibraryChangesPage({
    required this.items,
    required this.nextAfterRevision,
    required this.hasMore,
    required this.syncRevision,
  });

  final List<LibraryRemoteEntry> items;
  final int nextAfterRevision;
  final bool hasMore;
  final int syncRevision;

  factory LibraryChangesPage.fromJson(
    Map<String, dynamic> json, {
    required int afterRevision,
  }) {
    final rawItems = json['items'];
    final nextAfterRevision = json['next_after_revision'];
    final hasMore = json['has_more'];
    final syncRevision = json['sync_revision'];
    if (rawItems is! List ||
        nextAfterRevision is! int ||
        hasMore is! bool ||
        syncRevision is! int ||
        nextAfterRevision < afterRevision ||
        syncRevision < nextAfterRevision) {
      throw const FormatException('Invalid library changes envelope.');
    }
    final items = rawItems
        .map(
          (raw) => raw is Map
              ? LibraryRemoteEntry.fromJson(
                  Map<String, dynamic>.from(raw),
                  paperRequired: false,
                )
              : throw const FormatException('Invalid library change entry.'),
        )
        .toList(growable: false);
    var previous = afterRevision;
    for (final entry in items) {
      if (entry.item.revision <= previous ||
          entry.item.revision > syncRevision) {
        throw const FormatException('Library changes are not ascending.');
      }
      previous = entry.item.revision;
    }
    if (hasMore) {
      if (items.isEmpty || nextAfterRevision != items.last.item.revision) {
        throw const FormatException('Invalid paged changes checkpoint.');
      }
    } else if (nextAfterRevision != syncRevision) {
      throw const FormatException('Incomplete changes checkpoint.');
    }
    return LibraryChangesPage(
      items: items,
      nextAfterRevision: nextAfterRevision,
      hasMore: hasMore,
      syncRevision: syncRevision,
    );
  }
}

final class LibraryMutationResult {
  const LibraryMutationResult(this.item);

  final LibraryCanonicalItem item;

  factory LibraryMutationResult.fromJson(Map<String, dynamic> json) {
    final raw = json['item'];
    if (raw is! Map) {
      throw const FormatException('Missing canonical library item.');
    }
    return LibraryMutationResult(
      LibraryCanonicalItem.fromJson(Map<String, dynamic>.from(raw)),
    );
  }
}

final class LibrarySyncIssue {
  const LibrarySyncIssue({required this.code, required this.message});

  final String code;
  final String message;

  factory LibrarySyncIssue.fromCode(String code) => LibrarySyncIssue(
    code: _safeErrorCode(code),
    message: switch (code) {
      'UNAUTHENTICATED' ||
      'TOKEN_EXPIRED' => 'Sign in again to sync this save.',
      'PAPER_NOT_FOUND' => 'This paper is no longer available to save.',
      'RATE_LIMITED' => 'This save is waiting to retry.',
      _ => 'This save could not sync. Change it again to retry.',
    },
  );

  @override
  bool operator ==(Object other) =>
      other is LibrarySyncIssue &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}

final class LibrarySavedState {
  const LibrarySavedState({
    required this.saved,
    required this.syncPending,
    this.issue,
  });

  const LibrarySavedState.notSaved()
    : saved = false,
      syncPending = false,
      issue = null;

  final bool saved;
  final bool syncPending;
  final LibrarySyncIssue? issue;

  @override
  bool operator ==(Object other) =>
      other is LibrarySavedState &&
      other.saved == saved &&
      other.syncPending == syncPending &&
      other.issue == issue;

  @override
  int get hashCode => Object.hash(saved, syncPending, issue);
}

final class LibraryListItem {
  const LibraryListItem({
    required this.paper,
    required this.savedAt,
    required this.savedState,
  });

  final PaperSummary paper;
  final DateTime savedAt;
  final LibrarySavedState savedState;
}

final class LibraryPendingOperation {
  const LibraryPendingOperation({
    required this.operationId,
    required this.accountId,
    required this.paperId,
    required this.intent,
    required this.createdAt,
    required this.attemptCount,
  });

  final String operationId;
  final String accountId;
  final String paperId;
  final LibraryMutationIntent intent;
  final DateTime createdAt;
  final int attemptCount;
}

enum LibrarySyncPhase { idle, syncing, pending, failed }

final class LibrarySyncStatus {
  const LibrarySyncStatus({
    required this.phase,
    this.pendingCount = 0,
    this.issue,
  });

  const LibrarySyncStatus.idle()
    : phase = LibrarySyncPhase.idle,
      pendingCount = 0,
      issue = null;

  final LibrarySyncPhase phase;
  final int pendingCount;
  final LibrarySyncIssue? issue;
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String _requiredUuid(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key, maximumLength: 36);
  if (!_uuid.hasMatch(value)) throw FormatException('Invalid $key.');
  return value.toLowerCase();
}

String? _optionalBoundedString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20)) {
    throw FormatException('Invalid $key.');
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
  if (raw is! String || raw.length > 64) {
    throw FormatException('Invalid $key.');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !raw.endsWith('Z')) {
    throw FormatException('Invalid $key.');
  }
  return parsed.toUtc();
}

String _safeErrorCode(String value) =>
    RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value)
    ? value
    : 'LIBRARY_SYNC_FAILED';

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
