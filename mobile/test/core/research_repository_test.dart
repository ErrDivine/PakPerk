import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/api/transport_network_status.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/research_cache_dao.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/evidence_card.dart';
import 'package:pakperk/core/models/research_memory.dart';
import 'package:pakperk/core/research/research_api.dart';
import 'package:pakperk/core/research/research_repository.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

void main() {
  late PakPerkDatabase database;
  late ResearchCacheDao cache;
  late TransportNetworkStatus network;
  late _ResearchRemoteFake remote;
  late bool current;
  late ResearchRequestScope scope;

  setUp(() {
    database = PakPerkDatabase(NativeDatabase.memory());
    cache = ResearchCacheDao(database);
    network = TransportNetworkStatus()..markOffline();
    remote = _ResearchRemoteFake();
    current = true;
    scope = ResearchRequestScope(
      accountId: accountId,
      authEpoch: 8,
      paperId: paperId,
      generation: 2,
      isCurrent: () => current,
    );
  });

  tearDown(() async {
    network.dispose();
    await database.close();
  });

  test('offline create restores and replays one stable operation ID', () async {
    final firstRepository = ResearchRepository(
      remote: remote,
      cache: cache,
      networkStatus: network,
    );
    final local = await firstRepository.createAnnotation(
      scope: scope,
      blockId: blockId,
      kind: AnnotationKind.note,
      selector: const TextQuotePositionSelector(exact: 'exact source'),
      body: 'offline note',
    );
    final operationId = local.activeOperationId!;

    expect(remote.annotationWrites, isEmpty);
    expect(
      (await cache.pendingOperations(accountId)).single.operationId,
      operationId,
    );

    final restartedRepository = ResearchRepository(
      remote: remote,
      cache: ResearchCacheDao(database),
      networkStatus: network..markOnline(),
    );
    final firstSync = await restartedRepository.restoreAndSync(scope);
    final secondSync = await restartedRepository.restoreAndSync(scope);

    expect(firstSync.applied, 1);
    expect(secondSync.attempted, 0);
    expect(remote.annotationWrites, [operationId]);
    expect(await cache.pendingOperations(accountId), isEmpty);
    final settled = await cache.annotation(
      accountId: accountId,
      annotationId: local.id,
    );
    expect(settled!.revision, 1);
    expect(settled.syncState, ResearchSyncState.clean);
  });

  test(
    'account cleanup cannot be followed by a late research settle write',
    () async {
      final barrier = AccountDataWriteBarrier();
      final started = Completer<void>();
      final release = Completer<void>();
      remote
        ..annotationWriteStarted = started
        ..annotationWriteRelease = release;
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
        accountWrites: barrier,
      );
      final local = await repository.createAnnotation(
        scope: scope,
        blockId: blockId,
        kind: AnnotationKind.note,
        selector: const TextQuotePositionSelector(exact: 'exact source'),
        body: 'private note',
      );

      network.markOnline();
      final sync = repository.syncPending(scope);
      await started.future;
      current = false;
      final accounts = AccountCacheDao(database);
      await barrier.clear(
        accountId: accountId,
        invalidatedThroughEpoch: scope.authEpoch,
        clearAccount: accounts.clearAccountData,
        clearAll: accounts.clearAllAccountData,
      );
      release.complete();

      final report = await sync;
      expect(report.interrupted, isTrue);
      expect(report.applied, 0);
      expect(
        await cache.annotation(accountId: accountId, annotationId: local.id),
        isNull,
      );
      expect(await cache.pendingOperations(accountId), isEmpty);
    },
  );

  test(
    'generation-mismatched response is fenced and never settles local row',
    () async {
      final repository = ResearchRepository(
        remote: remote..responseGeneration = 3,
        cache: cache,
        networkStatus: network,
      );
      final local = await repository.createAnnotation(
        scope: scope,
        blockId: blockId,
        kind: AnnotationKind.highlight,
        selector: const TextQuotePositionSelector(exact: 'exact source'),
      );

      network.markOnline();
      final report = await repository.restoreAndSync(scope);

      expect(report.interrupted, isTrue);
      expect(report.applied, 0);
      expect(
        (await cache.pendingOperations(accountId)).single.state,
        ResearchOutboxState.queued,
      );
      expect(
        (await cache.annotation(
          accountId: accountId,
          annotationId: local.id,
        ))!.syncState,
        ResearchSyncState.pending,
      );
    },
  );

  test(
    '409 conflict preserves attempted and server bodies for merge review',
    () async {
      remote.conflictBody = 'server note';
      final telemetry = _RecordingTelemetrySink();
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
        telemetry: RedactingTelemetrySink(telemetry),
      );
      final local = await repository.createAnnotation(
        scope: scope,
        blockId: blockId,
        kind: AnnotationKind.note,
        selector: const TextQuotePositionSelector(exact: 'exact source'),
        body: 'attempted note',
      );

      network.markOnline();
      final report = await repository.restoreAndSync(scope);
      final conflicts = await cache.watchUnresolvedConflicts(accountId).first;

      expect(report.conflicts, 1);
      expect(conflicts.single.attemptedBody, 'attempted note');
      expect(conflicts.single.serverBody, 'server note');
      expect(
        (await cache.annotation(
          accountId: accountId,
          annotationId: local.id,
        ))!.syncState,
        ResearchSyncState.conflict,
      );
      expect(
        telemetry.events
            .singleWhere(
              (event) =>
                  event.$1 == PakPerkTelemetryEvent.annotationSyncOutcome,
            )
            .$2,
        const {
          'action': 'create',
          'outcome': 'conflict',
          'strategy': 'not_applicable',
          'offline': false,
        },
      );
    },
  );

  test(
    'conflict stays open until the server atomically accepts merge',
    () async {
      remote.conflictBody = 'server note';
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
      );
      final local = await repository.createAnnotation(
        scope: scope,
        blockId: blockId,
        kind: AnnotationKind.note,
        selector: const TextQuotePositionSelector(exact: 'exact source'),
        body: 'attempted note',
      );
      network.markOnline();
      await repository.restoreAndSync(scope);
      final conflict =
          (await cache.watchUnresolvedConflicts(accountId).first).single;
      final conflicted = (await cache.annotation(
        accountId: accountId,
        annotationId: local.id,
      ))!;

      network.markOffline();
      remote.conflictBody = null;
      await repository.mergeConflict(
        scope: scope,
        annotation: conflicted,
        conflict: conflict,
        mergedBody: 'lossless merged note',
      );
      expect(
        await cache.watchUnresolvedConflicts(accountId).first,
        hasLength(1),
      );

      network.markOnline();
      final restarted = ResearchRepository(
        remote: remote,
        cache: ResearchCacheDao(database),
        networkStatus: network,
      );
      await restarted.restoreAndSync(scope);

      expect(remote.resolvedConflictIds, [conflict.conflictId]);
      expect(await cache.watchUnresolvedConflicts(accountId).first, isEmpty);
      final conflictRow = await database
          .select(database.annotationConflicts)
          .getSingle();
      expect(conflictRow.attemptedBody, 'attempted note');
      expect(conflictRow.serverBody, 'server note');
      expect(conflictRow.mergedBody, 'lossless merged note');
      expect(
        (await cache.annotation(
          accountId: accountId,
          annotationId: local.id,
        ))!.syncState,
        ResearchSyncState.clean,
      );
    },
  );

  test('paper refresh restores every annotation and evidence page', () async {
    remote.annotationPages.addAll([
      AnnotationPage(
        items: [_remoteAnnotation(annotationPageOneId, revision: 1)],
        nextAfterRevision: 1,
        hasMore: true,
        syncRevision: 2,
        purgedThroughRevision: 0,
      ),
      AnnotationPage(
        items: [_remoteAnnotation(annotationPageTwoId, revision: 2)],
        nextAfterRevision: 2,
        hasMore: false,
        syncRevision: 2,
        purgedThroughRevision: 0,
      ),
    ]);
    remote.evidencePages.addAll([
      EvidenceCardPage(
        items: [_remoteEvidence(evidencePageOneId, revision: 1)],
        nextCursor: 'page-two',
        syncRevision: 2,
      ),
      EvidenceCardPage(
        items: [_remoteEvidence(evidencePageTwoId, revision: 2)],
        nextCursor: null,
        syncRevision: 2,
      ),
    ]);
    final repository = ResearchRepository(
      remote: remote,
      cache: cache,
      networkStatus: network..markOnline(),
    );

    await repository.refreshPaperResearch(scope);

    expect(remote.annotationPageCalls, 2);
    expect(remote.evidencePageCalls, 2);
    expect(
      await cache.annotationsForPaper(accountId: accountId, paperId: paperId),
      hasLength(2),
    );
    expect(
      await cache.evidenceForPaper(accountId: accountId, paperId: paperId),
      hasLength(2),
    );
  });

  test(
    'mobile import uploads only the annotation-bearing archive subset',
    () async {
      remote.annotationPages.add(
        const AnnotationPage(
          items: [],
          nextAfterRevision: 0,
          hasMore: false,
          syncRevision: 0,
          purgedThroughRevision: 0,
        ),
      );
      remote.evidencePages.add(
        const EvidenceCardPage(items: [], nextCursor: null, syncRevision: 0),
      );
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network..markOnline(),
      );

      await repository.importAnnotationArchive(
        scope: scope,
        encodedArchive: jsonEncode({
          'schema_version': 'pakperk.research-export.v1',
          'annotations': <Object?>[],
          'annotation_conflicts': <Object?>[],
          'annotation_reanchor_attempts': <Object?>[],
          'evidence_cards': [
            {'user_note': 'PRIVATE EVIDENCE MUST NOT TRANSIT'},
          ],
          'assistant_messages': [
            {'content': 'PRIVATE ASSISTANT MUST NOT TRANSIT'},
          ],
        }),
      );

      expect(remote.importedArchive!.keys, {
        'schema_version',
        'annotations',
        'annotation_conflicts',
        'annotation_reanchor_attempts',
      });
      expect(jsonEncode(remote.importedArchive), isNot(contains('PRIVATE')));
    },
  );

  test(
    'imported unresolved conflict resolves against refreshed revision',
    () async {
      final importedAnnotation = _remoteAnnotation(
        importedAnnotationId,
        revision: 41,
      );
      remote.annotationPages.add(
        AnnotationPage(
          items: [importedAnnotation],
          nextAfterRevision: 41,
          hasMore: false,
          syncRevision: 41,
          purgedThroughRevision: 0,
        ),
      );
      remote.evidencePages.add(
        const EvidenceCardPage(items: [], nextCursor: null, syncRevision: 41),
      );
      remote.remoteConflicts[importedConflictId] = AnnotationConflictSyncItem(
        conflict: AnnotationConflict(
          conflictId: importedConflictId,
          annotationId: importedAnnotationId,
          attemptedOperationId: importedAttemptOperationId,
          baseRevision: 6,
          serverRevision: 7,
          attemptedBody: 'archived attempted body',
          serverBody: 'archived server body',
          createdAt: DateTime.utc(2026, 8, 30),
          mergeState: AnnotationMergeState.unresolved,
        ),
        paperId: paperId,
        currentAnnotationRevision: 41,
      );
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network..markOnline(),
      );

      await repository.importAnnotationArchive(
        scope: scope,
        encodedArchive: jsonEncode({
          'schema_version': 'pakperk.research-export.v1',
          'annotations': [importedAnnotation.copyWith(revision: 7).toJson()],
          'annotation_conflicts': [
            {
              'conflict_id': importedConflictId,
              'annotation_id': importedAnnotationId,
              'attempted_operation_id': importedAttemptOperationId,
              'base_revision': 6,
              'server_revision': 7,
              'attempted_body': 'archived attempted body',
              'server_body': 'archived server body',
              'created_at': DateTime.utc(2026, 8, 30).toIso8601String(),
              'resolution': null,
              'merged_body': null,
              'resolved_at': null,
            },
          ],
          'annotation_reanchor_attempts': <Object?>[],
        }),
      );

      final conflict =
          (await cache.watchUnresolvedConflicts(accountId).first).single;
      expect(conflict.serverRevision, 41);
      expect(conflict.attemptedBody, 'archived attempted body');
      expect(conflict.serverBody, 'archived server body');
      final current = (await cache.annotation(
        accountId: accountId,
        annotationId: importedAnnotationId,
      ))!;

      network.markOffline();
      await repository.mergeConflict(
        scope: scope,
        annotation: current,
        conflict: conflict,
        mergedBody: 'merged after import',
      );
      final restarted = ResearchRepository(
        remote: remote,
        cache: ResearchCacheDao(database),
        networkStatus: network..markOnline(),
      );
      await restarted.restoreAndSync(scope);

      expect(remote.resolvedConflictIds, [importedConflictId]);
      expect(remote.annotationBaseRevisions, [41]);
      expect(await cache.watchUnresolvedConflicts(accountId).first, isEmpty);
    },
  );

  test(
    'restart after two-paper import commit recovers every unresolved conflict',
    () async {
      final firstConflict = AnnotationConflictSyncItem(
        conflict: AnnotationConflict(
          conflictId: importedConflictId,
          annotationId: importedAnnotationId,
          attemptedOperationId: importedAttemptOperationId,
          baseRevision: 6,
          serverRevision: 7,
          attemptedBody: 'first archived attempt',
          serverBody: 'first archived server body',
          createdAt: DateTime.utc(2026, 8, 29),
          mergeState: AnnotationMergeState.unresolved,
        ),
        paperId: paperId,
        currentAnnotationRevision: 41,
      );
      final secondConflict = AnnotationConflictSyncItem(
        conflict: AnnotationConflict(
          conflictId: secondImportedConflictId,
          annotationId: secondImportedAnnotationId,
          attemptedOperationId: secondImportedAttemptOperationId,
          baseRevision: 2,
          serverRevision: 3,
          attemptedBody: 'second archived attempt',
          serverBody: 'second archived server body',
          createdAt: DateTime.utc(2026, 8, 30),
          mergeState: AnnotationMergeState.unresolved,
        ),
        paperId: secondPaperId,
        currentAnnotationRevision: 42,
      );
      remote.conflictPages.addAll([
        AnnotationConflictPage(
          items: [firstConflict],
          nextCursor: 'second-conflict-page',
          syncRevision: 42,
        ),
        AnnotationConflictPage(
          items: [secondConflict],
          nextCursor: null,
          syncRevision: 42,
        ),
      ]);
      final restarted = ResearchRepository(
        remote: remote,
        cache: ResearchCacheDao(database),
        networkStatus: network..markOnline(),
      );

      // The import response was committed remotely, then the prior process
      // terminated before writing any local annotation or conflict row.
      await restarted.restoreAndSync(scope);

      expect(remote.conflictPageCalls, 2);
      final recoveredRows = await database
          .select(database.annotationConflicts)
          .get();
      expect(recoveredRows, hasLength(2));
      expect(recoveredRows.map((row) => row.serverRevision).toSet(), {41, 42});

      remote.annotationPages.add(
        AnnotationPage(
          items: [_remoteAnnotation(importedAnnotationId, revision: 41)],
          nextAfterRevision: 41,
          hasMore: false,
          syncRevision: 42,
          purgedThroughRevision: 0,
        ),
      );
      remote.evidencePages.add(
        const EvidenceCardPage(items: [], nextCursor: null, syncRevision: 42),
      );
      await restarted.refreshPaperResearch(scope);
      final currentPaperConflicts = await cache
          .watchUnresolvedConflicts(accountId, paperId: paperId)
          .first;
      expect(currentPaperConflicts.single.conflictId, importedConflictId);
      expect(currentPaperConflicts.single.serverRevision, 41);
    },
  );

  test(
    'conflict restore restarts once when a snapshot cursor expires',
    () async {
      final firstPage = AnnotationConflictPage(
        items: [
          _remoteConflict(
            conflictId: importedConflictId,
            annotationId: importedAnnotationId,
            operationId: importedAttemptOperationId,
            paperId: paperId,
            historicalRevision: 7,
            currentRevision: 41,
          ),
        ],
        nextCursor: 'second-conflict-page',
        syncRevision: 42,
      );
      final secondPage = AnnotationConflictPage(
        items: [
          _remoteConflict(
            conflictId: secondImportedConflictId,
            annotationId: secondImportedAnnotationId,
            operationId: secondImportedAttemptOperationId,
            paperId: secondPaperId,
            historicalRevision: 3,
            currentRevision: 42,
          ),
        ],
        nextCursor: null,
        syncRevision: 42,
      );
      remote
        ..conflictPages.addAll([firstPage, secondPage])
        ..conflictRestartPage = firstPage
        ..failNextConflictContinuation = true;
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network..markOnline(),
      );

      await repository.refreshUnresolvedConflicts(scope);

      expect(remote.conflictPageCalls, 4);
      expect(
        await database.select(database.annotationConflicts).get(),
        hasLength(2),
      );
    },
  );

  test(
    'memory creation is explicit and does not create Library state',
    () async {
      final telemetry = _RecordingTelemetrySink();
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
        telemetry: RedactingTelemetrySink(telemetry),
      );
      final item = await repository.createMemoryItem(
        scope: scope,
        sourceType: MemorySourceType.annotation,
        sourceId: annotationSourceId,
        promptText: 'What did I select?',
        answerText: 'Only this user-selected source.',
      );

      expect(item.sourceType, MemorySourceType.annotation);
      expect(item.status, MemoryStatus.active);
      expect(await database.select(database.libraryItems).get(), isEmpty);
      expect(await cache.memoryItems(accountId: accountId), hasLength(1));
      final operation = (await cache.pendingOperations(accountId)).single;
      expect(operation.payload['paper_id'], paperId);
      expect(operation.payload['generation'], 2);
      expect(telemetry.events.single.$1, PakPerkTelemetryEvent.memoryLifecycle);
      expect(telemetry.events.single.$2, const <String, Object?>{
        'action': 'create',
        'source_type': 'annotation',
        'offline': true,
      });
    },
  );

  test(
    'evidence create dispatches server-bounded Unicode scalar fields',
    () async {
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
      );
      final title = _scalars(evidenceCardTitleMaximumScalars);
      final claim = _scalars(evidenceCardClaimMaximumScalars);
      final local = await repository.createEvidenceCard(
        scope: scope,
        title: title,
        claimOrQuestion: claim,
        userNote: '  bounded note  ',
      );

      final report = await repository.restoreAndSync(
        scope,
      ); // Offline restore intentionally leaves the durable write queued.
      expect(report.interrupted, isTrue);
      network.markOnline();
      final online = await repository.restoreAndSync(scope);

      expect(online.applied, 1);
      expect(remote.evidenceWrites.single.create, isTrue);
      expect(remote.evidenceWrites.single.write.card.id, local.id);
      expect(remote.evidenceWrites.single.write.card.title, title);
      expect(remote.evidenceWrites.single.write.card.claimOrQuestion, claim);
      expect(remote.evidenceWrites.single.write.card.userNote, 'bounded note');
      expect(await cache.pendingOperations(accountId), isEmpty);
    },
  );

  test('evidence create and update reject server-invalid fields', () async {
    final repository = ResearchRepository(
      remote: remote,
      cache: cache,
      networkStatus: network,
    );
    await expectLater(
      repository.createEvidenceCard(scope: scope, title: 'bad\u0000title'),
      throwsArgumentError,
    );
    await expectLater(
      repository.createEvidenceCard(
        scope: scope,
        title: 'Valid title',
        claimOrQuestion: _scalars(evidenceCardClaimMaximumScalars + 1),
      ),
      throwsArgumentError,
    );
    final card = _remoteEvidence(evidencePageOneId, revision: 2);
    await expectLater(
      repository.updateEvidenceCard(
        scope: scope,
        card: card,
        title: _scalars(evidenceCardTitleMaximumScalars + 1),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.updateEvidenceCard(
        scope: scope,
        card: card,
        title: 'Valid title',
        userNote: 'bad\u0000note',
      ),
      throwsArgumentError,
    );

    expect(await cache.pendingOperations(accountId), isEmpty);
    expect(remote.evidenceWrites, isEmpty);
  });

  test(
    'active memory dispatch has no review date and exact prompt bound',
    () async {
      final repository = ResearchRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
      );
      final prompt = _scalars(memoryPromptMaximumScalars);
      final local = await repository.createMemoryItem(
        scope: scope,
        sourceType: MemorySourceType.annotation,
        sourceId: annotationSourceId,
        promptText: prompt,
        answerText: '  remembered answer  ',
      );
      expect(local.status, MemoryStatus.active);
      expect(local.nextReviewAt, isNull);

      network.markOnline();
      final report = await repository.restoreAndSync(scope);

      expect(report.applied, 1);
      expect(remote.memoryWrites.single.create, isTrue);
      expect(remote.memoryWrites.single.write.item.id, local.id);
      expect(remote.memoryWrites.single.write.item.promptText, prompt);
      expect(
        remote.memoryWrites.single.write.item.answerText,
        'remembered answer',
      );
      expect(remote.memoryWrites.single.write.item.status, MemoryStatus.active);
      expect(remote.memoryWrites.single.write.item.nextReviewAt, isNull);
      expect(await database.select(database.libraryItems).get(), isEmpty);
    },
  );

  test('memory writes reject invalid text and schedule combinations', () async {
    final repository = ResearchRepository(
      remote: remote,
      cache: cache,
      networkStatus: network,
    );
    await expectLater(
      repository.createMemoryItem(
        scope: scope,
        sourceType: MemorySourceType.annotation,
        sourceId: annotationSourceId,
        promptText: _scalars(memoryPromptMaximumScalars + 1),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.createMemoryItem(
        scope: scope,
        sourceType: MemorySourceType.annotation,
        sourceId: annotationSourceId,
        answerText: 'bad\u0000answer',
      ),
      throwsArgumentError,
    );
    final item = _remoteMemory(
      memoryPageOneId,
      paperId: paperId,
    ).copyWith(clearNextReviewAt: true);
    await expectLater(
      repository.reviewMemoryItem(
        scope: scope,
        item: item,
        status: MemoryStatus.active,
        nextReviewAt: DateTime.utc(2026, 9, 1),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.reviewMemoryItem(
        scope: scope,
        item: item,
        status: MemoryStatus.snoozed,
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.reviewMemoryItem(
        scope: scope,
        item: item,
        status: MemoryStatus.retired,
        nextReviewAt: DateTime.utc(2026, 9, 1),
      ),
      throwsArgumentError,
    );

    expect(await cache.pendingOperations(accountId), isEmpty);
    expect(remote.memoryWrites, isEmpty);
  });

  test('account memory refresh restores every page across papers', () async {
    remote.memoryPages.addAll([
      MemoryPage(
        items: [_remoteMemory(memoryPageOneId, paperId: paperId)],
        nextCursor: 'memory-page-two',
        syncRevision: 8,
      ),
      MemoryPage(
        items: [_remoteMemory(memoryPageTwoId, paperId: secondPaperId)],
        nextCursor: null,
        syncRevision: 8,
      ),
    ]);
    final repository = ResearchRepository(
      remote: remote,
      cache: cache,
      networkStatus: network..markOnline(),
    );

    await repository.refreshMemoryForAccount(
      ResearchAccountRequestScope(
        accountId: accountId,
        authEpoch: 8,
        isCurrent: () => current,
      ),
    );

    expect(remote.memoryPageCalls, 2);
    final restored = await cache.memoryItems(accountId: accountId);
    expect(restored.map((item) => item.id), {memoryPageOneId, memoryPageTwoId});
    expect(restored.map((item) => item.paperId).toSet(), {
      paperId,
      secondPaperId,
    });
    expect(await database.select(database.libraryItems).get(), isEmpty);
  });
}

final class _ResearchRemoteFake implements ResearchRemoteDataSource {
  final List<String> annotationWrites = [];
  final List<int> annotationBaseRevisions = [];
  final List<String> resolvedConflictIds = [];
  final List<AnnotationPage> annotationPages = [];
  final List<AnnotationConflictPage> conflictPages = [];
  final List<EvidenceCardPage> evidencePages = [];
  final List<MemoryPage> memoryPages = [];
  final List<({EvidenceCardWrite write, bool create})> evidenceWrites = [];
  final List<({MemoryItemWrite write, bool create})> memoryWrites = [];
  final Map<String, AnnotationConflictSyncItem> remoteConflicts = {};
  AnnotationConflictPage? conflictRestartPage;
  bool failNextConflictContinuation = false;
  int responseGeneration = 2;
  String? conflictBody;
  int annotationPageCalls = 0;
  int conflictPageCalls = 0;
  int evidencePageCalls = 0;
  int memoryPageCalls = 0;
  Map<String, dynamic>? importedArchive;
  Completer<void>? annotationWriteStarted;
  Completer<void>? annotationWriteRelease;

  @override
  Future<AnnotationPage> listAnnotations({
    required int expectedAuthEpoch,
    String? paperId,
    int afterRevision = 0,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    annotationPageCalls += 1;
    return annotationPages.removeAt(0);
  }

  @override
  Future<AnnotationConflictPage> listAnnotationConflicts({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
    RequestCancellation? cancellation,
  }) async {
    conflictPageCalls += 1;
    if (cursor != null && failNextConflictContinuation) {
      failNextConflictContinuation = false;
      final restartPage = conflictRestartPage;
      if (restartPage != null) conflictPages.insert(0, restartPage);
      throw const ApiException(
        code: 'INVALID_RESEARCH_CURSOR',
        message: 'The conflict snapshot changed.',
        statusCode: 400,
        retryable: true,
      );
    }
    if (conflictPages.isNotEmpty) return conflictPages.removeAt(0);
    return AnnotationConflictPage(
      items: remoteConflicts.values.toList(growable: false),
      nextCursor: null,
      syncRevision: remoteConflicts.values.fold<int>(
        0,
        (value, item) => value > item.currentAnnotationRevision
            ? value
            : item.currentAnnotationRevision,
      ),
    );
  }

  @override
  Future<EvidenceCardPage> listEvidenceCards({
    required int expectedAuthEpoch,
    String? paperId,
    String? cursor,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    evidencePageCalls += 1;
    return evidencePages.removeAt(0);
  }

  @override
  Future<MemoryPage> listMemoryReview({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 50,
    RequestCancellation? cancellation,
  }) async {
    memoryPageCalls += 1;
    return memoryPages.removeAt(0);
  }

  @override
  Future<EvidenceCard> putEvidenceCard({
    required EvidenceCardWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    evidenceWrites.add((write: write, create: create));
    return write.card.copyWith(
      revision: write.baseRevision + 1,
      syncState: ResearchSyncState.clean,
      clearActiveOperationId: true,
    );
  }

  @override
  Future<MemoryItem> putMemoryItem({
    required MemoryItemWrite write,
    required bool create,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    memoryWrites.add((write: write, create: create));
    return write.item.copyWith(
      revision: write.baseRevision + 1,
      syncState: ResearchSyncState.clean,
      clearActiveOperationId: true,
    );
  }

  @override
  Future<ResearchAnnotationImportResult> importAnnotations({
    required Map<String, dynamic> archive,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    importedArchive = archive;
    return const ResearchAnnotationImportResult(
      importedAnnotations: 0,
      importedConflicts: 0,
      importedReanchorAttempts: 0,
      skippedAnnotations: 0,
      replayed: false,
    );
  }

  @override
  Future<AnnotationMutationResult> putAnnotation({
    required AnnotationWrite write,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    annotationWrites.add(write.operationId);
    annotationBaseRevisions.add(write.baseRevision);
    annotationWriteStarted?.complete();
    if (annotationWriteRelease case final release?) await release.future;
    if (write.resolvesConflictId case final conflictId?) {
      resolvedConflictIds.add(conflictId);
      remoteConflicts.remove(conflictId);
    }
    final serverBody = conflictBody;
    if (serverBody != null) {
      final conflict = AnnotationConflict(
        conflictId: conflictId,
        annotationId: write.annotation.id,
        attemptedOperationId: write.operationId,
        baseRevision: write.baseRevision,
        serverRevision: write.baseRevision + 1,
        attemptedBody: write.annotation.body,
        serverBody: serverBody,
        createdAt: DateTime.utc(2026, 8, 31),
        mergeState: AnnotationMergeState.unresolved,
      );
      remoteConflicts[conflict.conflictId] = AnnotationConflictSyncItem(
        conflict: conflict,
        paperId: write.annotation.paperId,
        currentAnnotationRevision: write.baseRevision + 1,
      );
      return AnnotationMutationConflict(conflict);
    }
    return AnnotationMutationApplied(
      write.annotation.copyWith(
        generation: responseGeneration,
        revision: write.baseRevision + 1,
        syncState: ResearchSyncState.clean,
        clearActiveOperationId: true,
      ),
      replayed: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Annotation _remoteAnnotation(String id, {required int revision}) {
  final now = DateTime.utc(2026, 8, 31);
  return Annotation(
    id: id,
    paperId: paperId,
    generation: 2,
    blockId: blockId,
    kind: AnnotationKind.highlight,
    selector: const TextQuotePositionSelector(exact: 'exact source'),
    anchorStatus: AnnotationAnchorStatus.anchored,
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

EvidenceCard _remoteEvidence(String id, {required int revision}) {
  final now = DateTime.utc(2026, 8, 31);
  return EvidenceCard(
    id: id,
    paperId: paperId,
    generation: 2,
    title: 'Evidence $revision',
    verificationStatus: EvidenceVerificationStatus.userSelected,
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

MemoryItem _remoteMemory(String id, {required String paperId}) {
  final now = DateTime.utc(2026, 8, 31);
  return MemoryItem(
    id: id,
    paperId: paperId,
    generation: 2,
    sourceType: MemorySourceType.annotation,
    sourceId: annotationSourceId,
    promptText: 'Why did I save this?',
    answerText: 'Because it is exact user-selected evidence.',
    status: MemoryStatus.active,
    nextReviewAt: now,
    reviewCount: 0,
    revision: 1,
    createdAt: now,
    updatedAt: now,
  );
}

AnnotationConflictSyncItem _remoteConflict({
  required String conflictId,
  required String annotationId,
  required String operationId,
  required String paperId,
  required int historicalRevision,
  required int currentRevision,
}) => AnnotationConflictSyncItem(
  conflict: AnnotationConflict(
    conflictId: conflictId,
    annotationId: annotationId,
    attemptedOperationId: operationId,
    baseRevision: historicalRevision - 1,
    serverRevision: historicalRevision,
    attemptedBody: 'archived attempt',
    serverBody: 'archived server body',
    createdAt: DateTime.utc(2026, 8, 30),
    mergeState: AnnotationMergeState.unresolved,
  ),
  paperId: paperId,
  currentAnnotationRevision: currentRevision,
);

final class _RecordingTelemetrySink implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map<String, Object?>.from(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

const accountId = '00000000-0000-4000-8000-000000000001';
const paperId = '00000000-0000-4000-8000-000000000010';
const blockId = '00000000-0000-4000-8000-000000000020';
const annotationSourceId = '00000000-0000-4000-8000-000000000030';
const conflictId = '00000000-0000-7000-8000-000000000040';
const annotationPageOneId = '00000000-0000-4000-8000-000000000041';
const annotationPageTwoId = '00000000-0000-4000-8000-000000000042';
const evidencePageOneId = '00000000-0000-4000-8000-000000000043';
const evidencePageTwoId = '00000000-0000-4000-8000-000000000044';
const importedAnnotationId = '00000000-0000-4000-8000-000000000045';
const importedConflictId = '00000000-0000-7000-8000-000000000046';
const importedAttemptOperationId = '00000000-0000-7000-8000-000000000047';
const secondPaperId = '00000000-0000-4000-8000-000000000048';
const secondImportedAnnotationId = '00000000-0000-4000-8000-000000000049';
const secondImportedConflictId = '00000000-0000-7000-8000-000000000050';
const secondImportedAttemptOperationId = '00000000-0000-7000-8000-000000000051';
const memoryPageOneId = '00000000-0000-4000-8000-000000000052';
const memoryPageTwoId = '00000000-0000-4000-8000-000000000053';

String _scalars(int count) => List.filled(count, '🧪', growable: false).join();
