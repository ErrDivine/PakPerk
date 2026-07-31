import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import 'app_database.dart';
import 'paper_cache_dao.dart';

class DerivedCacheDao {
  DerivedCacheDao(this.database, this.papers);

  static const maxChatSnapshotBytes = 512 * 1024;

  final PakPerkDatabase database;
  final PaperCacheDao papers;

  Future<PaperProcessingState?> loadProcessing(String paperId) =>
      database.transaction(() async {
        final row = await (database.select(
          database.cachedProcessing,
        )..where((table) => table.paperId.equals(paperId))).getSingleOrNull();
        if (row == null) return null;
        final value = _decode(row.payloadJson, PaperProcessingState.fromJson);
        if (row.generation <= 0 ||
            !await _paperVersionMatches(paperId, row.versionKey) ||
            value == null ||
            value.paperId != paperId ||
            value.generation != row.generation) {
          await clearForPaper(paperId);
          return null;
        }
        return value;
      });

  Future<void> saveProcessing(PaperProcessingState value) async {
    final version = await papers.versionKey(value.paperId);
    if (version == null || value.paperId.trim().isEmpty) return;
    await saveProcessingForVersion(
      value,
      expectedVersionKey: PaperVersionKey(
        paperId: value.paperId,
        arxivId: version,
      ),
    );
  }

  Future<bool> saveProcessingForVersion(
    PaperProcessingState value, {
    required PaperVersionKey expectedVersionKey,
  }) => database.transaction(() async {
    if (value.generation <= 0 ||
        value.paperId != expectedVersionKey.paperId ||
        !await _isCurrentVersion(expectedVersionKey)) {
      return false;
    }
    final existing = await (database.select(
      database.cachedProcessing,
    )..where((table) => table.paperId.equals(value.paperId))).getSingleOrNull();
    if (existing != null && existing.versionKey == expectedVersionKey.arxivId) {
      final olderGeneration = value.generation < existing.generation;
      final olderWithinGeneration =
          value.generation == existing.generation &&
          value.updatedAt.toUtc().isBefore(existing.updatedAt);
      if (olderGeneration || olderWithinGeneration) return false;
      if (value.generation > existing.generation) {
        await _clearGenerationDerived(value.paperId);
      }
    } else if (existing != null) {
      await _clearGenerationDerived(value.paperId);
    }
    await database
        .into(database.cachedProcessing)
        .insertOnConflictUpdate(
          CachedProcessingCompanion.insert(
            paperId: value.paperId,
            versionKey: expectedVersionKey.arxivId,
            generation: Value(value.generation),
            payloadJson: jsonEncode(value.toJson()),
            updatedAt: value.updatedAt.toUtc(),
          ),
        );
    return true;
  });

  Future<PaperIntroduction?> loadIntroduction(String paperId) =>
      database.transaction(() async {
        final row = await (database.select(
          database.cachedIntroductions,
        )..where((table) => table.paperId.equals(paperId))).getSingleOrNull();
        if (row == null) return null;
        final value = _decode(row.payloadJson, PaperIntroduction.fromJson);
        if (!await _processingScopeMatches(
              paperId,
              row.versionKey,
              row.generation,
            ) ||
            value == null ||
            value.paperId != paperId ||
            value.generation != row.generation) {
          await (database.delete(
            database.cachedIntroductions,
          )..where((table) => table.paperId.equals(paperId))).go();
          return null;
        }
        return value;
      });

  Future<void> saveIntroduction(PaperIntroduction value) async {
    final version = await papers.versionKey(value.paperId);
    if (version == null || value.paperId.trim().isEmpty) return;
    await saveIntroductionForVersion(
      value,
      expectedVersionKey: PaperVersionKey(
        paperId: value.paperId,
        arxivId: version,
      ),
    );
  }

