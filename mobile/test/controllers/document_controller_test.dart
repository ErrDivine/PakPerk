import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/document/document_api.dart';
import 'package:pakperk/core/document/document_repository.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/provenance.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/models/reading_checkpoint.dart';
import 'package:pakperk/features/document_reader/document_controller.dart';
import 'package:pakperk/features/reader_modes/reader_mode.dart';

void main() {
  const args = DocumentControllerArgs(
    accountId: 'account-a',
    authEpoch: 4,
    paperId: '00000000-0000-4000-8000-000000000001',
    versionKey: '2601.00001v1',
    generation: 2,
    includePassport: true,
    includeSemanticFacets: true,
    includeVisualObjects: true,
  );

  test('new request cancels and fences an older document response', () async {
    final source = _DelayedDocumentSource();
    final controller = DocumentController(
      args: args,
      source: source,
      scopeIsCurrent: () => true,
    );
    addTearDown(controller.dispose);

    final first = controller.load();
    final second = controller.load(force: true);
    expect(source.cancellations.first.isCancelled, isTrue);

    source.loads[1].complete(
      DocumentLoadResult(snapshot: _snapshot('new'), fromCache: false),
    );
    await second;
    source.loads[0].complete(
      DocumentLoadResult(snapshot: _snapshot('old'), fromCache: true),
    );
    await first;

    expect(controller.state.snapshot!.blocks.single.text, 'new');
    expect(controller.state.fromCache, isFalse);
  });

  test('account scope change rejects a late response', () async {
    var current = true;
    final source = _DelayedDocumentSource();
    final controller = DocumentController(
      args: args,
      source: source,
      scopeIsCurrent: () => current,
    );
    addTearDown(controller.dispose);

    final operation = controller.load();
    current = false;
    source.loads.single.complete(
      DocumentLoadResult(snapshot: _snapshot('stale'), fromCache: false),
    );
    await operation;

    expect(controller.state.snapshot, isNull);
    expect(controller.state.availability, DocumentAvailability.loading);
  });

  test(
    'online load restores the exact-paper checkpoint from another device',
    () async {
      final remote = _checkpoint(revision: 12, blockId: 'block-1');
      final source = _DelayedDocumentSource(remoteCheckpoint: remote);
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      final load = controller.load();
      source.loads.single.complete(
        DocumentLoadResult(snapshot: _snapshot('remote'), fromCache: false),
      );
      await load;

      expect(source.checkpointFetches, 1);
      expect(controller.state.checkpoint?.revision, 12);
      expect(controller.state.checkpoint?.blockId, 'block-1');
      expect(controller.state.checkpoint?.pendingSync, isFalse);
      expect(source.savedCheckpoint?.revision, 12);
    },
  );

  test(
    'restart rebases a pending local checkpoint before retrying it',
    () async {
      const interruptedOperation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final source = _DelayedDocumentSource(
        localCheckpoint: _checkpoint(
          revision: 3,
          blockId: 'offline-block',
          pendingSync: true,
          operationId: interruptedOperation,
        ),
        remoteCheckpoint: _checkpoint(
          revision: 20,
          blockId: 'peer-block',
          lastReadAt: DateTime.utc(2099),
        ),
      );
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      final load = controller.load();
      source.loads.single.complete(
        DocumentLoadResult(snapshot: _snapshot('restart'), fromCache: false),
      );
      await load;
      await Future<void>.delayed(Duration.zero);

      expect(source.syncAttempts, hasLength(1));
      expect(source.syncAttempts.single.revision, 20);
      expect(source.syncAttempts.single.blockId, 'offline-block');
      expect(
        source.syncAttempts.single.operationId,
        isNot(interruptedOperation),
      );
      expect(controller.state.checkpoint?.revision, 21);
      expect(controller.state.checkpoint?.pendingSync, isFalse);
    },
  );

  test(
    'pending work from an older generation cannot replace the current server checkpoint',
    () async {
      final source = _DelayedDocumentSource(
        localCheckpoint: _checkpoint(
          generation: 1,
          revision: 8,
          blockId: 'stale-generation-block',
          pendingSync: true,
          operationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
        remoteCheckpoint: _checkpoint(
          revision: 21,
          blockId: 'current-generation-block',
        ),
      );
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      final load = controller.load();
      source.loads.single.complete(
        DocumentLoadResult(snapshot: _snapshot('current'), fromCache: false),
      );
      await load;
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.checkpoint?.generation, 2);
      expect(controller.state.checkpoint?.blockId, 'current-generation-block');
      expect(controller.state.checkpoint?.pendingSync, isFalse);
      expect(source.syncAttempts, isEmpty);
      expect(source.savedCheckpoint?.generation, 2);
    },
  );

  test('checkpoint conflict fetches, rebases, and settles once', () async {
    final source = _DelayedDocumentSource(
      remoteCheckpoint: _checkpoint(
        revision: 44,
        blockId: 'other-device-block',
        // Device clocks are not an authority. This explicit local commit must
        // still rebase instead of losing position to a future-skewed peer.
        lastReadAt: DateTime.utc(2099),
      ),
      syncConflictOnce: true,
    );
    final controller = DocumentController(
      args: args,
      source: source,
      scopeIsCurrent: () => true,
    );
    addTearDown(controller.dispose);

    final saved = await controller.saveCheckpoint(
      mode: ReaderDepthMode.inspect,
      stage: PaperStage.introduction,
      blockId: 'block-1',
      scrollFraction: .72,
    );

    expect(saved, isTrue);
    expect(source.checkpointFetches, 1);
    expect(source.syncAttempts, hasLength(2));
    expect(source.syncAttempts.first.revision, 0);
    expect(source.syncAttempts.last.revision, 44);
    expect(
      source.syncAttempts.last.operationId,
      isNot(source.syncAttempts.first.operationId),
    );
    expect(controller.state.checkpoint?.revision, 45);
    expect(controller.state.checkpoint?.pendingSync, isFalse);
    expect(controller.state.checkpoint?.blockId, 'block-1');
    expect(controller.state.checkpoint!.toJson(), isNot(contains('queue')));
    expect(controller.state.checkpoint!.toJson(), isNot(contains('library')));
  });

  test(
    'offline checkpoint commits position only and remains pending',
    () async {
      final source = _DelayedDocumentSource(offline: true);
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      final saved = await controller.saveCheckpoint(
        mode: ReaderDepthMode.read,
        stage: PaperStage.introduction,
        blockId: 'block-1',
        scrollFraction: .42,
      );

      expect(saved, isTrue);
      expect(source.savedCheckpoint, isNotNull);
      expect(source.syncedCheckpoint, isNull);
      expect(source.savedCheckpoint!.pendingSync, isTrue);
      expect(
        source.savedCheckpoint!.toJson(),
        isNot(contains('library_state')),
      );
      expect(source.savedCheckpoint!.toJson(), isNot(contains('reviewed')));
      expect(source.savedCheckpoint!.toJson(), isNot(contains('queue')));
    },
  );

  test(
    'exact source navigation pages forward and persists the result',
    () async {
      final source = _PagedDocumentSource();
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      await controller.load();
      final found = await controller.ensureBlockLoaded('block-3');

      expect(found, isTrue);
      expect(source.requestedCursors, ['cursor-1', 'cursor-2']);
      expect(controller.state.snapshot!.blocks.map((block) => block.id), [
        'block-1',
        'block-2',
        'block-3',
      ]);
      expect(source.persistedSnapshot?.blocks.length, 3);
    },
  );

  test(
    'exact source navigation stops when a page cursor does not advance',
    () async {
      final source = _PagedDocumentSource(stalled: true);
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      await controller.load();
      final found = await controller.ensureBlockLoaded('missing-block');

      expect(found, isFalse);
      expect(source.requestedCursors, ['cursor-1']);
      expect(controller.state.errorMessage, contains('could not be loaded'));
    },
  );

  test(
    'visual metadata stays idle until Inspect explicitly reveals it',
    () async {
      final source = _PagedDocumentSource();
      final controller = DocumentController(
        args: args,
        source: source,
        scopeIsCurrent: () => true,
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(source.initialVisualRequests, [false]);
      expect(source.visualObjectRequests, 0);
      expect(controller.state.snapshot!.visualObjectsIncluded, isFalse);

      await controller.loadVisualObjects();
      expect(source.visualObjectRequests, 1);
      expect(controller.state.snapshot!.visualObjectsIncluded, isTrue);
      expect(source.persistedSnapshot?.visualObjectsIncluded, isTrue);
    },
  );

  test('document reload cancels and fences late visual metadata', () async {
    final visualResponse = Completer<DocumentVisualObjects>();
    final source = _PagedDocumentSource(visualResponse: visualResponse);
    final controller = DocumentController(
      args: args,
      source: source,
      scopeIsCurrent: () => true,
    );
    addTearDown(controller.dispose);

    await controller.load();
    final visualLoad = controller.loadVisualObjects();
    expect(controller.state.loadingVisualObjects, isTrue);

    await controller.load(force: true);
    expect(source.visualCancellations.single.isCancelled, isTrue);
    visualResponse.complete(
      DocumentVisualObjects(
        paperId: args.paperId,
        generation: args.generation,
        figures: const [],
        tables: const [],
        equations: const [],
      ),
    );
    await visualLoad;

    expect(controller.state.snapshot!.visualObjectsIncluded, isFalse);
    expect(controller.state.loadingVisualObjects, isFalse);
  });
}

final class _DelayedDocumentSource implements DocumentDataSource {
  _DelayedDocumentSource({
    this.offline = false,
    this.localCheckpoint,
    this.remoteCheckpoint,
    this.syncConflictOnce = false,
  });

  final bool offline;
  final ReadingCheckpoint? localCheckpoint;
  final ReadingCheckpoint? remoteCheckpoint;
  final bool syncConflictOnce;
  final List<Completer<DocumentLoadResult>> loads = [];
  final List<RequestCancellation> cancellations = [];
  final List<ReadingCheckpoint> syncAttempts = [];
  ReadingCheckpoint? savedCheckpoint;
  ReadingCheckpoint? syncedCheckpoint;
  int checkpointFetches = 0;

  @override
  bool get isOffline => offline;

  @override
  Future<DocumentLoadResult> load({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    required bool force,
    RequestCancellation? cancellation,
  }) {
    final completer = Completer<DocumentLoadResult>();
    loads.add(completer);
    cancellations.add(cancellation!);
    return completer.future;
  }

  @override
  Future<ReadingCheckpoint?> readCheckpoint({
    required String accountId,
    required String paperId,
  }) async => localCheckpoint;

  @override
  Future<ReadingCheckpoint?> fetchCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    checkpointFetches += 1;
    return remoteCheckpoint;
  }

  @override
  Future<void> saveCheckpointLocally(
    ReadingCheckpoint checkpoint, {
    required int expectedAuthEpoch,
  }) async {
    savedCheckpoint = checkpoint;
  }

  @override
  Future<ReadingCheckpoint> syncCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    syncAttempts.add(checkpoint);
    if (syncConflictOnce && syncAttempts.length == 1) {
      throw const ApiException(
        code: 'RESEARCH_REVISION_CONFLICT',
        message: 'The checkpoint changed.',
        statusCode: 409,
      );
    }
    syncedCheckpoint = checkpoint;
    return checkpoint.copyWith(revision: checkpoint.revision + 1);
  }
}

