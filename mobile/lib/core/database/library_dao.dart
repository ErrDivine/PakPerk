import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../library/library_action_failure.dart';
import '../library/library_models.dart';
import '../models/paper.dart';
import 'app_database.dart';
import 'paper_cache_dao.dart';

typedef LibraryClock = DateTime Function();
typedef LibraryOperationIdFactory = String Function();
typedef LibraryScopeGuard = bool Function();

final class LibraryDao {
  LibraryDao(
    this.database, {
    LibraryClock? clock,
    LibraryOperationIdFactory? operationId,
  }) : _clock = clock ?? DateTime.now,
       _operationId = operationId ?? const Uuid().v4,
       _papers = PaperCacheDao(database);

  final PakPerkDatabase database;
  final LibraryClock _clock;
  final LibraryOperationIdFactory _operationId;
  final PaperCacheDao _papers;

  Stream<LibrarySavedState> watchSavedState(String accountId, String paperId) {
    _validateScope(accountId, paperId);
    return database
        .customSelect(
          '''
          SELECT
            li.deleted AS deleted,
            COALESCE((
              SELECT COUNT(*) FROM sync_outbox AS active
              WHERE active.account_id = li.account_id
                AND active.entity_kind IN ('library_item', 'library_v2_item')
                AND active.entity_id = li.paper_id
                AND active.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS active_count,
            (
              SELECT CASE
                WHEN current.state = 'failed' THEN current.last_error_code
                ELSE NULL
              END
              FROM sync_outbox AS current
              WHERE current.account_id = li.account_id
                AND current.entity_kind IN ('library_item', 'library_v2_item')
                AND current.entity_id = li.paper_id
              ORDER BY current.rowid DESC
              LIMIT 1
            ) AS failure_code
          FROM library_items AS li
          WHERE li.account_id = ? AND li.paper_id = ?
          ''',
          variables: [Variable(accountId), Variable(paperId)],
          readsFrom: {database.libraryItems, database.syncOutbox},
        )
        .watchSingleOrNull()
        .map((row) {
          if (row == null) return const LibrarySavedState.notSaved();
          final failureCode = row.readNullable<String>('failure_code');
          return LibrarySavedState(
            saved: !row.read<bool>('deleted'),
            syncPending: row.read<int>('active_count') > 0,
            issue: failureCode == null
                ? null
                : LibrarySyncIssue.fromCode(failureCode),
          );
        })
        .distinct();
  }

  Stream<List<LibraryListItem>> watchToRead(String accountId) =>
      _watchLibraryItems(accountId, activeOnly: true);

  /// Watches every retained library state for the dedicated Library
  /// destination. Queue authority continues to use [watchToRead], which
  /// deliberately excludes Reviewed and Archived rows.
  Stream<List<LibraryListItem>> watchLibraryItems(String accountId) =>
      _watchLibraryItems(accountId, activeOnly: false);

