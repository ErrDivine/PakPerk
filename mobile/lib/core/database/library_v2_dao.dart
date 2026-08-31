import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../library/library_models.dart';
import '../library/library_v2_models.dart';
import '../models/paper.dart';
import 'app_database.dart';
import 'library_dao.dart';
import 'paper_cache_dao.dart';

typedef LibraryV2OperationIdFactory = String Function();
typedef LibraryV2Clock = DateTime Function();

final class LibraryV2EnqueueResult {
  const LibraryV2EnqueueResult(this.operationIds);
  final List<String> operationIds;
}

final class LibraryV2Dao {
  LibraryV2Dao(
    this.database, {
    LibraryV2OperationIdFactory? operationId,
    LibraryV2Clock? clock,
  }) : _operationId = operationId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now,
       _papers = PaperCacheDao(database);

  final PakPerkDatabase database;
  final LibraryV2OperationIdFactory _operationId;
  final LibraryV2Clock _clock;
  final PaperCacheDao _papers;

  Stream<List<LibraryV2LocalList>> watchLists(String accountId) {
    _validateAccountId(accountId);
    return database
        .customSelect(
          '''
          SELECT
            value.list_id AS list_id,
            value.name AS name,
            value.description AS description,
            value.sort_order AS sort_order,
            COALESCE((
              SELECT COUNT(*) FROM sync_outbox AS pending
              WHERE pending.account_id = value.account_id
                AND pending.entity_kind = 'library_v2_list'
                AND pending.entity_id = value.list_id
                AND pending.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS pending_count
          FROM library_custom_lists AS value
          WHERE value.account_id = ? AND value.deleted = 0
          ORDER BY value.sort_order, value.name COLLATE NOCASE, value.list_id
          ''',
          variables: [Variable(accountId)],
          readsFrom: {database.libraryCustomLists, database.syncOutbox},
        )
        .watch()
        .map(
          (rows) => List.unmodifiable(
            rows.map(
              (row) => LibraryV2LocalList(
                id: row.read<String>('list_id'),
                name: row.read<String>('name'),
                description: row.readNullable<String>('description'),
                sortOrder: row.read<int>('sort_order'),
                syncPending: row.read<int>('pending_count') > 0,
              ),
            ),
          ),
        );
  }

  Stream<List<LibraryV2LocalTag>> watchTags(String accountId) {
    _validateAccountId(accountId);
    return database
        .customSelect(
          '''
          SELECT
            value.tag_id AS tag_id,
            value.name AS name,
            COALESCE((
              SELECT COUNT(*) FROM sync_outbox AS pending
              WHERE pending.account_id = value.account_id
                AND pending.entity_kind = 'library_v2_tag'
                AND pending.entity_id = value.tag_id
                AND pending.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS pending_count
          FROM library_tags AS value
          WHERE value.account_id = ? AND value.deleted = 0
          ORDER BY value.name COLLATE NOCASE, value.tag_id
          ''',
          variables: [Variable(accountId)],
          readsFrom: {database.libraryTags, database.syncOutbox},
        )
        .watch()
        .map(
          (rows) => List.unmodifiable(
            rows.map(
              (row) => LibraryV2LocalTag(
                id: row.read<String>('tag_id'),
                name: row.read<String>('name'),
                syncPending: row.read<int>('pending_count') > 0,
              ),
            ),
          ),
        );
  }

  Future<LibraryV2EnqueueResult> enqueueListUpsert({
    required String accountId,
    required String? listId,
    required String name,
    required String description,
    required int sortOrder,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    final normalizedName = _requiredTrimmed(name, 'name', maximumLength: 100);
    final normalizedDescription = _nullableTrimmed(
      description,
      'description',
      maximumLength: 500,
    );
    if (sortOrder < 0 || sortOrder > 1000000) {
      throw ArgumentError.value(sortOrder, 'sortOrder');
    }
    if (listId != null) _validateUuid(listId, 'listId');
    await _requireRevision(accountId, expectedRevision, scopeGuard);
    final rows =
        await (database.select(database.libraryCustomLists)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.deleted.equals(false),
            ))
            .get();
    if (rows.any(
      (row) =>
          row.listId != listId &&
          row.name.toLowerCase() == normalizedName.toLowerCase(),
    )) {
      throw const LibraryCollectionNameConflict();
    }
    final existing = listId == null
        ? null
        : _firstWhereOrNull(rows, (row) => row.listId == listId);
    if (listId != null && existing == null) {
      throw const LibraryRevisionConflict();
    }
    _requireScope(scopeGuard);
    final resolvedId = listId ?? _newOperationId();
    final operationId = _newOperationId();
    final now = _clock().toUtc();
    await database
        .into(database.libraryCustomLists)
        .insertOnConflictUpdate(
          LibraryCustomListsCompanion.insert(
            accountId: accountId,
            listId: resolvedId,
            name: normalizedName,
            description: Value(normalizedDescription),
            sortOrder: Value(sortOrder),
            revision: Value(existing?.revision),
            deleted: const Value(false),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            lastOperationId: Value(operationId),
            canonicalJson: Value(existing?.canonicalJson),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: operationId,
      entityKind: _listKind,
      entityId: resolvedId,
      operation: existing == null
          ? 'library_v2_list_create'
          : 'library_v2_list_update',
      payload: {
        'list_id': resolvedId,
        'name': normalizedName,
        'description': normalizedDescription,
        'sort_order': sortOrder,
      },
      createdAt: now,
    );
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult([operationId]);
  });

