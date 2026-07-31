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
    this.cursor,
    this.etag,
  });

  final String pageKey;
  final String paperId;
  final Object? payload;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  final String? cursor;
  final String? etag;
}

class CommentCacheDao {
  CommentCacheDao(this.database);

  final PakPerkDatabase database;

  Future<CachedCommentPageValue?> load(String pageKey, {DateTime? now}) async {
    final row = await (database.select(
      database.cachedCommentPages,
    )..where((table) => table.pageKey.equals(pageKey))).getSingleOrNull();
    if (row == null ||
        !row.expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      return null;
    }
    try {
      return CachedCommentPageValue(
        pageKey: row.pageKey,
        paperId: row.paperId,
        payload: jsonDecode(row.payloadJson),
        fetchedAt: row.fetchedAt,
        expiresAt: row.expiresAt,
        cursor: row.cursor,
        etag: row.etag,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> save(CachedCommentPageValue value) => database
      .into(database.cachedCommentPages)
      .insertOnConflictUpdate(
        CachedCommentPagesCompanion.insert(
          pageKey: value.pageKey,
          paperId: value.paperId,
          cursor: Value(value.cursor),
          payloadJson: jsonEncode(value.payload),
          fetchedAt: value.fetchedAt.toUtc(),
          expiresAt: value.expiresAt.toUtc(),
          etag: Value(value.etag),
        ),
      );
}
