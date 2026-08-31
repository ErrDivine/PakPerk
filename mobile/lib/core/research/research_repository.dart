import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../account/account_data_write_barrier.dart';
import '../api/api_exception.dart';
import '../api/request_cancellation.dart';
import '../api/transport_network_status.dart';
import '../database/research_cache_dao.dart';
import '../models/annotation.dart';
import '../models/evidence_card.dart';
import '../models/research_memory.dart';
import '../models/version_diff.dart';
import '../telemetry/telemetry.dart';
import 'research_api.dart';

typedef ResearchScopeFence = bool Function();

/// Authenticated account fence for research endpoints that are deliberately
/// not paper-scoped, such as the across-paper memory review queue.
final class ResearchAccountRequestScope {
  const ResearchAccountRequestScope({
    required this.accountId,
    required this.authEpoch,
    required this.isCurrent,
  });

  final String accountId;
  final int authEpoch;
  final ResearchScopeFence isCurrent;
}

final class ResearchRequestScope {
  const ResearchRequestScope({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
    required this.generation,
    required this.isCurrent,
  });

  final String accountId;
  final int authEpoch;
  final String paperId;
  final int generation;
  final ResearchScopeFence isCurrent;

  bool acceptsPaper(String responsePaperId, int responseGeneration) =>
      isCurrent() &&
      paperId == responsePaperId &&
      generation == responseGeneration;
}

final class ResearchSyncReport {
  const ResearchSyncReport({
    required this.attempted,
    required this.applied,
    required this.conflicts,
    required this.failed,
    required this.interrupted,
  });

  final int attempted;
  final int applied;
  final int conflicts;
  final int failed;
  final bool interrupted;
}

abstract interface class ResearchDataSource {
  bool get isOffline;

  Stream<List<Annotation>> watchAnnotations(ResearchRequestScope scope);
  Stream<List<EvidenceCard>> watchEvidenceCards(ResearchRequestScope scope);
  Stream<List<MemoryItem>> watchMemoryReview(String accountId);
  Stream<List<AnnotationConflict>> watchConflicts(ResearchRequestScope scope);

  Future<Annotation> createAnnotation({
    required ResearchRequestScope scope,
    required String blockId,
    required AnnotationKind kind,
    required TextQuotePositionSelector selector,
    String? body,
    AnnotationColorRole? colorRole,
    List<String> sectionHint,
    int? pageHint,
  });

  Future<EvidenceCard> createEvidenceCard({
    required ResearchRequestScope scope,
    required String title,
    String? claimOrQuestion,
    String? userNote,
    List<String> sourceBlockIds,
    List<String> figureIds,
    List<String> tableIds,
    List<String> citationContextIds,
  });

  Future<MemoryItem> createMemoryItem({
    required ResearchRequestScope scope,
    required MemorySourceType sourceType,
    required String sourceId,
    String? promptText,
    String? answerText,
  });

  Future<ResearchSyncReport> restoreAndSync(ResearchRequestScope scope);
}

