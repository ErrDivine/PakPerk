import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/research_cache_dao.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/evidence_card.dart';
import 'package:pakperk/core/models/research_memory.dart';

void main() {
  late PakPerkDatabase database;
  late ResearchCacheDao cache;

  setUp(() {
    database = PakPerkDatabase(NativeDatabase.memory());
    cache = ResearchCacheDao(database);
  });

  tearDown(() => database.close());

  test(
    'optimistic annotation and stable operation survive DAO restart',
    () async {
      final annotation = _annotation();
      final operation = _operation(
        entityKind: ResearchEntityKind.annotation,
        entityId: annotation.id,
      );
      await cache.persistOptimisticAnnotation(
        accountId: accountA,
        annotation: annotation,
        operation: operation,
      );
      await cache.markOperationInFlight(operation);

      final restarted = ResearchCacheDao(database);
      await restarted.restoreInterruptedOperations(accountA);
      final restored = await restarted.annotationsForPaper(
        accountId: accountA,
        paperId: paperId,
      );
      final outbox = await restarted.pendingOperations(accountA);

      expect(restored.single.body, 'my private note');
      expect(restored.single.syncState, ResearchSyncState.pending);
      expect(outbox.single.operationId, operationId);
      expect(outbox.single.state, ResearchOutboxState.queued);
      expect(
        await restarted.annotationsForPaper(
          accountId: accountB,
          paperId: paperId,
        ),
        isEmpty,
      );
    },
  );

  test(
    'conflict retains both note bodies through explicit resolution',
    () async {
      final annotation = _annotation();
      await cache.persistOptimisticAnnotation(
        accountId: accountA,
        annotation: annotation,
        operation: _operation(
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
        ),
      );
      final conflict = AnnotationConflict(
        conflictId: conflictId,
        annotationId: annotation.id,
        attemptedOperationId: operationId,
        baseRevision: 3,
        serverRevision: 4,
        attemptedBody: 'my private note',
        serverBody: 'note from the other device',
        createdAt: now,
        mergeState: AnnotationMergeState.unresolved,
      );
      await cache.recordAnnotationConflict(
        accountId: accountA,
        conflict: conflict,
      );

      final unresolved = await cache.watchUnresolvedConflicts(accountA).first;
      expect(unresolved.single.attemptedBody, 'my private note');
      expect(unresolved.single.serverBody, 'note from the other device');
      expect(
        (await cache.annotation(
          accountId: accountA,
          annotationId: annotation.id,
        ))!.syncState,
        ResearchSyncState.conflict,
      );

      await cache.resolveConflict(
        accountId: accountA,
        resolved: conflict.resolve('merged without data loss', now),
      );
      expect(await cache.watchUnresolvedConflicts(accountA).first, isEmpty);
      final row = await database
          .select(database.annotationConflicts)
          .getSingle();
      expect(row.attemptedBody, 'my private note');
      expect(row.serverBody, 'note from the other device');
      expect(row.mergedBody, 'merged without data loss');
      expect(row.mergeState, 'resolved');
    },
  );

  test(
    'annotation tombstone remains after ack while outbox is removed',
    () async {
      final annotation = _annotation().copyWith(deletedAt: now);
      await cache.persistOptimisticAnnotation(
        accountId: accountA,
        annotation: annotation,
        operation: _operation(
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
          operation: ResearchOutboxOperation.delete,
        ),
      );
      await cache.settleAnnotation(
        accountId: accountA,
        operationId: operationId,
        canonical: annotation.copyWith(
          revision: 5,
          syncState: ResearchSyncState.clean,
        ),
      );

      expect(
        await cache.annotationsForPaper(accountId: accountA, paperId: paperId),
        isEmpty,
      );
      final tombstones = await cache.annotationsForPaper(
        accountId: accountA,
        paperId: paperId,
        includeDeleted: true,
      );
      expect(tombstones.single.isDeleted, isTrue);
      expect(await cache.pendingOperations(accountA), isEmpty);
    },
  );

  test(
    'evidence and memory are account scoped and account cleanup is complete',
    () async {
      final evidence = _evidence();
      final memory = _memory(sourceId: evidence.id);
      await cache.persistOptimisticEvidence(
        accountId: accountA,
        card: evidence,
        operation: _operation(
          entityKind: ResearchEntityKind.evidenceCard,
          entityId: evidence.id,
        ),
      );
      await cache.persistOptimisticMemory(
        accountId: accountA,
        item: memory,
        operation: _operation(
          operationIdOverride: memoryOperationId,
          entityKind: ResearchEntityKind.memoryItem,
          entityId: memory.id,
        ),
      );

      expect(
        await cache.evidenceForPaper(accountId: accountA, paperId: paperId),
        hasLength(1),
      );
      expect(await cache.memoryItems(accountId: accountA), hasLength(1));
      expect(
        await cache.evidenceForPaper(accountId: accountB, paperId: paperId),
        isEmpty,
      );

      await AccountCacheDao(database).clearAccountData(accountA);

      expect(
        await cache.evidenceForPaper(accountId: accountA, paperId: paperId),
        isEmpty,
      );
      expect(await cache.memoryItems(accountId: accountA), isEmpty);
      expect(await cache.pendingOperations(accountA), isEmpty);
      expect(
        await database.select(database.annotationConflicts).get(),
        isEmpty,
      );
    },
  );

  test(
    'complete snapshots remove clean rows deleted on another device',
    () async {
      final annotation = _annotation();
      await cache.persistOptimisticAnnotation(
        accountId: accountA,
        annotation: annotation,
        operation: _operation(
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
        ),
      );
      await cache.settleAnnotation(
        accountId: accountA,
        operationId: operationId,
        canonical: annotation.copyWith(
          syncState: ResearchSyncState.clean,
          clearActiveOperationId: true,
        ),
      );
      await cache.mergeRemoteAnnotations(
        accountId: accountA,
        annotations: const [],
        syncRevision: 4,
        paperId: paperId,
        purgedThroughRevision: 3,
      );
      expect(
        await cache.annotationsForPaper(accountId: accountA, paperId: paperId),
        isEmpty,
      );

      final evidence = _evidence();
      await cache.persistOptimisticEvidence(
        accountId: accountA,
        card: evidence,
        operation: _operation(
          entityKind: ResearchEntityKind.evidenceCard,
          entityId: evidence.id,
        ),
      );
      await cache.settleEvidence(
        accountId: accountA,
        operationId: operationId,
        canonical: evidence.copyWith(
          revision: 1,
          syncState: ResearchSyncState.clean,
          clearActiveOperationId: true,
        ),
      );
      await cache.mergeRemoteEvidence(
        accountId: accountA,
        cards: const [],
        syncRevision: 1,
        paperId: paperId,
      );
      expect(
        await cache.evidenceForPaper(accountId: accountA, paperId: paperId),
        isEmpty,
      );
    },
  );

  test(
    'memory snapshot removes cross-device retired and snoozed rows but preserves pending',
    () async {
      final retiredElsewhere = _memory(
        id: retiredMemoryId,
        revision: 3,
        syncState: ResearchSyncState.clean,
      );
      final snoozedElsewhere = _memory(
        id: snoozedMemoryId,
        revision: 4,
        syncState: ResearchSyncState.clean,
      );
      await cache.mergeRemoteMemory(
        accountId: accountA,
        items: [retiredElsewhere, snoozedElsewhere],
        syncRevision: 4,
      );
      final pending = _memory(
        id: pendingMemoryId,
        operationIdOverride: pendingMemoryOperationId,
      );
      await cache.persistOptimisticMemory(
        accountId: accountA,
        item: pending,
        operation: _operation(
          operationIdOverride: pendingMemoryOperationId,
          entityKind: ResearchEntityKind.memoryItem,
          entityId: pending.id,
        ),
      );
      await cache.mergeRemoteMemory(
        accountId: accountB,
        items: [
          _memory(
            id: otherAccountMemoryId,
            revision: 4,
            syncState: ResearchSyncState.clean,
          ),
        ],
        syncRevision: 4,
      );

      // The next full eligible snapshot omits one item retired remotely and
      // one moved to a future snooze remotely.
      await cache.mergeRemoteMemory(
        accountId: accountA,
        items: const [],
        syncRevision: 5,
      );

      final remaining = await cache.memoryItems(accountId: accountA);
      expect(remaining.map((item) => item.id), [pendingMemoryId]);
      expect(remaining.single.syncState, ResearchSyncState.pending);
      expect(
        (await cache.pendingOperations(accountA)).single.operationId,
        pendingMemoryOperationId,
      );
      expect(
        (await cache.memoryItems(accountId: accountB)).single.id,
        otherAccountMemoryId,
      );
    },
  );

  test('research schema never creates a second Library authority', () async {
    for (final table in const [
      'local_annotations',
      'local_evidence_cards',
      'local_memory_items',
      'research_outbox',
      'reading_checkpoints',
    ]) {
      final rows = await database
          .customSelect('PRAGMA table_info($table)')
          .get();
      final columns = rows.map((row) => row.read<String>('name')).toSet();
      expect(columns, isNot(contains('library_state')), reason: table);
      expect(columns, isNot(contains('list_state')), reason: table);
      expect(columns, isNot(contains('queue_state')), reason: table);
    }
  });
}