final class _PagedDocumentSource
    implements
        DocumentDataSource,
        PagedDocumentDataSource,
        VisualDocumentDataSource,
        DocumentSnapshotPersistence {
  _PagedDocumentSource({this.stalled = false, this.visualResponse});

  final bool stalled;
  final Completer<DocumentVisualObjects>? visualResponse;
  final List<String> requestedCursors = [];
  final List<bool> initialVisualRequests = [];
  final List<RequestCancellation> visualCancellations = [];
  int visualObjectRequests = 0;
  DocumentSnapshot? persistedSnapshot;

  @override
  bool get isOffline => false;

  @override
  Future<DocumentLoadResult> load({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    required bool force,
    RequestCancellation? cancellation,
  }) async {
    initialVisualRequests.add(includeVisualObjects);
    return DocumentLoadResult(
      snapshot: _snapshot('page one', nextCursor: 'cursor-1'),
      fromCache: false,
    );
  }

  @override
  Future<DocumentVisualObjects> loadVisualObjects({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    visualObjectRequests += 1;
    visualCancellations.add(cancellation!);
    return visualResponse?.future ??
        DocumentVisualObjects(
          paperId: paperId,
          generation: generation,
          figures: const [],
          tables: const [],
          equations: const [],
        );
  }

  @override
  Future<DocumentBlockPage> loadNextPage({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    required String cursor,
    RequestCancellation? cancellation,
  }) async {
    requestedCursors.add(cursor);
    final blockNumber = cursor == 'cursor-1' ? 2 : 3;
    return DocumentBlockPage(
      paperId: paperId,
      generation: generation,
      blocks: [
        _block(
          id: 'block-$blockNumber',
          ordinal: blockNumber - 1,
          text: 'page $blockNumber',
        ),
      ],
      nextCursor: stalled
          ? cursor
          : cursor == 'cursor-1'
          ? 'cursor-2'
          : null,
      provenance: const ProvenanceSummary(status: 'ready'),
    );
  }

  @override
  Future<void> persistSnapshot({
    required String accountId,
    required int expectedAuthEpoch,
    required DocumentSnapshot snapshot,
  }) async {
    persistedSnapshot = snapshot;
  }

  @override
  Future<ReadingCheckpoint?> readCheckpoint({
    required String accountId,
    required String paperId,
  }) async => null;

  @override
  Future<ReadingCheckpoint?> fetchCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async => null;

  @override
  Future<void> saveCheckpointLocally(
    ReadingCheckpoint checkpoint, {
    required int expectedAuthEpoch,
  }) async {}

  @override
  Future<ReadingCheckpoint> syncCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async => checkpoint;
}

DocumentSnapshot _snapshot(String text, {String? nextCursor}) {
  const provenance = ProvenanceSummary(status: 'ready');
  const paperId = '00000000-0000-4000-8000-000000000001';
  final block = _block(id: 'block-1', ordinal: 0, text: text);
  return DocumentSnapshot(
    paperId: paperId,
    versionKey: '2601.00001v1',
    generation: 2,
    outline: DocumentOutline(
      paperId: paperId,
      generation: 2,
      sections: [
        DocumentSection(
          id: 'section-1',
          stableKey: 'introduction',
          title: 'Introduction',
          level: 1,
          ordinal: 0,
          blockIds: const ['block-1'],
        ),
      ],
      provenance: provenance,
    ),
    blocks: [block],
    figures: const [],
    tables: const [],
    equations: const [],
    terms: const [],
    passport: null,
    provenance: provenance,
    fetchedAt: DateTime.utc(2026, 8, 31),
    nextCursor: nextCursor,
  );
}

ReadingCheckpoint _checkpoint({
  required int revision,
  required String blockId,
  int generation = 2,
  DateTime? lastReadAt,
  bool pendingSync = false,
  String? operationId,
}) => ReadingCheckpoint(
  accountId: 'account-a',
  paperId: '00000000-0000-4000-8000-000000000001',
  generation: generation,
  mode: ReaderDepthMode.read,
  stage: PaperStage.introduction,
  blockId: blockId,
  scrollFraction: .3,
  lastReadAt: lastReadAt ?? DateTime.utc(2026, 8, 31),
  revision: revision,
  pendingSync: pendingSync,
  operationId: operationId,
);

DocumentBlock _block({
  required String id,
  required int ordinal,
  required String text,
}) => DocumentBlock(
  id: id,
  paperId: '00000000-0000-4000-8000-000000000001',
  generation: 2,
  stableKey: 'introduction:paragraph:$ordinal',
  ordinal: ordinal,
  sectionPath: const ['Introduction'],
  kind: DocumentBlockKind.paragraph,
  text: text,
  contentHash: 'hash-$text',
);
