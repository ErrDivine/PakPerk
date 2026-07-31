import 'package:drift/drift.dart';

import '../cache/feed_cache_persistence.dart';
import 'app_database.dart';

class CacheMaintenanceDao {
  CacheMaintenanceDao(
    this.database, {
    Future<int> Function()? databaseByteMeasurer,
    Future<int> Function()? physicalDatabaseByteMeasurer,
  }) : _databaseByteMeasurer =
           databaseByteMeasurer ?? database.liveDatabaseBytes,
       _physicalDatabaseByteMeasurer =
           physicalDatabaseByteMeasurer ?? database.physicalDatabaseBytes;

  final PakPerkDatabase database;
  final Future<int> Function() _databaseByteMeasurer;
  final Future<int> Function() _physicalDatabaseByteMeasurer;

  Future<FeedCacheUsage> measure() async {
    final countExpression = database.cachedPapers.paperId.count();
    final row = await (database.selectOnly(
      database.cachedPapers,
    )..addColumns([countExpression])).getSingle();
    return FeedCacheUsage(
      metadataRows: row.read(countExpression) ?? 0,
      databaseBytes: await _databaseByteMeasurer(),
      physicalDatabaseBytes: await _physicalDatabaseByteMeasurer(),
    );
  }

  Future<CacheEvictionResult> evict({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    required int maxMetadataPapers,
    required int maxDatabaseBytes,
    required Duration metadataTtl,
    required DateTime now,
    Set<String> protectedChatReaderKeys = const {},
  }) => database.transaction(() async {
    final utcNow = now.toUtc();
    final expiredCommentPages = await (database.delete(
      database.cachedCommentPages,
    )..where((table) => table.expiresAt.isSmallerOrEqualValue(utcNow))).go();

    final staleMembershipCutoff = utcNow.subtract(metadataTtl);
    final staleMembershipQueries =
        await (database.selectOnly(database.feedEntries)
              ..addColumns([database.feedEntries.queryKey])
              ..where(
                database.feedEntries.queryKey.equals(activeQueryKey).not() &
                    database.feedEntries.insertedAt.isSmallerOrEqualValue(
                      staleMembershipCutoff,
                    ),
              ))
            .get();
    final oldFeedEntries =
        await (database.delete(database.feedEntries)..where(
              (table) =>
                  table.queryKey.equals(activeQueryKey).not() &
                  table.insertedAt.isSmallerOrEqualValue(staleMembershipCutoff),
            ))
            .go();
    final staleQueryKeys = staleMembershipQueries
        .map((row) => row.read(database.feedEntries.queryKey))
        .whereType<String>()
        .toSet();
    if (staleQueryKeys.isNotEmpty) {
      await _repairFeedQueries(staleQueryKeys);
    }
    final hasNoEntries = notExistsQuery(
      database.select(database.feedEntries)..where(
        (entry) => entry.queryKey.equalsExp(database.feedQueries.queryKey),
      ),
    );
    await (database.delete(database.feedQueries)..where(
          (query) =>
              query.queryKey.equals(activeQueryKey).not() &
              query.refreshedAt.isSmallerOrEqualValue(staleMembershipCutoff) &
              hasNoEntries,
        ))
        .go();

    final internallyProtected = await _internallyProtectedPaperIds();
    final protected = {...protectedPaperIds, ...internallyProtected};
    final protectedChatPaperIds = await _paperIdsForProtectedChats(
      protectedChatReaderKeys,
    );
    // A protected chat also needs its backing paper row to survive the
    // metadata pass. It does not make unrelated derived artifacts for that
    // paper durable: [protectedChatReaderKeys] remains a per-chat guard.
    final metadataProtected = {...protected, ...protectedChatPaperIds};
    final candidates =
        await (database.select(database.cachedPapers)
              ..where((table) => table.pinnedByLibrary.equals(false))
              ..orderBy([(table) => OrderingTerm.asc(table.lastAccessedAt)]))
            .get();

    var usage = await measure();
    var removedPapers = 0;
    final metadataAffectedQueries = <String>{};
    for (final candidate in candidates) {
      if (metadataProtected.contains(candidate.paperId)) continue;
      final expired =
          candidate.expiresAt.isBefore(utcNow) ||
          candidate.expiresAt.isAtSameMomentAs(utcNow) ||
          candidate.lastAccessedAt.add(metadataTtl).isBefore(utcNow);
      final aboveBounds =
          usage.metadataRows > maxMetadataPapers ||
          usage.databaseBytes > maxDatabaseBytes;
      if (!expired && !aboveBounds) continue;
      final affectedQueries =
          await (database.selectOnly(database.feedEntries)
                ..addColumns([database.feedEntries.queryKey])
                ..where(database.feedEntries.paperId.equals(candidate.paperId)))
              .get();
      removedPapers += await (database.delete(
        database.cachedPapers,
      )..where((table) => table.paperId.equals(candidate.paperId))).go();
      final queryKeys = affectedQueries
          .map((row) => row.read(database.feedEntries.queryKey))
          .whereType<String>()
          .toSet();
      metadataAffectedQueries.addAll(queryKeys);
      usage = await measure();
    }
    if (metadataAffectedQueries.isNotEmpty) {
      await _repairFeedQueries(metadataAffectedQueries);
    }

    // Derived artifacts expire after comment pages, stale feed membership,
    // and paper metadata eviction, matching the documented eviction order.
    var derivedRows = await _deleteExpiredDerived(
      utcNow,
      protectedPaperIds: protected,
      protectedChatReaderKeys: protectedChatReaderKeys,
      protectedChatPaperIds: protectedChatPaperIds,
    );
    usage = await measure();
    if (usage.databaseBytes > maxDatabaseBytes) {
      final pressure = await _deleteOldestUnprotectedDerived(
        usage: usage,
        maxDatabaseBytes: maxDatabaseBytes,
        protectedPaperIds: protected,
        protectedChatReaderKeys: protectedChatReaderKeys,
        protectedChatPaperIds: protectedChatPaperIds,
      );
      derivedRows += pressure.removed;
      usage = pressure.usage;
    }

    return CacheEvictionResult(
      expiredCommentPages: expiredCommentPages,
      oldFeedEntries: oldFeedEntries,
      unpinnedPapers: removedPapers,
      derivedRows: derivedRows,
      usageAfter: usage,
    );
  });

