import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/library_v2_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

import '../support/fakes.dart';

void main() {
  test(
    'optimistic projection supersedes queued but never in-flight intent',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final ids = Queue.of([_operation1, _operation2]);
      final now = DateTime.utc(2026, 7, 31, 12);
      final dao = LibraryDao(
        database,
        clock: () => now,
        operationId: ids.removeFirst,
      );
      final scope = _Scope();
      final repository = _repository(dao, _FakeRemote(), scope);

      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: true,
        paper: samplePaper,
      );

      expect(
        await repository.watchSavedState(_accountId, samplePaper.paperId).first,
        const LibrarySavedState(saved: true, syncPending: true),
      );
      final localList = await repository.watchToRead(_accountId).first;
      expect(localList.single.paper.paperId, samplePaper.paperId);
      expect(localList.single.savedAt, now);
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isTrue,
      );
      final save = await repository.claimNextDue(
        accountId: _accountId,
        now: now,
      );
      expect(save?.operationId, _operation1);

      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: false,
        paper: samplePaper,
      );
      final outbox = await database.select(database.syncOutbox).get();
      expect(
        outbox.map((row) => row.state),
        containsAll(['in_flight', 'queued']),
      );
      expect(outbox, hasLength(2));
      expect(
        await repository.watchSavedState(_accountId, samplePaper.paperId).first,
        const LibrarySavedState(saved: false, syncPending: true),
      );

      await dao.applyMutationSuccess(
        operation: save!,
        item: _canonical(revision: 1, operationId: _operation1),
        scopeGuard: repository.scopeGuard(accountId: _accountId, authEpoch: 7),
      );
      var item = await database.select(database.libraryItems).getSingle();
      expect(item.canonicalDeleted, isFalse);
      expect(item.deleted, isTrue, reason: 'queued remove remains the overlay');
      expect(item.lastOperationId, _operation1);

      final remove = await repository.claimNextDue(
        accountId: _accountId,
        now: now,
      );
      expect(remove?.operationId, _operation2);
      await dao.applyMutationSuccess(
        operation: remove!,
        item: _canonical(revision: 2, operationId: _operation2, removed: true),
        scopeGuard: repository.scopeGuard(accountId: _accountId, authEpoch: 7),
      );
      item = await database.select(database.libraryItems).getSingle();
      expect(item.deleted, isTrue);
      expect(item.canonicalDeleted, isTrue);
      expect(item.revision, 2);
      expect(await database.select(database.syncOutbox).get(), isEmpty);
      expect(await repository.watchToRead(_accountId).first, isEmpty);
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isFalse,
      );
    },
  );

  test('Undo queues a fresh save behind an already-sent removal', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final ids = Queue.of([_operation1, _operation2]);
    final now = DateTime.utc(2026, 8, 1, 12);
    final dao = LibraryDao(
      database,
      clock: () => now,
      operationId: ids.removeFirst,
    );
    final scope = _Scope();
    final repository = _repository(dao, _FakeRemote(), scope);
    final guard = repository.scopeGuard(accountId: _accountId, authEpoch: 7);
    await dao.applyFullSnapshot(
      accountId: _accountId,
      entries: [
        LibraryRemoteEntry(
          item: _canonical(revision: 10, operationId: _serverOperation),
          paper: samplePaper,
        ),
      ],
      syncRevision: 10,
      scopeGuard: guard,
    );

    final removalId = await repository.setSaved(
      accountId: _accountId,
      authEpoch: 7,
      paperId: samplePaper.paperId,
      saved: false,
      paper: samplePaper,
    );
    final sentRemoval = await repository.claimNextDue(
      accountId: _accountId,
      now: now,
    );
    expect(sentRemoval?.operationId, removalId);
    expect(sentRemoval?.intent, LibraryMutationIntent.remove);

    final undoId = await repository.setSaved(
      accountId: _accountId,
      authEpoch: 7,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );

    expect(removalId, _operation1);
    expect(undoId, _operation2);
    expect(undoId, isNot(removalId));
    final outbox = await database.select(database.syncOutbox).get();
    final byId = {for (final row in outbox) row.operationId: row};
    expect(byId.keys, {removalId, undoId});
    expect(byId[removalId]?.state, 'in_flight');
    expect(byId[removalId]?.operation, 'library_remove');
    expect(byId[undoId]?.state, 'queued');
    expect(byId[undoId]?.operation, 'library_save');
  });

  test(
    'permanent failure rolls back to canonical and exposes safe issue',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 7, 31, 12);
      final dao = LibraryDao(
        database,
        clock: () => now,
        operationId: () => _operation1,
      );
      final scope = _Scope();
      final repository = _repository(dao, _FakeRemote(), scope);
      final guard = repository.scopeGuard(accountId: _accountId, authEpoch: 7);
      await dao.applyFullSnapshot(
        accountId: _accountId,
        entries: [
          LibraryRemoteEntry(
            item: _canonical(revision: 10, operationId: _serverOperation),
            paper: samplePaper,
          ),
        ],
        syncRevision: 10,
        scopeGuard: guard,
      );
      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: false,
        paper: samplePaper,
      );
      final operation = await repository.claimNextDue(
        accountId: _accountId,
        now: now,
      );
      await repository.failPermanently(
        operation: operation!,
        error: const ApiException(
          code: 'PAPER_NOT_FOUND',
          message: 'Raw server detail must not be persisted.',
          statusCode: 404,
        ),
        scopeGuard: guard,
      );

      final state = await repository
          .watchSavedState(_accountId, samplePaper.paperId)
          .first;
      expect(state.saved, isTrue);
      expect(state.syncPending, isFalse);
      expect(state.issue?.code, 'PAPER_NOT_FOUND');
      expect(state.issue?.message, isNot(contains('Raw server detail')));
      final failed = await database.select(database.syncOutbox).getSingle();
      expect(failed.state, 'failed');
      expect(failed.lastErrorCode, 'PAPER_NOT_FOUND');
      expect(failed.payloadJson, isNot(contains('Raw server detail')));
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isTrue,
      );
    },
  );

  test(
    'full snapshot overlays pending state then consumes ascending changes',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(
        database,
        clock: () => DateTime.utc(2026, 7, 31, 12),
        operationId: () => _operation1,
      );
      final scope = _Scope();
      final secondPaper = _paper('018f47a6-4b56-7f4c-8c7a-e2656e820102');
      final remote = _FakeRemote(
        listPages: [
          LibraryListPage(
            items: [
              LibraryRemoteEntry(
                item: _canonical(
                  paperId: secondPaper.paperId,
                  revision: 42,
                  operationId: _serverOperation,
                ),
                paper: secondPaper,
              ),
            ],
            nextCursor: null,
            syncRevision: 42,
          ),
        ],
        changesPages: [
          LibraryChangesPage(
            items: [
              LibraryRemoteEntry(
                item: _canonical(
                  paperId: secondPaper.paperId,
                  revision: 43,
                  operationId: _serverOperation2,
                  removed: true,
                ),
                paper: null,
              ),
            ],
            nextAfterRevision: 43,
            hasMore: false,
            syncRevision: 43,
          ),
        ],
      );
      final repository = _repository(dao, remote, scope);
      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: true,
        paper: samplePaper,
      );

      await repository.refresh(
        accountId: _accountId,
        authEpoch: 7,
        forceFull: true,
      );

      final pending = await repository
          .watchSavedState(_accountId, samplePaper.paperId)
          .first;
      expect(pending.saved, isTrue);
      expect(pending.syncPending, isTrue);
      final changed = await repository
          .watchSavedState(_accountId, secondPaper.paperId)
          .first;
      expect(changed.saved, isFalse);
      expect(await repository.watchToRead(_accountId).first, hasLength(1));
      expect(await dao.syncCheckpoint(_accountId), (true, 43));
      expect(remote.changesAfter, [42]);
      expect(remote.listAuthEpochs, [7]);
      expect(remote.changesAuthEpochs, [7]);
    },
  );

  test(
    '410 change history reset performs a canonical full replacement',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      final scope = _Scope();
      bool guard() => true;
      await dao.applyFullSnapshot(
        accountId: _accountId,
        entries: const [],
        syncRevision: 5,
        scopeGuard: guard,
      );
      final remote = _FakeRemote(
        resetOnce: true,
        listPages: [
          LibraryListPage(
            items: [
              LibraryRemoteEntry(
                item: _canonical(revision: 8, operationId: _serverOperation),
                paper: samplePaper,
              ),
            ],
            nextCursor: null,
            syncRevision: 8,
          ),
        ],
        changesPages: const [
          LibraryChangesPage(
            items: [],
            nextAfterRevision: 8,
            hasMore: false,
            syncRevision: 8,
          ),
        ],
      );
      final repository = _repository(dao, remote, scope);

      await repository.refresh(accountId: _accountId, authEpoch: 7);

      expect(
        (await repository
                .watchSavedState(_accountId, samplePaper.paperId)
                .first)
            .saved,
        isTrue,
      );
      expect(await dao.syncCheckpoint(_accountId), (true, 8));
      expect(remote.changesAfter, [5, 8]);
    },
  );

  test(
    'unverified identity permits local intent but no remote refresh',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database, operationId: () => _operation1);
      final scope = _Scope()..verified = false;
      final remote = _FakeRemote(
        listPages: [
          LibraryListPage(
            items: [
              LibraryRemoteEntry(
                item: _canonical(revision: 8, operationId: _serverOperation),
                paper: samplePaper,
              ),
            ],
            nextCursor: null,
            syncRevision: 8,
          ),
        ],
      );
      final repository = _repository(dao, remote, scope);

      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: true,
        paper: samplePaper,
      );
      await repository.refresh(
        accountId: _accountId,
        authEpoch: 7,
        forceFull: true,
      );

      expect(
        await repository.watchSavedState(_accountId, samplePaper.paperId).first,
        const LibrarySavedState(saved: true, syncPending: true),
      );
      expect(remote.listAuthEpochs, isEmpty);
      expect(remote.changesAuthEpochs, isEmpty);
      expect(await dao.syncCheckpoint(_accountId), (false, 0));
    },
  );

  test('scope loss rolls back an in-progress full snapshot', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final dao = LibraryDao(database);
    var scopeChecks = 0;

    await expectLater(
      dao.applyFullSnapshot(
        accountId: _accountId,
        entries: [
          LibraryRemoteEntry(
            item: _canonical(revision: 8, operationId: _serverOperation),
            paper: samplePaper,
          ),
        ],
        syncRevision: 8,
        // Expire immediately after the canonical paper and library rows have
        // been written, proving the enclosing transaction restores all of it.
        scopeGuard: () => ++scopeChecks <= 5,
      ),
      throwsA(isA<LibraryScopeChanged>()),
    );

    expect(await database.select(database.libraryItems).get(), isEmpty);
    expect(await database.select(database.cachedPapers).get(), isEmpty);
    expect(await database.select(database.librarySyncStates).get(), isEmpty);
    expect(await dao.syncCheckpoint(_accountId), (false, 0));
  });

  test('scope loss rolls back canonical mutation reconciliation', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final now = DateTime.utc(2026, 7, 31, 12);
    final dao = LibraryDao(
      database,
      clock: () => now,
      operationId: () => _operation1,
    );
    final scope = _Scope();
    final repository = _repository(dao, _FakeRemote(), scope);
    await repository.setSaved(
      accountId: _accountId,
      authEpoch: 7,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );
    final operation = await repository.claimNextDue(
      accountId: _accountId,
      now: now,
    );
    var scopeChecks = 0;

    await expectLater(
      dao.applyMutationSuccess(
        operation: operation!,
        item: _canonical(revision: 1, operationId: _operation1),
        // Expire after canonical reconciliation but before outbox deletion.
        scopeGuard: () => ++scopeChecks <= 2,
      ),
      throwsA(isA<LibraryScopeChanged>()),
    );

    final item = await database.select(database.libraryItems).getSingle();
    expect(item.canonicalDeleted, isNull);
    expect(item.revision, isNull);
    final outbox = await database.select(database.syncOutbox).getSingle();
    expect(outbox.operationId, _operation1);
    expect(outbox.state, 'in_flight');
  });

  test('local revision conflicts emit the closed sync boundary', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final legacy = LibraryDao(database);
    await legacy.applyFullSnapshot(
      accountId: _accountId,
      entries: const [],
      syncRevision: 9,
      scopeGuard: () => true,
    );
    final telemetry = _RecordingTelemetry();
    final scope = _Scope();
    final repository = LibraryRepository(
      local: legacy,
      remote: _FakeRemote(),
      sessionScope: () => (accountId: scope.accountId, authEpoch: scope.epoch),
      verifiedScope: () => (accountId: scope.accountId, authEpoch: scope.epoch),
      v2Local: LibraryV2Dao(
        database,
        operationId: () => _operation1,
        clock: () => DateTime.utc(2026, 8, 28),
      ),
      libraryV2Enabled: true,
      telemetry: RedactingTelemetrySink(telemetry),
    );

    await expectLater(
      repository.upsertTagV2(
        accountId: _accountId,
        authEpoch: 7,
        tagId: null,
        name: 'Methods',
        expectedRevision: 8,
      ),
      throwsA(isA<LibraryRevisionConflict>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      telemetry.events.single.$1,
      PakPerkTelemetryEvent.librarySyncConflict,
    );
    expect(telemetry.events.single.$2, const {'boundary': 'local_revision'});
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });
}