const accountA = '00000000-0000-4000-8000-000000000001';
const accountB = '00000000-0000-4000-8000-000000000002';
const paperId = '00000000-0000-4000-8000-000000000010';
const annotationId = '00000000-0000-7000-8000-000000000020';
const evidenceId = '00000000-0000-7000-8000-000000000021';
const memoryId = '00000000-0000-7000-8000-000000000022';
const retiredMemoryId = '00000000-0000-7000-8000-000000000023';
const snoozedMemoryId = '00000000-0000-7000-8000-000000000024';
const pendingMemoryId = '00000000-0000-7000-8000-000000000025';
const otherAccountMemoryId = '00000000-0000-7000-8000-000000000026';
const operationId = '00000000-0000-7000-8000-000000000030';
const memoryOperationId = '00000000-0000-7000-8000-000000000031';
const pendingMemoryOperationId = '00000000-0000-7000-8000-000000000032';
const conflictId = '00000000-0000-7000-8000-000000000040';
const blockId = '00000000-0000-4000-8000-000000000050';
final now = DateTime.utc(2026, 8, 31, 12);

Annotation _annotation() => Annotation(
  id: annotationId,
  paperId: paperId,
  generation: 2,
  blockId: blockId,
  kind: AnnotationKind.note,
  body: 'my private note',
  colorRole: AnnotationColorRole.blue,
  selector: const TextQuotePositionSelector(
    exact: 'selected evidence',
    prefix: 'before ',
    suffix: ' after',
    start: 7,
    end: 24,
  ),
  anchorStatus: AnnotationAnchorStatus.anchored,
  revision: 3,
  createdAt: now,
  updatedAt: now,
  syncState: ResearchSyncState.pending,
  activeOperationId: operationId,
);

