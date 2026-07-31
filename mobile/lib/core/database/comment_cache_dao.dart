import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';

class CachedCommentPageValue {
  const CachedCommentPageValue({
    required this.pageKey,
    required this.paperId,
    required this.payload,
    required this.fetchedAt,
    required this.expiresAt,
    this.viewerAccountId,
    this.cursor,
    this.etag,
  });

  final String pageKey;
  final String paperId;
  final Object? payload;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  final String? viewerAccountId;
  final String? cursor;
  final String? etag;
}

class CommentCacheDao {
  CommentCacheDao(this.database);

  final PakPerkDatabase database;

  Future<CachedCommentPageValue?> load(
    String pageKey, {
    DateTime? now,
    bool allowExpired = false,
  }) async {
    final row = await (database.select(
      database.cachedCommentPages,
    )..where((table) => table.pageKey.equals(pageKey))).getSingleOrNull();
    if (row == null ||
        (!allowExpired &&
            !row.expiresAt.isAfter((now ?? DateTime.now()).toUtc()))) {
      return null;
    }
    try {
      return CachedCommentPageValue(
        pageKey: row.pageKey,
        paperId: row.paperId,
        payload: jsonDecode(row.payloadJson),
        fetchedAt: row.fetchedAt,
        expiresAt: row.expiresAt,
        viewerAccountId: row.viewerAccountId,
        cursor: row.cursor,
        etag: row.etag,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save(CachedCommentPageValue value) {
    if (!_uuid.hasMatch(value.paperId) ||
        (value.viewerAccountId != null &&
            !_uuid.hasMatch(value.viewerAccountId!)) ||
        value.pageKey.isEmpty ||
        value.pageKey.length > 2048 ||
        (value.cursor != null &&
            (value.cursor!.isEmpty || value.cursor!.length > 512))) {
      throw ArgumentError('Invalid comment cache identity.');
    }
    final payloadJson = jsonEncode(value.payload);
    final payloadBytes = utf8.encode(payloadJson).length;
    if (payloadBytes > 600000) {
      throw ArgumentError.value(payloadBytes, 'payload', 'Too large.');
    }
    return database
        .into(database.cachedCommentPages)
        .insertOnConflictUpdate(
          CachedCommentPagesCompanion.insert(
            pageKey: value.pageKey,
            paperId: value.paperId,
            viewerAccountId: Value(value.viewerAccountId),
            cursor: Value(value.cursor),
            payloadJson: payloadJson,
            fetchedAt: value.fetchedAt.toUtc(),
            expiresAt: value.expiresAt.toUtc(),
            etag: Value(value.etag),
          ),
        );
  }

  Future<void> saveBounded(
    CachedCommentPageValue value, {
    int maximumPages = 3,
  }) async {
    if (maximumPages < 1 || maximumPages > 10) {
      throw ArgumentError.value(maximumPages, 'maximumPages');
    }
    await database.transaction(() async {
      await save(value);
      final rows =
          await (database.select(database.cachedCommentPages)
                ..where(
                  (table) =>
                      table.paperId.equals(value.paperId) &
                      (value.viewerAccountId == null
                          ? table.viewerAccountId.isNull()
                          : table.viewerAccountId.equals(
                              value.viewerAccountId!,
                            )),
                )
                ..orderBy([
                  (table) => OrderingTerm.desc(table.fetchedAt),
                  (table) => OrderingTerm.desc(table.pageKey),
                ]))
              .get();
      for (final stale in rows.skip(maximumPages)) {
        await (database.delete(
          database.cachedCommentPages,
        )..where((table) => table.pageKey.equals(stale.pageKey))).go();
      }
    });
  }

  Future<void> deleteViewer(String accountId) {
    if (!_uuid.hasMatch(accountId)) {
      throw ArgumentError.value(accountId, 'accountId', 'Must be a UUID.');
    }
    return (database.delete(
      database.cachedCommentPages,
    )..where((table) => table.viewerAccountId.equals(accountId))).go();
  }
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