  Future<LibraryV2EnqueueResult> enqueueListDelete({
    required String accountId,
    required String listId,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    _validateUuid(listId, 'listId');
    await _requireRevision(accountId, expectedRevision, scopeGuard);
    final existing =
        await (database.select(database.libraryCustomLists)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.listId.equals(listId) &
                  row.deleted.equals(false),
            ))
            .getSingleOrNull();
    if (existing == null) throw const LibraryRevisionConflict();
    final operationId = _newOperationId();
    final now = _clock().toUtc();
    await (database.update(database.libraryCustomLists)..where(
          (row) => row.accountId.equals(accountId) & row.listId.equals(listId),
        ))
        .write(
          LibraryCustomListsCompanion(
            deleted: const Value(true),
            updatedAt: Value(now),
            lastOperationId: Value(operationId),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: operationId,
      entityKind: _listKind,
      entityId: listId,
      operation: 'library_v2_list_delete',
      payload: {'list_id': listId},
      createdAt: now,
    );
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult([operationId]);
  });

  Future<LibraryV2EnqueueResult> enqueueTagUpsert({
    required String accountId,
    required String? tagId,
    required String name,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    final normalizedName = _requiredTrimmed(name, 'name', maximumLength: 60);
    if (tagId != null) _validateUuid(tagId, 'tagId');
    await _requireRevision(accountId, expectedRevision, scopeGuard);
    final rows =
        await (database.select(database.libraryTags)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.deleted.equals(false),
            ))
            .get();
    if (rows.any(
      (row) =>
          row.tagId != tagId &&
          row.name.toLowerCase() == normalizedName.toLowerCase(),
    )) {
      throw const LibraryCollectionNameConflict();
    }
    final existing = tagId == null
        ? null
        : _firstWhereOrNull(rows, (row) => row.tagId == tagId);
    if (tagId != null && existing == null) {
      throw const LibraryRevisionConflict();
    }
    _requireScope(scopeGuard);
    final resolvedId = tagId ?? _newOperationId();
    final operationId = _newOperationId();
    final now = _clock().toUtc();
    await database
        .into(database.libraryTags)
        .insertOnConflictUpdate(
          LibraryTagsCompanion.insert(
            accountId: accountId,
            tagId: resolvedId,
            name: normalizedName,
            revision: Value(existing?.revision),
            deleted: const Value(false),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            lastOperationId: Value(operationId),
            canonicalJson: Value(existing?.canonicalJson),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: operationId,
      entityKind: _tagKind,
      entityId: resolvedId,
      operation: existing == null
          ? 'library_v2_tag_create'
          : 'library_v2_tag_update',
      payload: {'tag_id': resolvedId, 'name': normalizedName},
      createdAt: now,
    );
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult([operationId]);
  });

  Future<LibraryV2EnqueueResult> enqueueTagDelete({
    required String accountId,
    required String tagId,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    _validateUuid(tagId, 'tagId');
    await _requireRevision(accountId, expectedRevision, scopeGuard);
    final existing =
        await (database.select(database.libraryTags)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.tagId.equals(tagId) &
                  row.deleted.equals(false),
            ))
            .getSingleOrNull();
    if (existing == null) throw const LibraryRevisionConflict();
    final operationId = _newOperationId();
    final now = _clock().toUtc();
    await (database.update(database.libraryTags)..where(
          (row) => row.accountId.equals(accountId) & row.tagId.equals(tagId),
        ))
        .write(
          LibraryTagsCompanion(
            deleted: const Value(true),
            updatedAt: Value(now),
            lastOperationId: Value(operationId),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: operationId,
      entityKind: _tagKind,
      entityId: tagId,
      operation: 'library_v2_tag_delete',
      payload: {'tag_id': tagId},
      createdAt: now,
    );
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult([operationId]);
  });

