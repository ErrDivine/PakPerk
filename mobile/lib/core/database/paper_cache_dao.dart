import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/paper.dart';
import 'app_database.dart';

class PaperCacheDao {
  PaperCacheDao(this.database);

  static const metadataTtl = Duration(days: 7);

  final PakPerkDatabase database;

  Future<PaperSummary?> load(String paperId, {bool touch = true}) async {
    final row = await (database.select(
      database.cachedPapers,
    )..where((table) => table.paperId.equals(paperId))).getSingleOrNull();
    if (row == null) return null;
    final paper = decode(row);
    if (paper != null && touch) {
      await recordAccess(paperId);
    }
    return paper;
  }

  Future<PaperSummary?> findByArxiv(String arxivBaseId) async {
    final rows =
        await (database.select(database.cachedPapers)
              ..where(
                (table) => table.arxivBaseId.lower().equals(
                  arxivBaseId.trim().toLowerCase(),
                ),
              )
              ..orderBy([
                (table) => OrderingTerm.desc(table.arxivVersion),
                (table) => OrderingTerm.desc(table.updatedAt),
              ]))
            .get();
    for (final row in rows) {
      final paper = decode(row);
      if (paper != null) {
        await recordAccess(paper.paperId);
        return paper;
      }
    }
    return null;
  }

  Future<void> save(
    PaperSummary paper, {
    DateTime? accessedAt,
    DateTime? expiresAt,
  }) => database.transaction(() async {
    final now = (accessedAt ?? DateTime.now()).toUtc();
    final existing = await (database.select(
      database.cachedPapers,
    )..where((table) => table.paperId.equals(paper.paperId))).getSingleOrNull();
    final existingPaper = existing == null ? null : decode(existing);
    final encodedMetadata = jsonEncode(paper.toJson());
    final incomingVersion = _arxivVersion(paper.arxivId);
    final existingVersion = existingPaper == null
        ? null
        : _arxivVersion(existingPaper.arxivId);
    if (existing != null && existingPaper != null) {
      final sameBase =
          existingPaper.arxivBaseId.toLowerCase() ==
          paper.arxivBaseId.toLowerCase();
      final olderVersion =
          sameBase && (incomingVersion ?? 0) < (existingVersion ?? 0);
      final olderWithinVersion =
          sameBase &&
          (incomingVersion ?? 0) == (existingVersion ?? 0) &&
          paper.updatedAt.toUtc().isBefore(existingPaper.updatedAt.toUtc());
      // A stable paper id must never be silently rebound to another arXiv
      // work. Within one work, freshness is a total order: version first,
      // then the source updated timestamp.
      if (!sameBase || olderVersion || olderWithinVersion) {
        await _refreshExisting(existing, now: now, expiresAt: expiresAt);
        return;
      }
    }
    if (existing != null && existing.metadataJson != encodedMetadata) {
      await _invalidateContainingFeedQueries(paper.paperId);
    }
    if (existingPaper != null && existingPaper.arxivId != paper.arxivId) {
      await (database.delete(
        database.cachedProcessing,
      )..where((table) => table.paperId.equals(paper.paperId))).go();
      await (database.delete(
        database.cachedIntroductions,
      )..where((table) => table.paperId.equals(paper.paperId))).go();
      await (database.delete(
        database.cachedConnections,
      )..where((table) => table.paperId.equals(paper.paperId))).go();
      await (database.delete(database.cachedChats)..where(
            (table) => table.readerKey.like('%:${existingPaper.arxivId}'),
          ))
          .go();
    }
    await database
        .into(database.cachedPapers)
        .insertOnConflictUpdate(
          CachedPapersCompanion.insert(
            paperId: paper.paperId,
            arxivBaseId: paper.arxivBaseId.toLowerCase(),
            arxivVersion: Value(incomingVersion),
            metadataJson: encodedMetadata,
            publishedAt: paper.publishedAt.toUtc(),
            updatedAt: paper.updatedAt.toUtc(),
            lastAccessedAt:
                existing != null && existing.lastAccessedAt.isAfter(now)
                ? existing.lastAccessedAt
                : now,
            expiresAt: (expiresAt ?? now.add(metadataTtl)).toUtc(),
            pinnedByLibrary: Value(existing?.pinnedByLibrary ?? false),
          ),
        );
  });

