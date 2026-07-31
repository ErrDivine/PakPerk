import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

@DataClassName('CachedPaperRow')
class CachedPapers extends Table {
  TextColumn get paperId => text()();
  TextColumn get arxivBaseId => text()();
  IntColumn get arxivVersion => integer().nullable()();
  TextColumn get metadataJson => text()();
  DateTimeColumn get publishedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get lastAccessedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();
  BoolColumn get pinnedByLibrary =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {paperId};
}

@DataClassName('FeedQueryRow')
class FeedQueries extends Table {
  TextColumn get queryKey => text()();
  TextColumn get category => text().nullable()();
  TextColumn get nextCursor => text().nullable()();
  DateTimeColumn get refreshedAt => dateTime()();
  BoolColumn get exhausted => boolean().withDefault(const Constant(false))();
  TextColumn get etag => text().nullable()();
  IntColumn get entryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {queryKey};
}

@DataClassName('FeedEntryRow')
class FeedEntries extends Table {
  TextColumn get queryKey =>
      text().references(FeedQueries, #queryKey, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.cascade)();
  DateTimeColumn get insertedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {queryKey, paperId};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {queryKey, position},
  ];
}

@DataClassName('CachedProcessingRow')
class CachedProcessing extends Table {
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.cascade)();
  TextColumn get versionKey => text()();
  IntColumn get generation => integer().withDefault(const Constant(0))();
  TextColumn get payloadJson => text()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {paperId};
}

@DataClassName('CachedIntroductionRow')
class CachedIntroductions extends Table {
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.cascade)();
  TextColumn get versionKey => text()();
  IntColumn get generation => integer()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {paperId};
}

@DataClassName('CachedConnectionRow')
class CachedConnections extends Table {
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.cascade)();
  TextColumn get versionKey => text()();
  IntColumn get generation => integer().withDefault(const Constant(0))();
  TextColumn get payloadJson => text()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {paperId};
}

@DataClassName('CachedCommentPageRow')
class CachedCommentPages extends Table {
  TextColumn get pageKey => text()();
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.cascade)();
  TextColumn get cursor => text().nullable()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();
  TextColumn get etag => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {pageKey};
}

@DataClassName('CachedChatRow')
class CachedChats extends Table {
  TextColumn get sessionId => text()();
  TextColumn get readerKey => text()();
  TextColumn get paperId => text().nullable().references(
    CachedPapers,
    #paperId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get versionKey => text().nullable()();
  IntColumn get generation => integer().withDefault(const Constant(0))();
  TextColumn get payloadJson => text()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId, readerKey};
}

@DataClassName('LibraryItemRow')
class LibraryItems extends Table {
  TextColumn get accountId => text()();
  // Account tombstones must survive public metadata eviction. Active rows are
  // projected into cached_papers.pinned_by_library by AccountCacheDao.
  TextColumn get paperId => text()();
  TextColumn get listState => text().withDefault(const Constant('to_read'))();
  DateTimeColumn get clientUpdatedAt => dateTime()();
  DateTimeColumn get serverUpdatedAt => dateTime().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get savedAt => dateTime().nullable()();
  DateTimeColumn get removedAt => dateTime().nullable()();
  IntColumn get revision => integer().nullable()();
  TextColumn get lastOperationId => text().nullable()();

  // The visible [deleted]/[savedAt] pair is the optimistic projection. These
  // nullable fields retain the last server-confirmed state so a permanent
  // mutation failure can roll back without guessing. Null canonicalDeleted
  // means this paper has never been observed on the server.
  BoolColumn get canonicalDeleted => boolean().nullable()();
  DateTimeColumn get canonicalSavedAt => dateTime().nullable()();
  DateTimeColumn get canonicalRemovedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, paperId};
}

@DataClassName('CommentDraftRow')
class CommentDrafts extends Table {
  TextColumn get draftId => text()();
  TextColumn get accountId => text().nullable()();
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.restrict)();
  TextColumn get parentCommentId => text().nullable()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {draftId};
}

