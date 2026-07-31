import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

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
                AND active.entity_kind = 'library_item'
                AND active.entity_id = li.paper_id
                AND active.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS active_count,
            (
              SELECT failed.last_error_code FROM sync_outbox AS failed
              WHERE failed.account_id = li.account_id
                AND failed.entity_kind = 'library_item'
                AND failed.entity_id = li.paper_id
                AND failed.state = 'failed'
              ORDER BY failed.created_at DESC, failed.operation_id DESC
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

  Stream<List<LibraryListItem>> watchToRead(String accountId) {
    _validateAccountId(accountId);
    return database
        .customSelect(
          '''
          SELECT
            li.paper_id AS paper_id,
            li.saved_at AS saved_at,
            li.client_updated_at AS client_updated_at,
            cp.metadata_json AS metadata_json,
            COALESCE((
              SELECT COUNT(*) FROM sync_outbox AS active
              WHERE active.account_id = li.account_id
                AND active.entity_kind = 'library_item'
                AND active.entity_id = li.paper_id
                AND active.state IN ('queued', 'recovery', 'in_flight')
            ), 0) AS active_count,
            (
              SELECT failed.last_error_code FROM sync_outbox AS failed
              WHERE failed.account_id = li.account_id
                AND failed.entity_kind = 'library_item'
                AND failed.entity_id = li.paper_id
                AND failed.state = 'failed'
              ORDER BY failed.created_at DESC, failed.operation_id DESC
              LIMIT 1
            ) AS failure_code
          FROM library_items AS li
          INNER JOIN cached_papers AS cp ON cp.paper_id = li.paper_id
          WHERE li.account_id = ? AND li.deleted = 0
          ORDER BY COALESCE(li.saved_at, li.client_updated_at) DESC,
                   li.paper_id DESC
          ''',
          variables: [Variable(accountId)],
          readsFrom: {
            database.libraryItems,
            database.syncOutbox,
            database.cachedPapers,
          },
        )
        .watch()
        .map((rows) {
          final items = <LibraryListItem>[];
          for (final row in rows) {
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
            database.syncOutbox.entityKind.equals('library_item') &
            database.syncOutbox.state.isIn(_activeOutboxStates),
      );
    return query.watchSingle().map((row) => row.read(count) ?? 0).distinct();
  }

  Future<String> enqueueMutation({
    required String accountId,
    required String paperId,
    required bool saved,
    PaperSummary? paper,
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
              payloadJson: saved ? '{"state":"to_read"}' : '{}',
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
              row.entityKind.equals('library_item') &
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
                      table.entityKind.equals('library_item') &
                      table.state.isIn(_activeOutboxStates),
                )
                ..orderBy([
                  (table) => OrderingTerm.asc(table.createdAt),
                  (table) => OrderingTerm.asc(table.operationId),
                ]))
              .get();
      final blockedPapers = active
          .where(
            (candidate) =>
                candidate.state == 'recovery' || candidate.state == 'in_flight',
          )
          .map((candidate) => candidate.entityId)
          .toSet();
      SyncOutboxRow? row;
      for (final candidate in active.where(
        (candidate) => candidate.state == 'recovery',
      )) {
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
        if (candidate.state != 'queued' ||
            blockedPapers.contains(candidate.entityId)) {
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
                  table.entityKind.equals('library_item') &
                  table.state.isIn(_activeOutboxStates),
            ))
            .get();
    final blockedPapers = active
        .where((row) => row.state == 'recovery' || row.state == 'in_flight')
        .map((row) => row.entityId)
        .toSet();
    DateTime? earliest;
    for (final row in active) {
      final eligible =
          row.state == 'recovery' ||
          (row.state == 'queued' && !blockedPapers.contains(row.entityId));
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
                    database.syncOutbox.entityKind.equals('library_item') &
                    database.syncOutbox.state.isIn(_activeOutboxStates),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  Future<LibrarySyncIssue?> latestSyncIssue(String accountId) async {
    _validateAccountId(accountId);
    final row =
        await (database.select(database.syncOutbox)
              ..where(
                (table) =>
                    table.accountId.equals(accountId) &
                    table.entityKind.equals('library_item') &
                    table.state.equals('failed'),
              )
              ..orderBy([
                (table) => OrderingTerm.desc(table.updatedAt),
                (table) => OrderingTerm.desc(table.createdAt),
                (table) => OrderingTerm.desc(table.operationId),
              ])
              ..limit(1))
            .getSingleOrNull();
    final code = row?.lastErrorCode;
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
        await (database.select(database.syncOutbox)..where(
              (row) =>
                  row.accountId.equals(operation.accountId) &
                  row.entityKind.equals('library_item') &
                  row.entityId.equals(operation.paperId) &
                  row.operationId.equals(operation.operationId).not() &
                  row.state.equals('queued'),
            ))
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
      paperId: row.entityId,
      intent: switch (row.operation) {
        'library_save' => LibraryMutationIntent.save,
        'library_remove' => LibraryMutationIntent.remove,
        _ => throw StateError('Unsupported library outbox operation.'),
      },
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
