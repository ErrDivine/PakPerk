import '../models/paper.dart';
import 'library_models.dart';

final class LibraryV2Item {
  const LibraryV2Item({
    required this.paperId,
    required this.state,
    required this.privateNote,
    required this.saveSourceKind,
    required this.reminderAt,
    required this.savedAt,
    required this.updatedAt,
    required this.reviewedAt,
    required this.archivedAt,
    required this.removed,
    required this.removedAt,
    required this.revision,
    required this.lastOperationId,
  });

  final String paperId;
  final LibraryItemState state;
  final String? privateNote;
  final LibrarySaveSourceKind? saveSourceKind;
  final DateTime? reminderAt;
  final DateTime savedAt;
  final DateTime updatedAt;
  final DateTime? reviewedAt;
  final DateTime? archivedAt;
  final bool removed;
  final DateTime? removedAt;
  final int revision;
  final String lastOperationId;

  factory LibraryV2Item.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {
      'paper_id',
      'state',
      'private_note',
      'save_source_kind',
      'reminder_at',
      'saved_at',
      'updated_at',
      'reviewed_at',
      'archived_at',
      'removed',
      'removed_at',
      'revision',
      'last_operation_id',
    });
    final state = LibraryItemState.tryFromStorage(
      _requiredString(json, 'state', maximumLength: 16),
    );
    if (state == null || json['state'] == 'to_read') {
      throw const FormatException('Invalid library state.');
    }
    final source = LibrarySaveSourceKind.tryFromWire(
      _optionalString(json, 'save_source_kind', maximumLength: 32),
    );
    // A newer server provenance is not equivalent to the explicit `other`
    // value. Preserve it as unknown/null until this client understands it.
    final savedAt = _requiredDate(json, 'saved_at');
    final updatedAt = _requiredDate(json, 'updated_at');
    final reviewedAt = _optionalDate(json, 'reviewed_at');
    final archivedAt = _optionalDate(json, 'archived_at');
    final removedAt = _optionalDate(json, 'removed_at');
    final reminderAt = _optionalDate(json, 'reminder_at');
    final removed = json['removed'];
    final revision = json['revision'];
    if (removed is! bool || revision is! int || revision <= 0) {
      throw const FormatException('Invalid library item metadata.');
    }
    if (removed != (removedAt != null) || updatedAt.isBefore(savedAt)) {
      throw const FormatException('Inconsistent library item timestamps.');
    }
    if (state == LibraryItemState.reviewed && reviewedAt == null) {
      throw const FormatException('Reviewed item omitted reviewed_at.');
    }
    if (state == LibraryItemState.archived && archivedAt == null) {
      throw const FormatException('Archived item omitted archived_at.');
    }
    if (reminderAt != null && (removed || !state.isActive)) {
      throw const FormatException('Inactive library item carried a reminder.');
    }
    return LibraryV2Item(
      paperId: _requiredUuid(json, 'paper_id'),
      state: state,
      privateNote: _optionalString(json, 'private_note', maximumLength: 500),
      saveSourceKind: source,
      reminderAt: reminderAt,
      savedAt: savedAt,
      updatedAt: updatedAt,
      reviewedAt: reviewedAt,
      archivedAt: archivedAt,
      removed: removed,
      removedAt: removedAt,
      revision: revision,
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }

  Map<String, dynamic> toJson() => {
    'paper_id': paperId,
    'state': state.storageValue,
    'private_note': privateNote,
    'save_source_kind': saveSourceKind?.wireValue,
    'reminder_at': reminderAt?.toUtc().toIso8601String(),
    'saved_at': savedAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'reviewed_at': reviewedAt?.toIso8601String(),
    'archived_at': archivedAt?.toIso8601String(),
    'removed': removed,
    'removed_at': removedAt?.toIso8601String(),
    'revision': revision,
    'last_operation_id': lastOperationId,
  };
}

final class LibraryV2Entry {
  const LibraryV2Entry({required this.item, required this.paper});

  final LibraryV2Item item;
  final PaperSummary? paper;

  factory LibraryV2Entry.fromJson(
    Map<String, dynamic> json, {
    required bool paperRequired,
  }) {
    _requireKeys(json, const {'item', 'paper'});
    final item = LibraryV2Item.fromJson(_requiredMap(json, 'item'));
    final rawPaper = json['paper'];
    final paper = rawPaper == null
        ? null
        : PaperSummary.fromJson(_asMap(rawPaper, 'paper'));
    if ((paperRequired || !item.removed) && paper == null) {
      throw const FormatException('Active library item omitted its paper.');
    }
    if (paper != null && paper.paperId != item.paperId) {
      throw const FormatException('Library paper identity mismatch.');
    }
    return LibraryV2Entry(item: item, paper: paper);
  }
}

