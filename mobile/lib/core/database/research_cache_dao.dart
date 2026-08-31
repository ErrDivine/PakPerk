import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/annotation.dart';
import '../models/evidence_card.dart';
import '../models/research_memory.dart';
import '../models/version_diff.dart';
import 'app_database.dart';

enum ResearchEntityKind { annotation, evidenceCard, memoryItem, checkpoint }

enum ResearchOutboxOperation { put, delete, reanchor, review }

enum ResearchOutboxState { queued, inFlight, failed }

final class ResearchOutboxEntry {
  const ResearchOutboxEntry({
    required this.accountId,
    required this.operationId,
    required this.entityKind,
    required this.entityId,
    required this.operation,
    required this.baseRevision,
    required this.payload,
    required this.state,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.lastErrorCode,
  });

  final String accountId;
  final String operationId;
  final ResearchEntityKind entityKind;
  final String entityId;
  final ResearchOutboxOperation operation;
  final int baseRevision;
  final Map<String, dynamic> payload;
  final ResearchOutboxState state;
  final int attemptCount;
  final String? lastErrorCode;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Durable private research store.
///
/// This DAO guarantees account scoping, transactionally pairs optimistic rows
/// with their outbox operation, and retains tombstones until acknowledgement.
/// It deliberately makes no at-rest encryption claim; platform file
/// protection and device access control define the local threat boundary.
final class ResearchCacheDao {
  const ResearchCacheDao(this.database);

  static const _versionListKey = 'versions_v1';
  static const _versionCacheTtl = Duration(days: 7);

  final PakPerkDatabase database;

