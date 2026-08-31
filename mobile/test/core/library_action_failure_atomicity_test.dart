import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/library_v2_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_action_failure.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/library/library_v2_models.dart';

import '../support/fakes.dart';

void main() {
  late PakPerkDatabase database;
  late LibraryDao legacy;
  late LibraryV2Dao v2;
  late LibraryRepository repository;

  setUp(() async {
    database = PakPerkDatabase(NativeDatabase.memory());
    legacy = LibraryDao(database, clock: () => _now);
    var nextOperation = 0;
    v2 = LibraryV2Dao(
      database,
      clock: () => _now,
      operationId: () => _operation(++nextOperation),
    );
    repository = LibraryRepository(
      local: legacy,
      remote: const _UnusedRemote(),
      sessionScope: () => (accountId: _accountId, authEpoch: 7),
      verifiedScope: () => (accountId: _accountId, authEpoch: 7),
      v2Local: v2,
      libraryV2Enabled: true,
    );
    await PaperCacheDao(database).save(samplePaper, accessedAt: _now);
    await database
        .into(database.libraryItems)
        .insert(
          LibraryItemsCompanion.insert(
            accountId: _accountId,
            paperId: samplePaper.paperId,
            listState: const Value('inbox'),
            privateNote: const Value('Confirmed note'),
            reminderAt: Value(_confirmedReminder),
            clientUpdatedAt: _now,
            serverUpdatedAt: Value(_now),
            savedAt: Value(_now),
            revision: const Value(9),
            lastOperationId: const Value(_serverOperationId),
            saveSourceKind: const Value('lookup'),
            canonicalDeleted: const Value(false),
            canonicalSavedAt: Value(_now),
            canonicalListState: const Value('inbox'),
            canonicalPrivateNote: const Value('Confirmed note'),
            canonicalSaveSourceKind: const Value('lookup'),
            canonicalReminderAt: Value(_confirmedReminder),
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
    await v2.enqueueItemEdit(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      state: LibraryItemState.reviewed,
      privateNote: 'Optimistic private note',
      reminderAt: null,
      listNames: const [],
      tagNames: const [],
      expectedRevision: 9,
      scopeGuard: () => true,
    );
  });

  tearDown(() => database.close());

  Future<void> enqueueThreeSuccessors() async {
    for (var index = 1; index <= 3; index += 1) {
      await v2.enqueueItemEdit(
        accountId: _accountId,
        paperId: samplePaper.paperId,
        state: LibraryItemState.inbox,
        privateNote: 'Successor $index',
        reminderAt: null,
        listNames: const [],
        tagNames: const [],
        expectedRevision: 9,
        scopeGuard: () => true,
      );
    }
  }

  test('failed alert is not observable before canonical rollback', () async {
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );
    expect(operation, isNotNull);
    final observed = repository
        .watchActionFailureAlerts(_accountId)
        .where((alerts) => alerts.isNotEmpty)
        .asyncMap((alerts) async {
          final item = await database.select(database.libraryItems).getSingle();
          return (alerts: alerts, item: item);
        })
        .first;

    await repository.failPermanently(
      operation: operation!,
      error: const ApiException(
        code: 'INVALID_LIBRARY_MUTATION',
        message: 'Rejected.',
        statusCode: 422,
      ),
      scopeGuard: () => true,
    );

    final committed = await observed.timeout(const Duration(seconds: 2));
    expect(committed.alerts.single.kind, LibraryActionFailureKind.paperEdit);
    expect(committed.item.listState, 'inbox');
    expect(committed.item.privateNote, 'Confirmed note');
    expect(committed.item.reminderAt?.toUtc(), _confirmedReminder);
  });

  test('scope loss rolls back both terminal mark and v2 restoration', () async {
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );
    var scopeChecks = 0;

    await expectLater(
      repository.failPermanently(
        operation: operation!,
        error: const ApiException(
          code: 'INVALID_LIBRARY_MUTATION',
          message: 'Rejected.',
          statusCode: 422,
        ),
        // Expire after the optimistic row is restored but before the outer
        // terminal-failure transaction may commit.
        scopeGuard: () => ++scopeChecks < 5,
      ),
      throwsA(isA<LibraryScopeChanged>()),
    );

    final outbox = await database.select(database.syncOutbox).getSingle();
    final item = await database.select(database.libraryItems).getSingle();
    expect(outbox.state, 'in_flight');
    expect(item.listState, 'reviewed');
    expect(item.privateNote, 'Optimistic private note');
    expect(item.reminderAt, isNull);
    expect(
      await repository.watchActionFailureAlerts(_accountId).first,
      isEmpty,
    );
  });

  test('scope loss after successor lookup rolls terminal mark back', () async {
    await v2.enqueueItemEdit(
      accountId: _accountId,
      paperId: samplePaper.paperId,
      state: LibraryItemState.inbox,
      privateNote: 'Newer intent',
      reminderAt: null,
      listNames: const [],
      tagNames: const [],
      expectedRevision: 9,
      scopeGuard: () => true,
    );
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );
    var scopeChecks = 0;

    await expectLater(
      repository.failPermanently(
        operation: operation!,
        error: const ApiException(
          code: 'INVALID_LIBRARY_MUTATION',
          message: 'Rejected.',
          statusCode: 422,
        ),
        scopeGuard: () => ++scopeChecks < 4,
      ),
      throwsA(isA<LibraryScopeChanged>()),
    );

    final rows = await database.select(database.syncOutbox).get();
    expect(
      {for (final row in rows) row.operationId: row.state},
      {_operation(1): 'in_flight', _operation(2): 'queued'},
    );
  });

  test('retry tolerates three queued successors for one entity', () async {
    await enqueueThreeSuccessors();
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );

    await legacy.markRetry(
      operation: operation!,
      errorCode: 'NETWORK_UNAVAILABLE',
      nextAttemptAt: _now.add(const Duration(minutes: 5)),
      scopeGuard: () => true,
    );

    final rows = await database.select(database.syncOutbox).get();
    expect(
      {for (final row in rows) row.operationId: row.state},
      {
        _operation(1): 'recovery',
        _operation(2): 'queued',
        _operation(3): 'queued',
        _operation(4): 'queued',
      },
    );
  });

  test('success preserves the newest of three queued successors', () async {
    await enqueueThreeSuccessors();
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );

    await v2.applyMutationSuccess(
      operation: operation!,
      value: _serverItem(operation.operationId),
      scopeGuard: () => true,
    );

    final rows = await database.select(database.syncOutbox).get();
    final item = await database.select(database.libraryItems).getSingle();
    expect(rows.map((row) => row.operationId).toSet(), {
      _operation(2),
      _operation(3),
      _operation(4),
    });
    expect(rows.every((row) => row.state == 'queued'), isTrue);
    expect(item.privateNote, 'Successor 3');
    expect(item.lastOperationId, _operation(4));
    expect(item.canonicalPrivateNote, 'Server confirmed');
  });

  test('terminal failure keeps three newer intents authoritative', () async {
    await enqueueThreeSuccessors();
    final operation = await legacy.claimNextDue(
      accountId: _accountId,
      now: _now.add(const Duration(minutes: 1)),
    );

    await repository.failPermanently(
      operation: operation!,
      error: const ApiException(
        code: 'INVALID_LIBRARY_MUTATION',
        message: 'Rejected.',
        statusCode: 422,
      ),
      scopeGuard: () => true,
    );

    final rows = await database.select(database.syncOutbox).get();
    final item = await database.select(database.libraryItems).getSingle();
    expect(
      {for (final row in rows) row.operationId: row.state},
      {
        _operation(1): 'failed',
        _operation(2): 'queued',
        _operation(3): 'queued',
        _operation(4): 'queued',
      },
    );
    expect(item.privateNote, 'Successor 3');
    expect(
      await repository.watchActionFailureAlerts(_accountId).first,
      isEmpty,
    );
  });

  test(
    'missing canonical proof retains the last item as active Inbox',
    () async {
      await (database.update(
        database.libraryItems,
      )..where((row) => row.accountId.equals(_accountId))).write(
        const LibraryItemsCompanion(
          canonicalDeleted: Value(null),
          canonicalListState: Value(null),
          canonicalSavedAt: Value(null),
        ),
      );
      final operation = await legacy.claimNextDue(
        accountId: _accountId,
        now: _now.add(const Duration(minutes: 1)),
      );

      await repository.failPermanently(
        operation: operation!,
        error: const ApiException(
          code: 'INVALID_LIBRARY_MUTATION',
          message: 'Rejected.',
          statusCode: 422,
        ),
        scopeGuard: () => true,
      );

      final item = await database.select(database.libraryItems).getSingle();
      expect(item.deleted, isFalse);
      expect(item.listState, 'inbox');
      expect(await repository.watchToRead(_accountId).first, hasLength(1));
    },
  );
}

LibraryV2Item _serverItem(String operationId) => LibraryV2Item(
  paperId: samplePaper.paperId,
  state: LibraryItemState.inbox,
  privateNote: 'Server confirmed',
  saveSourceKind: LibrarySaveSourceKind.lookup,
  reminderAt: null,
  savedAt: _now,
  updatedAt: _now.add(const Duration(seconds: 2)),
  reviewedAt: null,
  archivedAt: null,
  removed: false,
  removedAt: null,
  revision: 10,
  lastOperationId: operationId,
);

final class _UnusedRemote implements LibraryRemoteDataSource {
  const _UnusedRemote();

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) => throw UnimplementedError();

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) => throw UnimplementedError();

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

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _serverOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820301';
final _now = DateTime.utc(2026, 8, 28, 10);
final _confirmedReminder = DateTime.utc(2026, 9, 1, 10);

String _operation(int value) =>
    '018f47a6-4b56-7f4c-8c7a-${(0xe2656e820200 + value).toRadixString(16)}';