final class LibraryV2ItemsPage {
  const LibraryV2ItemsPage({
    required this.items,
    required this.nextCursor,
    required this.syncRevision,
  });

  final List<LibraryV2Entry> items;
  final String? nextCursor;
  final int syncRevision;

  factory LibraryV2ItemsPage.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'items', 'next_cursor', 'sync_revision'});
    final syncRevision = _nonNegativeRevision(json, 'sync_revision');
    final rawItems = json['items'];
    if (rawItems is! List) throw const FormatException('Invalid items.');
    final items = rawItems
        .map(
          (value) => LibraryV2Entry.fromJson(
            _asMap(value, 'items'),
            paperRequired: true,
          ),
        )
        .toList(growable: false);
    if (items.any(
      (entry) => entry.item.removed || entry.item.revision > syncRevision,
    )) {
      throw const FormatException('Invalid library snapshot.');
    }
    return LibraryV2ItemsPage(
      items: List.unmodifiable(items),
      nextCursor: _optionalString(json, 'next_cursor', maximumLength: 512),
      syncRevision: syncRevision,
    );
  }
}

final class LibraryV2List {
  const LibraryV2List({
    required this.id,
    required this.name,
    required this.description,
    required this.sortOrder,
    required this.revision,
    required this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOperationId,
  });

  final String id;
  final String name;
  final String? description;
  final int sortOrder;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastOperationId;

  factory LibraryV2List.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {
      'id',
      'name',
      'description',
      'sort_order',
      'revision',
      'deleted_at',
      'created_at',
      'updated_at',
      'last_operation_id',
    });
    final sortOrder = json['sort_order'];
    if (sortOrder is! int) throw const FormatException('Invalid sort order.');
    return LibraryV2List(
      id: _requiredUuid(json, 'id'),
      name: _requiredString(json, 'name', maximumLength: 100),
      description: _optionalString(json, 'description', maximumLength: 500),
      sortOrder: sortOrder,
      revision: _positiveRevision(json, 'revision'),
      deletedAt: _optionalDate(json, 'deleted_at'),
      createdAt: _requiredDate(json, 'created_at'),
      updatedAt: _requiredDate(json, 'updated_at'),
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'sort_order': sortOrder,
    'revision': revision,
    'deleted_at': deletedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_operation_id': lastOperationId,
  };
}

final class LibraryV2Tag {
  const LibraryV2Tag({
    required this.id,
    required this.name,
    required this.revision,
    required this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOperationId,
  });

  final String id;
  final String name;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastOperationId;

  factory LibraryV2Tag.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {
      'id',
      'name',
      'revision',
      'deleted_at',
      'created_at',
      'updated_at',
      'last_operation_id',
    });
    return LibraryV2Tag(
      id: _requiredUuid(json, 'id'),
      name: _requiredString(json, 'name', maximumLength: 60),
      revision: _positiveRevision(json, 'revision'),
      deletedAt: _optionalDate(json, 'deleted_at'),
      createdAt: _requiredDate(json, 'created_at'),
      updatedAt: _requiredDate(json, 'updated_at'),
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'revision': revision,
    'deleted_at': deletedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_operation_id': lastOperationId,
  };
}

final class LibraryV2ListItem {
  const LibraryV2ListItem({
    required this.listId,
    required this.paperId,
    required this.positionRank,
    required this.note,
    required this.revision,
    required this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOperationId,
  });

  final String listId;
  final String paperId;
  final int positionRank;
  final String? note;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastOperationId;

  factory LibraryV2ListItem.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {
      'list_id',
      'paper_id',
      'position_rank',
      'note',
      'revision',
      'deleted_at',
      'created_at',
      'updated_at',
      'last_operation_id',
    });
    final rank = json['position_rank'];
    if (rank is! int) throw const FormatException('Invalid position rank.');
    return LibraryV2ListItem(
      listId: _requiredUuid(json, 'list_id'),
      paperId: _requiredUuid(json, 'paper_id'),
      positionRank: rank,
      note: _optionalString(json, 'note', maximumLength: 500),
      revision: _positiveRevision(json, 'revision'),
      deletedAt: _optionalDate(json, 'deleted_at'),
      createdAt: _requiredDate(json, 'created_at'),
      updatedAt: _requiredDate(json, 'updated_at'),
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }

  Map<String, dynamic> toJson() => {
    'list_id': listId,
    'paper_id': paperId,
    'position_rank': positionRank,
    'note': note,
    'revision': revision,
    'deleted_at': deletedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_operation_id': lastOperationId,
  };
}