  Future<CacheCompactionResult> compactIfNeeded({
    required bool lifecycleSafe,
    required int maxDatabaseBytes,
  }) async {
    final before = await measure();
    if (!lifecycleSafe || before.physicalDatabaseBytes <= maxDatabaseBytes) {
      return CacheCompactionResult(
        ran: false,
        boundSatisfied: before.physicalDatabaseBytes <= maxDatabaseBytes,
        before: before,
        after: before,
      );
    }

    await database.checkpointAndCompact();
    final after = await measure();
    return CacheCompactionResult(
      ran: true,
      boundSatisfied: after.physicalDatabaseBytes <= maxDatabaseBytes,
      before: before,
      after: after,
    );
  }

  Future<int> _deleteExpiredDerived(
    DateTime now, {
    required Set<String> protectedPaperIds,
    required Set<String> protectedChatReaderKeys,
    required Set<String> protectedChatPaperIds,
  }) async {
    var removed = 0;
    final processingRows =
        await (database.select(database.cachedProcessing)..where(
              (table) =>
                  table.expiresAt.isNotNull() &
                  table.expiresAt.isSmallerOrEqualValue(now),
            ))
            .get();
    for (final row in processingRows) {
      if (protectedPaperIds.contains(row.paperId) ||
          protectedChatPaperIds.contains(row.paperId)) {
        continue;
      }
      // Processing is the root of a generation. Once it expires, every child
      // row in that paper generation is unreadable and should leave with it.
      removed += await _deletePaperDerived(row.paperId);
    }

    final introductionRows =
        await (database.select(database.cachedIntroductions)..where(
              (table) =>
                  table.expiresAt.isNotNull() &
                  table.expiresAt.isSmallerOrEqualValue(now),
            ))
            .get();
    for (final row in introductionRows) {
      if (protectedPaperIds.contains(row.paperId)) continue;
      removed += await (database.delete(
        database.cachedIntroductions,
      )..where((table) => table.paperId.equals(row.paperId))).go();
    }

    final connectionRows =
        await (database.select(database.cachedConnections)..where(
              (table) =>
                  table.expiresAt.isNotNull() &
                  table.expiresAt.isSmallerOrEqualValue(now),
            ))
            .get();
    for (final row in connectionRows) {
      if (protectedPaperIds.contains(row.paperId)) continue;
      removed += await (database.delete(
        database.cachedConnections,
      )..where((table) => table.paperId.equals(row.paperId))).go();
    }

    final chatRows = await (database.select(
      database.cachedChats,
    )..where((table) => table.expiresAt.isSmallerOrEqualValue(now))).get();
    for (final row in chatRows) {
      if ((row.paperId != null && protectedPaperIds.contains(row.paperId)) ||
          protectedChatReaderKeys.contains(row.readerKey)) {
        continue;
      }
      removed += await _deleteChat(row);
    }
    return removed;
  }

