import 'dart:collection';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_models.dart';

import '../support/fakes.dart';

void main() {
  test('pending authority distinguishes saves from final removes', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final operationIds = Queue.of([_operation1, _operation2]);
    final dao = LibraryDao(
      database,
      operationId: operationIds.removeFirst,
      clock: () => DateTime.utc(2026, 8, 19, 12),
    );

    expect(
      await dao.watchPendingIntents(_accountId).first,
      const LibraryPendingIntentCounts.empty(),
    );
    await dao.enqueueMutation(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );
    expect(
      await dao.watchPendingIntents(_accountId).first,
      const LibraryPendingIntentCounts(saves: 1, removes: 0),
    );

    await dao.enqueueMutation(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      saved: false,
    );
    expect(
      await dao.watchPendingIntents(_accountId).first,
      const LibraryPendingIntentCounts(saves: 0, removes: 1),
    );
  });

  test('sync reset is observable until a full snapshot commits', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final dao = LibraryDao(database);
    bool guard() => true;

    await dao.applyFullSnapshot(
      accountId: _accountId,
      entries: const [],
      syncRevision: 9,
      scopeGuard: guard,
    );
    expect(
      await dao.watchSyncCheckpoint(_accountId).first,
      const LibrarySyncCheckpoint(initialized: true, lastRevision: 9),
    );

    await dao.beginSyncReset(accountId: _accountId, scopeGuard: guard);
    final resetting = await dao.watchSyncCheckpoint(_accountId).first;
    expect(resetting.initialized, isFalse);
    expect(resetting.lastRevision, 9);
    expect(resetting.resetting, isTrue);

    await dao.applyFullSnapshot(
      accountId: _accountId,
      entries: const [],
      syncRevision: 12,
      scopeGuard: guard,
    );
    expect(
      await dao.watchSyncCheckpoint(_accountId).first,
      const LibrarySyncCheckpoint(initialized: true, lastRevision: 12),
    );
  });

  test(
    'canonical import projects immediately without a duplicate outbox save',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      bool guard() => true;
      final imported = _canonicalImport(revision: 10, operationId: _operation1);

      await dao.applyImportedPaper(
        accountId: _accountId,
        item: imported,
        paper: samplePaper,
        syncRevision: 10,
        scopeGuard: guard,
      );

      final queue = await dao.watchToRead(_accountId).first;
      expect(queue.single.paper.paperId, samplePaper.paperId);
      expect(queue.single.savedState.syncPending, isFalse);
      expect(
        await dao.watchPendingIntents(_accountId).first,
        const LibraryPendingIntentCounts.empty(),
      );
      expect(
        await dao.watchSyncCheckpoint(_accountId).first,
        const LibrarySyncCheckpoint.unknown(),
      );
    },
  );

  test(
    'canonical import advances an initialized checkpoint only forward',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      bool guard() => true;

      await dao.applyFullSnapshot(
        accountId: _accountId,
        entries: const [],
        syncRevision: 9,
        scopeGuard: guard,
      );
      await dao.applyImportedPaper(
        accountId: _accountId,
        item: _canonicalImport(revision: 10, operationId: _operation2),
        paper: samplePaper,
        syncRevision: 10,
        scopeGuard: guard,
      );

      expect(
        await dao.watchSyncCheckpoint(_accountId).first,
        const LibrarySyncCheckpoint(initialized: true, lastRevision: 10),
      );
    },
  );

  test(
    'only active v0.1 states participate in local queue authority',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      bool guard() => true;

      await dao.applyImportedPaper(
        accountId: _accountId,
        item: _canonicalImport(revision: 1, operationId: _operation1),
        paper: samplePaper,
        syncRevision: 1,
        scopeGuard: guard,
      );

      for (final state in LibraryItemState.values) {
        await (database.update(database.libraryItems)
              ..where((row) => row.accountId.equals(_accountId)))
            .write(LibraryItemsCompanion(listState: Value(state.storageValue)));
        final library = await dao.watchLibraryItems(_accountId).first;
        expect(library.single.state, state);
        final queue = await dao.watchToRead(_accountId).first;
        expect(queue.isNotEmpty, state.isActive, reason: state.storageValue);
      }

      await (database.update(database.libraryItems)
            ..where((row) => row.accountId.equals(_accountId)))
          .write(const LibraryItemsCompanion(listState: Value('to_read')));
      expect(
        (await dao.watchToRead(_accountId).first).single.state,
        LibraryItemState.inbox,
      );

      await (database.update(database.libraryItems)
            ..where((row) => row.accountId.equals(_accountId)))
          .write(const LibraryItemsCompanion(listState: Value('future_state')));
      expect(
        (await dao.watchToRead(_accountId).first).single.state,
        LibraryItemState.inbox,
      );
      expect(await dao.watchLibraryItems(_accountId).first, isEmpty);
    },
  );
}

LibraryCanonicalItem _canonicalImport({
  required int revision,
  required String operationId,
}) => LibraryCanonicalItem(
  paperId: samplePaper.paperId,
  state: 'to_read',
  savedAt: DateTime.utc(2026, 8, 19, 12),
  updatedAt: DateTime.utc(2026, 8, 19, 12),
  removed: false,
  removedAt: null,
  revision: revision,
  lastOperationId: operationId,
);

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _operation1 = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _operation2 = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