final class LibraryV2ItemTag {
  const LibraryV2ItemTag({
    required this.paperId,
    required this.tagId,
    required this.revision,
    required this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.lastOperationId,
  });

  final String paperId;
  final String tagId;
  final int revision;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastOperationId;

  factory LibraryV2ItemTag.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {
      'paper_id',
      'tag_id',
      'revision',
      'deleted_at',
      'created_at',
      'updated_at',
      'last_operation_id',
    });
    return LibraryV2ItemTag(
      paperId: _requiredUuid(json, 'paper_id'),
      tagId: _requiredUuid(json, 'tag_id'),
      revision: _positiveRevision(json, 'revision'),
      deletedAt: _optionalDate(json, 'deleted_at'),
      createdAt: _requiredDate(json, 'created_at'),
      updatedAt: _requiredDate(json, 'updated_at'),
      lastOperationId: _requiredUuid(json, 'last_operation_id'),
    );
  }

  Map<String, dynamic> toJson() => {
    'paper_id': paperId,
    'tag_id': tagId,
    'revision': revision,
    'deleted_at': deletedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_operation_id': lastOperationId,
  };
}

sealed class LibraryV2Change {
  const LibraryV2Change();

  int get revision;

  factory LibraryV2Change.fromJson(Map<String, dynamic> json) {
    final entity = json['entity'];
    return switch (entity) {
      'item' => LibraryV2ItemChange.fromJson(json),
      'list' => LibraryV2ListChange.fromJson(json),
      'list_item' => LibraryV2ListItemChange.fromJson(json),
      'tag' => LibraryV2TagChange.fromJson(json),
      'item_tag' => LibraryV2ItemTagChange.fromJson(json),
      _ => throw const FormatException('Unknown library change entity.'),
    };
  }
}

final class LibraryV2ItemChange extends LibraryV2Change {
  const LibraryV2ItemChange({required this.entry});

  final LibraryV2Entry entry;
  @override
  int get revision => entry.item.revision;

  factory LibraryV2ItemChange.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'entity', 'item', 'paper'});
    final item = LibraryV2Item.fromJson(_requiredMap(json, 'item'));
    final rawPaper = json['paper'];
    final paper = rawPaper == null
        ? null
        : PaperSummary.fromJson(_asMap(rawPaper, 'paper'));
    if (!item.removed && paper == null) {
      throw const FormatException('Active library change omitted its paper.');
    }
    if (paper != null && paper.paperId != item.paperId) {
      throw const FormatException('Library paper identity mismatch.');
    }
    return LibraryV2ItemChange(
      entry: LibraryV2Entry(item: item, paper: paper),
    );
  }
}

final class LibraryV2ListChange extends LibraryV2Change {
  const LibraryV2ListChange(this.list);
  final LibraryV2List list;
  @override
  int get revision => list.revision;

  factory LibraryV2ListChange.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'entity', 'list'});
    return LibraryV2ListChange(
      LibraryV2List.fromJson(_requiredMap(json, 'list')),
    );
  }
}

final class LibraryV2ListItemChange extends LibraryV2Change {
  const LibraryV2ListItemChange(this.listItem);
  final LibraryV2ListItem listItem;
  @override
  int get revision => listItem.revision;

  factory LibraryV2ListItemChange.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'entity', 'list_item'});
    return LibraryV2ListItemChange(
      LibraryV2ListItem.fromJson(_requiredMap(json, 'list_item')),
    );
  }
}

final class LibraryV2TagChange extends LibraryV2Change {
  const LibraryV2TagChange(this.tag);
  final LibraryV2Tag tag;
  @override
  int get revision => tag.revision;

  factory LibraryV2TagChange.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'entity', 'tag'});
    return LibraryV2TagChange(LibraryV2Tag.fromJson(_requiredMap(json, 'tag')));
  }
}

final class LibraryV2ItemTagChange extends LibraryV2Change {
  const LibraryV2ItemTagChange(this.itemTag);
  final LibraryV2ItemTag itemTag;
  @override
  int get revision => itemTag.revision;

  factory LibraryV2ItemTagChange.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'entity', 'item_tag'});
    return LibraryV2ItemTagChange(
      LibraryV2ItemTag.fromJson(_requiredMap(json, 'item_tag')),
    );
  }
}

final class LibraryV2ChangesPage {
  const LibraryV2ChangesPage({
    required this.items,
    required this.nextAfterRevision,
    required this.hasMore,
    required this.syncRevision,
  });

