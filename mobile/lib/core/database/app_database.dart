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
  // Null is the guest/public projection. Authenticated pages are isolated by
  // Pakperk account ID because server-side block filtering is viewer-specific.
  TextColumn get viewerAccountId => text().nullable()();
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
  TextColumn get privateNote => text().nullable()();
  TextColumn get saveSourceKind => text().nullable()();
  DateTimeColumn get reminderAt => dateTime().nullable()();
  DateTimeColumn get reviewedAt => dateTime().nullable()();
  DateTimeColumn get archivedAt => dateTime().nullable()();

  // The visible [deleted]/[savedAt] pair is the optimistic projection. These
  // nullable fields retain the last server-confirmed state so a permanent
  // mutation failure can roll back without guessing. Null canonicalDeleted
  // means this paper has never been observed on the server.
  BoolColumn get canonicalDeleted => boolean().nullable()();
  DateTimeColumn get canonicalSavedAt => dateTime().nullable()();
  DateTimeColumn get canonicalRemovedAt => dateTime().nullable()();
  TextColumn get canonicalListState => text().nullable()();
  TextColumn get canonicalPrivateNote => text().nullable()();
  TextColumn get canonicalSaveSourceKind => text().nullable()();
  DateTimeColumn get canonicalReminderAt => dateTime().nullable()();
  DateTimeColumn get canonicalReviewedAt => dateTime().nullable()();
  DateTimeColumn get canonicalArchivedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, paperId};
}

@DataClassName('LibraryCustomListRow')
class LibraryCustomLists extends Table {
  TextColumn get accountId => text()();
  TextColumn get listId => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get revision => integer().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get lastOperationId => text().nullable()();
  TextColumn get canonicalJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, listId};
}

@DataClassName('LibraryTagRow')
class LibraryTags extends Table {
  TextColumn get accountId => text()();
  TextColumn get tagId => text()();
  TextColumn get name => text()();
  IntColumn get revision => integer().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get lastOperationId => text().nullable()();
  TextColumn get canonicalJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, tagId};
}

@DataClassName('LibraryListMembershipRow')
class LibraryListMemberships extends Table {
  TextColumn get accountId => text()();
  TextColumn get listId => text()();
  TextColumn get paperId => text()();
  IntColumn get positionRank => integer().withDefault(const Constant(0))();
  TextColumn get note => text().nullable()();
  IntColumn get revision => integer().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get lastOperationId => text().nullable()();
  TextColumn get canonicalJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, listId, paperId};
}

@DataClassName('LibraryTagMembershipRow')
class LibraryTagMemberships extends Table {
  TextColumn get accountId => text()();
  TextColumn get paperId => text()();
  TextColumn get tagId => text()();
  IntColumn get revision => integer().nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get lastOperationId => text().nullable()();
  TextColumn get canonicalJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, paperId, tagId};
}

@DataClassName('CommentDraftRow')
class CommentDrafts extends Table {
  TextColumn get draftId => text()();
  TextColumn get accountId => text().nullable()();
  TextColumn get paperId =>
      text().references(CachedPapers, #paperId, onDelete: KeyAction.restrict)();
  TextColumn get body => text()();
  // Stable across explicit retries and app restarts. It is never enqueued or
  // auto-sent; the user must still press Send for every attempt.
  TextColumn get clientRequestId => text().nullable()();
  TextColumn get lastAttemptedBody => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {draftId};
}

@DataClassName('BlockedUserRow')
class BlockedUsers extends Table {
  TextColumn get accountId => text()();
  TextColumn get blockedUserId => text()();
  TextColumn get handle => text()();
  TextColumn get displayName => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get serverConfirmed =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {accountId, blockedUserId};
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

@DataClassName('CachedDocumentArtifactRow')
class CachedDocumentArtifacts extends Table {
  TextColumn get accountId => text()();
  TextColumn get paperId => text()();
  TextColumn get versionKey => text()();
  IntColumn get generation => integer()();
  TextColumn get artifactKind => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {
    accountId,
    paperId,
    generation,
    artifactKind,
  };
}

/// Position and presentation only. Library state and queue eligibility are
/// intentionally absent so a checkpoint can never become a second authority.
@DataClassName('ReadingCheckpointRow')
class ReadingCheckpoints extends Table {
  TextColumn get accountId => text()();
  TextColumn get paperId => text()();
  IntColumn get generation => integer()();
  TextColumn get mode => text()();
  TextColumn get stage => text()();
  TextColumn get blockId => text().nullable()();
  RealColumn get scrollFraction => real().nullable()();
  DateTimeColumn get lastReadAt => dateTime()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  BoolColumn get pendingSync => boolean().withDefault(const Constant(true))();
  TextColumn get operationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, paperId};
}

/// Private research data is account-scoped and intentionally never joined to
/// feed or Library authority. Note bodies are ordinary SQLite text: Pakperk
/// does not claim this database is encrypted at rest.
@DataClassName('LocalAnnotationRow')
class LocalAnnotations extends Table {
  TextColumn get accountId => text()();
  TextColumn get annotationId => text()();
  TextColumn get paperId => text()();
  IntColumn get generation => integer()();
  TextColumn get blockId => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get body => text().nullable()();
  TextColumn get colorRole => text().nullable()();
  TextColumn get selectorJson => text().nullable()();
  TextColumn get sectionHintJson => text().withDefault(const Constant('[]'))();
  IntColumn get pageHint => integer().nullable()();
  TextColumn get anchorStatus => text()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get syncState => text().withDefault(const Constant('clean'))();
  TextColumn get activeOperationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, annotationId};
}

