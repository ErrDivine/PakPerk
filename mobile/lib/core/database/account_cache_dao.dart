import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// Account-scoped durable state. This schema deliberately contains no access
/// token, refresh token, authorization code, or OIDC credential columns.
class AccountCacheDao {
  AccountCacheDao(this.database);

  final PakPerkDatabase database;

  Future<void> upsertLibraryItem({
    required String accountId,
    required String paperId,
    required String listState,
    required DateTime clientUpdatedAt,
    DateTime? serverUpdatedAt,
    bool deleted = false,
  }) => database.transaction(() async {
    await database
        .into(database.libraryItems)
        .insertOnConflictUpdate(
          LibraryItemsCompanion.insert(
            accountId: accountId,
            paperId: paperId,
            listState: Value(listState),
            clientUpdatedAt: clientUpdatedAt.toUtc(),
            serverUpdatedAt: Value(serverUpdatedAt?.toUtc()),
            deleted: Value(deleted),
          ),
        );
    await _refreshPaperPin(paperId);
  });

  Future<void> deleteLibraryItem(String accountId, String paperId) =>
      database.transaction(() async {
        await (database.delete(database.libraryItems)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(paperId),
            ))
            .go();
        await _refreshPaperPin(paperId);
      });

  Future<void> saveCommentDraft({
    required String draftId,
    required String paperId,
    required String body,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? accountId,
  }) => database
      .into(database.commentDrafts)
      .insertOnConflictUpdate(
        CommentDraftsCompanion.insert(
          draftId: draftId,
          accountId: Value(accountId),
          paperId: paperId,
          body: body,
          createdAt: createdAt.toUtc(),
          updatedAt: updatedAt.toUtc(),
        ),
      );

  Future<void> enqueue({
    required String operationId,
    required String entityKind,
    required String entityId,
    required String operation,
    required Object? payload,
    required DateTime createdAt,
    String? accountId,
  }) => database
      .into(database.syncOutbox)
      .insertOnConflictUpdate(
        SyncOutboxCompanion.insert(
          operationId: operationId,
          accountId: Value(accountId),
          entityKind: entityKind,
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: createdAt.toUtc(),
          updatedAt: Value(createdAt.toUtc()),
        ),
      );

  Future<void> clearAccountData(String accountId) =>
      database.transaction(() async {
        final affectedPapers =
            await (database.selectOnly(database.libraryItems)
                  ..addColumns([database.libraryItems.paperId])
                  ..where(database.libraryItems.accountId.equals(accountId)))
                .get();
        await (database.delete(
          database.libraryItems,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.libraryListMemberships,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.libraryTagMemberships,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.libraryCustomLists,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.libraryTags,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(database.commentDrafts)..where(
              (table) =>
                  table.accountId.equals(accountId) | table.accountId.isNull(),
            ))
            .go();
        await (database.delete(
          database.cachedCommentPages,
        )..where((table) => table.viewerAccountId.equals(accountId))).go();
        await (database.delete(
          database.blockedUsers,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(database.syncOutbox)..where(
              (table) =>
                  table.accountId.equals(accountId) | table.accountId.isNull(),
            ))
            .go();
        await (database.delete(
          database.librarySyncStates,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.cachedDocumentArtifacts,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.readingCheckpoints,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.localAnnotations,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.annotationConflicts,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.localEvidenceCards,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.localMemoryItems,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.researchOutbox,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.researchSyncStates,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.cachedVersionArtifacts,
        )..where((table) => table.accountId.equals(accountId))).go();
        for (final row in affectedPapers) {
          final paperId = row.read(database.libraryItems.paperId);
          if (paperId != null) await _refreshPaperPin(paperId);
        }
      });

  /// Fail-closed cleanup for a signed-out credential record that did not yet
  /// have a Pakperk account UUID bound to it. This still preserves all public
  /// feed, paper, derived-cache, and restoration data.
  Future<void> clearAllAccountData() => database.transaction(() async {
    final affectedPapers = await (database.selectOnly(
      database.libraryItems,
    )..addColumns([database.libraryItems.paperId])).get();
    await database.delete(database.libraryItems).go();
    await database.delete(database.libraryListMemberships).go();
    await database.delete(database.libraryTagMemberships).go();
    await database.delete(database.libraryCustomLists).go();
    await database.delete(database.libraryTags).go();
    await database.delete(database.commentDrafts).go();
    await (database.delete(
      database.cachedCommentPages,
    )..where((table) => table.viewerAccountId.isNotNull())).go();
    await database.delete(database.blockedUsers).go();
    await database.delete(database.syncOutbox).go();
    await database.delete(database.librarySyncStates).go();
    await database.delete(database.cachedDocumentArtifacts).go();
    await database.delete(database.readingCheckpoints).go();
    await database.delete(database.localAnnotations).go();
    await database.delete(database.annotationConflicts).go();
    await database.delete(database.localEvidenceCards).go();
    await database.delete(database.localMemoryItems).go();
    await database.delete(database.researchOutbox).go();
    await database.delete(database.researchSyncStates).go();
    await database.delete(database.cachedVersionArtifacts).go();
    for (final row in affectedPapers) {
      final paperId = row.read(database.libraryItems.paperId);
      if (paperId != null) await _refreshPaperPin(paperId);
    }
  });

  /// Stronger deletion-only purge for public comment snapshots.
  ///
  /// Guest-scoped pages can contain the deleting account's formerly public
  /// body and handle, so they cannot survive hard deletion. Ordinary sign-out
  /// intentionally does not call this method. Paper/feed caches are separate
  /// tables and remain available for anonymous reading.
  Future<void> purgeCommentPagesForAccountDeletion() =>
      database.delete(database.cachedCommentPages).go();

  Future<void> _refreshPaperPin(String paperId) async {
    final active =
        await (database.selectOnly(database.libraryItems)
              ..addColumns([database.libraryItems.paperId.count()])
              ..where(
                database.libraryItems.paperId.equals(paperId) &
                    database.libraryItems.deleted.equals(false),
              ))
            .map((row) => row.read(database.libraryItems.paperId.count()) ?? 0)
            .getSingle();
    await (database.update(database.cachedPapers)
          ..where((table) => table.paperId.equals(paperId)))
        .write(CachedPapersCompanion(pinnedByLibrary: Value(active > 0)));
  }
}