final class ResearchRepository implements ResearchDataSource {
  ResearchRepository({
    required ResearchRemoteDataSource remote,
    required ResearchCacheDao cache,
    required TransportNetworkStatus networkStatus,
    AccountDataWriteBarrier? accountWrites,
    Uuid uuid = const Uuid(),
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _remote = remote,
       _cache = cache,
       _networkStatus = networkStatus,
       _accountWrites = accountWrites ?? AccountDataWriteBarrier(),
       _uuid = uuid,
       _telemetry = telemetry;

  final ResearchRemoteDataSource _remote;
  final ResearchCacheDao _cache;
  final TransportNetworkStatus _networkStatus;
  final AccountDataWriteBarrier _accountWrites;
  final Uuid _uuid;
  final TelemetrySink _telemetry;
  final Map<String, Future<ResearchSyncReport>> _syncFlights = {};

  @override
  bool get isOffline => _networkStatus.isOffline;

  @override
  Stream<List<Annotation>> watchAnnotations(ResearchRequestScope scope) =>
      _cache.watchAnnotations(
        accountId: scope.accountId,
        paperId: scope.paperId,
      );

  @override
  Stream<List<EvidenceCard>> watchEvidenceCards(ResearchRequestScope scope) =>
      _cache.watchEvidenceCards(
        accountId: scope.accountId,
        paperId: scope.paperId,
      );

  @override
  Stream<List<MemoryItem>> watchMemoryReview(String accountId) =>
      _cache.watchMemoryReview(accountId);

  @override
  Stream<List<AnnotationConflict>> watchConflicts(ResearchRequestScope scope) =>
      _cache.watchUnresolvedConflicts(scope.accountId, paperId: scope.paperId);

  @override
  Future<Annotation> createAnnotation({
    required ResearchRequestScope scope,
    required String blockId,
    required AnnotationKind kind,
    required TextQuotePositionSelector selector,
    String? body,
    AnnotationColorRole? colorRole,
    List<String> sectionHint = const [],
    int? pageHint,
  }) async {
    _requireCurrent(scope);
    final now = DateTime.now().toUtc();
    final operationId = _uuid.v7();
    final annotation = Annotation(
      id: _uuid.v7(),
      paperId: scope.paperId,
      generation: scope.generation,
      blockId: blockId,
      kind: kind,
      body: _normalizedBody(body),
      colorRole: colorRole,
      selector: selector,
      sectionHint: List.unmodifiable(sectionHint),
      pageHint: pageHint,
      anchorStatus: AnnotationAnchorStatus.anchored,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = AnnotationWrite(
      annotation: annotation,
      operationId: operationId,
      baseRevision: 0,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticAnnotation(
        accountId: scope.accountId,
        annotation: annotation,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
          operation: ResearchOutboxOperation.put,
          payload: {
            ...write.toJson(),
            'id': annotation.id,
            'create': true,
            'telemetry_action': 'create',
            'telemetry_strategy': _selectorStrategy(selector),
          },
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
    return annotation;
  }

  Future<Annotation> updateAnnotation({
    required ResearchRequestScope scope,
    required Annotation annotation,
    String? body,
    bool clearBody = false,
    AnnotationColorRole? colorRole,
    bool manualReattach = false,
    String? resolvesConflictId,
  }) async {
    _requireCurrent(scope);
    if (!scope.acceptsPaper(annotation.paperId, annotation.generation)) {
      throw StateError('Annotation is outside the active document scope.');
    }
    final operationId = _uuid.v7();
    final pending = annotation.copyWith(
      body: _normalizedBody(body),
      clearBody: clearBody,
      colorRole: colorRole,
      updatedAt: DateTime.now().toUtc(),
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = AnnotationWrite(
      annotation: pending,
      operationId: operationId,
      baseRevision: annotation.revision,
      resolvesConflictId: resolvesConflictId,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticAnnotation(
        accountId: scope.accountId,
        annotation: pending,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
          operation: ResearchOutboxOperation.put,
          baseRevision: annotation.revision,
          payload: {
            ...write.toJson(),
            'id': annotation.id,
            'create': false,
            'telemetry_action': manualReattach
                ? 'manual_reattach'
                : resolvesConflictId != null
                ? 'conflict_merge'
                : 'update',
            'telemetry_strategy': manualReattach
                ? 'manual'
                : _selectorStrategy(pending.selector),
          },
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
    return pending;
  }

  Future<void> deleteAnnotation({
    required ResearchRequestScope scope,
    required Annotation annotation,
  }) async {
    _requireCurrent(scope);
    final operationId = _uuid.v7();
    final now = DateTime.now().toUtc();
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticAnnotation(
        accountId: scope.accountId,
        annotation: annotation.copyWith(
          deletedAt: now,
          updatedAt: now,
          syncState: ResearchSyncState.pending,
          activeOperationId: operationId,
        ),
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
          operation: ResearchOutboxOperation.delete,
          baseRevision: annotation.revision,
          payload: const {},
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
  }

  Future<void> requestReanchor({
    required ResearchRequestScope scope,
    required Annotation annotation,
  }) async {
    _requireCurrent(scope);
    final operationId = _uuid.v7();
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticAnnotation(
        accountId: scope.accountId,
        annotation: annotation.copyWith(
          syncState: ResearchSyncState.pending,
          activeOperationId: operationId,
        ),
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.annotation,
          entityId: annotation.id,
          operation: ResearchOutboxOperation.reanchor,
          baseRevision: annotation.revision,
          payload: {
            'to_generation': scope.generation,
            'telemetry_action': 'reanchor',
            'telemetry_strategy': 'server',
          },
        ),
      ),
    );
    _emitAnnotationOutcome(
      action: 'reanchor',
      outcome: 'requested',
      strategy: 'server',
    );
    if (!isOffline) unawaited(syncPending(scope));
  }

  Future<Annotation> manualReattach({
    required ResearchRequestScope scope,
    required Annotation annotation,
    required String blockId,
    required TextQuotePositionSelector selector,
  }) {
    final reattached = annotation.copyWith(
      generation: scope.generation,
      blockId: blockId,
      selector: selector,
      anchorStatus: AnnotationAnchorStatus.anchored,
      clearDeletedAt: true,
    );
    return updateAnnotation(
      scope: scope,
      annotation: reattached,
      manualReattach: true,
    );
  }

  Future<Annotation> mergeConflict({
    required ResearchRequestScope scope,
    required Annotation annotation,
    required AnnotationConflict conflict,
    required String? mergedBody,
  }) async {
    _requireCurrent(scope);
    final current = await _cache.annotation(
      accountId: scope.accountId,
      annotationId: annotation.id,
    );
    if (conflict.mergeState != AnnotationMergeState.unresolved ||
        current == null ||
        current.syncState == ResearchSyncState.pending) {
      throw StateError('This conflict is already being resolved.');
    }
    return updateAnnotation(
      scope: scope,
      annotation: current.copyWith(revision: conflict.serverRevision),
      body: mergedBody,
      clearBody: mergedBody == null,
      resolvesConflictId: conflict.conflictId,
    );
  }

  @override
  Future<EvidenceCard> createEvidenceCard({
    required ResearchRequestScope scope,
    required String title,
    String? claimOrQuestion,
    String? userNote,
    List<String> sourceBlockIds = const [],
    List<String> figureIds = const [],
    List<String> tableIds = const [],
    List<String> citationContextIds = const [],
  }) async {
    _requireCurrent(scope);
    final safeTitle = _normalizedRequiredText(
      title,
      parameter: 'title',
      maximumScalars: evidenceCardTitleMaximumScalars,
    );
    final now = DateTime.now().toUtc();
    final operationId = _uuid.v7();
    final card = EvidenceCard(
      id: _uuid.v7(),
      paperId: scope.paperId,
      generation: scope.generation,
      title: safeTitle,
      claimOrQuestion: _normalizedOptionalText(
        claimOrQuestion,
        parameter: 'claimOrQuestion',
        maximumScalars: evidenceCardClaimMaximumScalars,
      ),
      userNote: _normalizedOptionalText(
        userNote,
        parameter: 'userNote',
        maximumScalars: evidenceCardNoteMaximumScalars,
      ),
      sourceBlockIds: List.unmodifiable(sourceBlockIds),
      figureIds: List.unmodifiable(figureIds),
      tableIds: List.unmodifiable(tableIds),
      citationContextIds: List.unmodifiable(citationContextIds),
      verificationStatus: EvidenceVerificationStatus.userSelected,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = EvidenceCardWrite(
      card: card,
      operationId: operationId,
      baseRevision: 0,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticEvidence(
        accountId: scope.accountId,
        card: card,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.evidenceCard,
          entityId: card.id,
          operation: ResearchOutboxOperation.put,
          payload: {...write.toJson(), 'create': true},
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
    return card;
  }

  Future<EvidenceCard> updateEvidenceCard({
    required ResearchRequestScope scope,
    required EvidenceCard card,
    required String title,
    String? claimOrQuestion,
    String? userNote,
    EvidenceVerificationStatus? verificationStatus,
  }) async {
    _requireCurrent(scope);
    final safeTitle = _normalizedRequiredText(
      title,
      parameter: 'title',
      maximumScalars: evidenceCardTitleMaximumScalars,
    );
    final safeClaim = _normalizedOptionalText(
      claimOrQuestion,
      parameter: 'claimOrQuestion',
      maximumScalars: evidenceCardClaimMaximumScalars,
    );
    final safeNote = _normalizedOptionalText(
      userNote,
      parameter: 'userNote',
      maximumScalars: evidenceCardNoteMaximumScalars,
    );
    final operationId = _uuid.v7();
    final pending = card.copyWith(
      title: safeTitle,
      claimOrQuestion: safeClaim,
      clearClaimOrQuestion: safeClaim == null,
      userNote: safeNote,
      clearUserNote: safeNote == null,
      verificationStatus: verificationStatus,
      updatedAt: DateTime.now().toUtc(),
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = EvidenceCardWrite(
      card: pending,
      operationId: operationId,
      baseRevision: card.revision,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticEvidence(
        accountId: scope.accountId,
        card: pending,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.evidenceCard,
          entityId: card.id,
          operation: ResearchOutboxOperation.put,
          baseRevision: card.revision,
          payload: {...write.toJson(), 'create': false},
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
    return pending;
  }

  Future<void> deleteEvidenceCard({
    required ResearchRequestScope scope,
    required EvidenceCard card,
  }) async {
    _requireCurrent(scope);
    final now = DateTime.now().toUtc();
    final operationId = _uuid.v7();
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticEvidence(
        accountId: scope.accountId,
        card: card.copyWith(
          deletedAt: now,
          updatedAt: now,
          syncState: ResearchSyncState.pending,
          activeOperationId: operationId,
        ),
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.evidenceCard,
          entityId: card.id,
          operation: ResearchOutboxOperation.delete,
          baseRevision: card.revision,
          payload: const {},
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
  }

  @override
  Future<MemoryItem> createMemoryItem({
    required ResearchRequestScope scope,
    required MemorySourceType sourceType,
    required String sourceId,
    String? promptText,
    String? answerText,
  }) async {
    _requireCurrent(scope);
    final now = DateTime.now().toUtc();
    final operationId = _uuid.v7();
    final item = MemoryItem(
      id: _uuid.v7(),
      paperId: scope.paperId,
      generation: scope.generation,
      sourceType: sourceType,
      sourceId: sourceId,
      promptText: _normalizedOptionalText(
        promptText,
        parameter: 'promptText',
        maximumScalars: memoryPromptMaximumScalars,
      ),
      answerText: _normalizedOptionalText(
        answerText,
        parameter: 'answerText',
        maximumScalars: memoryAnswerMaximumScalars,
      ),
      status: MemoryStatus.active,
      reviewCount: 0,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = MemoryItemWrite(
      item: item,
      operationId: operationId,
      baseRevision: 0,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticMemory(
        accountId: scope.accountId,
        item: item,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.memoryItem,
          entityId: item.id,
          operation: ResearchOutboxOperation.put,
          payload: {...write.toJson(), 'create': true},
        ),
      ),
    );
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.memoryLifecycle, {
      'action': 'create',
      'source_type': sourceType.wireValue,
      'offline': isOffline,
    });
    if (!isOffline) unawaited(syncPending(scope));
    return item;
  }

  Future<MemoryItem> reviewMemoryItem({
    required ResearchRequestScope scope,
    required MemoryItem item,
    required MemoryStatus status,
    DateTime? nextReviewAt,
  }) async {
    _requireCurrent(scope);
    final safeNextReviewAt = nextReviewAt?.toUtc();
    _requireValidMemorySchedule(status, safeNextReviewAt);
    final operationId = _uuid.v7();
    final now = DateTime.now().toUtc();
    final pending = item.copyWith(
      status: status,
      nextReviewAt: safeNextReviewAt,
      clearNextReviewAt: safeNextReviewAt == null,
      reviewCount: item.reviewCount + 1,
      updatedAt: now,
      syncState: ResearchSyncState.pending,
      activeOperationId: operationId,
    );
    final write = MemoryReviewWrite(
      operationId: operationId,
      baseRevision: item.revision,
      status: status,
      nextReviewAt: safeNextReviewAt,
      reviewedAt: now,
    );
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticMemory(
        accountId: scope.accountId,
        item: pending,
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.memoryItem,
          entityId: item.id,
          operation: ResearchOutboxOperation.review,
          baseRevision: item.revision,
          payload: write.toJson(),
        ),
      ),
    );
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.memoryLifecycle, {
      'action': switch (status) {
        MemoryStatus.active => 'review',
        MemoryStatus.snoozed => 'snooze',
        MemoryStatus.retired => 'retire',
      },
      'source_type': item.sourceType.wireValue,
      'offline': isOffline,
    });
    if (!isOffline) unawaited(syncPending(scope));
    return pending;
  }

  Future<void> retireMemoryItem({
    required ResearchRequestScope scope,
    required MemoryItem item,
  }) async {
    await reviewMemoryItem(
      scope: scope,
      item: item,
      status: MemoryStatus.retired,
    );
  }

  Future<void> deleteMemoryItem({
    required ResearchRequestScope scope,
    required MemoryItem item,
  }) async {
    _requireCurrent(scope);
    final now = DateTime.now().toUtc();
    final operationId = _uuid.v7();
    await _writeForScope(
      scope,
      () => _cache.persistOptimisticMemory(
        accountId: scope.accountId,
        item: item.copyWith(
          deletedAt: now,
          updatedAt: now,
          syncState: ResearchSyncState.pending,
          activeOperationId: operationId,
        ),
        operation: _operation(
          scope: scope,
          operationId: operationId,
          entityKind: ResearchEntityKind.memoryItem,
          entityId: item.id,
          operation: ResearchOutboxOperation.delete,
          baseRevision: item.revision,
          payload: const {},
        ),
      ),
    );
    if (!isOffline) unawaited(syncPending(scope));
  }

  Future<void> refreshPaperResearch(
    ResearchRequestScope scope, {
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (isOffline) return;
    final annotationsById = <String, Annotation>{};
    var afterRevision = 0;
    var annotationSyncRevision = 0;
    var purgedThroughRevision = 0;
    for (var pageNumber = 0; pageNumber < 100; pageNumber += 1) {
      final page = await _remote.listAnnotations(
        expectedAuthEpoch: scope.authEpoch,
        paperId: scope.paperId,
        afterRevision: afterRevision,
        limit: 100,
        cancellation: cancellation,
      );
      if (!scope.isCurrent()) return;
      for (final annotation in page.items) {
        annotationsById[annotation.id] = annotation;
      }
      annotationSyncRevision = page.syncRevision;
      purgedThroughRevision = page.purgedThroughRevision;
      if (!page.hasMore) break;
      if (page.nextAfterRevision <= afterRevision || pageNumber == 99) {
        throw const ApiException(
          code: 'INVALID_ANNOTATION_PAGE',
          message: 'Annotation sync did not return a safe continuation.',
          retryable: true,
        );
      }
      afterRevision = page.nextAfterRevision;
    }
    final annotations = annotationsById.values.toList(growable: false);
    await _writeForScope(
      scope,
      () => _cache.mergeRemoteAnnotations(
        accountId: scope.accountId,
        annotations: annotations,
        syncRevision: annotationSyncRevision,
        paperId: scope.paperId,
        purgedThroughRevision: purgedThroughRevision,
      ),
    );
    for (final status in AnnotationAnchorStatus.values) {
      final count = annotations
          .where((annotation) => annotation.anchorStatus == status)
          .length;
      if (count == 0) continue;
      _emitAnnotationOutcome(
        action: 'refresh',
        outcome: status.wireValue,
        strategy: 'server',
        count: count,
      );
    }
    final evidenceById = <String, EvidenceCard>{};
    final seenCursors = <String>{};
    String? cursor;
    int? evidenceSyncRevision;
    for (var pageNumber = 0; pageNumber < 100; pageNumber += 1) {
      final page = await _remote.listEvidenceCards(
        expectedAuthEpoch: scope.authEpoch,
        paperId: scope.paperId,
        cursor: cursor,
        limit: 100,
        cancellation: cancellation,
      );
      if (!scope.isCurrent()) return;
      if (evidenceSyncRevision != null &&
          evidenceSyncRevision != page.syncRevision) {
        throw const ApiException(
          code: 'INVALID_EVIDENCE_PAGE',
          message: 'Evidence sync changed while restoring a snapshot.',
          retryable: true,
        );
      }
      evidenceSyncRevision = page.syncRevision;
      for (final card in page.items) {
        evidenceById[card.id] = card;
      }
      final next = page.nextCursor;
      if (next == null) break;
      if (!seenCursors.add(next) || next == cursor || pageNumber == 99) {
        throw const ApiException(
          code: 'INVALID_EVIDENCE_PAGE',
          message: 'Evidence sync did not return a safe continuation.',
          retryable: true,
        );
      }
      cursor = next;
    }
    await _writeForScope(
      scope,
      () => _cache.mergeRemoteEvidence(
        accountId: scope.accountId,
        cards: evidenceById.values,
        syncRevision: evidenceSyncRevision ?? 0,
        paperId: scope.paperId,
        cursor: null,
      ),
    );
  }

  Future<void> refreshMemory(
    ResearchRequestScope scope, {
    RequestCancellation? cancellation,
  }) => refreshMemoryForAccount(
    ResearchAccountRequestScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      isCurrent: scope.isCurrent,
    ),
    cancellation: cancellation,
  );

  /// Restores the one account-owned memory review snapshot exposed by the
  /// server. Pagination and cache replacement stay inside this repository so
  /// an across-paper UI cannot become a second review authority.
  Future<void> refreshMemoryForAccount(
    ResearchAccountRequestScope scope, {
    RequestCancellation? cancellation,
  }) async {
    _requireCurrentAccount(scope);
    if (isOffline) return;
    final itemsById = <String, MemoryItem>{};
    final seenCursors = <String>{};
    String? cursor;
    int? syncRevision;
    for (var pageNumber = 0; pageNumber < 100; pageNumber += 1) {
      final page = await _remote.listMemoryReview(
        expectedAuthEpoch: scope.authEpoch,
        cursor: cursor,
        limit: 100,
        cancellation: cancellation,
      );
      if (!scope.isCurrent()) return;
      if (syncRevision != null && syncRevision != page.syncRevision) {
        throw const ApiException(
          code: 'INVALID_MEMORY_PAGE',
          message: 'Memory sync changed while restoring a snapshot.',
          retryable: true,
        );
      }
      syncRevision = page.syncRevision;
      for (final item in page.items) {
        itemsById[item.id] = item;
      }
      final next = page.nextCursor;
      if (next == null) break;
      if (!seenCursors.add(next) || next == cursor || pageNumber == 99) {
        throw const ApiException(
          code: 'INVALID_MEMORY_PAGE',
          message: 'Memory sync did not return a safe continuation.',
          retryable: true,
        );
      }
      cursor = next;
    }
    await _writeForAccountScope(
      scope,
      () => _cache.mergeRemoteMemory(
        accountId: scope.accountId,
        items: itemsById.values,
        syncRevision: syncRevision ?? 0,
        cursor: null,
      ),
    );
  }

  Future<void> refreshUnresolvedConflicts(
    ResearchRequestScope scope, {
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (isOffline) return;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        await _refreshUnresolvedConflictSnapshot(
          scope,
          cancellation: cancellation,
        );
        return;
      } on ApiException catch (error) {
        final canRestart =
            error.code == 'INVALID_RESEARCH_CURSOR' &&
            attempt == 0 &&
            scope.isCurrent() &&
            !isOffline;
        if (!canRestart) rethrow;
      }
    }
  }

  Future<void> _refreshUnresolvedConflictSnapshot(
    ResearchRequestScope scope, {
    RequestCancellation? cancellation,
  }) async {
    final conflictsById = <String, AnnotationConflict>{};
    final seenCursors = <String>{};
    String? cursor;
    int? syncRevision;
    for (var pageNumber = 0; pageNumber < 100; pageNumber += 1) {
      final page = await _remote.listAnnotationConflicts(
        expectedAuthEpoch: scope.authEpoch,
        cursor: cursor,
        limit: 200,
        cancellation: cancellation,
      );
      if (!scope.isCurrent()) return;
      if (syncRevision != null && syncRevision != page.syncRevision) {
        throw const ApiException(
          code: 'INVALID_ANNOTATION_CONFLICT_PAGE',
          message: 'Conflict sync changed while restoring a snapshot.',
          retryable: true,
        );
      }
      syncRevision = page.syncRevision;
      for (final item in page.items) {
        if (item.currentAnnotationRevision > page.syncRevision ||
            conflictsById.containsKey(item.conflict.conflictId)) {
          throw const ApiException(
            code: 'INVALID_ANNOTATION_CONFLICT_PAGE',
            message: 'Conflict sync returned an inconsistent snapshot.',
            retryable: true,
          );
        }
        conflictsById[item.conflict.conflictId] = item.conflict
            .atCurrentAnnotationRevision(item.currentAnnotationRevision);
      }
      final next = page.nextCursor;
      if (next == null) break;
      if (!seenCursors.add(next) || next == cursor || pageNumber == 99) {
        throw const ApiException(
          code: 'INVALID_ANNOTATION_CONFLICT_PAGE',
          message: 'Conflict sync did not return a safe continuation.',
          retryable: true,
        );
      }
      cursor = next;
    }
    if (!scope.isCurrent()) return;
    await _writeForScope(
      scope,
      () => _cache.mergeRemoteUnresolvedConflicts(
        accountId: scope.accountId,
        conflicts: conflictsById.values,
        syncRevision: syncRevision ?? 0,
      ),
    );
  }

  Future<List<DocumentVersion>> versions(
    ResearchRequestScope scope, {
    bool force = false,
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (!force) {
      final cached = await _cache.readCachedVersions(
        accountId: scope.accountId,
        paperId: scope.paperId,
      );
      if (cached != null) return cached;
    }
    if (isOffline) {
      throw const ApiException(
        code: 'OFFLINE_VERSION_HISTORY_UNAVAILABLE',
        message: 'Version history is not available offline for this paper.',
        retryable: true,
        isOffline: true,
      );
    }
    final versions = await _remote.listVersions(
      paperId: scope.paperId,
      expectedAuthEpoch: scope.authEpoch,
      cancellation: cancellation,
    );
    if (!scope.isCurrent()) throw _staleScope;
    await _writeForScope(
      scope,
      () => _cache.cacheVersions(
        accountId: scope.accountId,
        paperId: scope.paperId,
        versions: versions,
      ),
    );
    return versions;
  }

  Future<PaperVersionDiff> versionDiff({
    required ResearchRequestScope scope,
    required int fromGeneration,
    required int toGeneration,
    bool force = false,
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (!force) {
      final cached = await _cache.readCachedVersionDiff(
        accountId: scope.accountId,
        paperId: scope.paperId,
        fromGeneration: fromGeneration,
        toGeneration: toGeneration,
      );
      if (cached != null) return cached;
    }
    if (isOffline) {
      throw const ApiException(
        code: 'OFFLINE_VERSION_DIFF_UNAVAILABLE',
        message: 'This version comparison is not available offline.',
        retryable: true,
        isOffline: true,
      );
    }
    final diff = await _remote.getVersionDiff(
      paperId: scope.paperId,
      fromGeneration: fromGeneration,
      toGeneration: toGeneration,
      expectedAuthEpoch: scope.authEpoch,
      cancellation: cancellation,
    );
    if (!scope.acceptsPaper(diff.paperId, toGeneration)) throw _staleScope;
    await _writeForScope(
      scope,
      () => _cache.cacheVersionDiff(accountId: scope.accountId, diff: diff),
    );
    return diff;
  }

  Future<ResearchExportArtifact> exportResearch({
    required ResearchRequestScope scope,
    required ResearchExportFormat format,
    bool allPapers = false,
    String? cursor,
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (isOffline) {
      throw const ApiException(
        code: 'OFFLINE_EXPORT_UNAVAILABLE',
        message: 'Reconnect to create a complete bounded research export.',
        retryable: true,
        isOffline: true,
      );
    }
    final artifact = await _remote.exportResearch(
      format: format,
      expectedAuthEpoch: scope.authEpoch,
      paperId: allPapers ? null : scope.paperId,
      cursor: cursor,
      cancellation: cancellation,
    );
    if (!scope.isCurrent()) throw _staleScope;
    return artifact;
  }

  Future<ResearchAnnotationImportResult> importAnnotationArchive({
    required ResearchRequestScope scope,
    required String encodedArchive,
    RequestCancellation? cancellation,
  }) async {
    _requireCurrent(scope);
    if (isOffline) {
      throw const ApiException(
        code: 'OFFLINE_IMPORT_UNAVAILABLE',
        message: 'Reconnect to import an annotation archive.',
        retryable: true,
        isOffline: true,
      );
    }
    final bytes = utf8.encode(encodedArchive);
    if (bytes.isEmpty || bytes.length > ResearchApi.maximumClientExportBytes) {
      throw const ApiException(
        code: 'INVALID_ANNOTATION_IMPORT',
        message: 'The clipboard archive is empty or too large to import.',
        statusCode: 400,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encodedArchive);
    } on FormatException {
      throw const ApiException(
        code: 'INVALID_ANNOTATION_IMPORT',
        message: 'The clipboard does not contain a valid JSON research export.',
        statusCode: 400,
      );
    }
    if (decoded is! Map ||
        decoded['schema_version'] != 'pakperk.research-export.v1' ||
        const {
          'user_id',
          'owner_user_id',
          'account_id',
        }.any(decoded.containsKey)) {
      throw const ApiException(
        code: 'INVALID_ANNOTATION_IMPORT',
        message: 'The clipboard is not a compatible Pakperk research export.',
        statusCode: 400,
      );
    }
    final archive = Map<String, dynamic>.from(decoded);
    final annotationArchive = <String, dynamic>{
      'schema_version': archive['schema_version'],
      'annotations': archive['annotations'] ?? const <Object?>[],
      'annotation_conflicts':
          archive['annotation_conflicts'] ?? const <Object?>[],
      'annotation_reanchor_attempts':
          archive['annotation_reanchor_attempts'] ?? const <Object?>[],
    };
    final result = await _remote.importAnnotations(
      archive: annotationArchive,
      operationId: _uuid.v7(),
      expectedAuthEpoch: scope.authEpoch,
      cancellation: cancellation,
    );
    if (!scope.isCurrent()) throw _staleScope;

    try {
      await Future.wait<void>([
        refreshPaperResearch(scope, cancellation: cancellation),
        refreshUnresolvedConflicts(scope, cancellation: cancellation),
      ]);
    } on Object {
      // The server import is atomic and already accepted. A later normal
      // refresh restores the local projection if this best-effort refresh
      // loses connectivity after the commit.
    }
    return result;
  }

  @override
  Future<ResearchSyncReport> restoreAndSync(ResearchRequestScope scope) async {
    _requireCurrent(scope);
    await _writeForScope(
      scope,
      () => _cache.restoreInterruptedOperations(scope.accountId),
    );
    final report = await syncPending(scope);
    if (!isOffline && scope.isCurrent()) {
      await refreshUnresolvedConflicts(scope);
    }
    return report;
  }

  Future<ResearchSyncReport> syncPending(ResearchRequestScope scope) {
    final active = _syncFlights[scope.accountId];
    if (active != null) return active;
    late final Future<ResearchSyncReport> flight;
    flight = _syncPending(scope).whenComplete(() {
      if (identical(_syncFlights[scope.accountId], flight)) {
        _syncFlights.remove(scope.accountId);
      }
    });
    _syncFlights[scope.accountId] = flight;
    return flight;
  }

  Future<ResearchSyncReport> _syncPending(ResearchRequestScope scope) async {
    if (isOffline || !scope.isCurrent()) {
      return const ResearchSyncReport(
        attempted: 0,
        applied: 0,
        conflicts: 0,
        failed: 0,
        interrupted: true,
      );
    }
    var attempted = 0;
    var applied = 0;
    var conflicts = 0;
    var failed = 0;
    var interrupted = false;
    final operations = await _cache.pendingOperations(scope.accountId);
    for (final operation in operations) {
      if (isOffline || !scope.isCurrent()) {
        interrupted = true;
        break;
      }
      // A paper-scoped controller never replays a different paper. That row
      // remains durable for its own reader or a future account-level runtime.
      if (operation.payload['paper_id'] != null &&
          operation.payload['paper_id'] != scope.paperId) {
        continue;
      }
      attempted += 1;
      if (!await _tryWriteForScope(
        scope,
        () => _cache.markOperationInFlight(operation),
      )) {
        interrupted = true;
        break;
      }
      try {
        final outcome = await _dispatch(scope, operation);
        if (!scope.isCurrent()) {
          interrupted = true;
          break;
        }
        if (outcome == _DispatchOutcome.conflict) {
          conflicts += 1;
        } else {
          applied += 1;
        }
      } on ApiException catch (error) {
        if (error.cancelled ||
            error.code == 'STALE_RESEARCH_SCOPE' ||
            !scope.isCurrent()) {
          if (scope.isCurrent()) {
            await _tryWriteForScope(
              scope,
              () => _cache.restoreInterruptedOperations(scope.accountId),
            );
          }
          interrupted = true;
          break;
        }
        if (!await _tryWriteForScope(
          scope,
          () => _cache.markOperationFailed(operation, error.code),
        )) {
          interrupted = true;
          break;
        }
        failed += 1;
        if (error.isOffline) {
          interrupted = true;
          break;
        }
      } on Object {
        if (!await _tryWriteForScope(
          scope,
          () =>
              _cache.markOperationFailed(operation, 'INVALID_RESEARCH_OUTBOX'),
        )) {
          interrupted = true;
          break;
        }
        failed += 1;
      }
    }
    return ResearchSyncReport(
      attempted: attempted,
      applied: applied,
      conflicts: conflicts,
      failed: failed,
      interrupted: interrupted,
    );
  }

  Future<_DispatchOutcome> _dispatch(
    ResearchRequestScope scope,
    ResearchOutboxEntry operation,
  ) async {
    switch (operation.entityKind) {
      case ResearchEntityKind.annotation:
        final telemetryAction =
            operation.payload['telemetry_action'] as String?;
        final telemetryStrategy =
            operation.payload['telemetry_strategy'] as String? ??
            'not_applicable';
        final local = await _cache.annotation(
          accountId: scope.accountId,
          annotationId: operation.entityId,
        );
        if (local == null) throw const FormatException('Missing annotation.');
        final Annotation canonical;
        if (operation.operation == ResearchOutboxOperation.delete) {
          canonical = await _remote.deleteAnnotation(
            annotationId: local.id,
            operationId: operation.operationId,
            baseRevision: operation.baseRevision,
            expectedAuthEpoch: scope.authEpoch,
          );
        } else if (operation.operation == ResearchOutboxOperation.reanchor) {
          canonical = await _remote.reanchorAnnotation(
            annotationId: local.id,
            operationId: operation.operationId,
            baseRevision: operation.baseRevision,
            toGeneration:
                (operation.payload['to_generation'] as num?)?.toInt() ??
                scope.generation,
            expectedAuthEpoch: scope.authEpoch,
          );
        } else {
          final result = await _remote.putAnnotation(
            write: AnnotationWrite(
              annotation: local,
              operationId: operation.operationId,
              baseRevision: operation.baseRevision,
              resolvesConflictId:
                  operation.payload['resolves_conflict_id'] as String?,
            ),
            expectedAuthEpoch: scope.authEpoch,
          );
          if (result case AnnotationMutationConflict(:final conflict)) {
            await _writeForScope(
              scope,
              () => _cache.recordAnnotationConflict(
                accountId: scope.accountId,
                conflict: conflict,
              ),
            );
            if (telemetryAction != null) {
              _emitAnnotationOutcome(
                action: telemetryAction,
                outcome: 'conflict',
                strategy: 'not_applicable',
              );
            }
            return _DispatchOutcome.conflict;
          }
          canonical = (result as AnnotationMutationApplied).annotation;
        }
        if (!scope.acceptsPaper(canonical.paperId, canonical.generation)) {
          throw _staleScope;
        }
        await _writeForScope(
          scope,
          () => _cache.settleAnnotation(
            accountId: scope.accountId,
            operationId: operation.operationId,
            canonical: canonical,
            resolvedConflictId:
                operation.payload['resolves_conflict_id'] as String?,
            mergedBody: operation.payload['resolves_conflict_id'] == null
                ? null
                : canonical.body,
          ),
        );
        if (telemetryAction != null) {
          _emitAnnotationOutcome(
            action: telemetryAction,
            outcome: canonical.anchorStatus.wireValue,
            strategy: telemetryStrategy,
          );
        }
      case ResearchEntityKind.evidenceCard:
        final local = await _cache.evidenceCard(
          accountId: scope.accountId,
          cardId: operation.entityId,
        );
        if (local == null) throw const FormatException('Missing evidence.');
        final canonical = operation.operation == ResearchOutboxOperation.delete
            ? await _remote.deleteEvidenceCard(
                cardId: local.id,
                operationId: operation.operationId,
                baseRevision: operation.baseRevision,
                expectedAuthEpoch: scope.authEpoch,
              )
            : await _remote.putEvidenceCard(
                write: EvidenceCardWrite(
                  card: local,
                  operationId: operation.operationId,
                  baseRevision: operation.baseRevision,
                ),
                create: operation.payload['create'] == true,
                expectedAuthEpoch: scope.authEpoch,
              );
        if (!scope.acceptsPaper(canonical.paperId, canonical.generation)) {
          throw _staleScope;
        }
        await _writeForScope(
          scope,
          () => _cache.settleEvidence(
            accountId: scope.accountId,
            operationId: operation.operationId,
            canonical: canonical,
          ),
        );
      case ResearchEntityKind.memoryItem:
        final local = await _cache.memoryItem(
          accountId: scope.accountId,
          itemId: operation.entityId,
        );
        if (local == null) throw const FormatException('Missing memory item.');
        final MemoryItem canonical;
        if (operation.operation == ResearchOutboxOperation.delete) {
          canonical = await _remote.deleteMemoryItem(
            itemId: local.id,
            operationId: operation.operationId,
            baseRevision: operation.baseRevision,
            expectedAuthEpoch: scope.authEpoch,
          );
        } else if (operation.operation == ResearchOutboxOperation.review) {
          final status = MemoryStatus.fromWire(operation.payload['status']);
          final nextReviewAt = _date(operation.payload['next_review_at']);
          _requireValidMemorySchedule(status, nextReviewAt);
          canonical = await _remote.reviewMemoryItem(
            itemId: local.id,
            write: MemoryReviewWrite(
              operationId: operation.operationId,
              baseRevision: operation.baseRevision,
              status: status,
              nextReviewAt: nextReviewAt,
              reviewedAt:
                  _date(operation.payload['reviewed_at']) ??
                  operation.createdAt,
            ),
            expectedAuthEpoch: scope.authEpoch,
          );
        } else {
          _requireValidMemorySchedule(local.status, local.nextReviewAt);
          canonical = await _remote.putMemoryItem(
            write: MemoryItemWrite(
              item: local,
              operationId: operation.operationId,
              baseRevision: operation.baseRevision,
            ),
            create: operation.payload['create'] == true,
            expectedAuthEpoch: scope.authEpoch,
          );
        }
        if (!scope.acceptsPaper(canonical.paperId, canonical.generation)) {
          throw _staleScope;
        }
        await _writeForScope(
          scope,
          () => _cache.settleMemory(
            accountId: scope.accountId,
            operationId: operation.operationId,
            canonical: canonical,
          ),
        );
      case ResearchEntityKind.checkpoint:
        throw const FormatException(
          'Checkpoints are synced by the position-only document repository.',
        );
    }
    return _DispatchOutcome.applied;
  }

  ResearchOutboxEntry _operation({
    required ResearchRequestScope scope,
    required String operationId,
    required ResearchEntityKind entityKind,
    required String entityId,
    required ResearchOutboxOperation operation,
    required Map<String, Object?> payload,
    int baseRevision = 0,
  }) {
    final now = DateTime.now().toUtc();
    return ResearchOutboxEntry(
      accountId: scope.accountId,
      operationId: operationId,
      entityKind: entityKind,
      entityId: entityId,
      operation: operation,
      baseRevision: baseRevision,
      // Every operation carries its exact paper scope, including deletes and
      // review-only writes whose wire DTO otherwise omits paper identity. This
      // lets an account-level review surface replay one paper without settling
      // a late response into another paper's optimistic row.
      payload: <String, dynamic>{
        ...payload,
        'paper_id': scope.paperId,
        'generation': scope.generation,
      },
      state: ResearchOutboxState.queued,
      attemptCount: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> _writeForScope(
    ResearchRequestScope scope,
    Future<void> Function() write,
  ) async {
    if (!await _tryWriteForScope(scope, write)) throw _staleScope;
  }

  Future<bool> _tryWriteForScope(
    ResearchRequestScope scope,
    Future<void> Function() write,
  ) => _tryWriteForAccountScope(
    ResearchAccountRequestScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      isCurrent: scope.isCurrent,
    ),
    write,
  );

  Future<void> _writeForAccountScope(
    ResearchAccountRequestScope scope,
    Future<void> Function() write,
  ) async {
    if (!await _tryWriteForAccountScope(scope, write)) throw _staleScope;
  }

  Future<bool> _tryWriteForAccountScope(
    ResearchAccountRequestScope scope,
    Future<void> Function() write,
  ) => _accountWrites.writeIfCurrent(
    accountId: scope.accountId,
    authEpoch: scope.authEpoch,
    isCurrent: scope.isCurrent,
    write: write,
  );

  void _requireCurrent(ResearchRequestScope scope) {
    _requireCurrentAccount(
      ResearchAccountRequestScope(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
        isCurrent: scope.isCurrent,
      ),
    );
    if (scope.generation <= 0) {
      throw _staleScope;
    }
  }

  void _requireCurrentAccount(ResearchAccountRequestScope scope) {
    if (scope.accountId.trim().isEmpty ||
        scope.authEpoch < 0 ||
        !scope.isCurrent()) {
      throw _staleScope;
    }
  }

  void _emitAnnotationOutcome({
    required String action,
    required String outcome,
    required String strategy,
    int? count,
  }) {
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.annotationSyncOutcome, {
      'action': action,
      'outcome': outcome,
      'strategy': strategy,
      'offline': isOffline,
      if (count != null) 'count': count,
    });
  }
}

enum _DispatchOutcome { applied, conflict }

String? _normalizedBody(String? value) {
  return _normalizedOptionalText(
    value,
    parameter: 'body',
    maximumScalars: 100000,
  );
}

String _normalizedRequiredText(
  String value, {
  required String parameter,
  required int maximumScalars,
}) {
  final text = _normalizedOptionalText(
    value,
    parameter: parameter,
    maximumScalars: maximumScalars,
  );
  if (text == null) throw ArgumentError.value(value, parameter);
  return text;
}

String? _normalizedOptionalText(
  String? value, {
  required String parameter,
  required int maximumScalars,
}) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  if (text.contains('\u0000') || text.runes.length > maximumScalars) {
    throw ArgumentError.value(value, parameter);
  }
  return text;
}

void _requireValidMemorySchedule(MemoryStatus status, DateTime? nextReviewAt) {
  if ((status == MemoryStatus.snoozed) != (nextReviewAt != null)) {
    throw ArgumentError.value(
      nextReviewAt,
      'nextReviewAt',
      'must be present if and only if status is snoozed',
    );
  }
}

String _selectorStrategy(TextQuotePositionSelector? selector) =>
    selector?.prefix != null || selector?.suffix != null
    ? 'quote_context'
    : 'exact_quote';

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toUtc();

const _staleScope = ApiException(
  code: 'STALE_RESEARCH_SCOPE',
  message: 'This research response belongs to an inactive account or version.',
);