@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  TextColumn get operationId => text()();
  TextColumn get accountId => text().nullable()();
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('queued'))();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

@DataClassName('LibrarySyncStateRow')
class LibrarySyncStates extends Table {
  TextColumn get accountId => text()();
  IntColumn get lastRevision => integer().withDefault(const Constant(0))();
  BoolColumn get initialized => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastFullSyncAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

@DataClassName('CacheMetadataRow')
class CacheMetadata extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    CachedPapers,
    FeedQueries,
    FeedEntries,
    CachedProcessing,
    CachedIntroductions,
    CachedConnections,
    CachedCommentPages,
    CachedChats,
    LibraryItems,
    CommentDrafts,
    SyncOutbox,
    LibrarySyncStates,
    CacheMetadata,
  ],
)
class PakPerkDatabase extends _$PakPerkDatabase {
  PakPerkDatabase(super.executor) : _databasePath = null;

  PakPerkDatabase.atPath(super.executor, String databasePath)
    : _databasePath = Future.value(databasePath);

  factory PakPerkDatabase.defaults() {
    final path = _productionDatabasePath();
    return PakPerkDatabase._withPath(
      driftDatabase(
        // Schema versions migrate in place; never encode them in the
        // production filename or an upgrade silently strands old data.
        name: 'pakperk_content',
        native: DriftNativeOptions(
          shareAcrossIsolates: true,
          databasePath: () => path,
        ),
      ),
      path,
    );
  }

  PakPerkDatabase._withPath(super.executor, this._databasePath);