  Future<bool> saveIntroductionForVersion(
    PaperIntroduction value, {
    required PaperVersionKey expectedVersionKey,
  }) => database.transaction(() async {
    if (value.paperId != expectedVersionKey.paperId ||
        !await _processingScopeMatches(
          value.paperId,
          expectedVersionKey.arxivId,
          value.generation,
        )) {
      return false;
    }
    await database
        .into(database.cachedIntroductions)
        .insertOnConflictUpdate(
          CachedIntroductionsCompanion.insert(
            paperId: value.paperId,
            versionKey: expectedVersionKey.arxivId,
            generation: value.generation,
            payloadJson: jsonEncode(value.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    return true;
  });

  Future<PaperConnections?> loadConnections(String paperId) =>
      database.transaction(() async {
        final row = await (database.select(
          database.cachedConnections,
        )..where((table) => table.paperId.equals(paperId))).getSingleOrNull();
        if (row == null) return null;
        final value = _decode(row.payloadJson, PaperConnections.fromJson);
        if (!await _processingScopeMatches(
              paperId,
              row.versionKey,
              row.generation,
            ) ||
            value == null ||
            value.paperId != paperId ||
            value.generation != row.generation) {
          await (database.delete(
            database.cachedConnections,
          )..where((table) => table.paperId.equals(paperId))).go();
          return null;
        }
        return value;
      });

  Future<void> saveConnections(PaperConnections value) async {
    final version = await papers.versionKey(value.paperId);
    if (version == null || value.paperId.trim().isEmpty) return;
    await saveConnectionsForVersion(
      value,
      expectedVersionKey: PaperVersionKey(
        paperId: value.paperId,
        arxivId: version,
      ),
    );
  }

  Future<bool> saveConnectionsForVersion(
    PaperConnections value, {
    required PaperVersionKey expectedVersionKey,
  }) => database.transaction(() async {
    if (value.paperId != expectedVersionKey.paperId ||
        !await _processingScopeMatches(
          value.paperId,
          expectedVersionKey.arxivId,
          value.generation,
        )) {
      return false;
    }
    await database
        .into(database.cachedConnections)
        .insertOnConflictUpdate(
          CachedConnectionsCompanion.insert(
            paperId: value.paperId,
            versionKey: expectedVersionKey.arxivId,
            generation: Value(value.generation),
            payloadJson: jsonEncode(value.toJson()),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    return true;
  });

  Future<ChatSnapshot?> loadChat(
    String readerKey, {
    required String sessionId,
    DateTime? now,
  }) => database.transaction(() async {
    final row =
        await (database.select(database.cachedChats)..where(
              (table) =>
                  table.sessionId.equals(sessionId) &
                  table.readerKey.equals(readerKey),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    final utcNow = (now ?? DateTime.now()).toUtc();
    final value = _decode(row.payloadJson, ChatSnapshot.fromJson);
    if (!row.expiresAt.isAfter(utcNow) ||
        row.paperId == null ||
        row.versionKey == null ||
        row.generation <= 0 ||
        !await _processingScopeMatches(
          row.paperId!,
          row.versionKey!,
          row.generation,
        ) ||
        value == null ||
        value.generation != row.generation) {
      await _deleteChat(sessionId, readerKey);
      return null;
    }
    return value;
  });

  Future<bool> saveChat(
    String readerKey,
    ChatSnapshot value, {
    required String sessionId,
    required PaperVersionKey expectedVersionKey,
    required int expectedGeneration,
    DateTime? now,
    Duration ttl = const Duration(days: 7),
  }) async {
    if (readerKey.trim().isEmpty ||
        sessionId.trim().isEmpty ||
        expectedGeneration <= 0 ||
        value.generation != expectedGeneration) {
      return false;
    }
    final payload = jsonEncode(value.toJson());
    if (utf8.encode(payload).length > maxChatSnapshotBytes) return false;
    return database.transaction(() async {
      if (!await _processingScopeMatches(
        expectedVersionKey.paperId,
        expectedVersionKey.arxivId,
        expectedGeneration,
      )) {
        return false;
      }
      final updatedAt = (now ?? DateTime.now()).toUtc();
      await database
          .into(database.cachedChats)
          .insertOnConflictUpdate(
            CachedChatsCompanion.insert(
              sessionId: sessionId,
              readerKey: readerKey,
              paperId: Value(expectedVersionKey.paperId),
              versionKey: Value(expectedVersionKey.arxivId),
              generation: Value(expectedGeneration),
              payloadJson: payload,
              updatedAt: updatedAt,
              expiresAt: updatedAt.add(ttl),
            ),
          );
      return true;
    });
  }

  Future<void> clearForPaper(String paperId) => database.transaction(() async {
    await (database.delete(
      database.cachedProcessing,
    )..where((table) => table.paperId.equals(paperId))).go();
    await _clearGenerationDerived(paperId);
  });

  Future<void> _clearGenerationDerived(String paperId) async {
    await (database.delete(
      database.cachedIntroductions,
    )..where((table) => table.paperId.equals(paperId))).go();
    await (database.delete(
      database.cachedConnections,
    )..where((table) => table.paperId.equals(paperId))).go();
    await (database.delete(
      database.cachedChats,
    )..where((table) => table.paperId.equals(paperId))).go();
  }

  Future<void> clearChats() => database.delete(database.cachedChats).go();

  Future<void> _deleteChat(String sessionId, String readerKey) async {
    await (database.delete(database.cachedChats)..where(
          (table) =>
              table.sessionId.equals(sessionId) &
              table.readerKey.equals(readerKey),
        ))
        .go();
  }

  Future<bool> _paperVersionMatches(String paperId, String versionKey) async =>
      await papers.versionKey(paperId) == versionKey;

  Future<bool> _processingScopeMatches(
    String paperId,
    String versionKey,
    int generation,
  ) async {
    if (generation <= 0 || !await _paperVersionMatches(paperId, versionKey)) {
      return false;
    }
    final processing = await (database.select(
      database.cachedProcessing,
    )..where((table) => table.paperId.equals(paperId))).getSingleOrNull();
    if (processing == null ||
        processing.versionKey != versionKey ||
        processing.generation != generation) {
      return false;
    }
    final decoded = _decode(
      processing.payloadJson,
      PaperProcessingState.fromJson,
    );
    return decoded != null &&
        decoded.paperId == paperId &&
        decoded.generation == generation;
  }

  Future<bool> _isCurrentVersion(PaperVersionKey expected) async =>
      expected.paperId.isNotEmpty &&
      await papers.versionKey(expected.paperId) == expected.arxivId;
}

T? _decode<T>(String raw, T Function(Map<String, dynamic>) parse) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? parse(Map<String, dynamic>.from(decoded)) : null;
  } on Object {
    return null;
  }
}
