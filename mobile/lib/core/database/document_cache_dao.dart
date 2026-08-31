import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/document_block.dart';
import '../models/reading_checkpoint.dart';
import '../telemetry/telemetry.dart';
import 'app_database.dart';

final class DocumentCacheDao {
  const DocumentCacheDao(
    this.database, {
    this.telemetry = const NoopTelemetrySink(),
  });

  static const _snapshotKind = 'document_snapshot_v1';

  final PakPerkDatabase database;
  final TelemetrySink telemetry;

  Future<DocumentSnapshot?> readSnapshot({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    DateTime? now,
  }) async {
    final row =
        await (database.select(database.cachedDocumentArtifacts)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(paperId) &
                  table.versionKey.equals(versionKey) &
                  table.generation.equals(generation) &
                  table.artifactKind.equals(_snapshotKind),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    if (!row.expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      await _evictSnapshot(
        accountId: accountId,
        paperId: paperId,
        versionKey: versionKey,
        generation: generation,
        reason: 'expired',
      );
      return null;
    }
    try {
      final decoded = jsonDecode(row.payloadJson);
      if (decoded is! Map) {
        await _evictSnapshot(
          accountId: accountId,
          paperId: paperId,
          versionKey: versionKey,
          generation: generation,
          reason: 'invalid',
        );
        return null;
      }
      final snapshot = DocumentSnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (snapshot.paperId != paperId ||
          snapshot.versionKey != versionKey ||
          snapshot.generation != generation) {
        await _evictSnapshot(
          accountId: accountId,
          paperId: paperId,
          versionKey: versionKey,
          generation: generation,
          reason: 'invalid',
        );
        return null;
      }
      return snapshot;
    } on FormatException {
      await _evictSnapshot(
        accountId: accountId,
        paperId: paperId,
        versionKey: versionKey,
        generation: generation,
        reason: 'invalid',
      );
      return null;
    }
  }

  Future<void> writeSnapshot({
    required String accountId,
    required DocumentSnapshot snapshot,
    Duration ttl = const Duration(days: 30),
  }) async {
    final fetchedAt = snapshot.fetchedAt.toUtc();
    final payload = jsonEncode(snapshot.toJson());
    await database
        .into(database.cachedDocumentArtifacts)
        .insertOnConflictUpdate(
          CachedDocumentArtifactsCompanion.insert(
            accountId: accountId,
            paperId: snapshot.paperId,
            versionKey: snapshot.versionKey,
            generation: snapshot.generation,
            artifactKind: _snapshotKind,
            payloadJson: payload,
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.add(ttl),
          ),
        );
    emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheSize, {
      'bytes': utf8.encode(payload).length,
    });
  }

  Future<ReadingCheckpoint?> readCheckpoint({
    required String accountId,
    required String paperId,
  }) async {
    final row =
        await (database.select(database.readingCheckpoints)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(paperId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return ReadingCheckpoint.fromJson(
      {
        'paper_id': row.paperId,
        'generation': row.generation,
        'mode': row.mode,
        'stage': row.stage,
        'block_id': row.blockId,
        'scroll_fraction': row.scrollFraction,
        'last_read_at': row.lastReadAt.toUtc().toIso8601String(),
        'revision': row.revision,
        'operation_id': row.operationId,
      },
      accountId: row.accountId,
      pendingSync: row.pendingSync,
    );
  }

  Future<void> writeCheckpoint(ReadingCheckpoint checkpoint) async {
    final json = checkpoint.toJson();
    await database
        .into(database.readingCheckpoints)
        .insertOnConflictUpdate(
          ReadingCheckpointsCompanion.insert(
            accountId: checkpoint.accountId,
            paperId: checkpoint.paperId,
            generation: checkpoint.generation,
            mode: checkpoint.mode.wireValue,
            stage: json['stage']! as String,
            blockId: Value(checkpoint.blockId),
            scrollFraction: Value(checkpoint.scrollFraction),
            lastReadAt: checkpoint.lastReadAt.toUtc(),
            revision: Value(checkpoint.revision),
            pendingSync: Value(checkpoint.pendingSync),
            operationId: Value(checkpoint.operationId),
          ),
        );
  }

  Future<void> clearExpired({DateTime? now}) async {
    final count =
        await (database.delete(database.cachedDocumentArtifacts)..where(
              (table) => table.expiresAt.isSmallerOrEqualValue(
                (now ?? DateTime.now()).toUtc(),
              ),
            ))
            .go();
    if (count > 0) {
      emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
        'reason': 'expired',
        'count': count,
      });
    }
  }

  Future<void> clearAccount(String accountId) => database.transaction(() async {
    final documentCount = await (database.delete(
      database.cachedDocumentArtifacts,
    )..where((table) => table.accountId.equals(accountId))).go();
    await (database.delete(
      database.readingCheckpoints,
    )..where((table) => table.accountId.equals(accountId))).go();
    if (documentCount > 0) {
      emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
        'reason': 'account_cleanup',
        'count': documentCount,
      });
    }
  });

  Future<void> _evictSnapshot({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    required String reason,
  }) async {
    final count =
        await (database.delete(database.cachedDocumentArtifacts)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(paperId) &
                  table.versionKey.equals(versionKey) &
                  table.generation.equals(generation) &
                  table.artifactKind.equals(_snapshotKind),
            ))
            .go();
    if (count > 0) {
      emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
        'reason': reason,
        'count': count,
      });
    }
  }
}