LibraryRepository _repository(
  LibraryDao dao,
  LibraryRemoteDataSource remote,
  _Scope scope,
) => LibraryRepository(
  local: dao,
  remote: remote,
  sessionScope: () => (accountId: scope.accountId, authEpoch: scope.epoch),
  verifiedScope: () => scope.verified
      ? (accountId: scope.accountId, authEpoch: scope.epoch)
      : null,
);

final class _Scope {
  String? accountId = _accountId;
  int epoch = 7;
  bool verified = true;
}

final class _FakeRemote implements LibraryRemoteDataSource {
  _FakeRemote({
    List<LibraryListPage> listPages = const [],
    List<LibraryChangesPage> changesPages = const [],
    this.resetOnce = false,
  }) : _listPages = Queue.of(listPages),
       _changesPages = Queue.of(changesPages);

  final Queue<LibraryListPage> _listPages;
  final Queue<LibraryChangesPage> _changesPages;
  bool resetOnce;
  final List<int> changesAfter = [];
  final List<int> listAuthEpochs = [];
  final List<int> changesAuthEpochs = [];

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async {
    changesAfter.add(afterRevision);
    changesAuthEpochs.add(expectedAuthEpoch);
    if (resetOnce) {
      resetOnce = false;
      throw const ApiException(
        code: 'LIBRARY_SYNC_RESET_REQUIRED',
        message: 'Reset.',
        statusCode: 410,
        retryable: true,
      );
    }
    if (_changesPages.isEmpty) {
      return LibraryChangesPage(
        items: const [],
        nextAfterRevision: afterRevision,
        hasMore: false,
        syncRevision: afterRevision,
      );
    }
    return _changesPages.removeFirst();
  }

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async {
    listAuthEpochs.add(expectedAuthEpoch);
    return _listPages.removeFirst();
  }

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => throw UnimplementedError();

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
    LibrarySaveSourceKind? saveSourceKind,
  }) => throw UnimplementedError();
}

final class _RecordingTelemetry implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map.unmodifiable(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

LibraryCanonicalItem _canonical({
  String paperId = '',
  required int revision,
  required String operationId,
  bool removed = false,
}) {
  final savedAt = DateTime.utc(2026, 7, 31, 12);
  return LibraryCanonicalItem(
    paperId: paperId.isEmpty ? samplePaper.paperId : paperId,
    state: 'to_read',
    savedAt: savedAt,
    updatedAt: savedAt.add(Duration(minutes: revision)),
    removed: removed,
    removedAt: removed ? savedAt.add(Duration(minutes: revision)) : null,
    revision: revision,
    lastOperationId: operationId,
  );
}

PaperSummary _paper(String paperId) => PaperSummary.fromJson(
  samplePaper.toJson()
    ..['paper_id'] = paperId
    ..['arxiv_id'] = '2607.12345v1'
    ..['title'] = 'Second saved paper',
);

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _operation1 = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _operation2 = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _serverOperation = '018f47a6-4b56-7f4c-8c7a-e2656e820301';
const _serverOperation2 = '018f47a6-4b56-7f4c-8c7a-e2656e820302';