  Future<void> _refreshExisting(
    CachedPaperRow existing, {
    required DateTime now,
    DateTime? expiresAt,
  }) async {
    final nextExpiry = (expiresAt ?? now.add(metadataTtl)).toUtc();
    await (database.update(
      database.cachedPapers,
    )..where((table) => table.paperId.equals(existing.paperId))).write(
      CachedPapersCompanion(
        lastAccessedAt: Value(
          existing.lastAccessedAt.isAfter(now) ? existing.lastAccessedAt : now,
        ),
        expiresAt: Value(
          existing.expiresAt.isAfter(nextExpiry)
              ? existing.expiresAt
              : nextExpiry,
        ),
      ),
    );
  }

  Future<void> _invalidateContainingFeedQueries(String paperId) async {
    final rows =
        await (database.selectOnly(database.feedEntries)
              ..addColumns([database.feedEntries.queryKey])
              ..where(database.feedEntries.paperId.equals(paperId)))
            .get();
    final queryKeys = rows
        .map((row) => row.read(database.feedEntries.queryKey))
        .whereType<String>()
        .toSet();
    if (queryKeys.isEmpty) return;
    await (database.update(
      database.feedQueries,
    )..where((query) => query.queryKey.isIn(queryKeys))).write(
      FeedQueriesCompanion(
        etag: const Value(null),
        refreshedAt: Value(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
      ),
    );
  }

  Future<void> ensureAll(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) => database.transaction(() async {
    for (final paper in papers) {
      await save(paper, accessedAt: accessedAt);
    }
  });

  Future<void> recordAccess(String paperId, {DateTime? accessedAt}) async {
    await (database.update(
      database.cachedPapers,
    )..where((table) => table.paperId.equals(paperId))).write(
      CachedPapersCompanion(
        lastAccessedAt: Value((accessedAt ?? DateTime.now()).toUtc()),
      ),
    );
  }

  Future<Set<String>> existingIds(Iterable<String> ids) async {
    final unique = ids.where((id) => id.trim().isNotEmpty).toSet();
    if (unique.isEmpty) return const {};
    final rows = await (database.select(
      database.cachedPapers,
    )..where((table) => table.paperId.isIn(unique))).get();
    return rows
        .where((row) => decode(row) != null)
        .map((row) => row.paperId)
        .toSet();
  }

  Future<String?> versionKey(String paperId) async {
    final row =
        await (database.selectOnly(database.cachedPapers)
              ..addColumns([database.cachedPapers.metadataJson])
              ..where(database.cachedPapers.paperId.equals(paperId)))
            .getSingleOrNull();
    final raw = row?.read(database.cachedPapers.metadataJson);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PaperSummary.fromJson(Map<String, dynamic>.from(decoded)).arxivId;
    } on Object {
      return null;
    }
  }

  Future<PaperVersionKey?> versionKeyForArxivId(String arxivId) async {
    final version = _arxivVersion(arxivId);
    final baseId = arxivId.replaceFirst(
      RegExp(r'v\d+$', caseSensitive: false),
      '',
    );
    final query = database.select(database.cachedPapers)
      ..where(
        (table) =>
            table.arxivBaseId.lower().equals(baseId.toLowerCase()) &
            (version == null
                ? table.arxivVersion.isNull()
                : table.arxivVersion.equals(version)),
      );
    final rows = await query.get();
    for (final row in rows) {
      final paper = decode(row);
      if (paper != null &&
          paper.arxivId.toLowerCase() == arxivId.toLowerCase()) {
        return paper.versionKey;
      }
    }
    return null;
  }

  PaperSummary? decode(CachedPaperRow row) {
    try {
      final value = jsonDecode(row.metadataJson);
      if (value is! Map) return null;
      final paper = PaperSummary.fromJson(Map<String, dynamic>.from(value));
      return paper.paperId == row.paperId ? paper : null;
    } on Object {
      return null;
    }
  }
}

int? _arxivVersion(String arxivId) {
  final match = RegExp(r'v(\d+)$', caseSensitive: false).firstMatch(arxivId);
  return int.tryParse(match?.group(1) ?? '');
}