/// A conflict is never represented by overwriting either body. Resolution
/// adds a third explicit merged value and retains both original versions.
@DataClassName('AnnotationConflictRow')
class AnnotationConflicts extends Table {
  TextColumn get accountId => text()();
  TextColumn get conflictId => text()();
  TextColumn get annotationId => text()();
  TextColumn get attemptedOperationId => text()();
  IntColumn get baseRevision => integer()();
  IntColumn get serverRevision => integer()();
  TextColumn get attemptedBody => text().nullable()();
  TextColumn get serverBody => text().nullable()();
  TextColumn get mergeState =>
      text().withDefault(const Constant('unresolved'))();
  TextColumn get mergedBody => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, conflictId};
}

@DataClassName('LocalEvidenceCardRow')
class LocalEvidenceCards extends Table {
  TextColumn get accountId => text()();
  TextColumn get cardId => text()();
  TextColumn get paperId => text()();
  IntColumn get generation => integer()();
  TextColumn get title => text()();
  TextColumn get claimOrQuestion => text().nullable()();
  TextColumn get userNote => text().nullable()();
  TextColumn get sourceBlockIdsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get figureIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get tableIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get citationContextIdsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get verificationStatus => text()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get syncState => text().withDefault(const Constant('clean'))();
  TextColumn get activeOperationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, cardId};
}

@DataClassName('LocalMemoryItemRow')
class LocalMemoryItems extends Table {
  TextColumn get accountId => text()();
  TextColumn get itemId => text()();
  TextColumn get paperId => text()();
  IntColumn get generation => integer()();
  TextColumn get sourceType => text()();
  TextColumn get sourceId => text()();
  TextColumn get promptText => text().nullable()();
  TextColumn get answerText => text().nullable()();
  TextColumn get status => text()();
  DateTimeColumn get nextReviewAt => dateTime().nullable()();
  IntColumn get reviewCount => integer().withDefault(const Constant(0))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get syncState => text().withDefault(const Constant('clean'))();
  TextColumn get activeOperationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, itemId};
}

/// Stable operation IDs make replay safe across process death. Tombstone
/// operations remain queued until the server acknowledges them.
@DataClassName('ResearchOutboxRow')
class ResearchOutbox extends Table {
  TextColumn get accountId => text()();
  TextColumn get operationId => text()();
  TextColumn get entityKind => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  IntColumn get baseRevision => integer().withDefault(const Constant(0))();
  TextColumn get payloadJson => text()();
  TextColumn get state => text().withDefault(const Constant('queued'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastErrorCode => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, operationId};
}

@DataClassName('ResearchSyncStateRow')
class ResearchSyncStates extends Table {
  TextColumn get accountId => text()();
  TextColumn get entityKind => text()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  TextColumn get cursor => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, entityKind};
}