  final List<LibraryV2Change> items;
  final int nextAfterRevision;
  final bool hasMore;
  final int syncRevision;

  factory LibraryV2ChangesPage.fromJson(
    Map<String, dynamic> json, {
    required int afterRevision,
  }) {
    _requireKeys(json, const {
      'items',
      'next_after_revision',
      'has_more',
      'sync_revision',
    });
    final rawItems = json['items'];
    final next = _nonNegativeRevision(json, 'next_after_revision');
    final sync = _nonNegativeRevision(json, 'sync_revision');
    final hasMore = json['has_more'];
    if (rawItems is! List ||
        hasMore is! bool ||
        next < afterRevision ||
        sync < next) {
      throw const FormatException('Invalid library changes envelope.');
    }
    final items = rawItems
        .map((value) => LibraryV2Change.fromJson(_asMap(value, 'items')))
        .toList(growable: false);
    var previous = afterRevision;
    for (final item in items) {
      if (item.revision <= previous || item.revision > sync) {
        throw const FormatException('Library changes are not ascending.');
      }
      previous = item.revision;
    }
    if (hasMore) {
      if (items.isEmpty || next != items.last.revision) {
        throw const FormatException('Invalid changes cursor.');
      }
    } else if (next != sync) {
      throw const FormatException('Incomplete changes checkpoint.');
    }
    return LibraryV2ChangesPage(
      items: List.unmodifiable(items),
      nextAfterRevision: next,
      hasMore: hasMore,
      syncRevision: sync,
    );
  }
}

/// Optimistic account-local projection used by Library organization UI. It is
/// deliberately distinct from the strict server DTO because a newly queued
/// collection does not have a canonical revision yet.
final class LibraryV2LocalList {
  const LibraryV2LocalList({
    required this.id,
    required this.name,
    required this.description,
    required this.sortOrder,
    required this.syncPending,
  });

  final String id;
  final String name;
  final String? description;
  final int sortOrder;
  final bool syncPending;
}

final class LibraryV2LocalTag {
  const LibraryV2LocalTag({
    required this.id,
    required this.name,
    required this.syncPending,
  });

  final String id;
  final String name;
  final bool syncPending;
}

final class LibraryV2NamedPage<T> {
  const LibraryV2NamedPage({required this.items, required this.syncRevision});
  final List<T> items;
  final int syncRevision;
}

final class LibraryV2Mutation<T> {
  const LibraryV2Mutation({required this.value, required this.replayed});
  final T value;
  final bool replayed;

  /// Binds an idempotent response to the exact durable operation that may be
  /// deleted after it is projected. Runtime type is part of the contract so a
  /// malformed or crossed response can never update a different entity. A
  /// replay may contain a newer same-entity operation from another device;
  /// first-time responses must still echo this exact operation id.
  bool matchesOperation(LibraryPendingOperation operation) => switch (value) {
    LibraryV2Item item =>
      operation.entityKind == 'library_v2_item' &&
          item.paperId == operation.entityId &&
          (replayed || item.lastOperationId == operation.operationId),
    LibraryV2List list =>
      operation.entityKind == 'library_v2_list' &&
          list.id == operation.entityId &&
          (replayed || list.lastOperationId == operation.operationId),
    LibraryV2Tag tag =>
      operation.entityKind == 'library_v2_tag' &&
          tag.id == operation.entityId &&
          (replayed || tag.lastOperationId == operation.operationId),
    LibraryV2ListItem item =>
      operation.entityKind == 'library_v2_list_item' &&
          '${item.listId}:${item.paperId}' == operation.entityId &&
          (replayed || item.lastOperationId == operation.operationId),
    LibraryV2ItemTag tag =>
      operation.entityKind == 'library_v2_item_tag' &&
          '${tag.paperId}:${tag.tagId}' == operation.entityId &&
          (replayed || tag.lastOperationId == operation.operationId),
    _ => false,
  };
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) =>
    _asMap(json[key], key);

Map<String, dynamic> _asMap(Object? value, String key) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('Invalid $key.');
}

void _requireKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected response shape.');
  }
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = _optionalString(json, key, maximumLength: maximumLength);
  if (value == null) throw FormatException('Invalid $key.');
  return value;
}

String? _optionalString(
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

String _requiredUuid(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key, maximumLength: 36).toLowerCase();
  if (!_uuid.hasMatch(value)) throw FormatException('Invalid $key.');
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
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed.toUtc();
}

int _positiveRevision(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) throw FormatException('Invalid $key.');
  return value;
}

int _nonNegativeRevision(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key.');
  return value;
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
