import 'dart:async';
import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/sync/outbox_controller.dart';
import 'package:pakperk/core/sync/retry_policy.dart';

import '../support/fakes.dart';

void main() {
  test('retry policy always adds positive bounded jitter', () {
    final zero = OutboxRetryPolicy(jitter: () => 0);
    final high = OutboxRetryPolicy(jitter: () => 1);

    expect(zero.delayFor(completedAttempts: 0), const Duration(seconds: 5));
    expect(high.delayFor(completedAttempts: 0), const Duration(seconds: 6));
    final cappedLow = zero.delayFor(completedAttempts: 20);
    final cappedHigh = high.delayFor(completedAttempts: 20);
    expect(cappedLow, lessThan(cappedHigh));
    expect(cappedLow, lessThan(const Duration(hours: 1)));
    expect(cappedHigh, const Duration(hours: 1));
    expect(
      high.delayFor(
        completedAttempts: 0,
        retryAfter: const Duration(seconds: 17),
      ),
      const Duration(seconds: 17),
    );
    expect(
      high.delayFor(completedAttempts: 0, retryAfter: const Duration(days: 2)),
      const Duration(days: 2),
    );
    expect(
      high.delayFor(
        completedAttempts: 20,
        retryAfter: const Duration(seconds: 17),
      ),
      const Duration(hours: 1),
      reason: 'Retry-After is a minimum, not a shorter replacement delay.',
    );
  });

  test('429 remains optimistic and honors Retry-After durably', () async {
    final harness = await _Harness.create(
      saveBehaviors: [
        (operationId) async => throw const ApiException(
          code: 'RATE_LIMITED',
          message: 'Retry later.',
          retryable: true,
          statusCode: 429,
          retryAfter: Duration(seconds: 17),
        ),
      ],
    );
    addTearDown(harness.close);
    await harness.enqueueSave();

    final result = await harness.outbox.drain(
      accountId: _accountId,
      authEpoch: 7,
    );

    expect(result.pendingCount, 1);
    expect(result.nextAttemptAt, harness.now.add(const Duration(seconds: 17)));
    final row = await harness.database
        .select(harness.database.syncOutbox)
        .getSingle();
    expect(row.state, 'queued');
    expect(row.attemptCount, 1);
    expect(row.lastErrorCode, 'RATE_LIMITED');
    expect(
      row.nextAttemptAt?.toUtc(),
      harness.now.add(const Duration(seconds: 17)),
    );
    expect(row.updatedAt?.toUtc(), harness.now);
    final saved = await harness.repository
        .watchSavedState(_accountId, samplePaper.paperId)
        .first;
    expect(saved.saved, isTrue);
    expect(saved.syncPending, isTrue);
  });

  test(
    'unverified identity cannot claim or upload local outbox work',
    () async {
      final harness = await _Harness.create(
        saveBehaviors: [
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 1, operationId: operationId),
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();
      harness.scope.verified = false;

      final result = await harness.outbox.drain(
        accountId: _accountId,
        authEpoch: 7,
      );

      expect(result.scopeChanged, isTrue);
      expect(harness.remote.calls, isEmpty);
      final row = await harness.database
          .select(harness.database.syncOutbox)
          .getSingle();
      expect(row.state, 'queued');
      expect(row.attemptCount, 0);
    },
  );

  test(
    'restart recovers in-flight and replays the same operation UUID',
    () async {
      final harness = await _Harness.create(
        saveBehaviors: [
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 1, operationId: operationId),
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();
      final claimed = await harness.repository.claimNextDue(
        accountId: _accountId,
        now: harness.now,
      );
      expect(claimed?.operationId, _operation1);
      expect(
        (await harness.database.select(harness.database.syncOutbox).getSingle())
            .state,
        'in_flight',
      );

      await harness.repository.recoverInFlight(_accountId);
      await harness.outbox.drain(accountId: _accountId, authEpoch: 7);

      expect(harness.remote.saveOperationIds, [_operation1]);
      expect(harness.remote.expectedAuthEpochs, [7]);
      expect(
        await harness.database.select(harness.database.syncOutbox).get(),
        isEmpty,
      );
      final item = await harness.database
          .select(harness.database.libraryItems)
          .getSingle();
      expect(item.canonicalDeleted, isFalse);
      expect(item.lastOperationId, _operation1);
    },
  );

  test(
    'restart reclaims in-flight before equal-time queued successor',
    () async {
      final harness = await _Harness.create(
        operationIds: [_operationHigh, _operationLow],
        saveBehaviors: [
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 1, operationId: operationId),
          ),
        ],
        removeBehaviors: [
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 2, operationId: operationId, removed: true),
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();
      expect(
        (await harness.repository.claimNextDue(
          accountId: _accountId,
          now: harness.now,
        ))?.operationId,
        _operationHigh,
      );
      await harness.repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: false,
        paper: samplePaper,
      );

      await harness.repository.recoverInFlight(_accountId);
      final recovered = await harness.database
          .select(harness.database.syncOutbox)
          .get();
      expect(
        recovered.map((row) => row.state),
        containsAll(['recovery', 'queued']),
      );
      await harness.outbox.drain(accountId: _accountId, authEpoch: 7);

      expect(harness.remote.calls, [
        'save:$_operationHigh',
        'remove:$_operationLow',
      ]);
      expect(
        await harness.database.select(harness.database.syncOutbox).get(),
        isEmpty,
      );
      expect(
        (await harness.database
                .select(harness.database.libraryItems)
                .getSingle())
            .canonicalDeleted,
        isTrue,
      );
    },
  );

  test(
    'late result is epoch-guarded then safely replayed after recovery',
    () async {
      final firstResponse = Completer<LibraryMutationResult>();
      final harness = await _Harness.create(
        saveBehaviors: [
          (operationId) => firstResponse.future,
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 2, operationId: operationId),
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();
      final drain = harness.outbox.drain(accountId: _accountId, authEpoch: 7);
      await harness.remote.firstSaveStarted.future;

      harness.scope.epoch = 8;
      firstResponse.complete(
        LibraryMutationResult(
          _canonical(revision: 1, operationId: _operation1),
        ),
      );
      expect((await drain).scopeChanged, isTrue);
      var item = await harness.database
          .select(harness.database.libraryItems)
          .getSingle();
      expect(item.canonicalDeleted, isNull);
      expect(
        (await harness.database.select(harness.database.syncOutbox).getSingle())
            .state,
        'in_flight',
      );

      await harness.repository.recoverInFlight(_accountId);
      await harness.outbox.drain(accountId: _accountId, authEpoch: 8);
      expect(harness.remote.saveOperationIds, [_operation1, _operation1]);
      expect(
        await harness.database.select(harness.database.syncOutbox).get(),
        isEmpty,
      );
      item = await harness.database
          .select(harness.database.libraryItems)
          .getSingle();
      expect(item.revision, 2);
    },
  );

  test('new account drain does not inherit the old scope flight', () async {
    final oldResponse = Completer<LibraryMutationResult>();
    final harness = await _Harness.create(
      operationIds: [_operation1, _operation2],
      saveBehaviors: [
        (operationId) => oldResponse.future,
        (operationId) async => LibraryMutationResult(
          _canonical(revision: 2, operationId: operationId),
        ),
      ],
    );
    addTearDown(harness.close);
    await harness.enqueueSave();
    final oldDrain = harness.outbox.drain(accountId: _accountId, authEpoch: 7);
    await harness.remote.firstSaveStarted.future;

    harness.scope
      ..accountId = _secondAccountId
      ..epoch = 8;
    await harness.repository.setSaved(
      accountId: _secondAccountId,
      authEpoch: 8,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );
    final newResult = await harness.outbox.drain(
      accountId: _secondAccountId,
      authEpoch: 8,
    );

    expect(newResult.scopeChanged, isFalse);
    expect(harness.remote.saveOperationIds, [_operation1, _operation2]);
    final secondItem = await (harness.database.select(
      harness.database.libraryItems,
    )..where((row) => row.accountId.equals(_secondAccountId))).getSingle();
    expect(secondItem.revision, 2);

    oldResponse.complete(
      LibraryMutationResult(_canonical(revision: 1, operationId: _operation1)),
    );
    expect((await oldDrain).scopeChanged, isTrue);
    final firstItem = await (harness.database.select(
      harness.database.libraryItems,
    )..where((row) => row.accountId.equals(_accountId))).getSingle();
    expect(firstItem.canonicalDeleted, isNull);
  });

  test(
    'permanent rejection rolls absent save back and retains safe failure',
    () async {
      final harness = await _Harness.create(
        saveBehaviors: [
          (operationId) async => throw const ApiException(
            code: 'INVALID_LIBRARY_MUTATION',
            message: 'Sensitive upstream detail.',
            statusCode: 422,
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();

      final result = await harness.outbox.drain(
        accountId: _accountId,
        authEpoch: 7,
      );

      expect(result.issue?.code, 'INVALID_LIBRARY_MUTATION');
      final saved = await harness.repository
          .watchSavedState(_accountId, samplePaper.paperId)
          .first;
      expect(saved.saved, isFalse);
      expect(saved.syncPending, isFalse);
      expect(saved.issue?.code, 'INVALID_LIBRARY_MUTATION');
      final row = await harness.database
          .select(harness.database.syncOutbox)
          .getSingle();
      expect(row.state, 'failed');
      expect(row.payloadJson, isNot(contains('Sensitive upstream detail')));
    },
  );

  test('successful queued successor clears failed predecessor issue', () async {
    final saveResponse = Completer<LibraryMutationResult>();
    final harness = await _Harness.create(
      operationIds: [_operation1, _operation2],
      saveBehaviors: [(operationId) => saveResponse.future],
      removeBehaviors: [
        (operationId) async => LibraryMutationResult(
          _canonical(revision: 2, operationId: operationId, removed: true),
        ),
      ],
    );
    addTearDown(harness.close);
    await harness.enqueueSave();
    final drain = harness.outbox.drain(accountId: _accountId, authEpoch: 7);
    await harness.remote.firstSaveStarted.future;
    await harness.repository.setSaved(
      accountId: _accountId,
      authEpoch: 7,
      paperId: samplePaper.paperId,
      saved: false,
      paper: samplePaper,
    );
    saveResponse.completeError(
      const ApiException(
        code: 'INVALID_LIBRARY_MUTATION',
        message: 'Rejected predecessor.',
        statusCode: 422,
      ),
    );

    final result = await drain;

    expect(result.issue, isNull);
    expect(
      await harness.database.select(harness.database.syncOutbox).get(),
      isEmpty,
    );
    final state = await harness.repository
        .watchSavedState(_accountId, samplePaper.paperId)
        .first;
    expect(state.saved, isFalse);
    expect(state.syncPending, isFalse);
    expect(state.issue, isNull);
    expect(
      (await harness.database.select(harness.database.libraryItems).getSingle())
          .revision,
      2,
    );
  });

  test(
    'one paper serializes save then queued remove without mutation',
    () async {
      final saveResponse = Completer<LibraryMutationResult>();
      final harness = await _Harness.create(
        operationIds: [_operation1, _operation2],
        saveBehaviors: [(operationId) => saveResponse.future],
        removeBehaviors: [
          (operationId) async => LibraryMutationResult(
            _canonical(revision: 2, operationId: operationId, removed: true),
          ),
        ],
      );
      addTearDown(harness.close);
      await harness.enqueueSave();
      final drain = harness.outbox.drain(accountId: _accountId, authEpoch: 7);
      await harness.remote.firstSaveStarted.future;
      await harness.repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: samplePaper.paperId,
        saved: false,
        paper: samplePaper,
      );
      final during = await harness.database
          .select(harness.database.syncOutbox)
          .get();
      expect(
        during.map((row) => row.state),
        containsAll(['in_flight', 'queued']),
      );

      saveResponse.complete(
        LibraryMutationResult(
          _canonical(revision: 1, operationId: _operation1),
        ),
      );
      await drain;

      expect(harness.remote.calls, [
        'save:$_operation1',
        'remove:$_operation2',
      ]);
      expect(
        await harness.database.select(harness.database.syncOutbox).get(),
        isEmpty,
      );
      final item = await harness.database
          .select(harness.database.libraryItems)
          .getSingle();
      expect(item.deleted, isTrue);
      expect(item.canonicalDeleted, isTrue);
      expect(item.revision, 2);
    },
  );
}

typedef _MutationBehavior =
    Future<LibraryMutationResult> Function(String operationId);

final class _Harness {
  _Harness._({
    required this.database,
    required this.repository,
    required this.remote,
    required this.outbox,
    required this.scope,
    required this.now,
  });

  final PakPerkDatabase database;
  final LibraryRepository repository;
  final _MutationRemote remote;
  final LibraryOutboxController outbox;
  final _Scope scope;
  final DateTime now;

  static Future<_Harness> create({
    List<String> operationIds = const [_operation1],
    List<_MutationBehavior> saveBehaviors = const [],
    List<_MutationBehavior> removeBehaviors = const [],
  }) async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    final ids = Queue.of(operationIds);
    final now = DateTime.utc(2026, 7, 31, 12);
    final dao = LibraryDao(
      database,
      clock: () => now,
      operationId: ids.removeFirst,
    );
    final scope = _Scope();
    final remote = _MutationRemote(
      saveBehaviors: saveBehaviors,
      removeBehaviors: removeBehaviors,
    );
    late final LibraryRepository repository;
    repository = LibraryRepository(
      local: dao,
      remote: remote,
      sessionScope: () => (accountId: scope.accountId, authEpoch: scope.epoch),
      verifiedScope: () => scope.verified
          ? (accountId: scope.accountId, authEpoch: scope.epoch)
          : null,
    );
    return _Harness._(
      database: database,
      repository: repository,
      remote: remote,
      outbox: LibraryOutboxController(
        repository: repository,
        retryPolicy: OutboxRetryPolicy(jitter: () => 0),
        clock: () => now,
      ),
      scope: scope,
      now: now,
    );
  }

  Future<void> enqueueSave() => repository.setSaved(
    accountId: _accountId,
    authEpoch: scope.epoch,
    paperId: samplePaper.paperId,
    saved: true,
    paper: samplePaper,
  );

  Future<void> close() => database.close();
}

final class _Scope {
  String? accountId = _accountId;
  int epoch = 7;
  bool verified = true;
}

final class _MutationRemote implements LibraryRemoteDataSource {
  _MutationRemote({
    required List<_MutationBehavior> saveBehaviors,
    required List<_MutationBehavior> removeBehaviors,
  }) : _saveBehaviors = Queue.of(saveBehaviors),
       _removeBehaviors = Queue.of(removeBehaviors);

  final Queue<_MutationBehavior> _saveBehaviors;
  final Queue<_MutationBehavior> _removeBehaviors;
  final List<String> saveOperationIds = [];
  final List<int> expectedAuthEpochs = [];
  final List<String> calls = [];
  final Completer<void> firstSaveStarted = Completer<void>();

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) {
    saveOperationIds.add(operationId);
    expectedAuthEpochs.add(expectedAuthEpoch);
    calls.add('save:$operationId');
    if (!firstSaveStarted.isCompleted) firstSaveStarted.complete();
    return _saveBehaviors.removeFirst()(operationId);
  }

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) {
    expectedAuthEpochs.add(expectedAuthEpoch);
    calls.add('remove:$operationId');
    return _removeBehaviors.removeFirst()(operationId);
  }

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) => throw UnimplementedError();

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) => throw UnimplementedError();
}

LibraryCanonicalItem _canonical({
  required int revision,
  required String operationId,
  bool removed = false,
}) => LibraryCanonicalItem(
  paperId: samplePaper.paperId,
  state: 'to_read',
  savedAt: DateTime.utc(2026, 7, 31, 12),
  updatedAt: DateTime.utc(2026, 7, 31, 12, revision),
  removed: removed,
  removedAt: removed ? DateTime.utc(2026, 7, 31, 12, revision) : null,
  revision: revision,
  lastOperationId: operationId,
);

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _secondAccountId = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
const _operation1 = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _operation2 = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _operationHigh = '018f47a6-4b56-7f4c-8c7a-e2656e820209';
const _operationLow = '018f47a6-4b56-7f4c-8c7a-e2656e820200';