  Future<({int removed, FeedCacheUsage usage})>
  _deleteOldestUnprotectedDerived({
    required FeedCacheUsage usage,
    required int maxDatabaseBytes,
    required Set<String> protectedPaperIds,
    required Set<String> protectedChatReaderKeys,
    required Set<String> protectedChatPaperIds,
  }) async {
    final candidates = <_DerivedEvictionCandidate>[];
    final paperClusterUpdatedAt = <String, DateTime>{};

    void includeInPaperCluster(String paperId, DateTime updatedAt) {
      final previous = paperClusterUpdatedAt[paperId];
      // A generation is as recent as its newest member. This avoids evicting a
      // newly-written child merely because its processing row is older.
      if (previous == null || updatedAt.isAfter(previous)) {
        paperClusterUpdatedAt[paperId] = updatedAt;
      }
    }

    final processingRows = await database
        .select(database.cachedProcessing)
        .get();
    for (final row in processingRows) {
      if (protectedPaperIds.contains(row.paperId) ||
          protectedChatPaperIds.contains(row.paperId)) {
        continue;
      }
      includeInPaperCluster(row.paperId, row.updatedAt);
    }

    final introductionRows = await database
        .select(database.cachedIntroductions)
        .get();
    for (final row in introductionRows) {
      if (protectedPaperIds.contains(row.paperId)) continue;
      if (protectedChatPaperIds.contains(row.paperId)) {
        candidates.add(
          _DerivedEvictionCandidate.introduction(
            paperId: row.paperId,
            updatedAt: row.updatedAt,
          ),
        );
      } else {
        includeInPaperCluster(row.paperId, row.updatedAt);
      }
    }

    final connectionRows = await database
        .select(database.cachedConnections)
        .get();
    for (final row in connectionRows) {
      if (protectedPaperIds.contains(row.paperId)) continue;
      if (protectedChatPaperIds.contains(row.paperId)) {
        candidates.add(
          _DerivedEvictionCandidate.connection(
            paperId: row.paperId,
            updatedAt: row.updatedAt,
          ),
        );
      } else {
        includeInPaperCluster(row.paperId, row.updatedAt);
      }
    }

    final chatRows = await database.select(database.cachedChats).get();
    for (final row in chatRows) {
      if ((row.paperId != null && protectedPaperIds.contains(row.paperId)) ||
          protectedChatReaderKeys.contains(row.readerKey)) {
        continue;
      }
      final paperId = row.paperId;
      if (paperId != null && !protectedChatPaperIds.contains(paperId)) {
        includeInPaperCluster(paperId, row.updatedAt);
      } else {
        candidates.add(_DerivedEvictionCandidate.chat(row));
      }
    }

    candidates.addAll(
      paperClusterUpdatedAt.entries.map(
        (entry) => _DerivedEvictionCandidate.paperCluster(
          paperId: entry.key,
          updatedAt: entry.value,
        ),
      ),
    );
    candidates.sort((left, right) {
      final freshness = left.updatedAt.compareTo(right.updatedAt);
      return freshness != 0 ? freshness : left.sortKey.compareTo(right.sortKey);
    });

    var removed = 0;
    var currentUsage = usage;
    for (final candidate in candidates) {
      if (currentUsage.databaseBytes <= maxDatabaseBytes) break;
      removed += switch (candidate.kind) {
        _DerivedEvictionKind.paperCluster => await _deletePaperDerived(
          candidate.paperId!,
        ),
        _DerivedEvictionKind.introduction => await (database.delete(
          database.cachedIntroductions,
        )..where((table) => table.paperId.equals(candidate.paperId!))).go(),
        _DerivedEvictionKind.connection => await (database.delete(
          database.cachedConnections,
        )..where((table) => table.paperId.equals(candidate.paperId!))).go(),
        _DerivedEvictionKind.chat => await _deleteChat(candidate.chat!),
      };
      currentUsage = await measure();
    }
    return (removed: removed, usage: currentUsage);
  }

  Future<int> _deletePaperDerived(String paperId) async {
    var removed = 0;
    // Delete generation children before their processing root so no partial
    // generation remains at a transaction boundary.
    removed += await (database.delete(
      database.cachedChats,
    )..where((table) => table.paperId.equals(paperId))).go();
    removed += await (database.delete(
      database.cachedIntroductions,
    )..where((table) => table.paperId.equals(paperId))).go();
    removed += await (database.delete(
      database.cachedConnections,
    )..where((table) => table.paperId.equals(paperId))).go();
    removed += await (database.delete(
      database.cachedProcessing,
    )..where((table) => table.paperId.equals(paperId))).go();
    return removed;
  }

  Future<int> _deleteChat(CachedChatRow row) =>
      (database.delete(database.cachedChats)..where(
            (table) =>
                table.sessionId.equals(row.sessionId) &
                table.readerKey.equals(row.readerKey),
          ))
          .go();

