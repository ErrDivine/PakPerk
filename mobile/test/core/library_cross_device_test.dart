import 'dart:collection';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/sync/outbox_controller.dart';

import '../support/fakes.dart';

void main() {
  test('two devices converge through active changes and tombstones', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
    );
    final server = _SharedLibraryServer();
    final deviceA = _Device(server, [_deviceASave, _deviceAResave]);
    final deviceB = _Device(server, [_deviceBRemove]);
    addTearDown(deviceA.close);
    addTearDown(deviceB.close);

    await deviceA.repository.refresh(
      accountId: _accountId,
      authEpoch: 1,
      forceFull: true,
    );
    await deviceB.repository.refresh(
      accountId: _accountId,
      authEpoch: 1,
      forceFull: true,
    );

    await deviceA.setSaved(true);
    await deviceA.outbox.drain(accountId: _accountId, authEpoch: 1);
    await deviceA.repository.refresh(accountId: _accountId, authEpoch: 1);
    await deviceB.repository.refresh(accountId: _accountId, authEpoch: 1);
    expect(await deviceA.saved(), isTrue);
    expect(await deviceB.saved(), isTrue);

    await deviceB.setSaved(false);
    await deviceB.outbox.drain(accountId: _accountId, authEpoch: 1);
    await deviceB.repository.refresh(accountId: _accountId, authEpoch: 1);
    expect(await deviceB.saved(), isFalse);

    // Device A comes back after being offline and consumes B's tombstone.
    await deviceA.repository.refresh(accountId: _accountId, authEpoch: 1);
    expect(await deviceA.saved(), isFalse);
    expect(await deviceA.dao.syncCheckpoint(_accountId), (true, 2));
    expect(await deviceB.dao.syncCheckpoint(_accountId), (true, 2));

    // Simulate a process crash after the server accepted A's re-save but
    // before the local canonical transaction. Restart recovery must replay the
    // exact UUID; the server returns the same revision instead of mutating.
    await deviceA.setSaved(true);
    final inFlight = await deviceA.repository.claimNextDue(
      accountId: _accountId,
      now: deviceA.now,
    );
    expect(inFlight?.operationId, _deviceAResave);
    final accepted = await server.save(
      paperId: samplePaper.paperId,
      operationId: _deviceAResave,
      expectedAuthEpoch: 1,
    );
    expect(accepted.item.revision, 3);
    await deviceA.repository.recoverInFlight(_accountId);
    await deviceA.outbox.drain(accountId: _accountId, authEpoch: 1);

    expect(
      server.revision,
      3,
      reason: 'duplicate UUID must not mint revision 4',
    );
    expect(
      server.operationCalls.where((id) => id == _deviceAResave),
      hasLength(2),
    );
    expect(await deviceA.saved(), isTrue);
    expect(
      await deviceA.database.select(deviceA.database.syncOutbox).get(),
      isEmpty,
    );
    expect(
      (await deviceA.database.select(deviceA.database.libraryItems).getSingle())
          .revision,
      3,
    );
  });
}

final class _Device {
  _Device(LibraryRemoteDataSource server, List<String> operationIds)
    : database = PakPerkDatabase(NativeDatabase.memory()),
      now = DateTime.utc(2026, 7, 31, 12),
      _ids = Queue.of(operationIds) {
    dao = LibraryDao(database, clock: () => now, operationId: _ids.removeFirst);
    repository = LibraryRepository(
      local: dao,
      remote: server,
      sessionScope: () => (accountId: _accountId, authEpoch: 1),
      verifiedScope: () => (accountId: _accountId, authEpoch: 1),
    );
    outbox = LibraryOutboxController(repository: repository, clock: () => now);
  }

  final PakPerkDatabase database;
  final DateTime now;
  final Queue<String> _ids;
  late final LibraryDao dao;
  late final LibraryRepository repository;
  late final LibraryOutboxController outbox;

  Future<void> setSaved(bool value) => repository.setSaved(
    accountId: _accountId,
    authEpoch: 1,
    paperId: samplePaper.paperId,
    saved: value,
    paper: samplePaper,
  );

  Future<bool> saved() async =>
      (await repository.watchSavedState(_accountId, samplePaper.paperId).first)
          .saved;

  Future<void> close() => database.close();
}

final class _SharedLibraryServer implements LibraryRemoteDataSource {
  int revision = 0;
  LibraryCanonicalItem? current;
  final List<LibraryCanonicalItem> history = [];
  final Map<String, LibraryMutationIntent> ledger = {};
  final List<String> operationCalls = [];

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => _mutate(
    paperId: paperId,
    operationId: operationId,
    intent: LibraryMutationIntent.save,
  );

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => _mutate(
    paperId: paperId,
    operationId: operationId,
    intent: LibraryMutationIntent.remove,
  );

  Future<LibraryMutationResult> _mutate({
    required String paperId,
    required String operationId,
    required LibraryMutationIntent intent,
  }) async {
    operationCalls.add(operationId);
    final priorIntent = ledger[operationId];
    if (priorIntent != null) {
      if (priorIntent != intent) throw StateError('Operation intent changed.');
      return LibraryMutationResult(current!);
    }
    ledger[operationId] = intent;
    revision += 1;
    final acceptedAt = DateTime.utc(2026, 7, 31, 12, revision);
    final previous = current;
    final removed = intent == LibraryMutationIntent.remove;
    final savedAt = !removed && previous != null && !previous.removed
        ? previous.savedAt
        : acceptedAt;
    current = LibraryCanonicalItem(
      paperId: paperId,
      state: 'to_read',
      savedAt: savedAt,
      updatedAt: acceptedAt,
      removed: removed,
      removedAt: removed ? acceptedAt : null,
      revision: revision,
      lastOperationId: operationId,
    );
    history.add(current!);
    return LibraryMutationResult(current!);
  }

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async {
    if (cursor != null) throw StateError('One-page fake received a cursor.');
    final value = current;
    return LibraryListPage(
      items: value == null || value.removed
          ? const []
          : [LibraryRemoteEntry(item: value, paper: samplePaper)],
      nextCursor: null,
      syncRevision: revision,
    );
  }

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async {
    final items = history
        .where((item) => item.revision > afterRevision)
        .take(limit)
        .map(
          (item) => LibraryRemoteEntry(
            item: item,
            paper: item.removed ? null : samplePaper,
          ),
        )
        .toList(growable: false);
    final hasMore = history.any(
      (item) =>
          item.revision >
          (items.isEmpty ? afterRevision : items.last.item.revision),
    );
    return LibraryChangesPage(
      items: items,
      nextAfterRevision: hasMore ? items.last.item.revision : revision,
      hasMore: hasMore,
      syncRevision: revision,
    );
  }
}

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _deviceASave = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _deviceAResave = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _deviceBRemove = '018f47a6-4b56-7f4c-8c7a-e2656e820301';