EvidenceCard _evidence() => EvidenceCard(
  id: evidenceId,
  paperId: paperId,
  generation: 2,
  title: 'Supported result',
  claimOrQuestion: 'selected evidence',
  sourceBlockIds: const [blockId],
  verificationStatus: EvidenceVerificationStatus.userSelected,
  revision: 0,
  createdAt: now,
  updatedAt: now,
  syncState: ResearchSyncState.pending,
  activeOperationId: operationId,
);

MemoryItem _memory({
  String id = memoryId,
  String sourceId = evidenceId,
  int revision = 0,
  ResearchSyncState syncState = ResearchSyncState.pending,
  String? operationIdOverride = memoryOperationId,
}) => MemoryItem(
  id: id,
  paperId: paperId,
  generation: 2,
  sourceType: MemorySourceType.evidenceCard,
  sourceId: sourceId,
  promptText: 'Which source supported the result?',
  answerText: 'The selected block.',
  status: MemoryStatus.active,
  nextReviewAt: now,
  reviewCount: 0,
  revision: revision,
  createdAt: now,
  updatedAt: now,
  syncState: syncState,
  activeOperationId: syncState == ResearchSyncState.pending
      ? operationIdOverride
      : null,
);

ResearchOutboxEntry _operation({
  required ResearchEntityKind entityKind,
  required String entityId,
  ResearchOutboxOperation operation = ResearchOutboxOperation.put,
  String operationIdOverride = operationId,
}) => ResearchOutboxEntry(
  accountId: accountA,
  operationId: operationIdOverride,
  entityKind: entityKind,
  entityId: entityId,
  operation: operation,
  baseRevision: 0,
  payload: const {'paper_id': paperId, 'create': true},
  state: ResearchOutboxState.queued,
  attemptCount: 0,
  createdAt: now,
  updatedAt: now,
);