@DataClassName('CachedVersionArtifactRow')
class CachedVersionArtifacts extends Table {
  TextColumn get accountId => text()();
  TextColumn get paperId => text()();
  TextColumn get cacheKey => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {accountId, paperId, cacheKey};
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
    LibraryCustomLists,
    LibraryTags,
    LibraryListMemberships,
    LibraryTagMemberships,
    CommentDrafts,
    BlockedUsers,
    SyncOutbox,
    LibrarySyncStates,
    CacheMetadata,
    CachedDocumentArtifacts,
    ReadingCheckpoints,
    LocalAnnotations,
    AnnotationConflicts,
    LocalEvidenceCards,
    LocalMemoryItems,
    ResearchOutbox,
    ResearchSyncStates,
    CachedVersionArtifacts,
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
  int get schemaVersion => 10;

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
      if (from < 5) {
        if (!await _columnExists('cached_comment_pages', 'viewer_account_id')) {
          // Phase 4 never exposed comments, so any pre-v5 payload is only a
          // dormant public cache entry. Preserve it as a guest projection.
          await migrator.addColumn(
            cachedCommentPages,
            cachedCommentPages.viewerAccountId,
          );
        }
        if (!await _columnExists('comment_drafts', 'client_request_id')) {
          await migrator.addColumn(
            commentDrafts,
            commentDrafts.clientRequestId,
          );
        }
        if (!await _columnExists('comment_drafts', 'last_attempted_body')) {
          await migrator.addColumn(
            commentDrafts,
            commentDrafts.lastAttemptedBody,
          );
        }
        // Drafts created before the comment feature had no verified account
        // ownership. Fail closed instead of attaching them to the next login.
        await (delete(
          commentDrafts,
        )..where((row) => row.accountId.isNull())).go();
        await migrator.createTable(blockedUsers);
      }
      if (from < 6 &&
          await _columnExists('comment_drafts', 'parent_comment_id')) {
        // Replies are intentionally outside v0.0. Rebuild the table so a
        // dormant legacy field cannot quietly become a reply feature later.
        await migrator.alterTable(TableMigration(commentDrafts));
      }
      if (from < 7) {
        if (!await _columnExists('library_items', 'private_note')) {
          await migrator.addColumn(libraryItems, libraryItems.privateNote);
        }
        if (!await _columnExists('library_items', 'save_source_kind')) {
          await migrator.addColumn(libraryItems, libraryItems.saveSourceKind);
        }
        if (!await _columnExists('library_items', 'reviewed_at')) {
          await migrator.addColumn(libraryItems, libraryItems.reviewedAt);
        }
        if (!await _columnExists('library_items', 'archived_at')) {
          await migrator.addColumn(libraryItems, libraryItems.archivedAt);
        }
        if (!await _columnExists('library_items', 'canonical_list_state')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalListState,
          );
        }
        if (!await _columnExists('library_items', 'canonical_private_note')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalPrivateNote,
          );
        }
        if (!await _columnExists(
          'library_items',
          'canonical_save_source_kind',
        )) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalSaveSourceKind,
          );
        }
        if (!await _columnExists('library_items', 'canonical_reviewed_at')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalReviewedAt,
          );
        }
        if (!await _columnExists('library_items', 'canonical_archived_at')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalArchivedAt,
          );
        }
        await migrator.createTable(libraryCustomLists);
        await migrator.createTable(libraryTags);
        await migrator.createTable(libraryListMemberships);
        await migrator.createTable(libraryTagMemberships);
        await customStatement('''
              UPDATE library_items
              SET canonical_list_state = CASE
                WHEN canonical_deleted IS NULL THEN NULL
                ELSE 'inbox'
              END
            ''');
      }
      if (from < 8) {
        if (!await _columnExists('library_items', 'reminder_at')) {
          await migrator.addColumn(libraryItems, libraryItems.reminderAt);
        }
        if (!await _columnExists('library_items', 'canonical_reminder_at')) {
          await migrator.addColumn(
            libraryItems,
            libraryItems.canonicalReminderAt,
          );
        }
      }
      if (from < 9) {
        await migrator.createTable(cachedDocumentArtifacts);
        await migrator.createTable(readingCheckpoints);
      }
      if (from < 10) {
        if (!await _columnExists('reading_checkpoints', 'operation_id')) {
          await migrator.addColumn(
            readingCheckpoints,
            readingCheckpoints.operationId,
          );
        }
        await migrator.createTable(localAnnotations);
        await migrator.createTable(annotationConflicts);
        await migrator.createTable(localEvidenceCards);
        await migrator.createTable(localMemoryItems);
        await migrator.createTable(researchOutbox);
        await migrator.createTable(researchSyncStates);
        await migrator.createTable(cachedVersionArtifacts);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customSelect('PRAGMA journal_mode = WAL').get();
      await _installLibraryIndexes();
      await _installLibraryPinTriggers();
      await _installCommentIndexes();
      await _installDeepReaderIndexes();
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

  /// Drops SQLite's expendable page-cache allocations after an OS memory
  /// warning. Unlike checkpointing or VACUUM this is safe while the reader is
  /// interactive and does not rewrite the database file.
  Future<void> releaseMemory() => customStatement('PRAGMA shrink_memory');

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
          CREATE INDEX IF NOT EXISTS library_lists_account_order
          ON library_custom_lists(account_id, deleted, sort_order, name, list_id)
        ''');
    await customStatement('''
          CREATE UNIQUE INDEX IF NOT EXISTS library_lists_account_name
          ON library_custom_lists(account_id, name COLLATE NOCASE)
          WHERE deleted = 0
        ''');
    await customStatement('''
          CREATE UNIQUE INDEX IF NOT EXISTS library_tags_account_name
          ON library_tags(account_id, name COLLATE NOCASE)
          WHERE deleted = 0
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS library_list_memberships_paper
          ON library_list_memberships(account_id, paper_id, deleted, list_id)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS library_tag_memberships_paper
          ON library_tag_memberships(account_id, paper_id, deleted, tag_id)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS sync_outbox_library_v2_due
          ON sync_outbox(account_id, state, next_attempt_at, created_at)
          WHERE entity_kind LIKE 'library_v2_%'
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

  Future<void> _installCommentIndexes() async {
    await customStatement('''
          CREATE UNIQUE INDEX IF NOT EXISTS comment_drafts_one_per_paper
          ON comment_drafts(account_id, paper_id)
          WHERE account_id IS NOT NULL
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS cached_comment_pages_viewer_paper
          ON cached_comment_pages(
            viewer_account_id, paper_id, fetched_at DESC, page_key
          )
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS blocked_users_account_created
          ON blocked_users(account_id, created_at DESC, blocked_user_id)
        ''');
  }

  Future<void> _installDeepReaderIndexes() async {
    await customStatement('''
          CREATE INDEX IF NOT EXISTS document_artifacts_account_expiry
          ON cached_document_artifacts(account_id, expires_at, fetched_at)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS checkpoints_account_recent
          ON reading_checkpoints(account_id, last_read_at DESC, paper_id)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS annotations_account_paper_updated
          ON local_annotations(account_id, paper_id, updated_at DESC)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS annotations_anchor_review
          ON local_annotations(account_id, anchor_status, updated_at DESC)
          WHERE deleted_at IS NULL AND anchor_status != 'anchored'
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS annotation_conflicts_unresolved
          ON annotation_conflicts(account_id, merge_state, created_at DESC)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS evidence_account_paper_updated
          ON local_evidence_cards(account_id, paper_id, updated_at DESC)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS memory_account_review
          ON local_memory_items(account_id, status, next_review_at, updated_at)
          WHERE deleted_at IS NULL
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS research_outbox_due
          ON research_outbox(account_id, state, created_at)
        ''');
    await customStatement('''
          CREATE INDEX IF NOT EXISTS version_cache_account_expiry
          ON cached_version_artifacts(account_id, expires_at, fetched_at)
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
    await delete(cachedDocumentArtifacts).go();
    await delete(cachedVersionArtifacts).go();
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

  /// Explicit user-requested local wipe. Compliance guards and authentication
  /// invalidation live outside this database and are deliberately preserved.
  Future<void> clearAllLocalData() => transaction(() async {
    // Drafts restrict paper deletion, while every other paper child cascades.
    await delete(commentDrafts).go();
    await delete(feedEntries).go();
    await delete(cachedProcessing).go();
    await delete(cachedIntroductions).go();
    await delete(cachedConnections).go();
    await delete(cachedCommentPages).go();
    await delete(cachedChats).go();
    await delete(cachedDocumentArtifacts).go();
    await delete(readingCheckpoints).go();
    await delete(localAnnotations).go();
    await delete(annotationConflicts).go();
    await delete(localEvidenceCards).go();
    await delete(localMemoryItems).go();
    await delete(researchOutbox).go();
    await delete(researchSyncStates).go();
    await delete(cachedVersionArtifacts).go();
    await delete(feedQueries).go();
    await delete(libraryItems).go();
    await delete(libraryListMemberships).go();
    await delete(libraryTagMemberships).go();
    await delete(libraryCustomLists).go();
    await delete(libraryTags).go();
    await delete(blockedUsers).go();
    await delete(syncOutbox).go();
    await delete(librarySyncStates).go();
    await delete(cachedPapers).go();
    await delete(cacheMetadata).go();
  });
}

Future<String> _productionDatabasePath() async {
  final directory = await getApplicationDocumentsDirectory();
  return '${directory.path}/pakperk_content.sqlite';
}