  Future<LibraryV2EnqueueResult> enqueueItemEdit({
    required String accountId,
    required String paperId,
    required LibraryItemState state,
    required String privateNote,
    required DateTime? reminderAt,
    required Iterable<String> listNames,
    required Iterable<String> tagNames,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateUuid(paperId, 'paperId');
    _validateAccountId(accountId);
    final normalizedNote = _nullableTrimmed(
      privateNote,
      'privateNote',
      maximumLength: 500,
    );
    final normalizedReminderAt = reminderAt?.toUtc();
    final desiredLists = _normalizeNames(
      listNames,
      maximumLength: 100,
      field: 'listNames',
    );
    final desiredTags = _normalizeNames(
      tagNames,
      maximumLength: 60,
      field: 'tagNames',
    );
    _requireScope(scopeGuard);
    final checkpoint = await (database.select(
      database.librarySyncStates,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    if (checkpoint == null ||
        !checkpoint.initialized ||
        checkpoint.lastRevision != expectedRevision) {
      throw const LibraryRevisionConflict();
    }
    _requireScope(scopeGuard);
    final item =
        await (database.select(database.libraryItems)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.paperId.equals(paperId),
            ))
            .getSingleOrNull();
    if (item == null || item.deleted) throw const LibraryRevisionConflict();

    final now = _clock().toUtc();
    if (normalizedReminderAt != null &&
        (!state.isActive || !normalizedReminderAt.isAfter(now))) {
      throw ArgumentError.value(reminderAt, 'reminderAt');
    }
    final operationIds = <String>[];
    var sequence = 0;
    // Drift's SQLite date-time codec persists whole seconds, so use that
    // precision to keep dependent create/member operations strictly ordered.
    DateTime nextTimestamp() => now.add(Duration(seconds: sequence++));

    final itemOperationId = _newOperationId();
    operationIds.add(itemOperationId);
    await (database.update(database.libraryItems)..where(
          (row) =>
              row.accountId.equals(accountId) & row.paperId.equals(paperId),
        ))
        .write(
          LibraryItemsCompanion(
            listState: Value(state.storageValue),
            privateNote: Value(normalizedNote),
            reminderAt: Value(state.isActive ? normalizedReminderAt : null),
            clientUpdatedAt: Value(now),
            reviewedAt: Value(
              state == LibraryItemState.reviewed ? now : item.reviewedAt,
            ),
            archivedAt: Value(
              state == LibraryItemState.archived ? now : item.archivedAt,
            ),
            lastOperationId: Value(itemOperationId),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: itemOperationId,
      entityKind: _itemKind,
      entityId: paperId,
      operation: state.isActive
          ? 'library_v2_item_put_active'
          : 'library_v2_item_put_inactive',
      payload: {
        'paper_id': paperId,
        'state': state.storageValue,
        'private_note': normalizedNote,
        'save_source_kind': item.saveSourceKind,
        'reminder_at': state.isActive
            ? normalizedReminderAt?.toIso8601String()
            : null,
      },
      createdAt: nextTimestamp(),
    );

    final lists =
        await (database.select(database.libraryCustomLists)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.deleted.equals(false),
            ))
            .get();
    final listByName = {for (final row in lists) row.name.toLowerCase(): row};
    for (final name in desiredLists) {
      if (listByName.containsKey(name.toLowerCase())) continue;
      final listId = _newOperationId();
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      final optimistic = LibraryCustomListsCompanion.insert(
        accountId: accountId,
        listId: listId,
        name: name,
        createdAt: createdAt,
        updatedAt: createdAt,
        lastOperationId: Value(operationId),
      );
      await database.into(database.libraryCustomLists).insert(optimistic);
      listByName[name.toLowerCase()] =
          await (database.select(database.libraryCustomLists)..where(
                (row) =>
                    row.accountId.equals(accountId) & row.listId.equals(listId),
              ))
              .getSingle();
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _listKind,
        entityId: listId,
        operation: 'library_v2_list_create',
        payload: {
          'list_id': listId,
          'name': name,
          'description': null,
          'sort_order': 0,
        },
        createdAt: createdAt,
      );
    }

    final currentLists =
        await (database.select(database.libraryListMemberships)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.deleted.equals(false),
            ))
            .get();
    final desiredListIds = {
      for (final name in desiredLists) listByName[name.toLowerCase()]!.listId,
    };
    final currentListIds = currentLists.map((row) => row.listId).toSet();
    for (final listId in desiredListIds.difference(currentListIds)) {
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      await database
          .into(database.libraryListMemberships)
          .insertOnConflictUpdate(
            LibraryListMembershipsCompanion.insert(
              accountId: accountId,
              listId: listId,
              paperId: paperId,
              createdAt: createdAt,
              updatedAt: createdAt,
              lastOperationId: Value(operationId),
            ),
          );
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _listItemKind,
        entityId: '$listId:$paperId',
        operation: 'library_v2_list_item_put',
        payload: {
          'list_id': listId,
          'paper_id': paperId,
          'position_rank': 0,
          'note': null,
        },
        createdAt: createdAt,
      );
    }
    for (final listId in currentListIds.difference(desiredListIds)) {
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      await (database.update(database.libraryListMemberships)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.listId.equals(listId) &
                row.paperId.equals(paperId),
          ))
          .write(
            LibraryListMembershipsCompanion(
              deleted: const Value(true),
              updatedAt: Value(createdAt),
              lastOperationId: Value(operationId),
            ),
          );
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _listItemKind,
        entityId: '$listId:$paperId',
        operation: 'library_v2_list_item_delete',
        payload: {'list_id': listId, 'paper_id': paperId},
        createdAt: createdAt,
      );
    }

    final tags =
        await (database.select(database.libraryTags)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.deleted.equals(false),
            ))
            .get();
    final tagByName = {for (final row in tags) row.name.toLowerCase(): row};
    for (final name in desiredTags) {
      if (tagByName.containsKey(name.toLowerCase())) continue;
      final tagId = _newOperationId();
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      await database
          .into(database.libraryTags)
          .insert(
            LibraryTagsCompanion.insert(
              accountId: accountId,
              tagId: tagId,
              name: name,
              createdAt: createdAt,
              updatedAt: createdAt,
              lastOperationId: Value(operationId),
            ),
          );
      tagByName[name.toLowerCase()] =
          await (database.select(database.libraryTags)..where(
                (row) =>
                    row.accountId.equals(accountId) & row.tagId.equals(tagId),
              ))
              .getSingle();
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _tagKind,
        entityId: tagId,
        operation: 'library_v2_tag_create',
        payload: {'tag_id': tagId, 'name': name},
        createdAt: createdAt,
      );
    }

    final currentTags =
        await (database.select(database.libraryTagMemberships)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.deleted.equals(false),
            ))
            .get();
    final desiredTagIds = {
      for (final name in desiredTags) tagByName[name.toLowerCase()]!.tagId,
    };
    final currentTagIds = currentTags.map((row) => row.tagId).toSet();
    for (final tagId in desiredTagIds.difference(currentTagIds)) {
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      await database
          .into(database.libraryTagMemberships)
          .insertOnConflictUpdate(
            LibraryTagMembershipsCompanion.insert(
              accountId: accountId,
              paperId: paperId,
              tagId: tagId,
              createdAt: createdAt,
              updatedAt: createdAt,
              lastOperationId: Value(operationId),
            ),
          );
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _itemTagKind,
        entityId: '$paperId:$tagId',
        operation: 'library_v2_item_tag_put',
        payload: {'paper_id': paperId, 'tag_id': tagId},
        createdAt: createdAt,
      );
    }
    for (final tagId in currentTagIds.difference(desiredTagIds)) {
      final operationId = _newOperationId();
      operationIds.add(operationId);
      final createdAt = nextTimestamp();
      await (database.update(database.libraryTagMemberships)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.paperId.equals(paperId) &
                row.tagId.equals(tagId),
          ))
          .write(
            LibraryTagMembershipsCompanion(
              deleted: const Value(true),
              updatedAt: Value(createdAt),
              lastOperationId: Value(operationId),
            ),
          );
      await _enqueue(
        accountId: accountId,
        operationId: operationId,
        entityKind: _itemTagKind,
        entityId: '$paperId:$tagId',
        operation: 'library_v2_item_tag_delete',
        payload: {'paper_id': paperId, 'tag_id': tagId},
        createdAt: createdAt,
      );
    }
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult(List.unmodifiable(operationIds));
  });

  Future<LibraryV2EnqueueResult> enqueueItemRemove({
    required String accountId,
    required String paperId,
    required int expectedRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateUuid(paperId, 'paperId');
    _validateAccountId(accountId);
    await _requireRevision(accountId, expectedRevision, scopeGuard);
    final item =
        await (database.select(database.libraryItems)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.paperId.equals(paperId),
            ))
            .getSingleOrNull();
    if (item == null || item.deleted) throw const LibraryRevisionConflict();
    _requireScope(scopeGuard);

    final operationId = _newOperationId();
    final now = _clock().toUtc();
    await (database.update(database.libraryItems)..where(
          (row) =>
              row.accountId.equals(accountId) & row.paperId.equals(paperId),
        ))
        .write(
          LibraryItemsCompanion(
            deleted: const Value(true),
            removedAt: Value(now),
            reminderAt: const Value(null),
            clientUpdatedAt: Value(now),
            lastOperationId: Value(operationId),
          ),
        );
    await _enqueue(
      accountId: accountId,
      operationId: operationId,
      entityKind: _itemKind,
      entityId: paperId,
      operation: 'library_v2_item_delete',
      payload: {'paper_id': paperId},
      createdAt: now,
    );
    _requireScope(scopeGuard);
    return LibraryV2EnqueueResult([operationId]);
  });

  Future<void> applyMutationSuccess({
    required LibraryPendingOperation operation,
    required Object value,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final current =
        await (database.select(database.syncOutbox)..where(
              (row) =>
                  row.operationId.equals(operation.operationId) &
                  row.accountId.equals(operation.accountId) &
                  row.state.equals('in_flight'),
            ))
            .getSingleOrNull();
    if (current == null) return;
    await _applyValue(operation.accountId, value, preserveProjection: true);
    _requireScope(scopeGuard);
    await (database.delete(
      database.syncOutbox,
    )..where((row) => row.operationId.equals(operation.operationId))).go();
    final successor =
        await (database.select(database.syncOutbox)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.entityKind.equals(operation.entityKind) &
                    row.entityId.equals(operation.entityId) &
                    row.state.isIn(_activeStates),
              )
              ..limit(1))
            .getSingleOrNull();
    if (successor == null) {
      await _applyValue(operation.accountId, value, preserveProjection: false);
    }
    await (database.delete(database.syncOutbox)..where(
          (row) =>
              row.accountId.equals(operation.accountId) &
              row.entityKind.equals(operation.entityKind) &
              row.entityId.equals(operation.entityId) &
              row.state.equals('failed'),
        ))
        .go();
    _requireScope(scopeGuard);
  });

  Future<void> rollbackPermanentFailure({
    required LibraryPendingOperation operation,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    // The durable entity kind, entity id, and payload may themselves be the
    // corruption that caused terminalization. The operation id is globally
    // unique and is written onto the one optimistic projection in the same
    // transaction as its outbox row, so it is the only safe rollback key.
    final item =
        await (database.select(database.libraryItems)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.lastOperationId.equals(operation.operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (item != null) {
      await (database.update(database.libraryItems)..where(
            (row) =>
                row.accountId.equals(operation.accountId) &
                row.paperId.equals(item.paperId),
          ))
          .write(
            LibraryItemsCompanion(
              listState: Value(item.canonicalListState ?? 'inbox'),
              privateNote: Value(item.canonicalPrivateNote),
              saveSourceKind: Value(item.canonicalSaveSourceKind),
              reminderAt: Value(item.canonicalReminderAt),
              reviewedAt: Value(item.canonicalReviewedAt),
              archivedAt: Value(item.canonicalArchivedAt),
              deleted: Value(item.canonicalDeleted ?? false),
              savedAt: Value(item.canonicalSavedAt),
              removedAt: Value(item.canonicalRemovedAt),
            ),
          );
      _requireScope(scopeGuard);
      return;
    }

    final list =
        await (database.select(database.libraryCustomLists)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.lastOperationId.equals(operation.operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (list != null) {
      await _restoreList(operation.accountId, list.listId);
      _requireScope(scopeGuard);
      return;
    }

    final tag =
        await (database.select(database.libraryTags)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.lastOperationId.equals(operation.operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (tag != null) {
      await _restoreTag(operation.accountId, tag.tagId);
      _requireScope(scopeGuard);
      return;
    }

    final listItem =
        await (database.select(database.libraryListMemberships)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.lastOperationId.equals(operation.operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (listItem != null) {
      await _restoreListItem(
        operation.accountId,
        listItem.listId,
        listItem.paperId,
      );
      _requireScope(scopeGuard);
      return;
    }

    final itemTag =
        await (database.select(database.libraryTagMemberships)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.lastOperationId.equals(operation.operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (itemTag != null) {
      await _restoreItemTag(
        operation.accountId,
        itemTag.paperId,
        itemTag.tagId,
      );
    }
    _requireScope(scopeGuard);
  });

  /// Projects the already-durable v2 import response without manufacturing a
  /// second outbox save. An initialized checkpoint may advance, but importing
  /// one paper never establishes a complete library snapshot by itself.
  Future<void> applyImportedPaper({
    required String accountId,
    required LibraryV2Item item,
    required PaperSummary paper,
    required int syncRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    if (item.removed ||
        item.state != LibraryItemState.inbox ||
        item.paperId != paper.paperId ||
        item.revision != syncRevision) {
      throw ArgumentError('The imported paper result is inconsistent.');
    }
    _requireScope(scopeGuard);
    final active = await _activeEntityKeys(accountId);
    _requireScope(scopeGuard);
    await _applyValue(
      accountId,
      LibraryV2Entry(item: item, paper: paper),
      preserveProjection: active.contains('$_itemKind:${item.paperId}'),
    );
    _requireScope(scopeGuard);
    final checkpoint = await (database.select(
      database.librarySyncStates,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    _requireScope(scopeGuard);
    if (checkpoint != null &&
        checkpoint.initialized &&
        syncRevision > checkpoint.lastRevision) {
      await (database.update(database.librarySyncStates)
            ..where((row) => row.accountId.equals(accountId)))
          .write(LibrarySyncStatesCompanion(lastRevision: Value(syncRevision)));
      _requireScope(scopeGuard);
    }
  });

  Future<void> applyFullSnapshot({
    required String accountId,
    required List<LibraryV2Entry> items,
    required List<LibraryV2List> lists,
    required List<LibraryV2Tag> tags,
    required Set<({String listId, String paperId})> listMemberships,
    required Set<({String paperId, String tagId})> tagMemberships,
    required int syncRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final active = await _activeEntityKeys(accountId);
    await _replaceItems(accountId, items, active);
    await _replaceLists(accountId, lists, active);
    await _replaceTags(accountId, tags, active);
    await _replaceInferredMemberships(
      accountId,
      listMemberships,
      tagMemberships,
      active,
    );
    await database
        .into(database.librarySyncStates)
        .insertOnConflictUpdate(
          LibrarySyncStatesCompanion.insert(
            accountId: accountId,
            lastRevision: Value(syncRevision),
            initialized: const Value(true),
            lastFullSyncAt: Value(_clock().toUtc()),
          ),
        );
    _requireScope(scopeGuard);
  });

  Future<void> applyChanges({
    required String accountId,
    required LibraryV2ChangesPage page,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final active = await _activeEntityKeys(accountId);
    for (final change in page.items) {
      final key = _changeEntityKey(change);
      await _applyValue(accountId, switch (change) {
        LibraryV2ItemChange(:final entry) => entry,
        LibraryV2ListChange(:final list) => list,
        LibraryV2ListItemChange(:final listItem) => listItem,
        LibraryV2TagChange(:final tag) => tag,
        LibraryV2ItemTagChange(:final itemTag) => itemTag,
      }, preserveProjection: active.contains(key));
      _requireScope(scopeGuard);
    }
    await database
        .into(database.librarySyncStates)
        .insertOnConflictUpdate(
          LibrarySyncStatesCompanion.insert(
            accountId: accountId,
            lastRevision: Value(page.nextAfterRevision),
            initialized: const Value(true),
          ),
        );
    _requireScope(scopeGuard);
  });

  Future<void> _applyValue(
    String accountId,
    Object value, {
    required bool preserveProjection,
  }) async {
    switch (value) {
      case LibraryV2Entry(:final item, :final paper):
        if (paper != null) {
          await _papers.save(paper, accessedAt: _clock().toUtc());
        }
        await _applyItem(accountId, item, preserveProjection);
      case LibraryV2Item item:
        await _applyItem(accountId, item, preserveProjection);
      case LibraryV2List list:
        await _applyList(accountId, list, preserveProjection);
      case LibraryV2Tag tag:
        await _applyTag(accountId, tag, preserveProjection);
      case LibraryV2ListItem listItem:
        await _applyListItem(accountId, listItem, preserveProjection);
      case LibraryV2ItemTag itemTag:
        await _applyItemTag(accountId, itemTag, preserveProjection);
      default:
        throw StateError('Unsupported Library v2 canonical value.');
    }
  }

  Future<void> _applyItem(
    String accountId,
    LibraryV2Item item,
    bool preserve,
  ) async {
    final existing =
        await (database.select(database.libraryItems)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(item.paperId),
            ))
            .getSingleOrNull();
    await database
        .into(database.libraryItems)
        .insertOnConflictUpdate(
          LibraryItemsCompanion.insert(
            accountId: accountId,
            paperId: item.paperId,
            listState: Value(
              preserve && existing != null
                  ? existing.listState
                  : item.state.storageValue,
            ),
            clientUpdatedAt: preserve && existing != null
                ? existing.clientUpdatedAt
                : item.updatedAt,
            serverUpdatedAt: Value(item.updatedAt),
            deleted: Value(
              preserve && existing != null ? existing.deleted : item.removed,
            ),
            savedAt: Value(
              preserve && existing != null ? existing.savedAt : item.savedAt,
            ),
            removedAt: Value(
              preserve && existing != null
                  ? existing.removedAt
                  : item.removedAt,
            ),
            revision: Value(item.revision),
            lastOperationId: Value(
              preserve && existing != null
                  ? existing.lastOperationId
                  : item.lastOperationId,
            ),
            privateNote: Value(
              preserve && existing != null
                  ? existing.privateNote
                  : item.privateNote,
            ),
            saveSourceKind: Value(
              preserve && existing != null
                  ? existing.saveSourceKind
                  : item.saveSourceKind?.wireValue,
            ),
            reminderAt: Value(
              preserve && existing != null
                  ? existing.reminderAt
                  : item.reminderAt,
            ),
            reviewedAt: Value(
              preserve && existing != null
                  ? existing.reviewedAt
                  : item.reviewedAt,
            ),
            archivedAt: Value(
              preserve && existing != null
                  ? existing.archivedAt
                  : item.archivedAt,
            ),
            canonicalDeleted: Value(item.removed),
            canonicalSavedAt: Value(item.savedAt),
            canonicalRemovedAt: Value(item.removedAt),
            canonicalListState: Value(item.state.storageValue),
            canonicalPrivateNote: Value(item.privateNote),
            canonicalSaveSourceKind: Value(item.saveSourceKind?.wireValue),
            canonicalReminderAt: Value(item.reminderAt),
            canonicalReviewedAt: Value(item.reviewedAt),
            canonicalArchivedAt: Value(item.archivedAt),
          ),
        );
  }

  Future<void> _applyList(
    String accountId,
    LibraryV2List value,
    bool preserve,
  ) async {
    final existing =
        await (database.select(database.libraryCustomLists)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.listId.equals(value.id),
            ))
            .getSingleOrNull();
    await database
        .into(database.libraryCustomLists)
        .insertOnConflictUpdate(
          LibraryCustomListsCompanion.insert(
            accountId: accountId,
            listId: value.id,
            name: preserve && existing != null ? existing.name : value.name,
            description: Value(
              preserve && existing != null
                  ? existing.description
                  : value.description,
            ),
            sortOrder: Value(
              preserve && existing != null
                  ? existing.sortOrder
                  : value.sortOrder,
            ),
            revision: Value(value.revision),
            deleted: Value(
              preserve && existing != null
                  ? existing.deleted
                  : value.deletedAt != null,
            ),
            createdAt: value.createdAt,
            updatedAt: preserve && existing != null
                ? existing.updatedAt
                : value.updatedAt,
            lastOperationId: Value(
              preserve && existing != null
                  ? existing.lastOperationId
                  : value.lastOperationId,
            ),
            canonicalJson: Value(jsonEncode(value.toJson())),
          ),
        );
  }

  Future<void> _applyTag(
    String accountId,
    LibraryV2Tag value,
    bool preserve,
  ) async {
    final existing =
        await (database.select(database.libraryTags)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.tagId.equals(value.id),
            ))
            .getSingleOrNull();
    await database
        .into(database.libraryTags)
        .insertOnConflictUpdate(
          LibraryTagsCompanion.insert(
            accountId: accountId,
            tagId: value.id,
            name: preserve && existing != null ? existing.name : value.name,
            revision: Value(value.revision),
            deleted: Value(
              preserve && existing != null
                  ? existing.deleted
                  : value.deletedAt != null,
            ),
            createdAt: value.createdAt,
            updatedAt: preserve && existing != null
                ? existing.updatedAt
                : value.updatedAt,
            lastOperationId: Value(
              preserve && existing != null
                  ? existing.lastOperationId
                  : value.lastOperationId,
            ),
            canonicalJson: Value(jsonEncode(value.toJson())),
          ),
        );
  }

  Future<void> _applyListItem(
    String accountId,
    LibraryV2ListItem value,
    bool preserve,
  ) async {
    final existing =
        await (database.select(database.libraryListMemberships)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.listId.equals(value.listId) &
                  row.paperId.equals(value.paperId),
            ))
            .getSingleOrNull();
    await database
        .into(database.libraryListMemberships)
        .insertOnConflictUpdate(
          LibraryListMembershipsCompanion.insert(
            accountId: accountId,
            listId: value.listId,
            paperId: value.paperId,
            positionRank: Value(
              preserve && existing != null
                  ? existing.positionRank
                  : value.positionRank,
            ),
            note: Value(
              preserve && existing != null ? existing.note : value.note,
            ),
            revision: Value(value.revision),
            deleted: Value(
              preserve && existing != null
                  ? existing.deleted
                  : value.deletedAt != null,
            ),
            createdAt: value.createdAt,
            updatedAt: preserve && existing != null
                ? existing.updatedAt
                : value.updatedAt,
            lastOperationId: Value(
              preserve && existing != null
                  ? existing.lastOperationId
                  : value.lastOperationId,
            ),
            canonicalJson: Value(jsonEncode(value.toJson())),
          ),
        );
  }

  Future<void> _applyItemTag(
    String accountId,
    LibraryV2ItemTag value,
    bool preserve,
  ) async {
    final existing =
        await (database.select(database.libraryTagMemberships)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(value.paperId) &
                  row.tagId.equals(value.tagId),
            ))
            .getSingleOrNull();
    await database
        .into(database.libraryTagMemberships)
        .insertOnConflictUpdate(
          LibraryTagMembershipsCompanion.insert(
            accountId: accountId,
            paperId: value.paperId,
            tagId: value.tagId,
            revision: Value(value.revision),
            deleted: Value(
              preserve && existing != null
                  ? existing.deleted
                  : value.deletedAt != null,
            ),
            createdAt: value.createdAt,
            updatedAt: preserve && existing != null
                ? existing.updatedAt
                : value.updatedAt,
            lastOperationId: Value(
              preserve && existing != null
                  ? existing.lastOperationId
                  : value.lastOperationId,
            ),
            canonicalJson: Value(jsonEncode(value.toJson())),
          ),
        );
  }

  Future<void> _replaceItems(
    String accountId,
    List<LibraryV2Entry> items,
    Set<String> active,
  ) async {
    final remoteIds = items.map((entry) => entry.item.paperId).toSet();
    final rows = await (database.select(
      database.libraryItems,
    )..where((row) => row.accountId.equals(accountId))).get();
    for (final row in rows) {
      if (!remoteIds.contains(row.paperId) &&
          !active.contains('$_itemKind:${row.paperId}')) {
        await (database.delete(database.libraryItems)..where(
              (item) =>
                  item.accountId.equals(accountId) &
                  item.paperId.equals(row.paperId),
            ))
            .go();
      }
    }
    for (final entry in items) {
      await _applyValue(
        accountId,
        entry,
        preserveProjection: active.contains('$_itemKind:${entry.item.paperId}'),
      );
    }
  }

  Future<void> _replaceLists(
    String accountId,
    List<LibraryV2List> values,
    Set<String> active,
  ) async {
    final ids = values.map((value) => value.id).toSet();
    await (database.delete(database.libraryCustomLists)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.listId.isNotIn(ids.toList()) &
              row.listId.isNotIn(_activeIds(active, _listKind)),
        ))
        .go();
    for (final value in values) {
      await _applyList(
        accountId,
        value,
        active.contains('$_listKind:${value.id}'),
      );
    }
  }

  Future<void> _replaceTags(
    String accountId,
    List<LibraryV2Tag> values,
    Set<String> active,
  ) async {
    final ids = values.map((value) => value.id).toSet();
    await (database.delete(database.libraryTags)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.tagId.isNotIn(ids.toList()) &
              row.tagId.isNotIn(_activeIds(active, _tagKind)),
        ))
        .go();
    for (final value in values) {
      await _applyTag(
        accountId,
        value,
        active.contains('$_tagKind:${value.id}'),
      );
    }
  }

  Future<void> _replaceInferredMemberships(
    String accountId,
    Set<({String listId, String paperId})> lists,
    Set<({String paperId, String tagId})> tags,
    Set<String> active,
  ) async {
    final now = _clock().toUtc();
    final existingLists = await (database.select(
      database.libraryListMemberships,
    )..where((row) => row.accountId.equals(accountId))).get();
    for (final row in existingLists) {
      final key = '$_listItemKind:${row.listId}:${row.paperId}';
      if (!lists.contains((listId: row.listId, paperId: row.paperId)) &&
          !active.contains(key)) {
        await (database.delete(database.libraryListMemberships)..where(
              (value) =>
                  value.accountId.equals(accountId) &
                  value.listId.equals(row.listId) &
                  value.paperId.equals(row.paperId),
            ))
            .go();
      }
    }
    for (final membership in lists) {
      final current = existingLists.where(
        (row) =>
            row.listId == membership.listId &&
            row.paperId == membership.paperId,
      );
      if (current.isNotEmpty) continue;
      await database
          .into(database.libraryListMemberships)
          .insert(
            LibraryListMembershipsCompanion.insert(
              accountId: accountId,
              listId: membership.listId,
              paperId: membership.paperId,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    final existingTags = await (database.select(
      database.libraryTagMemberships,
    )..where((row) => row.accountId.equals(accountId))).get();
    for (final row in existingTags) {
      final key = '$_itemTagKind:${row.paperId}:${row.tagId}';
      if (!tags.contains((paperId: row.paperId, tagId: row.tagId)) &&
          !active.contains(key)) {
        await (database.delete(database.libraryTagMemberships)..where(
              (value) =>
                  value.accountId.equals(accountId) &
                  value.paperId.equals(row.paperId) &
                  value.tagId.equals(row.tagId),
            ))
            .go();
      }
    }
    for (final membership in tags) {
      final current = existingTags.where(
        (row) =>
            row.paperId == membership.paperId && row.tagId == membership.tagId,
      );
      if (current.isNotEmpty) continue;
      await database
          .into(database.libraryTagMemberships)
          .insert(
            LibraryTagMembershipsCompanion.insert(
              accountId: accountId,
              paperId: membership.paperId,
              tagId: membership.tagId,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  Future<Set<String>> _activeEntityKeys(String accountId) async {
    final rows =
        await (database.select(database.syncOutbox)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.entityKind.like('library_v2_%') &
                  row.state.isIn(_activeStates),
            ))
            .get();
    return rows.map((row) => '${row.entityKind}:${row.entityId}').toSet();
  }

  Future<void> _restoreList(String accountId, String listId) async {
    final row =
        await (database.select(database.libraryCustomLists)..where(
              (value) =>
                  value.accountId.equals(accountId) &
                  value.listId.equals(listId),
            ))
            .getSingleOrNull();
    if (row == null) return;
    final canonical = _canonical(row.canonicalJson, LibraryV2List.fromJson);
    if (canonical == null) {
      await (database.delete(database.libraryCustomLists)..where(
            (value) =>
                value.accountId.equals(accountId) & value.listId.equals(listId),
          ))
          .go();
    } else {
      await _applyList(accountId, canonical, false);
    }
  }

  Future<void> _restoreTag(String accountId, String tagId) async {
    final row =
        await (database.select(database.libraryTags)..where(
              (value) =>
                  value.accountId.equals(accountId) & value.tagId.equals(tagId),
            ))
            .getSingleOrNull();
    if (row == null) return;
    final canonical = _canonical(row.canonicalJson, LibraryV2Tag.fromJson);
    if (canonical == null) {
      await (database.delete(database.libraryTags)..where(
            (value) =>
                value.accountId.equals(accountId) & value.tagId.equals(tagId),
          ))
          .go();
    } else {
      await _applyTag(accountId, canonical, false);
    }
  }

  Future<void> _restoreListItem(
    String accountId,
    String listId,
    String paperId,
  ) async {
    final row =
        await (database.select(database.libraryListMemberships)..where(
              (value) =>
                  value.accountId.equals(accountId) &
                  value.listId.equals(listId) &
                  value.paperId.equals(paperId),
            ))
            .getSingleOrNull();
    if (row == null) return;
    final canonical = _canonical(row.canonicalJson, LibraryV2ListItem.fromJson);
    if (canonical == null) {
      await (database.delete(database.libraryListMemberships)..where(
            (value) =>
                value.accountId.equals(accountId) &
                value.listId.equals(listId) &
                value.paperId.equals(paperId),
          ))
          .go();
    } else {
      await _applyListItem(accountId, canonical, false);
    }
  }

  Future<void> _restoreItemTag(
    String accountId,
    String paperId,
    String tagId,
  ) async {
    final row =
        await (database.select(database.libraryTagMemberships)..where(
              (value) =>
                  value.accountId.equals(accountId) &
                  value.paperId.equals(paperId) &
                  value.tagId.equals(tagId),
            ))
            .getSingleOrNull();
    if (row == null) return;
    final canonical = _canonical(row.canonicalJson, LibraryV2ItemTag.fromJson);
    if (canonical == null) {
      await (database.delete(database.libraryTagMemberships)..where(
            (value) =>
                value.accountId.equals(accountId) &
                value.paperId.equals(paperId) &
                value.tagId.equals(tagId),
          ))
          .go();
    } else {
      await _applyItemTag(accountId, canonical, false);
    }
  }

  Future<void> _requireRevision(
    String accountId,
    int expectedRevision,
    LibraryScopeGuard scopeGuard,
  ) async {
    _requireScope(scopeGuard);
    final checkpoint = await (database.select(
      database.librarySyncStates,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    if (checkpoint == null ||
        !checkpoint.initialized ||
        checkpoint.lastRevision != expectedRevision) {
      throw const LibraryRevisionConflict();
    }
    _requireScope(scopeGuard);
  }

  Future<void> _enqueue({
    required String accountId,
    required String operationId,
    required String entityKind,
    required String entityId,
    required String operation,
    required Map<String, dynamic> payload,
    required DateTime createdAt,
  }) => database
      .into(database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          operationId: operationId,
          accountId: Value(accountId),
          entityKind: entityKind,
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: createdAt,
          nextAttemptAt: Value(createdAt),
          state: const Value('queued'),
          updatedAt: Value(createdAt),
        ),
      );

  String _newOperationId() {
    final value = _operationId().toLowerCase();
    _validateUuid(value, 'operationId');
    return value;
  }
}

T? _canonical<T>(String? json, T Function(Map<String, dynamic>) decode) {
  if (json == null) return null;
  try {
    final value = jsonDecode(json);
    if (value is! Map) return null;
    return decode(Map<String, dynamic>.from(value));
  } on Object {
    // Corrupt local canonical data must not keep a terminal outbox row in
    // flight forever. Returning null applies the existing fail-closed path:
    // discard the optimistic projection rather than invent confirmed state.
    return null;
  }
}

String _changeEntityKey(LibraryV2Change change) => switch (change) {
  LibraryV2ItemChange(:final entry) => '$_itemKind:${entry.item.paperId}',
  LibraryV2ListChange(:final list) => '$_listKind:${list.id}',
  LibraryV2ListItemChange(:final listItem) =>
    '$_listItemKind:${listItem.listId}:${listItem.paperId}',
  LibraryV2TagChange(:final tag) => '$_tagKind:${tag.id}',
  LibraryV2ItemTagChange(:final itemTag) =>
    '$_itemTagKind:${itemTag.paperId}:${itemTag.tagId}',
};

List<String> _activeIds(Set<String> values, String kind) => values
    .where((value) => value.startsWith('$kind:'))
    .map((value) => value.substring(kind.length + 1))
    .toList(growable: false);

List<String> _normalizeNames(
  Iterable<String> values, {
  required int maximumLength,
  required String field,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    if (value.length > maximumLength ||
        value.runes.any((rune) => rune < 0x20)) {
      throw ArgumentError.value(raw, field);
    }
    if (seen.add(value.toLowerCase())) result.add(value);
    if (result.length > 20) throw ArgumentError.value(values, field);
  }
  return result;
}

String? _nullableTrimmed(
  String value,
  String field, {
  required int maximumLength,
}) {
  final normalized = value.trim();
  if (normalized.length > maximumLength ||
      normalized.runes.any((rune) => rune == 0)) {
    throw ArgumentError.value(value, field);
  }
  return normalized.isEmpty ? null : normalized;
}

String _requiredTrimmed(
  String value,
  String field, {
  required int maximumLength,
}) {
  final normalized = _nullableTrimmed(
    value,
    field,
    maximumLength: maximumLength,
  );
  if (normalized == null) throw ArgumentError.value(value, field);
  if (normalized.split(RegExp(r'\s+')).join(' ') != normalized ||
      normalized.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}

void _validateAccountId(String value) {
  if (value.isEmpty || value.length > 128) {
    throw ArgumentError.value(value, 'accountId');
  }
}

void _validateUuid(String value, String field) {
  if (!_uuid.hasMatch(value)) throw ArgumentError.value(value, field);
}

void _requireScope(LibraryScopeGuard guard) {
  if (!guard()) throw const LibraryScopeChanged();
}

final class LibraryRevisionConflict implements Exception {
  const LibraryRevisionConflict();

  @override
  String toString() => 'LibraryRevisionConflict';
}

final class LibraryCollectionNameConflict implements Exception {
  const LibraryCollectionNameConflict();

  @override
  String toString() => 'LibraryCollectionNameConflict';
}

const _itemKind = 'library_v2_item';
const _listKind = 'library_v2_list';
const _tagKind = 'library_v2_tag';
const _listItemKind = 'library_v2_list_item';
const _itemTagKind = 'library_v2_item_tag';
const _activeStates = ['queued', 'recovery', 'in_flight'];

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