  /// Watches terminal failures from direct, user-initiated Library actions.
  ///
  /// This intentionally selects neither `payload_json` nor arbitrary outbox
  /// kinds. Retryable work remains in an active state and is not an alert.
  Stream<List<LibraryActionFailure>> watchActionFailureAlerts(
    String accountId, {
    int limit = 10,
  }) {
    _validateAccountId(accountId);
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 50.');
    }
    return database
        .customSelect(
          '''
          WITH ranked_failures AS (
            SELECT
              operation_id,
              entity_kind,
              entity_id,
              operation,
              last_error_code,
              state,
              created_at,
              updated_at,
              rowid AS outbox_row_id,
              ROW_NUMBER() OVER (
                PARTITION BY entity_kind, entity_id
                ORDER BY rowid DESC
              ) AS failure_rank
            FROM sync_outbox
            WHERE account_id = ?
              AND entity_kind IN (
                'library_item',
                'library_v2_item',
                'library_v2_list',
                'library_v2_tag',
                'library_v2_list_item',
                'library_v2_item_tag'
              )
          )
          SELECT
            failed.operation_id AS operation_id,
            failed.entity_kind AS entity_kind,
            failed.operation AS operation,
            failed.last_error_code AS last_error_code,
            COALESCE(failed.updated_at, failed.created_at) AS occurred_at,
            CASE
              WHEN failed.entity_kind IN ('library_item', 'library_v2_item')
              THEN failed.entity_id
              ELSE NULL
            END AS paper_id,
            cached.metadata_json AS metadata_json
          FROM ranked_failures AS failed
          LEFT JOIN cached_papers AS cached
            ON cached.paper_id = failed.entity_id
           AND failed.entity_kind IN ('library_item', 'library_v2_item')
          WHERE failed.failure_rank = 1
            AND failed.state = 'failed'
          ORDER BY occurred_at DESC, failed.outbox_row_id DESC
          LIMIT ?
          ''',
          variables: [Variable<String>(accountId), Variable<int>(limit)],
          readsFrom: {database.syncOutbox, database.cachedPapers},
        )
        .watch()
        .map(
          (rows) => List<LibraryActionFailure>.unmodifiable(
            rows.map(_actionFailureFromRow),
          ),
        );
  }

  Stream<List<LibraryListItem>> _watchLibraryItems(
    String accountId, {
    required bool activeOnly,
  }) {
    _validateAccountId(accountId);
    final statePredicate = activeOnly
        ? "AND li.list_state NOT IN ('reviewed', 'archived')"
        : '';
    return database
        .customSelect(
          '''
          SELECT
            li.paper_id AS paper_id,
            li.list_state AS list_state,
            li.saved_at AS saved_at,
            li.client_updated_at AS client_updated_at,
            li.private_note AS private_note,
            li.save_source_kind AS save_source_kind,
            li.reminder_at AS reminder_at,
            cp.metadata_json AS metadata_json,
            COALESCE((
              SELECT json_group_array(named.name) FROM (
                SELECT lists.name AS name
                FROM library_list_memberships AS membership
                INNER JOIN library_custom_lists AS lists
                  ON lists.account_id = membership.account_id
                 AND lists.list_id = membership.list_id
                WHERE membership.account_id = li.account_id
                  AND membership.paper_id = li.paper_id
                  AND membership.deleted = 0
                  AND lists.deleted = 0
                ORDER BY lists.sort_order, lists.name COLLATE NOCASE, lists.list_id
              ) AS named
            ), '[]') AS list_names_json,
            COALESCE((
              SELECT json_group_array(named.name) FROM (
                SELECT tags.name AS name
                FROM library_tag_memberships AS membership
                INNER JOIN library_tags AS tags
                  ON tags.account_id = membership.account_id
                 AND tags.tag_id = membership.tag_id
                WHERE membership.account_id = li.account_id
                  AND membership.paper_id = li.paper_id
                  AND membership.deleted = 0
                  AND tags.deleted = 0
                ORDER BY tags.name COLLATE NOCASE, tags.tag_id
              ) AS named
            ), '[]') AS tag_names_json,
            COALESCE((
              SELECT COUNT(*) FROM sync_outbox AS active
              WHERE active.account_id = li.account_id
                AND active.entity_kind IN ('library_item', 'library_v2_item')
                AND active.entity_id = li.paper_id
                AND active.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS active_count,
            (
              SELECT CASE
                WHEN current.state = 'failed' THEN current.last_error_code
                ELSE NULL
              END
              FROM sync_outbox AS current
              WHERE current.account_id = li.account_id
                AND current.entity_kind IN ('library_item', 'library_v2_item')
                AND current.entity_id = li.paper_id
              ORDER BY current.rowid DESC
              LIMIT 1
            ) AS failure_code
          FROM library_items AS li
          INNER JOIN cached_papers AS cp ON cp.paper_id = li.paper_id
          WHERE li.account_id = ? AND li.deleted = 0
          $statePredicate
          ORDER BY COALESCE(li.saved_at, li.client_updated_at) DESC,
                   li.paper_id DESC
          ''',
          variables: [Variable(accountId)],
          readsFrom: {
            database.libraryItems,
            database.syncOutbox,
            database.cachedPapers,
            database.libraryCustomLists,
            database.libraryTags,
            database.libraryListMemberships,
            database.libraryTagMemberships,
          },
        )
        .watch()
        .map((rows) {
          final items = <LibraryListItem>[];
          for (final row in rows) {
            final storedState = row.read<String>('list_state');
            final decodedState = LibraryItemState.tryFromStorage(storedState);
            // A future unknown nondeleted state must not make an older client
            // infer an empty queue. Treat it as active Inbox for queue
            // authority, but omit it from the organizing destination rather
            // than presenting a fabricated canonical state.
            if (decodedState == null && !activeOnly) continue;
            final state = decodedState ?? LibraryItemState.inbox;
            final paper = _decodePaper(
              row.read<String>('paper_id'),
              row.read<String>('metadata_json'),
            );
            if (paper == null) continue;
            final failureCode = row.readNullable<String>('failure_code');
            items.add(
              LibraryListItem(
                paper: paper,
                savedAt:
                    row.readNullable<DateTime>('saved_at')?.toUtc() ??
                    row.read<DateTime>('client_updated_at').toUtc(),
                savedState: LibrarySavedState(
                  saved: true,
                  syncPending: row.read<int>('active_count') > 0,
                  issue: failureCode == null
                      ? null
                      : LibrarySyncIssue.fromCode(failureCode),
                ),
                state: state,
                privateNote: row.readNullable<String>('private_note'),
                saveSourceKind: LibrarySaveSourceKind.tryFromWire(
                  row.readNullable<String>('save_source_kind'),
                ),
                reminderAt: row.readNullable<DateTime>('reminder_at')?.toUtc(),
                listNames: _decodeNames(row.read<String>('list_names_json')),
                tagNames: _decodeNames(row.read<String>('tag_names_json')),
              ),
            );
          }
          return List<LibraryListItem>.unmodifiable(items);
        });
  }

  Stream<int> watchPendingCount(String accountId) {
    _validateAccountId(accountId);
    final count = database.syncOutbox.operationId.count();
    final query = database.selectOnly(database.syncOutbox)
      ..addColumns([count])
      ..where(
        database.syncOutbox.accountId.equals(accountId) &
            _isLibraryOutboxKind(database.syncOutbox.entityKind) &
            database.syncOutbox.state.isIn(_activeOutboxStates),
      );
    return query.watchSingle().map((row) => row.read(count) ?? 0).distinct();
  }

  Stream<LibraryPendingIntentCounts> watchPendingIntents(String accountId) {
    _validateAccountId(accountId);
    return database
        .customSelect(
          '''
          SELECT
            COALESCE(SUM(CASE WHEN operation IN (
              'library_save', 'library_v2_item_put_active'
            ) THEN 1 ELSE 0 END), 0)
              AS save_count,
            COALESCE(SUM(CASE WHEN operation IN (
              'library_remove', 'library_v2_item_put_inactive',
              'library_v2_item_delete'
            ) THEN 1 ELSE 0 END), 0)
              AS remove_count
          FROM sync_outbox
          WHERE account_id = ?
            AND entity_kind IN ('library_item', 'library_v2_item')
            AND state IN ('queued', 'recovery', 'in_flight')
          ''',
          variables: [Variable(accountId)],
          readsFrom: {database.syncOutbox},
        )
        .watchSingle()
        .map(
          (row) => LibraryPendingIntentCounts(
            saves: row.read<int>('save_count'),
            removes: row.read<int>('remove_count'),
          ),
        )
        .distinct();
  }

  Stream<LibrarySyncCheckpoint> watchSyncCheckpoint(String accountId) {
    _validateAccountId(accountId);
    final query = database.select(database.librarySyncStates)
      ..where((table) => table.accountId.equals(accountId));
    return query
        .watchSingleOrNull()
        .map(
          (row) => row == null
              ? const LibrarySyncCheckpoint.unknown()
              : LibrarySyncCheckpoint(
                  initialized: row.initialized,
                  lastRevision: row.lastRevision,
                ),
        )
        .distinct();
  }

  Future<String> enqueueMutation({
    required String accountId,
    required String paperId,
    required bool saved,
    PaperSummary? paper,
    LibrarySaveSourceKind? saveSourceKind,
    LibraryScopeGuard? scopeGuard,
  }) async {
    _validateScope(accountId, paperId);
    if (paper != null && paper.paperId != paperId) {
      throw ArgumentError.value(
        paper.paperId,
        'paper',
        'Paper identity does not match the target.',
      );
    }
    final operationId = _operationId().toLowerCase();
    if (!_uuid.hasMatch(operationId)) {
      throw StateError('The operation ID factory returned a non-UUID value.');
    }
    final now = _clock().toUtc();
    final guard = scopeGuard ?? () => true;
    if (!guard()) throw const LibraryScopeChanged();
    await database.transaction(() async {
      if (!guard()) throw const LibraryScopeChanged();
      if (paper != null) await _papers.save(paper, accessedAt: now);
      if (!guard()) throw const LibraryScopeChanged();
      final existing = await _libraryItem(accountId, paperId);

      // A queued operation has not crossed the network boundary and can be
      // replaced atomically. An in-flight operation is immutable and the new
      // intent waits behind it. A new explicit intent also dismisses an older
      // permanent error for the same paper.
      await (database.delete(database.syncOutbox)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.entityKind.equals('library_item') &
                row.entityId.equals(paperId) &
                row.state.isIn(const ['queued', 'failed']),
          ))
          .go();

      final projectedSavedAt = saved
          ? (existing != null && !existing.deleted
                ? existing.savedAt ?? now
                : now)
          : existing?.savedAt;
      final projectedSaveSource = saved
          ? saveSourceKind?.wireValue ?? existing?.saveSourceKind
          : existing?.saveSourceKind;
      await database
          .into(database.libraryItems)
          .insertOnConflictUpdate(
            LibraryItemsCompanion.insert(
              accountId: accountId,
              paperId: paperId,
              listState: const Value('to_read'),
              clientUpdatedAt: now,
              serverUpdatedAt: Value(existing?.serverUpdatedAt),
              deleted: Value(!saved),
              savedAt: Value(projectedSavedAt),
              removedAt: Value(saved ? null : now),
              saveSourceKind: Value(projectedSaveSource),
              revision: Value(existing?.revision),
              lastOperationId: Value(existing?.lastOperationId),
              canonicalDeleted: Value(existing?.canonicalDeleted),
              canonicalSavedAt: Value(existing?.canonicalSavedAt),
              canonicalRemovedAt: Value(existing?.canonicalRemovedAt),
            ),
          );
      await database
          .into(database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              operationId: operationId,
              accountId: Value(accountId),
              entityKind: 'library_item',
              entityId: paperId,
              operation: saved ? 'library_save' : 'library_remove',
              payloadJson: saved
                  ? jsonEncode({
                      'state': 'to_read',
                      if (saveSourceKind != null)
                        'save_source_kind': saveSourceKind.wireValue,
                    })
                  : '{}',
              createdAt: now,
              nextAttemptAt: Value(now),
              state: const Value('queued'),
              updatedAt: Value(now),
            ),
          );
      if (!guard()) throw const LibraryScopeChanged();
    });
    return operationId;
  }

  Future<void> recoverInFlight(String accountId) async {
    _validateAccountId(accountId);
    final now = _clock().toUtc();
    await (database.update(database.syncOutbox)..where(
          (row) =>
              row.accountId.equals(accountId) &
              _isLibraryOutboxKind(row.entityKind) &
              row.state.equals('in_flight'),
        ))
        .write(
          SyncOutboxCompanion(
            state: const Value('recovery'),
            startedAt: const Value(null),
            nextAttemptAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  Future<LibraryPendingOperation?> claimNextDue({
    required String accountId,
    required DateTime now,
  }) {
    _validateAccountId(accountId);
    return database.transaction(() async {
      final active =
          await (database.select(database.syncOutbox)
                ..where(
                  (table) =>
                      table.accountId.equals(accountId) &
                      _isLibraryOutboxKind(table.entityKind) &
                      table.state.isIn(_activeOutboxStates),
                )
                ..orderBy([
                  (table) => OrderingTerm.asc(table.createdAt),
                  (table) => OrderingTerm.asc(table.operationId),
                ]))
              .get();
      SyncOutboxRow? firstV2;
      for (final candidate in active) {
        if (_isV2Outbox(candidate)) {
          firstV2 = candidate;
          break;
        }
      }
      final blockedEntities = active
          .where(
            (candidate) =>
                candidate.state == 'recovery' || candidate.state == 'in_flight',
          )
          .map(_outboxEntityKey)
          .toSet();
      SyncOutboxRow? row;
      for (final candidate in active.where(
        (candidate) => candidate.state == 'recovery',
      )) {
        if (_isV2Outbox(candidate) && !identical(candidate, firstV2)) {
          continue;
        }
        final due =
            candidate.nextAttemptAt == null ||
            !candidate.nextAttemptAt!.toUtc().isAfter(now.toUtc());
        if (due) {
          row = candidate;
          break;
        }
      }
      for (final candidate in active) {
        if (row != null) break;
        if (_isV2Outbox(candidate) && !identical(candidate, firstV2)) {
          continue;
        }
        if (candidate.state != 'queued' ||
            blockedEntities.contains(_outboxEntityKey(candidate))) {
          continue;
        }
        final due =
            candidate.nextAttemptAt == null ||
            !candidate.nextAttemptAt!.toUtc().isAfter(now.toUtc());
        if (due) {
          row = candidate;
          break;
        }
      }
      final claimed = row;
      if (claimed == null || claimed.accountId == null) return null;
      final updated =
          await (database.update(database.syncOutbox)..where(
                (table) =>
                    table.operationId.equals(claimed.operationId) &
                    table.state.equals(claimed.state),
              ))
              .write(
                SyncOutboxCompanion(
                  state: const Value('in_flight'),
                  startedAt: Value(now.toUtc()),
                  updatedAt: Value(now.toUtc()),
                ),
              );
      if (updated != 1) return null;
      return _pendingOperation(claimed);
    });
  }

  Future<DateTime?> nextAttemptAt(String accountId) async {
    _validateAccountId(accountId);
    final active =
        await (database.select(database.syncOutbox)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  _isLibraryOutboxKind(table.entityKind) &
                  table.state.isIn(_activeOutboxStates),
            ))
            .get();
    SyncOutboxRow? firstV2;
    for (final row in active) {
      if (_isV2Outbox(row)) {
        firstV2 = row;
        break;
      }
    }
    final blockedEntities = active
        .where((row) => row.state == 'recovery' || row.state == 'in_flight')
        .map(_outboxEntityKey)
        .toSet();
    DateTime? earliest;
    for (final row in active) {
      if (_isV2Outbox(row) && !identical(row, firstV2)) continue;
      final eligible =
          row.state == 'recovery' ||
          (row.state == 'queued' &&
              !blockedEntities.contains(_outboxEntityKey(row)));
      if (!eligible) continue;
      final candidate = (row.nextAttemptAt ?? row.createdAt).toUtc();
      if (earliest == null || candidate.isBefore(earliest)) {
        earliest = candidate;
      }
    }
    return earliest;
  }

  Future<int> pendingCount(String accountId) async {
    _validateAccountId(accountId);
    final count = database.syncOutbox.operationId.count();
    final row =
        await (database.selectOnly(database.syncOutbox)
              ..addColumns([count])
              ..where(
                database.syncOutbox.accountId.equals(accountId) &
                    _isLibraryOutboxKind(database.syncOutbox.entityKind) &
                    database.syncOutbox.state.isIn(_activeOutboxStates),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<LibraryOutboxSnapshot> outboxSnapshot(String accountId) async {
    _validateAccountId(accountId);
    final count = database.syncOutbox.operationId.count();
    final oldest = database.syncOutbox.createdAt.min();
    final all =
        await (database.selectOnly(database.syncOutbox)
              ..addColumns([count, oldest])
              ..where(
                database.syncOutbox.accountId.equals(accountId) &
                    _isLibraryOutboxKind(database.syncOutbox.entityKind) &
                    database.syncOutbox.state.isIn(_activeOutboxStates),
              ))
            .getSingle();
    final oldestSave = database.syncOutbox.createdAt.min();
    final saves =
        await (database.selectOnly(database.syncOutbox)
              ..addColumns([oldestSave])
              ..where(
                database.syncOutbox.accountId.equals(accountId) &
                    database.syncOutbox.entityKind.isIn(const [
                      'library_item',
                      'library_v2_item',
                    ]) &
                    database.syncOutbox.operation.isIn(const [
                      'library_save',
                      'library_v2_item_put_active',
                    ]) &
                    database.syncOutbox.state.isIn(_activeOutboxStates),
              ))
            .getSingle();
    return LibraryOutboxSnapshot(
      pendingCount: all.read(count) ?? 0,
      oldestCreatedAt: all.read(oldest)?.toUtc(),
      oldestSaveCreatedAt: saves.read(oldestSave)?.toUtc(),
    );
  }

  Future<LibraryPendingIntentCounts> pendingIntents(String accountId) async {
    _validateAccountId(accountId);
    return await watchPendingIntents(accountId).first;
  }

  Future<int> activeToReadCount(String accountId) async {
    _validateAccountId(accountId);
    final count = database.libraryItems.paperId.count();
    final row =
        await (database.selectOnly(database.libraryItems)
              ..addColumns([count])
              ..where(
                database.libraryItems.accountId.equals(accountId) &
                    database.libraryItems.deleted.equals(false) &
                    database.libraryItems.listState.isNotIn(const [
                      'reviewed',
                      'archived',
                    ]),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<LibrarySyncIssue?> latestSyncIssue(String accountId) async {
    _validateAccountId(accountId);
    final row = await database
        .customSelect(
          '''
          WITH current_operations AS (
            SELECT
              last_error_code,
              state,
              created_at,
              updated_at,
              rowid AS outbox_row_id,
              ROW_NUMBER() OVER (
                PARTITION BY entity_kind, entity_id
                ORDER BY rowid DESC
              ) AS operation_rank
            FROM sync_outbox
            WHERE account_id = ?
              AND entity_kind IN (
                'library_item',
                'library_v2_item',
                'library_v2_list',
                'library_v2_tag',
                'library_v2_list_item',
                'library_v2_item_tag'
              )
          )
          SELECT last_error_code
          FROM current_operations
          WHERE operation_rank = 1
            AND state = 'failed'
            AND last_error_code IS NOT NULL
          ORDER BY COALESCE(updated_at, created_at) DESC, outbox_row_id DESC
          LIMIT 1
          ''',
          variables: [Variable<String>(accountId)],
          readsFrom: {database.syncOutbox},
        )
        .getSingleOrNull();
    final code = row?.readNullable<String>('last_error_code');
    return code == null ? null : LibrarySyncIssue.fromCode(code);
  }

  Future<void> markRetry({
    required LibraryPendingOperation operation,
    required String errorCode,
    required DateTime nextAttemptAt,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final queuedSuccessor =
        await (database.select(database.syncOutbox)
              ..where(
                (row) =>
                    row.accountId.equals(operation.accountId) &
                    row.entityKind.equals(operation.entityKind) &
                    row.entityId.equals(operation.entityId) &
                    row.operationId.equals(operation.operationId).not() &
                    row.state.equals('queued'),
              )
              ..limit(1))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    await (database.update(database.syncOutbox)..where(
          (row) =>
              row.operationId.equals(operation.operationId) &
              row.accountId.equals(operation.accountId) &
              row.state.equals('in_flight'),
        ))
        .write(
          SyncOutboxCompanion(
            attemptCount: Value(operation.attemptCount + 1),
            nextAttemptAt: Value(nextAttemptAt.toUtc()),
            lastErrorCode: Value(_safeErrorCode(errorCode)),
            state: Value(queuedSuccessor == null ? 'queued' : 'recovery'),
            startedAt: const Value(null),
            updatedAt: Value(_clock().toUtc()),
          ),
        );
    _requireScope(scopeGuard);
  });

  Future<void> markPermanentFailure({
    required LibraryPendingOperation operation,
    required String errorCode,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final changed =
        await (database.update(database.syncOutbox)..where(
              (row) =>
                  row.operationId.equals(operation.operationId) &
                  row.accountId.equals(operation.accountId) &
                  row.state.equals('in_flight'),
            ))
            .write(
              SyncOutboxCompanion(
                attemptCount: Value(operation.attemptCount + 1),
                nextAttemptAt: const Value(null),
                lastErrorCode: Value(_safeErrorCode(errorCode)),
                state: const Value('failed'),
                startedAt: const Value(null),
                updatedAt: Value(_clock().toUtc()),
              ),
            );
    _requireScope(scopeGuard);
    if (changed != 1) return;
    if (operation.entityKind != 'library_item') return;
    final hasActiveOperation = await _hasActiveOperation(
      operation.accountId,
      operation.paperId,
    );
    _requireScope(scopeGuard);
    if (hasActiveOperation) {
      return;
    }
    final row = await _libraryItem(operation.accountId, operation.paperId);
    _requireScope(scopeGuard);
    if (row == null) return;
    final canonicalDeleted = row.canonicalDeleted;
    await (database.update(database.libraryItems)..where(
          (table) =>
              table.accountId.equals(operation.accountId) &
              table.paperId.equals(operation.paperId),
        ))
        .write(
          LibraryItemsCompanion(
            deleted: Value(canonicalDeleted ?? true),
            savedAt: Value(row.canonicalSavedAt),
            removedAt: Value(row.canonicalRemovedAt),
            clientUpdatedAt: Value(row.serverUpdatedAt ?? _clock().toUtc()),
          ),
        );
    _requireScope(scopeGuard);
  });

  Future<void> applyMutationSuccess({
    required LibraryPendingOperation operation,
    required LibraryCanonicalItem item,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    if (item.paperId != operation.paperId) return;
    final outbox =
        await (database.select(database.syncOutbox)..where(
              (row) =>
                  row.operationId.equals(operation.operationId) &
                  row.accountId.equals(operation.accountId),
            ))
            .getSingleOrNull();
    _requireScope(scopeGuard);
    if (outbox == null || outbox.state != 'in_flight') return;

    await _applyCanonical(
      accountId: operation.accountId,
      entry: LibraryRemoteEntry(item: item, paper: null),
      preserveProjection: true,
    );
    _requireScope(scopeGuard);
    await (database.delete(
      database.syncOutbox,
    )..where((row) => row.operationId.equals(operation.operationId))).go();
    _requireScope(scopeGuard);
    await (database.delete(database.syncOutbox)..where(
          (row) =>
              row.accountId.equals(operation.accountId) &
              row.entityKind.equals('library_item') &
              row.entityId.equals(operation.paperId) &
              row.state.equals('failed'),
        ))
        .go();
    _requireScope(scopeGuard);
    final hasActiveOperation = await _hasActiveOperation(
      operation.accountId,
      operation.paperId,
    );
    _requireScope(scopeGuard);
    if (!hasActiveOperation) {
      await _projectCanonical(operation.accountId, operation.paperId);
      _requireScope(scopeGuard);
    }
  });

  /// Applies the canonical result of `/v1/me/library/imports` without
  /// fabricating a second outbox save. The server import is already the
  /// durable mutation; this transaction only projects its returned identity
  /// into the account-scoped cache.
  Future<void> applyImportedPaper({
    required String accountId,
    required LibraryCanonicalItem item,
    required PaperSummary paper,
    required int syncRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    if (item.removed ||
        item.paperId != paper.paperId ||
        item.revision != syncRevision) {
      throw ArgumentError('The imported paper result is inconsistent.');
    }
    _requireScope(scopeGuard);
    final preserveProjection = await _hasActiveOperation(
      accountId,
      paper.paperId,
    );
    _requireScope(scopeGuard);
    await _applyCanonical(
      accountId: accountId,
      entry: LibraryRemoteEntry(item: item, paper: paper),
      preserveProjection: preserveProjection,
    );
    _requireScope(scopeGuard);

    // An initialized checkpoint can advance to the import response revision.
    // A never-synced account stays uninitialized: importing one paper is not
    // proof that its complete remote library snapshot has been downloaded.
    final checkpoint = await (database.select(
      database.librarySyncStates,
    )..where((table) => table.accountId.equals(accountId))).getSingleOrNull();
    _requireScope(scopeGuard);
    if (checkpoint != null &&
        checkpoint.initialized &&
        syncRevision > checkpoint.lastRevision) {
      await (database.update(database.librarySyncStates)
            ..where((table) => table.accountId.equals(accountId)))
          .write(LibrarySyncStatesCompanion(lastRevision: Value(syncRevision)));
      _requireScope(scopeGuard);
    }
  });

  Future<void> applyFullSnapshot({
    required String accountId,
    required List<LibraryRemoteEntry> entries,
    required int syncRevision,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final activePaperIds = await _operationPaperIds(
      accountId,
      states: _activeOutboxStates,
    );
    _requireScope(scopeGuard);
    final failedPaperIds = await _operationPaperIds(
      accountId,
      states: const ['failed'],
    );
    _requireScope(scopeGuard);
    final protectedPaperIds = {...activePaperIds, ...failedPaperIds};
    final rows = await (database.select(
      database.libraryItems,
    )..where((table) => table.accountId.equals(accountId))).get();
    _requireScope(scopeGuard);
    for (final row in rows) {
      _requireScope(scopeGuard);
      if (protectedPaperIds.contains(row.paperId)) {
        await (database.update(database.libraryItems)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(row.paperId),
            ))
            .write(
              LibraryItemsCompanion(
                serverUpdatedAt: const Value(null),
                revision: const Value(null),
                canonicalDeleted: const Value(null),
                canonicalSavedAt: const Value(null),
                canonicalRemovedAt: const Value(null),
                deleted:
                    failedPaperIds.contains(row.paperId) &&
                        !activePaperIds.contains(row.paperId)
                    ? const Value(true)
                    : const Value.absent(),
              ),
            );
      } else {
        await (database.delete(database.libraryItems)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(row.paperId),
            ))
            .go();
      }
      _requireScope(scopeGuard);
    }
    for (final entry in entries) {
      _requireScope(scopeGuard);
      await _applyCanonical(
        accountId: accountId,
        entry: entry,
        preserveProjection: activePaperIds.contains(entry.item.paperId),
      );
      _requireScope(scopeGuard);
    }
    _requireScope(scopeGuard);
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
    required LibraryChangesPage page,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _requireScope(scopeGuard);
    final activePaperIds = await _operationPaperIds(
      accountId,
      states: _activeOutboxStates,
    );
    _requireScope(scopeGuard);
    for (final entry in page.items) {
      _requireScope(scopeGuard);
      await _applyCanonical(
        accountId: accountId,
        entry: entry,
        preserveProjection: activePaperIds.contains(entry.item.paperId),
      );
      _requireScope(scopeGuard);
    }
    _requireScope(scopeGuard);
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

  Future<(bool initialized, int lastRevision)> syncCheckpoint(
    String accountId,
  ) async {
    _validateAccountId(accountId);
    final row = await (database.select(
      database.librarySyncStates,
    )..where((table) => table.accountId.equals(accountId))).getSingleOrNull();
    return (row?.initialized ?? false, row?.lastRevision ?? 0);
  }

  Future<void> beginSyncReset({
    required String accountId,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    _requireScope(scopeGuard);
    final current = await (database.select(
      database.librarySyncStates,
    )..where((table) => table.accountId.equals(accountId))).getSingleOrNull();
    _requireScope(scopeGuard);
    await database
        .into(database.librarySyncStates)
        .insertOnConflictUpdate(
          LibrarySyncStatesCompanion.insert(
            accountId: accountId,
            lastRevision: Value(current?.lastRevision ?? 0),
            initialized: const Value(false),
          ),
        );
    _requireScope(scopeGuard);
  });

  Future<void> clearSyncIssue(String accountId, String paperId) async {
    _validateScope(accountId, paperId);
    await (database.delete(database.syncOutbox)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.entityKind.equals('library_item') &
              row.entityId.equals(paperId) &
              row.state.equals('failed'),
        ))
        .go();
  }

  /// Acknowledges the displayed failure and obsolete predecessors for the
  /// same logical entity. A newer failure committed after this alert was read
  /// is preserved by SQLite's local insertion sequence. That sequence is
  /// intentionally kept inside the DAO and never reaches presentation code.
  Future<bool> dismissActionFailure({
    required String accountId,
    required String operationId,
    required LibraryScopeGuard scopeGuard,
  }) => database.transaction(() async {
    _validateAccountId(accountId);
    _validateOperationId(operationId);
    _requireScope(scopeGuard);
    final target = await database
        .customSelect(
          '''
          SELECT
            rowid AS outbox_row_id,
            entity_kind,
            entity_id
          FROM sync_outbox
          WHERE account_id = ?
            AND operation_id = ?
            AND state = 'failed'
            AND entity_kind IN (
              'library_item',
              'library_v2_item',
              'library_v2_list',
              'library_v2_tag',
              'library_v2_list_item',
              'library_v2_item_tag'
            )
          LIMIT 1
          ''',
          variables: [
            Variable<String>(accountId),
            Variable<String>(operationId),
          ],
          readsFrom: {database.syncOutbox},
        )
        .getSingleOrNull();
    _requireScope(scopeGuard);
    if (target == null) return false;
    final removed = await database.customUpdate(
      '''
      DELETE FROM sync_outbox
      WHERE account_id = ?
        AND entity_kind = ?
        AND entity_id = ?
        AND state = 'failed'
        AND rowid <= ?
      ''',
      variables: [
        Variable<String>(accountId),
        Variable<String>(target.read<String>('entity_kind')),
        Variable<String>(target.read<String>('entity_id')),
        Variable<int>(target.read<int>('outbox_row_id')),
      ],
      updates: {database.syncOutbox},
    );
    _requireScope(scopeGuard);
    return removed > 0;
  });

  Future<void> _applyCanonical({
    required String accountId,
    required LibraryRemoteEntry entry,
    required bool preserveProjection,
  }) async {
    final item = entry.item;
    final paper = entry.paper;
    if (paper != null) await _papers.save(paper, accessedAt: _clock().toUtc());
    final existing = await _libraryItem(accountId, item.paperId);
    await database
        .into(database.libraryItems)
        .insertOnConflictUpdate(
          LibraryItemsCompanion.insert(
            accountId: accountId,
            paperId: item.paperId,
            listState: const Value('to_read'),
            clientUpdatedAt: preserveProjection && existing != null
                ? existing.clientUpdatedAt
                : item.updatedAt,
            serverUpdatedAt: Value(item.updatedAt),
            deleted: Value(
              preserveProjection && existing != null
                  ? existing.deleted
                  : item.removed,
            ),
            savedAt: Value(
              preserveProjection && existing != null
                  ? existing.savedAt
                  : item.savedAt,
            ),
            removedAt: Value(
              preserveProjection && existing != null
                  ? existing.removedAt
                  : item.removedAt,
            ),
            revision: Value(item.revision),
            lastOperationId: Value(item.lastOperationId),
            canonicalDeleted: Value(item.removed),
            canonicalSavedAt: Value(item.savedAt),
            canonicalRemovedAt: Value(item.removedAt),
            saveSourceKind: Value(
              preserveProjection && existing != null
                  ? existing.saveSourceKind
                  : item.saveSourceKind?.wireValue,
            ),
          ),
        );
  }

  Future<void> _projectCanonical(String accountId, String paperId) async {
    final row = await _libraryItem(accountId, paperId);
    if (row == null || row.canonicalDeleted == null) return;
    await (database.update(database.libraryItems)..where(
          (table) =>
              table.accountId.equals(accountId) & table.paperId.equals(paperId),
        ))
        .write(
          LibraryItemsCompanion(
            deleted: Value(row.canonicalDeleted!),
            savedAt: Value(row.canonicalSavedAt),
            removedAt: Value(row.canonicalRemovedAt),
            clientUpdatedAt: Value(row.serverUpdatedAt ?? row.clientUpdatedAt),
          ),
        );
  }

  Future<LibraryItemRow?> _libraryItem(String accountId, String paperId) =>
      (database.select(database.libraryItems)..where(
            (table) =>
                table.accountId.equals(accountId) &
                table.paperId.equals(paperId),
          ))
          .getSingleOrNull();

  Future<bool> _hasActiveOperation(String accountId, String paperId) async {
    final count = database.syncOutbox.operationId.count();
    final row =
        await (database.selectOnly(database.syncOutbox)
              ..addColumns([count])
              ..where(
                database.syncOutbox.accountId.equals(accountId) &
                    database.syncOutbox.entityKind.equals('library_item') &
                    database.syncOutbox.entityId.equals(paperId) &
                    database.syncOutbox.state.isIn(_activeOutboxStates),
              ))
            .getSingle();
    return (row.read(count) ?? 0) > 0;
  }

  Future<Set<String>> _operationPaperIds(
    String accountId, {
    required List<String> states,
  }) async {
    final rows =
        await (database.selectOnly(database.syncOutbox)
              ..addColumns([database.syncOutbox.entityId])
              ..where(
                database.syncOutbox.accountId.equals(accountId) &
                    database.syncOutbox.entityKind.equals('library_item') &
                    database.syncOutbox.state.isIn(states),
              ))
            .get();
    return rows
        .map((row) => row.read(database.syncOutbox.entityId))
        .whereType<String>()
        .toSet();
  }

  LibraryPendingOperation _pendingOperation(SyncOutboxRow row) {
    final accountId = row.accountId;
    if (accountId == null) throw StateError('Library operation has no owner.');
    return LibraryPendingOperation(
      operationId: row.operationId,
      accountId: accountId,
      entityKind: row.entityKind,
      entityId: row.entityId,
      operation: row.operation,
      payloadJson: row.payloadJson,
      createdAt: row.createdAt.toUtc(),
      attemptCount: row.attemptCount,
    );
  }
}

PaperSummary? _decodePaper(String expectedId, String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    final paper = PaperSummary.fromJson(Map<String, dynamic>.from(decoded));
    return paper.paperId == expectedId ? paper : null;
  } on Object {
    return null;
  }
}

LibraryActionFailure _actionFailureFromRow(QueryRow row) {
  final entityKind = row.read<String>('entity_kind');
  final operation = row.read<String>('operation');
  final errorCode = row.readNullable<String>('last_error_code');
  final kind = errorCode == 'LOCAL_OUTBOX_CORRUPT'
      ? LibraryActionFailureKind.localDataIssue
      : _actionFailureKind(entityKind, operation);
  final paperId = row.readNullable<String>('paper_id');
  final metadata = row.readNullable<String>('metadata_json');
  final paper = paperId == null || metadata == null
      ? null
      : _decodePaper(paperId, metadata);
  final requiresSignIn = switch (errorCode) {
    'UNAUTHENTICATED' || 'TOKEN_EXPIRED' => true,
    _ => false,
  };
  final action = requiresSignIn
      ? LibraryActionFailureAction.signIn
      : switch (kind) {
          LibraryActionFailureKind.paperAdd ||
          LibraryActionFailureKind.paperRemove when paper != null =>
            LibraryActionFailureAction.reviewPaper,
          LibraryActionFailureKind.paperEdit when paper != null =>
            LibraryActionFailureAction.reviewItem,
          LibraryActionFailureKind.collectionsEdit =>
            LibraryActionFailureAction.reviewCollections,
          LibraryActionFailureKind.localDataIssue =>
            LibraryActionFailureAction.reviewLibrary,
          _ => LibraryActionFailureAction.reviewLibrary,
        };
  return LibraryActionFailure(
    operationId: row.read<String>('operation_id'),
    kind: kind,
    action: action,
    occurredAt: row.read<DateTime>('occurred_at').toUtc(),
    paper:
        action == LibraryActionFailureAction.reviewPaper ||
            action == LibraryActionFailureAction.reviewItem
        ? paper
        : null,
  );
}

LibraryActionFailureKind _actionFailureKind(
  String entityKind,
  String operation,
) => switch ((entityKind, operation)) {
  ('library_item', 'library_save') => LibraryActionFailureKind.paperAdd,
  ('library_item', 'library_remove') => LibraryActionFailureKind.paperRemove,
  (
    'library_v2_item',
    'library_v2_item_put_active' ||
        'library_v2_item_put_inactive' ||
        'library_v2_item_delete',
  ) =>
    LibraryActionFailureKind.paperEdit,
  (
    'library_v2_list',
    'library_v2_list_create' ||
        'library_v2_list_update' ||
        'library_v2_list_delete',
  ) =>
    LibraryActionFailureKind.collectionsEdit,
  (
    'library_v2_tag',
    'library_v2_tag_create' ||
        'library_v2_tag_update' ||
        'library_v2_tag_delete',
  ) =>
    LibraryActionFailureKind.collectionsEdit,
  (
    'library_v2_list_item',
    'library_v2_list_item_put' || 'library_v2_list_item_delete',
  ) =>
    LibraryActionFailureKind.collectionsEdit,
  (
    'library_v2_item_tag',
    'library_v2_item_tag_put' || 'library_v2_item_tag_delete',
  ) =>
    LibraryActionFailureKind.collectionsEdit,
  _ => LibraryActionFailureKind.unknown,
};

List<String> _decodeNames(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.any((name) => name is! String)) {
      return const [];
    }
    return List<String>.unmodifiable(decoded.cast<String>());
  } on Object {
    return const [];
  }
}

Expression<bool> _isLibraryOutboxKind(GeneratedColumn<String> column) =>
    column.equals('library_item') | column.like('library_v2_%');

String _outboxEntityKey(SyncOutboxRow row) =>
    '${row.entityKind}\u{0}${row.entityId}';

bool _isV2Outbox(SyncOutboxRow row) => row.entityKind.startsWith('library_v2_');

String _safeErrorCode(String value) =>
    RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value)
    ? value
    : 'LIBRARY_SYNC_FAILED';

void _validateScope(String accountId, String paperId) {
  _validateAccountId(accountId);
  if (paperId.isEmpty || paperId.length > 128) {
    throw ArgumentError.value(paperId, 'paperId', 'Invalid paper id.');
  }
}

void _validateAccountId(String value) {
  if (value.isEmpty || value.length > 128) {
    throw ArgumentError.value(value, 'accountId', 'Invalid account id.');
  }
}

void _validateOperationId(String value) {
  if (value.isEmpty ||
      value.length > 128 ||
      value.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(value, 'operationId', 'Invalid operation id.');
  }
}

void _requireScope(LibraryScopeGuard scopeGuard) {
  if (!scopeGuard()) throw const LibraryScopeChanged();
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

const _activeOutboxStates = ['queued', 'recovery', 'in_flight'];

final class LibraryScopeChanged implements Exception {
  const LibraryScopeChanged();

  @override
  String toString() => 'LibraryScopeChanged';
}
