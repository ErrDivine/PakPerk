import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/library_v2_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_v2_models.dart';

import '../support/fakes.dart';

void main() {
  late PakPerkDatabase database;
  late LibraryDao legacy;
  late LibraryV2Dao dao;
  late Iterator<String> ids;

  setUp(() async {
    database = PakPerkDatabase(NativeDatabase.memory());
    legacy = LibraryDao(database);
    ids = _ids.iterator;
    dao = LibraryV2Dao(
      database,
      operationId: () {
        ids.moveNext();
        return ids.current;
      },
      clock: () => DateTime.utc(2026, 8, 19, 10),
    );
    await PaperCacheDao(database).save(samplePaper);
    await database
        .into(database.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            accountId: _accountId,
            paperId: samplePaper.paperId,
            listState: const Value('inbox'),
            clientUpdatedAt: DateTime.utc(2026, 8, 19, 9),
            serverUpdatedAt: Value(DateTime.utc(2026, 8, 19, 9)),
            savedAt: Value(DateTime.utc(2026, 8, 19, 9)),
            revision: const Value(9),
            lastOperationId: const Value(_serverOperationId),
            saveSourceKind: const Value('lookup'),
            canonicalDeleted: const Value(false),
            canonicalSavedAt: Value(DateTime.utc(2026, 8, 19, 9)),
            canonicalListState: const Value('inbox'),
            canonicalSaveSourceKind: const Value('lookup'),
          ),
        );
    await database
        .into(database.librarySyncStates)
        .insert(
          LibrarySyncStatesCompanion.insert(
            accountId: _accountId,
            lastRevision: const Value(9),
            initialized: const Value(true),
          ),
        );
  });

  tearDown(() => database.close());

  test('edit is atomic, optimistic, ordered, and visible with names', () async {
    final result = await dao.enqueueItemEdit(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      state: LibraryItemState.reviewed,
      privateNote: ' Compare proofs ',
      reminderAt: null,
      listNames: const ['Methods'],
      tagNames: const ['Evaluation'],
      expectedRevision: 9,
      scopeGuard: () => true,
    );

    expect(result.operationIds, hasLength(5));
    final item = await database.select(database.libraryItems).getSingle();
    expect(item.listState, 'reviewed');
    expect(item.privateNote, 'Compare proofs');
    expect(item.canonicalListState, 'inbox');
    expect(
      await database.select(database.libraryCustomLists).get(),
      hasLength(1),
    );
    expect(await database.select(database.libraryTags).get(), hasLength(1));
    expect(
      await database.select(database.libraryListMemberships).get(),
      hasLength(1),
    );
    expect(
      await database.select(database.libraryTagMemberships).get(),
      hasLength(1),
    );
    final outbox = await (database.select(
      database.syncOutbox,
    )..orderBy([(row) => OrderingTerm.asc(row.createdAt)])).get();
    expect(outbox.map((row) => row.operation), [
      'library_v2_item_put_inactive',
      'library_v2_list_create',
      'library_v2_list_item_put',
      'library_v2_tag_create',
      'library_v2_item_tag_put',
    ]);
    expect(
      outbox.map((row) => row.createdAt).toSet(),
      hasLength(outbox.length),
      reason: 'dependent creates must remain ahead of membership writes',
    );
    final visible = await legacy.watchLibraryItems(_accountId).first;
    expect(visible.single.state, LibraryItemState.reviewed);
    expect(visible.single.privateNote, 'Compare proofs');
    expect(visible.single.listNames, ['Methods']);
    expect(visible.single.tagNames, ['Evaluation']);
    expect(visible.single.saveSourceKind, LibrarySaveSourceKind.lookup);
    expect(
      await legacy.watchPendingIntents(_accountId).first,
      const LibraryPendingIntentCounts(saves: 0, removes: 1),
    );
  });

  test(
    'stale editor revision and scope changes fail before durable writes',
    () async {
      await expectLater(
        dao.enqueueItemEdit(
          accountId: _accountId,
          paperId: samplePaper.paperId,
          state: LibraryItemState.readNext,
          privateNote: '',
          reminderAt: null,
          listNames: const [],
          tagNames: const [],
          expectedRevision: 8,
          scopeGuard: () => true,
        ),
        throwsA(isA<LibraryRevisionConflict>()),
      );
      await expectLater(
        dao.enqueueItemEdit(
          accountId: _accountId,
          paperId: samplePaper.paperId,
          state: LibraryItemState.readNext,
          privateNote: '',
          reminderAt: null,
          listNames: const [],
          tagNames: const [],
          expectedRevision: 9,
          scopeGuard: () => false,
        ),
        throwsA(isA<LibraryScopeChanged>()),
      );
      expect(await database.select(database.syncOutbox).get(), isEmpty);
    },
  );

  test(
    'remove is optimistic, clears reminders, and queues one active removal',
    () async {
      await (database.update(database.libraryItems)..where(
            (row) =>
                row.accountId.equals(_accountId) &
                row.paperId.equals(samplePaper.paperId),
          ))
          .write(
            LibraryItemsCompanion(
              reminderAt: Value(DateTime.utc(2026, 8, 20, 9)),
            ),
          );

      final result = await dao.enqueueItemRemove(
        accountId: _accountId,
        paperId: samplePaper.paperId,
        expectedRevision: 9,
        scopeGuard: () => true,
      );

      expect(result.operationIds, [_ids.first]);
      final item = await database.select(database.libraryItems).getSingle();
      expect(item.deleted, isTrue);
      expect(item.removedAt?.toUtc(), DateTime.utc(2026, 8, 19, 10));
      expect(item.reminderAt, isNull);
      expect(await legacy.watchLibraryItems(_accountId).first, isEmpty);

      final operation = await database.select(database.syncOutbox).getSingle();
      expect(operation.operation, 'library_v2_item_delete');
      expect(operation.entityId, samplePaper.paperId);
      expect(operation.payloadJson, contains(samplePaper.paperId));
      expect(
        await legacy.watchPendingIntents(_accountId).first,
        const LibraryPendingIntentCounts(saves: 0, removes: 1),
      );
    },
  );

  test(
    'canonical success advances fields and removes only its outbox row',
    () async {
      await dao.enqueueItemEdit(
        accountId: _accountId,
        paperId: samplePaper.paperId,
        state: LibraryItemState.readNext,
        privateNote: 'Next',
        reminderAt: null,
        listNames: const [],
        tagNames: const [],
        expectedRevision: 9,
        scopeGuard: () => true,
      );
      final operation = await legacy.claimNextDue(
        accountId: _accountId,
        now: DateTime.utc(2026, 8, 19, 10, 1),
      );
      expect(operation, isNotNull);
      await dao.applyMutationSuccess(
        operation: operation!,
        value: LibraryV2Item.fromJson(_canonicalItem()),
        scopeGuard: () => true,
      );

      expect(await database.select(database.syncOutbox).get(), isEmpty);
      final item = await database.select(database.libraryItems).getSingle();
      expect(item.listState, 'read_next');
      expect(item.privateNote, 'Next');
      expect(item.revision, 10);
      expect(item.canonicalListState, 'read_next');
      expect(item.canonicalPrivateNote, 'Next');
    },
  );

  test('a retrying v2 dependency blocks later membership work', () async {
    await dao.enqueueItemEdit(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      state: LibraryItemState.readNext,
      privateNote: '',
      reminderAt: null,
      listNames: const ['Methods'],
      tagNames: const [],
      expectedRevision: 9,
      scopeGuard: () => true,
    );
    final first = await legacy.claimNextDue(
      accountId: _accountId,
      now: DateTime.utc(2026, 8, 19, 10, 1),
    );
    await legacy.markRetry(
      operation: first!,
      errorCode: 'RATE_LIMITED',
      nextAttemptAt: DateTime.utc(2026, 8, 19, 11),
      scopeGuard: () => true,
    );

    expect(
      await legacy.claimNextDue(
        accountId: _accountId,
        now: DateTime.utc(2026, 8, 19, 10, 2),
      ),
      isNull,
    );
    expect(
      await legacy.nextAttemptAt(_accountId),
      DateTime.utc(2026, 8, 19, 11),
    );
  });

  test(
    'standalone list and tag changes are optimistic and outbox-backed',
    () async {
      await dao.enqueueListUpsert(
        accountId: _accountId,
        listId: null,
        name: 'Reading group',
        description: 'Thursday discussion',
        sortOrder: 1000,
        expectedRevision: 9,
        scopeGuard: () => true,
      );
      await dao.enqueueTagUpsert(
        accountId: _accountId,
        tagId: null,
        name: 'Methods',
        expectedRevision: 9,
        scopeGuard: () => true,
      );

      final lists = await dao.watchLists(_accountId).first;
      final tags = await dao.watchTags(_accountId).first;
      expect(lists.single.id, _ids[0]);
      expect(lists.single.name, 'Reading group');
      expect(lists.single.description, 'Thursday discussion');
      expect(lists.single.syncPending, isTrue);
      expect(tags.single.id, _ids[2]);
      expect(tags.single.name, 'Methods');
      expect(tags.single.syncPending, isTrue);

      await dao.enqueueListDelete(
        accountId: _accountId,
        listId: lists.single.id,
        expectedRevision: 9,
        scopeGuard: () => true,
      );
      await dao.enqueueTagDelete(
        accountId: _accountId,
        tagId: tags.single.id,
        expectedRevision: 9,
        scopeGuard: () => true,
      );

      expect(await dao.watchLists(_accountId).first, isEmpty);
      expect(await dao.watchTags(_accountId).first, isEmpty);
      final operations = await (database.select(
        database.syncOutbox,
      )..orderBy([(row) => OrderingTerm.asc(row.createdAt)])).get();
      expect(
        operations.map((row) => row.operation),
        unorderedEquals(const [
          'library_v2_list_create',
          'library_v2_tag_create',
          'library_v2_list_delete',
          'library_v2_tag_delete',
        ]),
      );
    },
  );

  test('list and tag names reject server-incompatible spacing', () async {
    for (final action in <Future<LibraryV2EnqueueResult> Function()>[
      () => dao.enqueueListUpsert(
        accountId: _accountId,
        listId: null,
        name: 'Reading  group',
        description: '',
        sortOrder: 0,
        expectedRevision: 9,
        scopeGuard: () => true,
      ),
      () => dao.enqueueTagUpsert(
        accountId: _accountId,
        tagId: null,
        name: 'Methods\nprivate',
        expectedRevision: 9,
        scopeGuard: () => true,
      ),
    ]) {
      await expectLater(action(), throwsArgumentError);
    }
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });
}

Map<String, Object?> _canonicalItem() => {
  'paper_id': samplePaper.paperId,
  'state': 'read_next',
  'private_note': 'Next',
  'save_source_kind': 'lookup',
  'reminder_at': null,
  'saved_at': '2026-08-19T09:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'reviewed_at': null,
  'archived_at': null,
  'removed': false,
  'removed_at': null,
  'revision': 10,
  'last_operation_id': _ids.first,
};

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _serverOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
const _ids = [
  '018f47a6-4b56-7f4c-8c7a-e2656e821001',
  '018f47a6-4b56-7f4c-8c7a-e2656e821002',
  '018f47a6-4b56-7f4c-8c7a-e2656e821003',
  '018f47a6-4b56-7f4c-8c7a-e2656e821004',
  '018f47a6-4b56-7f4c-8c7a-e2656e821005',
  '018f47a6-4b56-7f4c-8c7a-e2656e821006',
  '018f47a6-4b56-7f4c-8c7a-e2656e821007',
];
