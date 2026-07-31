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
    String? parentCommentId,
  }) => database
      .into(database.commentDrafts)
      .insertOnConflictUpdate(
        CommentDraftsCompanion.insert(
          draftId: draftId,
          accountId: Value(accountId),
          paperId: paperId,
          parentCommentId: Value(parentCommentId),
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
          database.commentDrafts,
        )..where((table) => table.accountId.equals(accountId))).go();
        await (database.delete(
          database.syncOutbox,
        )..where((table) => table.accountId.equals(accountId))).go();
        for (final row in affectedPapers) {
          final paperId = row.read(database.libraryItems.paperId);
          if (paperId != null) await _refreshPaperPin(paperId);
        }
      });

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