  Stream<List<Annotation>> watchAnnotations({
    required String accountId,
    required String paperId,
    bool includeDeleted = false,
  }) {
    final query = database.select(database.localAnnotations)
      ..where(
        (row) => row.accountId.equals(accountId) & row.paperId.equals(paperId),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.updatedAt),
        (row) => OrderingTerm.asc(row.annotationId),
      ]);
    if (!includeDeleted) query.where((row) => row.deletedAt.isNull());
    return query.watch().map(
      (rows) => rows.map(_annotationFromRow).toList(growable: false),
    );
  }

  Future<List<Annotation>> annotationsForPaper({
    required String accountId,
    required String paperId,
    bool includeDeleted = false,
  }) async {
    final query = database.select(database.localAnnotations)
      ..where(
        (row) => row.accountId.equals(accountId) & row.paperId.equals(paperId),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    if (!includeDeleted) query.where((row) => row.deletedAt.isNull());
    return (await query.get()).map(_annotationFromRow).toList(growable: false);
  }

  Future<Annotation?> annotation({
    required String accountId,
    required String annotationId,
  }) async {
    final row =
        await (database.select(database.localAnnotations)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.annotationId.equals(annotationId),
            ))
            .getSingleOrNull();
    return row == null ? null : _annotationFromRow(row);
  }

  Future<void> persistOptimisticAnnotation({
    required String accountId,
    required Annotation annotation,
    required ResearchOutboxEntry operation,
  }) => database.transaction(() async {
    await _putAnnotation(accountId, annotation);
    await _putOutbox(operation);
  });

  Future<void> settleAnnotation({
    required String accountId,
    required String operationId,
    required Annotation canonical,
    String? resolvedConflictId,
    String? mergedBody,
  }) => database.transaction(() async {
    await _putAnnotation(
      accountId,
      canonical.copyWith(
        syncState: ResearchSyncState.clean,
        clearActiveOperationId: true,
      ),
    );
    if (resolvedConflictId != null) {
      final retained =
          await (database.select(database.annotationConflicts)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.conflictId.equals(resolvedConflictId),
              ))
              .getSingleOrNull();
      final trueMergedBody =
          retained == null ||
              mergedBody == retained.attemptedBody ||
              mergedBody == retained.serverBody
          ? null
          : mergedBody;
      await (database.update(database.annotationConflicts)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.conflictId.equals(resolvedConflictId) &
                row.mergeState.equals(
                  AnnotationMergeState.unresolved.wireValue,
                ),
          ))
          .write(
            AnnotationConflictsCompanion(
              mergeState: Value(AnnotationMergeState.resolved.wireValue),
              mergedBody: Value(trueMergedBody),
              resolvedAt: Value(canonical.updatedAt.toUtc()),
            ),
          );
    }
    await _deleteOutbox(accountId, operationId);
  });

  Future<void> recordAnnotationConflict({
    required String accountId,
    required AnnotationConflict conflict,
  }) => database.transaction(() async {
    await _putAnnotationConflict(accountId, conflict);
    await _markAnnotationConflict(accountId, conflict.annotationId);
    await _deleteOutbox(accountId, conflict.attemptedOperationId);
  });

  Stream<List<AnnotationConflict>> watchUnresolvedConflicts(
    String accountId, {
    String? paperId,
  }) {
    if (paperId != null) {
      final query =
          database.select(database.annotationConflicts).join([
              innerJoin(
                database.localAnnotations,
                database.localAnnotations.accountId.equalsExp(
                      database.annotationConflicts.accountId,
                    ) &
                    database.localAnnotations.annotationId.equalsExp(
                      database.annotationConflicts.annotationId,
                    ),
              ),
            ])
            ..where(
              database.annotationConflicts.accountId.equals(accountId) &
                  database.annotationConflicts.mergeState.equals(
                    AnnotationMergeState.unresolved.wireValue,
                  ) &
                  database.localAnnotations.paperId.equals(paperId),
            )
            ..orderBy([
              OrderingTerm.desc(database.annotationConflicts.createdAt),
            ]);
      return query.watch().map(
        (rows) => rows
            .map((row) => row.readTable(database.annotationConflicts))
            .map(_conflictFromRow)
            .toList(growable: false),
      );
    }
    final query = database.select(database.annotationConflicts)
      ..where(
        (row) =>
            row.accountId.equals(accountId) &
            row.mergeState.equals(AnnotationMergeState.unresolved.wireValue),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]);
    return query.watch().map(
      (rows) => rows.map(_conflictFromRow).toList(growable: false),
    );
  }

  Future<void> mergeRemoteUnresolvedConflicts({
    required String accountId,
    required Iterable<AnnotationConflict> conflicts,
    required int syncRevision,
  }) => database.transaction(() async {
    final remote = conflicts.toList(growable: false);
    final remoteIds = remote.map((conflict) => conflict.conflictId).toSet();
    final annotationIds = remote
        .map((conflict) => conflict.annotationId)
        .toSet();
    for (final conflict in remote) {
      if (conflict.mergeState != AnnotationMergeState.unresolved) {
        throw const FormatException(
          'Conflict snapshot contains a resolved row.',
        );
      }
      await _putAnnotationConflict(accountId, conflict);
      await _deleteOutbox(accountId, conflict.attemptedOperationId);
    }
    final retained =
        await (database.select(database.annotationConflicts)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.mergeState.equals(
                    AnnotationMergeState.unresolved.wireValue,
                  ),
            ))
            .get();
    for (final row in retained) {
      if (remoteIds.contains(row.conflictId)) continue;
      await (database.delete(database.annotationConflicts)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.conflictId.equals(row.conflictId),
          ))
          .go();
    }
    final conflictedAnnotations =
        await (database.select(database.localAnnotations)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.syncState.equals(ResearchSyncState.conflict.wireValue),
            ))
            .get();
    for (final row in conflictedAnnotations) {
      if (annotationIds.contains(row.annotationId)) continue;
      await (database.update(database.localAnnotations)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.annotationId.equals(row.annotationId) &
                candidate.syncState.equals(
                  ResearchSyncState.conflict.wireValue,
                ),
          ))
          .write(const LocalAnnotationsCompanion(syncState: Value('clean')));
    }
    for (final annotationId in annotationIds) {
      await _markRemoteAnnotationConflict(accountId, annotationId);
    }
    await _putSyncState(
      accountId,
      'annotation_conflict',
      syncRevision: syncRevision,
    );
  });

  Future<void> resolveConflict({
    required String accountId,
    required AnnotationConflict resolved,
  }) =>
      (database.update(database.annotationConflicts)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.conflictId.equals(resolved.conflictId),
          ))
          .write(
            AnnotationConflictsCompanion(
              mergeState: Value(resolved.mergeState.wireValue),
              mergedBody: Value(resolved.mergedBody),
              resolvedAt: Value(resolved.resolvedAt?.toUtc()),
            ),
          )
          .then((_) {});

  Future<void> persistOptimisticEvidence({
    required String accountId,
    required EvidenceCard card,
    required ResearchOutboxEntry operation,
  }) => database.transaction(() async {
    await _putEvidence(accountId, card);
    await _putOutbox(operation);
  });

  Future<void> settleEvidence({
    required String accountId,
    required String operationId,
    required EvidenceCard canonical,
  }) => database.transaction(() async {
    await _putEvidence(
      accountId,
      canonical.copyWith(
        syncState: ResearchSyncState.clean,
        clearActiveOperationId: true,
      ),
    );
    await _deleteOutbox(accountId, operationId);
  });

  Stream<List<EvidenceCard>> watchEvidenceCards({
    required String accountId,
    required String paperId,
  }) {
    final query = database.select(database.localEvidenceCards)
      ..where(
        (row) =>
            row.accountId.equals(accountId) &
            row.paperId.equals(paperId) &
            row.deletedAt.isNull(),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    return query.watch().map(
      (rows) => rows.map(_evidenceFromRow).toList(growable: false),
    );
  }

  Future<List<EvidenceCard>> evidenceForPaper({
    required String accountId,
    required String paperId,
    bool includeDeleted = false,
  }) async {
    final query = database.select(database.localEvidenceCards)
      ..where(
        (row) => row.accountId.equals(accountId) & row.paperId.equals(paperId),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]);
    if (!includeDeleted) query.where((row) => row.deletedAt.isNull());
    return (await query.get()).map(_evidenceFromRow).toList(growable: false);
  }

  Future<EvidenceCard?> evidenceCard({
    required String accountId,
    required String cardId,
  }) async {
    final row =
        await (database.select(database.localEvidenceCards)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.cardId.equals(cardId),
            ))
            .getSingleOrNull();
    return row == null ? null : _evidenceFromRow(row);
  }

  Future<void> persistOptimisticMemory({
    required String accountId,
    required MemoryItem item,
    required ResearchOutboxEntry operation,
  }) => database.transaction(() async {
    await _putMemory(accountId, item);
    await _putOutbox(operation);
  });

  Future<void> settleMemory({
    required String accountId,
    required String operationId,
    required MemoryItem canonical,
  }) => database.transaction(() async {
    await _putMemory(
      accountId,
      canonical.copyWith(
        syncState: ResearchSyncState.clean,
        clearActiveOperationId: true,
      ),
    );
    await _deleteOutbox(accountId, operationId);
  });

  Stream<List<MemoryItem>> watchMemoryReview(String accountId) {
    final query = database.select(database.localMemoryItems)
      ..where((row) => row.accountId.equals(accountId) & row.deletedAt.isNull())
      ..orderBy([
        (row) => OrderingTerm.asc(row.nextReviewAt),
        (row) => OrderingTerm.desc(row.updatedAt),
      ]);
    return query.watch().map(
      (rows) => rows.map(_memoryFromRow).toList(growable: false),
    );
  }

  Future<List<MemoryItem>> memoryItems({
    required String accountId,
    bool includeDeleted = false,
  }) async {
    final query = database.select(database.localMemoryItems)
      ..where((row) => row.accountId.equals(accountId))
      ..orderBy([(row) => OrderingTerm.asc(row.nextReviewAt)]);
    if (!includeDeleted) query.where((row) => row.deletedAt.isNull());
    return (await query.get()).map(_memoryFromRow).toList(growable: false);
  }

  Future<MemoryItem?> memoryItem({
    required String accountId,
    required String itemId,
  }) async {
    final row =
        await (database.select(database.localMemoryItems)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.itemId.equals(itemId),
            ))
            .getSingleOrNull();
    return row == null ? null : _memoryFromRow(row);
  }

  Future<List<ResearchOutboxEntry>> pendingOperations(
    String accountId, {
    int limit = 100,
  }) async {
    final rows =
        await (database.select(database.researchOutbox)
              ..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.state.isIn(const ['queued', 'failed']),
              )
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.operationId),
              ])
              ..limit(limit))
            .get();
    return rows.map(_outboxFromRow).toList(growable: false);
  }

  Future<void> markOperationInFlight(ResearchOutboxEntry entry) =>
      (database.update(database.researchOutbox)..where(
            (row) =>
                row.accountId.equals(entry.accountId) &
                row.operationId.equals(entry.operationId),
          ))
          .write(
            ResearchOutboxCompanion(
              state: const Value('inFlight'),
              attemptCount: Value(entry.attemptCount + 1),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          )
          .then((_) {});

  Future<void> markOperationFailed(
    ResearchOutboxEntry entry,
    String errorCode,
  ) =>
      (database.update(database.researchOutbox)..where(
            (row) =>
                row.accountId.equals(entry.accountId) &
                row.operationId.equals(entry.operationId),
          ))
          .write(
            ResearchOutboxCompanion(
              state: const Value('failed'),
              lastErrorCode: Value(errorCode),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          )
          .then((_) {});

  Future<void> restoreInterruptedOperations(String accountId) =>
      (database.update(database.researchOutbox)..where(
            (row) =>
                row.accountId.equals(accountId) & row.state.equals('inFlight'),
          ))
          .write(
            ResearchOutboxCompanion(
              state: const Value('queued'),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          )
          .then((_) {});

  Future<void> mergeRemoteAnnotations({
    required String accountId,
    required Iterable<Annotation> annotations,
    required int syncRevision,
    required String paperId,
    required int purgedThroughRevision,
  }) => database.transaction(() async {
    final remoteIds = annotations.map((value) => value.id).toSet();
    for (final annotation in annotations) {
      final local = await this.annotation(
        accountId: accountId,
        annotationId: annotation.id,
      );
      if (local?.syncState == ResearchSyncState.pending ||
          local?.syncState == ResearchSyncState.conflict) {
        continue;
      }
      await _putAnnotation(accountId, annotation);
    }
    final unresolved =
        await (database.select(database.annotationConflicts)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.mergeState.equals(
                    AnnotationMergeState.unresolved.wireValue,
                  ),
            ))
            .get();
    for (final conflict in unresolved) {
      await _markRemoteAnnotationConflict(accountId, conflict.annotationId);
    }
    final localRows =
        await (database.select(database.localAnnotations)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.syncState.equals(ResearchSyncState.clean.wireValue) &
                  row.revision.isSmallerOrEqualValue(purgedThroughRevision),
            ))
            .get();
    for (final row in localRows) {
      if (remoteIds.contains(row.annotationId)) continue;
      await (database.delete(database.localAnnotations)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.annotationId.equals(row.annotationId),
          ))
          .go();
    }
    await _putSyncState(accountId, 'annotation', syncRevision: syncRevision);
  });

  Future<void> mergeRemoteEvidence({
    required String accountId,
    required Iterable<EvidenceCard> cards,
    required int syncRevision,
    required String paperId,
    String? cursor,
  }) => database.transaction(() async {
    final remoteIds = cards.map((value) => value.id).toSet();
    for (final card in cards) {
      final local = await evidenceCard(accountId: accountId, cardId: card.id);
      if (local?.syncState == ResearchSyncState.pending) continue;
      await _putEvidence(accountId, card);
    }
    final localRows =
        await (database.select(database.localEvidenceCards)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.syncState.equals(ResearchSyncState.clean.wireValue) &
                  row.revision.isSmallerOrEqualValue(syncRevision),
            ))
            .get();
    for (final row in localRows) {
      if (remoteIds.contains(row.cardId)) continue;
      await (database.delete(database.localEvidenceCards)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.cardId.equals(row.cardId),
          ))
          .go();
    }
    await _putSyncState(
      accountId,
      'evidenceCard',
      syncRevision: syncRevision,
      cursor: cursor,
    );
  });

  Future<void> mergeRemoteMemory({
    required String accountId,
    required Iterable<MemoryItem> items,
    required int syncRevision,
    String? cursor,
  }) => database.transaction(() async {
    final remote = items.toList(growable: false);
    final remoteIds = remote.map((item) => item.id).toSet();
    for (final item in remote) {
      final local = await memoryItem(accountId: accountId, itemId: item.id);
      if (local?.syncState == ResearchSyncState.pending) continue;
      await _putMemory(accountId, item);
    }
    // /v1/memory/review is the complete eligible review snapshot. A clean
    // local row omitted at this revision was retired, deleted, or moved to a
    // future review time on another device and must not remain due forever.
    // Pending optimistic rows remain authoritative until their operation is
    // acknowledged, and rows newer than this snapshot are revision-fenced.
    final localRows =
        await (database.select(database.localMemoryItems)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.syncState.equals(ResearchSyncState.clean.wireValue) &
                  row.revision.isSmallerOrEqualValue(syncRevision),
            ))
            .get();
    for (final row in localRows) {
      if (remoteIds.contains(row.itemId)) continue;
      await (database.delete(database.localMemoryItems)..where(
            (candidate) =>
                candidate.accountId.equals(accountId) &
                candidate.itemId.equals(row.itemId),
          ))
          .go();
    }
    await _putSyncState(
      accountId,
      'memoryItem',
      syncRevision: syncRevision,
      cursor: cursor,
    );
  });

  Future<void> cacheVersions({
    required String accountId,
    required String paperId,
    required List<DocumentVersion> versions,
    DateTime? fetchedAt,
  }) async {
    final fetched = (fetchedAt ?? DateTime.now()).toUtc();
    await database
        .into(database.cachedVersionArtifacts)
        .insertOnConflictUpdate(
          CachedVersionArtifactsCompanion.insert(
            accountId: accountId,
            paperId: paperId,
            cacheKey: _versionListKey,
            payloadJson: jsonEncode(
              versions.map((version) => version.toJson()).toList(),
            ),
            fetchedAt: fetched,
            expiresAt: fetched.add(_versionCacheTtl),
          ),
        );
  }

  Future<List<DocumentVersion>?> readCachedVersions({
    required String accountId,
    required String paperId,
    DateTime? now,
  }) async {
    final row =
        await (database.select(database.cachedVersionArtifacts)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.cacheKey.equals(_versionListKey),
            ))
            .getSingleOrNull();
    if (row == null ||
        !row.expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      return null;
    }
    try {
      final decoded = jsonDecode(row.payloadJson);
      if (decoded is! List || decoded.length > 128) return null;
      return decoded
          .map((item) => DocumentVersion.fromJson(_map(item)))
          .toList(growable: false);
    } on FormatException {
      return null;
    }
  }

  Future<void> cacheVersionDiff({
    required String accountId,
    required PaperVersionDiff diff,
    DateTime? fetchedAt,
  }) async {
    final fetched = (fetchedAt ?? DateTime.now()).toUtc();
    final key = 'diff_v1:${diff.fromGeneration}:${diff.toGeneration}';
    await database
        .into(database.cachedVersionArtifacts)
        .insertOnConflictUpdate(
          CachedVersionArtifactsCompanion.insert(
            accountId: accountId,
            paperId: diff.paperId,
            cacheKey: key,
            payloadJson: jsonEncode(diff.toJson()),
            fetchedAt: fetched,
            expiresAt: fetched.add(_versionCacheTtl),
          ),
        );
  }

  Future<PaperVersionDiff?> readCachedVersionDiff({
    required String accountId,
    required String paperId,
    required int fromGeneration,
    required int toGeneration,
    DateTime? now,
  }) async {
    final key = 'diff_v1:$fromGeneration:$toGeneration';
    final row =
        await (database.select(database.cachedVersionArtifacts)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.paperId.equals(paperId) &
                  row.cacheKey.equals(key),
            ))
            .getSingleOrNull();
    if (row == null ||
        !row.expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      return null;
    }
    try {
      return PaperVersionDiff.fromJson(_map(jsonDecode(row.payloadJson)));
    } on FormatException {
      return null;
    }
  }

  Future<void> clearAccount(String accountId) => database.transaction(() async {
    await (database.delete(
      database.localAnnotations,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.annotationConflicts,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.localEvidenceCards,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.localMemoryItems,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.researchOutbox,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.researchSyncStates,
    )..where((row) => row.accountId.equals(accountId))).go();
    await (database.delete(
      database.cachedVersionArtifacts,
    )..where((row) => row.accountId.equals(accountId))).go();
  });

  Future<void> _putAnnotation(String accountId, Annotation value) => database
      .into(database.localAnnotations)
      .insertOnConflictUpdate(
        LocalAnnotationsCompanion.insert(
          accountId: accountId,
          annotationId: value.id,
          paperId: value.paperId,
          generation: value.generation,
          blockId: Value(value.blockId),
          kind: value.kind.wireValue,
          body: Value(value.body),
          colorRole: Value(value.colorRole?.wireValue),
          selectorJson: Value(
            value.selector == null
                ? null
                : jsonEncode(value.selector!.toJson()),
          ),
          sectionHintJson: Value(jsonEncode(value.sectionHint)),
          pageHint: Value(value.pageHint),
          anchorStatus: value.anchorStatus.wireValue,
          revision: Value(value.revision),
          deletedAt: Value(value.deletedAt?.toUtc()),
          createdAt: value.createdAt.toUtc(),
          updatedAt: value.updatedAt.toUtc(),
          syncState: Value(value.syncState.wireValue),
          activeOperationId: Value(value.activeOperationId),
        ),
      );

  Future<void> _putAnnotationConflict(
    String accountId,
    AnnotationConflict conflict,
  ) => database
      .into(database.annotationConflicts)
      .insertOnConflictUpdate(
        AnnotationConflictsCompanion.insert(
          accountId: accountId,
          conflictId: conflict.conflictId,
          annotationId: conflict.annotationId,
          attemptedOperationId: conflict.attemptedOperationId,
          baseRevision: conflict.baseRevision,
          serverRevision: conflict.serverRevision,
          attemptedBody: Value(conflict.attemptedBody),
          serverBody: Value(conflict.serverBody),
          mergeState: Value(conflict.mergeState.wireValue),
          mergedBody: Value(conflict.mergedBody),
          createdAt: conflict.createdAt.toUtc(),
          resolvedAt: Value(conflict.resolvedAt?.toUtc()),
        ),
      );

  Future<void> _markAnnotationConflict(String accountId, String annotationId) =>
      (database.update(database.localAnnotations)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.annotationId.equals(annotationId),
          ))
          .write(const LocalAnnotationsCompanion(syncState: Value('conflict')))
          .then((_) {});

  Future<void> _markRemoteAnnotationConflict(
    String accountId,
    String annotationId,
  ) =>
      (database.update(database.localAnnotations)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.annotationId.equals(annotationId) &
                row.syncState.isNotValue(ResearchSyncState.pending.wireValue),
          ))
          .write(const LocalAnnotationsCompanion(syncState: Value('conflict')))
          .then((_) {});

  Future<void> _putEvidence(String accountId, EvidenceCard value) => database
      .into(database.localEvidenceCards)
      .insertOnConflictUpdate(
        LocalEvidenceCardsCompanion.insert(
          accountId: accountId,
          cardId: value.id,
          paperId: value.paperId,
          generation: value.generation,
          title: value.title,
          claimOrQuestion: Value(value.claimOrQuestion),
          userNote: Value(value.userNote),
          sourceBlockIdsJson: Value(jsonEncode(value.sourceBlockIds)),
          figureIdsJson: Value(jsonEncode(value.figureIds)),
          tableIdsJson: Value(jsonEncode(value.tableIds)),
          citationContextIdsJson: Value(jsonEncode(value.citationContextIds)),
          verificationStatus: value.verificationStatus.wireValue,
          revision: Value(value.revision),
          deletedAt: Value(value.deletedAt?.toUtc()),
          createdAt: value.createdAt.toUtc(),
          updatedAt: value.updatedAt.toUtc(),
          syncState: Value(value.syncState.wireValue),
          activeOperationId: Value(value.activeOperationId),
        ),
      );

  Future<void> _putMemory(String accountId, MemoryItem value) => database
      .into(database.localMemoryItems)
      .insertOnConflictUpdate(
        LocalMemoryItemsCompanion.insert(
          accountId: accountId,
          itemId: value.id,
          paperId: value.paperId,
          generation: value.generation,
          sourceType: value.sourceType.wireValue,
          sourceId: value.sourceId,
          promptText: Value(value.promptText),
          answerText: Value(value.answerText),
          status: value.status.wireValue,
          nextReviewAt: Value(value.nextReviewAt?.toUtc()),
          reviewCount: Value(value.reviewCount),
          revision: Value(value.revision),
          deletedAt: Value(value.deletedAt?.toUtc()),
          createdAt: value.createdAt.toUtc(),
          updatedAt: value.updatedAt.toUtc(),
          syncState: Value(value.syncState.wireValue),
          activeOperationId: Value(value.activeOperationId),
        ),
      );

  Future<void> _putOutbox(ResearchOutboxEntry entry) => database
      .into(database.researchOutbox)
      .insertOnConflictUpdate(
        ResearchOutboxCompanion.insert(
          accountId: entry.accountId,
          operationId: entry.operationId,
          entityKind: entry.entityKind.name,
          entityId: entry.entityId,
          operation: entry.operation.name,
          baseRevision: Value(entry.baseRevision),
          payloadJson: jsonEncode(entry.payload),
          state: Value(entry.state.name),
          attemptCount: Value(entry.attemptCount),
          lastErrorCode: Value(entry.lastErrorCode),
          createdAt: entry.createdAt.toUtc(),
          updatedAt: entry.updatedAt.toUtc(),
        ),
      );

  Future<void> _deleteOutbox(String accountId, String operationId) =>
      (database.delete(database.researchOutbox)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.operationId.equals(operationId),
          ))
          .go()
          .then((_) {});

  Future<void> _putSyncState(
    String accountId,
    String entityKind, {
    required int syncRevision,
    String? cursor,
  }) => database
      .into(database.researchSyncStates)
      .insertOnConflictUpdate(
        ResearchSyncStatesCompanion.insert(
          accountId: accountId,
          entityKind: entityKind,
          revision: Value(syncRevision),
          cursor: Value(cursor),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
}

Annotation _annotationFromRow(LocalAnnotationRow row) {
  final selector = row.selectorJson == null
      ? null
      : TextQuotePositionSelector.fromJson(_map(jsonDecode(row.selectorJson!)));
  return Annotation(
    id: row.annotationId,
    paperId: row.paperId,
    generation: row.generation,
    blockId: row.blockId,
    kind: AnnotationKind.fromWire(row.kind),
    body: row.body,
    colorRole: AnnotationColorRole.fromWire(row.colorRole),
    selector: selector,
    sectionHint: _strings(jsonDecode(row.sectionHintJson)),
    pageHint: row.pageHint,
    anchorStatus: AnnotationAnchorStatus.fromWire(row.anchorStatus),
    revision: row.revision,
    deletedAt: row.deletedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    syncState: ResearchSyncState.fromWire(row.syncState),
    activeOperationId: row.activeOperationId,
  );
}

AnnotationConflict _conflictFromRow(AnnotationConflictRow row) =>
    AnnotationConflict(
      conflictId: row.conflictId,
      annotationId: row.annotationId,
      attemptedOperationId: row.attemptedOperationId,
      baseRevision: row.baseRevision,
      serverRevision: row.serverRevision,
      attemptedBody: row.attemptedBody,
      serverBody: row.serverBody,
      createdAt: row.createdAt,
      mergeState: AnnotationMergeState.fromWire(row.mergeState),
      mergedBody: row.mergedBody,
      resolvedAt: row.resolvedAt,
    );

EvidenceCard _evidenceFromRow(LocalEvidenceCardRow row) => EvidenceCard(
  id: row.cardId,
  paperId: row.paperId,
  generation: row.generation,
  title: row.title,
  claimOrQuestion: row.claimOrQuestion,
  userNote: row.userNote,
  sourceBlockIds: _strings(jsonDecode(row.sourceBlockIdsJson)),
  figureIds: _strings(jsonDecode(row.figureIdsJson)),
  tableIds: _strings(jsonDecode(row.tableIdsJson)),
  citationContextIds: _strings(jsonDecode(row.citationContextIdsJson)),
  verificationStatus: EvidenceVerificationStatus.fromWire(
    row.verificationStatus,
  ),
  revision: row.revision,
  deletedAt: row.deletedAt,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
  syncState: ResearchSyncState.fromWire(row.syncState),
  activeOperationId: row.activeOperationId,
);

MemoryItem _memoryFromRow(LocalMemoryItemRow row) => MemoryItem(
  id: row.itemId,
  paperId: row.paperId,
  generation: row.generation,
  sourceType: MemorySourceType.fromWire(row.sourceType),
  sourceId: row.sourceId,
  promptText: row.promptText,
  answerText: row.answerText,
  status: MemoryStatus.fromWire(row.status),
  nextReviewAt: row.nextReviewAt,
  reviewCount: row.reviewCount,
  revision: row.revision,
  deletedAt: row.deletedAt,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
  syncState: ResearchSyncState.fromWire(row.syncState),
  activeOperationId: row.activeOperationId,
);

ResearchOutboxEntry _outboxFromRow(ResearchOutboxRow row) =>
    ResearchOutboxEntry(
      accountId: row.accountId,
      operationId: row.operationId,
      entityKind: ResearchEntityKind.values.byName(row.entityKind),
      entityId: row.entityId,
      operation: ResearchOutboxOperation.values.byName(row.operation),
      baseRevision: row.baseRevision,
      payload: _map(jsonDecode(row.payloadJson)),
      state: ResearchOutboxState.values.byName(row.state),
      attemptCount: row.attemptCount,
      lastErrorCode: row.lastErrorCode,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected JSON object.');
}

List<String> _strings(Object? value) {
  if (value is! List) throw const FormatException('Expected JSON list.');
  return value
      .map((item) {
        if (item is! String) {
          throw const FormatException('Expected string item.');
        }
        return item;
      })
      .toList(growable: false);
}
