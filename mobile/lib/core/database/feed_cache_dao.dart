import 'dart:convert';

import 'package:drift/drift.dart';

import '../cache/feed_cache_persistence.dart';
import '../models/paper.dart';
import 'app_database.dart';
import 'paper_cache_dao.dart';

class FeedCacheDao {
  FeedCacheDao(this.database, this.papers);

  final PakPerkDatabase database;
  final PaperCacheDao papers;

  Future<FeedPage?> loadPage(String queryKey) => database.transaction(() async {
    final query = await (database.select(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).getSingleOrNull();
    if (query == null) return null;

    final joined =
        database.select(database.feedEntries).join([
            innerJoin(
              database.cachedPapers,
              database.cachedPapers.paperId.equalsExp(
                database.feedEntries.paperId,
              ),
            ),
          ])
          ..where(database.feedEntries.queryKey.equals(queryKey))
          ..orderBy([OrderingTerm.asc(database.feedEntries.position)]);
    final rows = await joined.get();
    final entries = rows
        .map((row) => row.readTable(database.feedEntries))
        .toList(growable: false);
    final items = rows
        .map((row) => papers.decode(row.readTable(database.cachedPapers)))
        .whereType<PaperSummary>()
        .toList(growable: false);
    if (!_isCompleteSnapshot(
      expectedCount: query.entryCount,
      entries: entries,
      decodedPaperCount: items.length,
    )) {
      // A partial relation cannot represent the entity that produced the
      // validator. Returning null also closes the race where membership is
      // evicted after a conditional request starts but before its 304 lands.
      await _invalidateValidator(queryKey);
      return null;
    }
    return FeedPage(items: items, nextCursor: query.nextCursor);
  });

  Future<void> persistPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  }) => database.transaction(() async {
    final now = (refreshedAt ?? DateTime.now()).toUtc();
    await papers.ensureAll(page.items, accessedAt: now);
    final exactMetadata = await _metadataMatches(page.items);

    final previousQuery = await (database.select(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).getSingleOrNull();
    final candidateEtag = replace ? etag : etag ?? previousQuery?.etag;
    final persistedEtag = exactMetadata ? candidateEtag : null;

    await database
        .into(database.feedQueries)
        .insertOnConflictUpdate(
          FeedQueriesCompanion.insert(
            queryKey: queryKey,
            category: Value(_normalizedCategory(category)),
            nextCursor: Value(page.nextCursor),
            refreshedAt: now,
            exhausted: Value(page.nextCursor == null),
            etag: Value(persistedEtag),
            entryCount: Value(previousQuery?.entryCount ?? 0),
          ),
        );

    if (replace) {
      await (database.delete(
        database.feedEntries,
      )..where((table) => table.queryKey.equals(queryKey))).go();
    }

    final existingRows = await (database.select(
      database.feedEntries,
    )..where((table) => table.queryKey.equals(queryKey))).get();
    final existingIds = existingRows.map((row) => row.paperId).toSet();
    var position = replace
        ? 0
        : existingRows.fold<int>(
                -1,
                (largest, row) =>
                    row.position > largest ? row.position : largest,
              ) +
              1;
    for (final paper in page.items) {
      if (!existingIds.add(paper.paperId)) continue;
      await database
          .into(database.feedEntries)
          .insert(
            FeedEntriesCompanion.insert(
              queryKey: queryKey,
              position: position,
              paperId: paper.paperId,
              insertedAt: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      position += 1;
    }

    final countExpression = database.feedEntries.paperId.count();
    final countRow =
        await (database.selectOnly(database.feedEntries)
              ..addColumns([countExpression])
              ..where(database.feedEntries.queryKey.equals(queryKey)))
            .getSingle();
    await (database.update(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).write(
      FeedQueriesCompanion(
        entryCount: Value(countRow.read(countExpression) ?? 0),
      ),
    );
  });

  Future<FeedCacheValidator?> loadValidator(String queryKey) =>
      database.transaction(() async {
        final row = await (database.select(
          database.feedQueries,
        )..where((table) => table.queryKey.equals(queryKey))).getSingleOrNull();
        if (row == null) return null;
        if (!await _queryIsComplete(queryKey, row.entryCount)) {
          await _invalidateValidator(queryKey);
          return FeedCacheValidator(etag: null, refreshedAt: _invalidatedAt);
        }
        return FeedCacheValidator(etag: row.etag, refreshedAt: row.refreshedAt);
      });

  Future<void> storeValidator(
    String queryKey, {
    required String? etag,
    required DateTime refreshedAt,
  }) => database.transaction(() async {
    final row = await (database.select(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).getSingleOrNull();
    // A validator is meaningful only alongside the exact representation that
    // produced it. Never manufacture an ETag-only query row.
    if (row == null) return;
    // An eviction or metadata replacement can invalidate the validator
    // while its conditional request is in flight. A late 304 must not
    // resurrect that validator for the now-different local relation.
    if (row.etag == null) {
      await _invalidateValidator(queryKey);
      return;
    }
    if (!await _queryIsComplete(queryKey, row.entryCount)) {
      await _invalidateValidator(queryKey);
      return;
    }
    await (database.update(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).write(
      FeedQueriesCompanion(
        etag: Value(etag),
        refreshedAt: Value(refreshedAt.toUtc()),
      ),
    );
  });

  Future<void> touchRefreshedAt(String queryKey, DateTime refreshedAt) async {
    final updated =
        await (database.update(
          database.feedQueries,
        )..where((table) => table.queryKey.equals(queryKey))).write(
          FeedQueriesCompanion(refreshedAt: Value(refreshedAt.toUtc())),
        );
    if (updated == 0) {
      await database
          .into(database.feedQueries)
          .insert(
            FeedQueriesCompanion.insert(
              queryKey: queryKey,
              refreshedAt: refreshedAt.toUtc(),
            ),
          );
    }
  }

  Future<bool> _queryIsComplete(String queryKey, int expectedCount) async {
    final entries =
        await (database.select(database.feedEntries)
              ..where((table) => table.queryKey.equals(queryKey))
              ..orderBy([(table) => OrderingTerm.asc(table.position)]))
            .get();
    if (!_isCompleteSnapshot(
      expectedCount: expectedCount,
      entries: entries,
      decodedPaperCount: entries.length,
    )) {
      return false;
    }
    return (await papers.existingIds(
          entries.map((entry) => entry.paperId),
        )).length ==
        entries.length;
  }

  Future<bool> _metadataMatches(Iterable<PaperSummary> incoming) async {
    for (final paper in incoming) {
      final stored = await papers.load(paper.paperId, touch: false);
      if (stored == null ||
          jsonEncode(stored.toJson()) != jsonEncode(paper.toJson())) {
        return false;
      }
    }
    return true;
  }

  Future<void> _invalidateValidator(String queryKey) async {
    await (database.update(
      database.feedQueries,
    )..where((table) => table.queryKey.equals(queryKey))).write(
      FeedQueriesCompanion(
        etag: const Value(null),
        refreshedAt: Value(_invalidatedAt),
      ),
    );
  }
}

final DateTime _invalidatedAt = DateTime.fromMillisecondsSinceEpoch(
  0,
  isUtc: true,
);

bool _isCompleteSnapshot({
  required int expectedCount,
  required List<FeedEntryRow> entries,
  required int decodedPaperCount,
}) {
  if (expectedCount != entries.length || decodedPaperCount != entries.length) {
    return false;
  }
  for (var index = 0; index < entries.length; index += 1) {
    if (entries[index].position != index) return false;
  }
  return true;
}

String? _normalizedCategory(String? category) {
  final value = category?.trim();
  if (value == null || value.isEmpty) return null;
  return value.length > 128 ? value.substring(0, 128) : value;
}