  Future<Set<String>> _paperIdsForProtectedChats(
    Set<String> protectedChatReaderKeys,
  ) async {
    if (protectedChatReaderKeys.isEmpty) return const {};
    final rows =
        await (database.selectOnly(database.cachedChats)
              ..addColumns([database.cachedChats.paperId])
              ..where(
                database.cachedChats.readerKey.isIn(protectedChatReaderKeys) &
                    database.cachedChats.paperId.isNotNull(),
              ))
            .get();
    return rows
        .map((row) => row.read(database.cachedChats.paperId))
        .whereType<String>()
        .toSet();
  }

  Future<void> _repairFeedQueries(Set<String> queryKeys) async {
    for (final queryKey in queryKeys) {
      final entries =
          await (database.select(database.feedEntries)
                ..where((entry) => entry.queryKey.equals(queryKey))
                ..orderBy([(entry) => OrderingTerm.asc(entry.position)]))
              .get();
      if (entries.isEmpty) {
        // This query previously had a representation and lost it during
        // eviction. Do not turn that cache miss into an authoritative empty
        // category while retaining an unrelated old cursor.
        await (database.delete(
          database.feedQueries,
        )..where((query) => query.queryKey.equals(queryKey))).go();
        continue;
      }
      // Cascades and TTL deletion can punch holes in an otherwise useful
      // offline snapshot. Shift only downward, in ascending order, so the
      // UNIQUE(query_key, position) constraint remains satisfied throughout.
      for (var position = 0; position < entries.length; position += 1) {
        final entry = entries[position];
        if (entry.position == position) continue;
        await (database.update(database.feedEntries)..where(
              (row) =>
                  row.queryKey.equals(queryKey) &
                  row.paperId.equals(entry.paperId),
            ))
            .write(FeedEntriesCompanion(position: Value(position)));
      }
      await (database.update(
        database.feedQueries,
      )..where((query) => query.queryKey.equals(queryKey))).write(
        FeedQueriesCompanion(
          entryCount: Value(entries.length),
          etag: const Value(null),
          refreshedAt: Value(
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        ),
      );
    }
  }

  Future<Set<String>> _internallyProtectedPaperIds() async {
    final protected = <String>{};
    final library =
        await (database.selectOnly(database.libraryItems)
              ..addColumns([database.libraryItems.paperId])
              ..where(database.libraryItems.deleted.equals(false)))
            .get();
    protected.addAll(
      library
          .map((row) => row.read(database.libraryItems.paperId))
          .whereType<String>(),
    );
    final drafts = await (database.selectOnly(
      database.commentDrafts,
    )..addColumns([database.commentDrafts.paperId])).get();
    protected.addAll(
      drafts
          .map((row) => row.read(database.commentDrafts.paperId))
          .whereType<String>(),
    );
    final outboxRows = await database.select(database.syncOutbox).get();
    protected.addAll(
      outboxRows
          .where(
            (row) =>
                row.entityKind == 'paper' ||
                row.entityKind == 'library_item' ||
                row.entityKind == 'comment',
          )
          .map((row) => row.entityId)
          .where((id) => id.isNotEmpty),
    );
    return protected;
  }
}

enum _DerivedEvictionKind { paperCluster, introduction, connection, chat }

class _DerivedEvictionCandidate {
  const _DerivedEvictionCandidate._({
    required this.kind,
    required this.updatedAt,
    this.paperId,
    this.chat,
  });

  factory _DerivedEvictionCandidate.paperCluster({
    required String paperId,
    required DateTime updatedAt,
  }) => _DerivedEvictionCandidate._(
    kind: _DerivedEvictionKind.paperCluster,
    paperId: paperId,
    updatedAt: updatedAt,
  );

  factory _DerivedEvictionCandidate.introduction({
    required String paperId,
    required DateTime updatedAt,
  }) => _DerivedEvictionCandidate._(
    kind: _DerivedEvictionKind.introduction,
    paperId: paperId,
    updatedAt: updatedAt,
  );

  factory _DerivedEvictionCandidate.connection({
    required String paperId,
    required DateTime updatedAt,
  }) => _DerivedEvictionCandidate._(
    kind: _DerivedEvictionKind.connection,
    paperId: paperId,
    updatedAt: updatedAt,
  );

  factory _DerivedEvictionCandidate.chat(CachedChatRow chat) =>
      _DerivedEvictionCandidate._(
        kind: _DerivedEvictionKind.chat,
        chat: chat,
        updatedAt: chat.updatedAt,
      );

  final _DerivedEvictionKind kind;
  final DateTime updatedAt;
  final String? paperId;
  final CachedChatRow? chat;

  String get sortKey => switch (kind) {
    _DerivedEvictionKind.paperCluster => 'paper:${paperId!}',
    _DerivedEvictionKind.introduction => 'introduction:${paperId!}',
    _DerivedEvictionKind.connection => 'connection:${paperId!}',
    _DerivedEvictionKind.chat => 'chat:${chat!.sessionId}:${chat!.readerKey}',
  };
}