  final Future<String>? _databasePath;

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(feedQueries, feedQueries.etag);
        await migrator.createTable(cachedChats);
      }
      if (from < 3) {
        if (!await _columnExists('feed_queries', 'entry_count')) {
          await migrator.addColumn(feedQueries, feedQueries.entryCount);
        }
        await customStatement('''
              UPDATE feed_queries
              SET entry_count = (
                SELECT COUNT(*) FROM feed_entries
                WHERE feed_entries.query_key = feed_queries.query_key
              )
            ''');
        // Pre-generation derived blobs cannot be proven current. They are
        // rebuildable, so discard them rather than relabeling them with a
        // generation introduced by this migration.
        await delete(cachedProcessing).go();
        await delete(cachedIntroductions).go();
        await delete(cachedConnections).go();
        if (!await _columnExists('cached_processing', 'generation')) {
          await migrator.addColumn(
            cachedProcessing,
            cachedProcessing.generation,
          );
        }
        if (!await _columnExists('cached_connections', 'generation')) {
          await migrator.addColumn(
            cachedConnections,
            cachedConnections.generation,
          );
        }
        // A v1 upgrade created the current chat table just above. A v2
        // database has the older table and needs the new column added.
        if (from == 2) {
          await migrator.deleteTable('cached_chats');
          await migrator.createTable(cachedChats);
        }
      }
      if (from < 4) {
        if (!await _columnExists('library_items', 'saved_at')) {
          await migrator.addColumn(libraryItems, libraryItems.savedAt);
        }
        if (!await _columnExists('library_items', 'removed_at')) {
          await migrator.addColumn(libraryItems, libraryItems.removedAt);
        }
        if (!await _columnExists('library_items', 'revision')) {
          await migrator.addColumn(libraryItems, libraryItems.revision);
        }
        if (!await _columnExists('library_items', 'last_operation_id')) {
          await migrator.addColumn(libraryItems, libraryItems.lastOperationId);
        }
        if (!await _columnExists('library_items', 'canonical_deleted')) {
          await migrator.addColumn(libraryItems, libraryItems.canonicalDeleted);
        }
        if (!await _columnExists('library_items', 'canonical_saved_at')) {
          await migrator.addColumn(libraryItems, libraryItems.canonicalSavedAt);
        }
        if (!await _columnExists('library_items', 'canonical_removed_at')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalRemovedAt,
          );
        }
        if (!await _columnExists('sync_outbox', 'state')) {
          await migrator.addColumn(syncOutbox, syncOutbox.state);
        }
        if (!await _columnExists('sync_outbox', 'started_at')) {
          await migrator.addColumn(syncOutbox, syncOutbox.startedAt);
        }
        if (!await _columnExists('sync_outbox', 'updated_at')) {
          await migrator.addColumn(syncOutbox, syncOutbox.updatedAt);
        }
        await migrator.createTable(librarySyncStates);
        await customStatement('''
              UPDATE library_items
              SET saved_at = CASE WHEN deleted = 0 THEN client_updated_at END,
                  removed_at = CASE WHEN deleted = 1 THEN client_updated_at END,
                  canonical_deleted = CASE
                    WHEN server_updated_at IS NULL THEN NULL
                    ELSE deleted
                  END,
                  canonical_saved_at = CASE
                    WHEN server_updated_at IS NOT NULL AND deleted = 0
                    THEN client_updated_at
                  END,
                  canonical_removed_at = CASE
                    WHEN server_updated_at IS NOT NULL AND deleted = 1
                    THEN client_updated_at
                  END
            ''');
        await customStatement('''
              UPDATE sync_outbox
              SET updated_at = created_at
              WHERE updated_at IS NULL
            ''');
        await customStatement('''
              DELETE FROM sync_outbox AS older
              WHERE older.entity_kind = 'library_item'
                AND older.state = 'queued'
                AND EXISTS (
                  SELECT 1 FROM sync_outbox AS newer
                  WHERE newer.account_id IS older.account_id
                    AND newer.entity_kind = older.entity_kind
                    AND newer.entity_id = older.entity_id
                    AND newer.state = 'queued'
                    AND (
                      newer.created_at > older.created_at OR
                      (newer.created_at = older.created_at AND
                       newer.operation_id > older.operation_id)
                    )
                )
            ''');
        await customStatement('''
              UPDATE cached_papers
              SET pinned_by_library = EXISTS (
                SELECT 1 FROM library_items
                WHERE library_items.paper_id = cached_papers.paper_id
                  AND library_items.deleted = 0
              )
            ''');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customSelect('PRAGMA journal_mode = WAL').get();
      await _installLibraryIndexes();
      await _installLibraryPinTriggers();
    },
  );

  Future<T> writeTransaction<T>(Future<T> Function() action) =>
      transaction(action);

  Future<int> liveDatabaseBytes() async {
    final pageCount = await _pragmaInt('page_count');
    final freePages = await _pragmaInt('freelist_count');
    final pageSize = await _pragmaInt('page_size');
    return (pageCount - freePages) * pageSize;
  }

  Future<int> physicalDatabaseBytes() async {
    final path = await _databasePath;
    if (path != null) {
      var bytes = 0;
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (await file.exists()) bytes += await file.length();
      }
      return bytes;
    }
    final pageCount = await _pragmaInt('page_count');
    final pageSize = await _pragmaInt('page_size');
    return pageCount * pageSize;
  }

  /// Reclaims freelist and WAL pages. Call only from a lifecycle-safe state,
  /// never from the swipe-time eviction path.
  Future<void> checkpointAndCompact() async {
    await customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
    await customStatement('VACUUM');
    await customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
  }

  Future<int> _pragmaInt(String name) async {
    final row = await customSelect('PRAGMA $name').getSingle();
    final value = row.data.values.firstOrNull;
    return switch (value) {
      int number => number,
      num number => number.toInt(),
      _ => int.tryParse(value?.toString() ?? '') ?? 0,
    };
  }

  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((row) => row.read<String>('name') == column);
  }

  Future<void> _installLibraryPinTriggers() async {
    await customStatement('''
          CREATE TRIGGER IF NOT EXISTS library_pin_after_insert
          AFTER INSERT ON library_items
          BEGIN
            UPDATE cached_papers
            SET pinned_by_library = EXISTS (
              SELECT 1 FROM library_items
              WHERE paper_id = NEW.paper_id AND deleted = 0
            )
            WHERE paper_id = NEW.paper_id;
          END
        ''');
    await customStatement('''
          CREATE TRIGGER IF NOT EXISTS library_pin_after_update
          AFTER UPDATE OF paper_id, deleted ON library_items
          BEGIN
            UPDATE cached_papers
            SET pinned_by_library = EXISTS (
              SELECT 1 FROM library_items
              WHERE paper_id = OLD.paper_id AND deleted = 0
            )
            WHERE paper_id = OLD.paper_id;
            UPDATE cached_papers
            SET pinned_by_library = EXISTS (
              SELECT 1 FROM library_items
              WHERE paper_id = NEW.paper_id AND deleted = 0
            )
            WHERE paper_id = NEW.paper_id;
          END
        ''');
    await customStatement('''
          CREATE TRIGGER IF NOT EXISTS library_pin_after_delete
          AFTER DELETE ON library_items
          BEGIN
            UPDATE cached_papers
            SET pinned_by_library = EXISTS (
              SELECT 1 FROM library_items
              WHERE paper_id = OLD.paper_id AND deleted = 0
            )
            WHERE paper_id = OLD.paper_id;
          END
        ''');
    await customStatement('''
          CREATE TRIGGER IF NOT EXISTS library_pin_after_paper_insert
          AFTER INSERT ON cached_papers
          BEGIN
            UPDATE cached_papers
            SET pinned_by_library = EXISTS (
              SELECT 1 FROM library_items
              WHERE paper_id = NEW.paper_id AND deleted = 0
            )
            WHERE paper_id = NEW.paper_id;
          END
        ''');
  }

  Future<void> _installLibraryIndexes() async {
    await customStatement('''
          CREATE INDEX IF NOT EXISTS library_items_account_saved
          ON library_items(account_id, deleted, saved_at DESC, paper_id DESC)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS library_items_account_revision
          ON library_items(account_id, revision)
        ''');
    await customStatement('''
          CREATE UNIQUE INDEX IF NOT EXISTS sync_outbox_one_queued_library
          ON sync_outbox(account_id, entity_id)
          WHERE entity_kind = 'library_item' AND state = 'queued'
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS sync_outbox_library_due
          ON sync_outbox(account_id, state, next_attempt_at, created_at)
          WHERE entity_kind = 'library_item'
        ''');
  }

  Future<void> putMetadata(String key, Object? value, {DateTime? updatedAt}) =>
      into(cacheMetadata).insertOnConflictUpdate(
        CacheMetadataCompanion.insert(
          key: key,
          valueJson: jsonEncode(value),
          updatedAt: updatedAt ?? DateTime.now().toUtc(),
        ),
      );

  Future<Object?> readMetadata(String key) async {
    final row = await (select(
      cacheMetadata,
    )..where((table) => table.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.valueJson);
    } on FormatException {
      return null;
    }
  }

  Future<void> clearPublicCache() => transaction(() async {
    await delete(feedEntries).go();
    await delete(feedQueries).go();
    await delete(cachedProcessing).go();
    await delete(cachedIntroductions).go();
    await delete(cachedConnections).go();
    await delete(cachedCommentPages).go();
    await delete(cachedChats).go();
    await customStatement('''
          DELETE FROM cached_papers
          WHERE pinned_by_library = 0
            AND NOT EXISTS (
              SELECT 1 FROM library_items
              WHERE library_items.paper_id = cached_papers.paper_id
                AND library_items.deleted = 0
            )
            AND NOT EXISTS (
              SELECT 1 FROM comment_drafts
              WHERE comment_drafts.paper_id = cached_papers.paper_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM sync_outbox
              WHERE sync_outbox.entity_id = cached_papers.paper_id
                AND sync_outbox.entity_kind IN (
                  'paper', 'library_item', 'comment'
                )
            )
        ''');
    await (delete(cacheMetadata)..where((row) => row.key.like('feed:%'))).go();
  });
}

Future<String> _productionDatabasePath() async {
  final directory = await getApplicationDocumentsDirectory();
  return '${directory.path}/pakperk_content.sqlite';
}
