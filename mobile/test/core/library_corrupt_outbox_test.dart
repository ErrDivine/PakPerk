import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/library_v2_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/library/library_action_failure.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/library/library_v2_api.dart';
import 'package:pakperk/core/library/library_v2_models.dart';
import 'package:pakperk/core/sync/outbox_controller.dart';

import '../support/fakes.dart';

void main() {
  test(
    'malformed payload and canonical membership terminalize and unblock FIFO',
    () async {
      final result = await _drainBehindCorrupt(
        entityKind: 'library_v2_list_item',
        entityId: '$_listId:${samplePaper.paperId}',
        operation: 'library_v2_list_item_put',
        payloadJson: '{',
        insertOptimisticMembership: true,
      );

      expect(result.remainingMemberships, 0);
      _expectCorruptWasTerminalAndLaterAdvanced(result);
    },
  );

  test(
    'valid JSON with an invalid UUID terminalizes and unblocks FIFO',
    () async {
      final result = await _drainBehindCorrupt(
        entityKind: 'library_v2_list',
        entityId: _listId,
        operation: 'library_v2_list_create',
        payloadJson: jsonEncode({
          'list_id': 'not-a-uuid',
          'name': 'Methods',
          'description': null,
          'sort_order': 0,
        }),
      );

      _expectCorruptWasTerminalAndLaterAdvanced(result);
    },
  );

  test(
    'valid JSON with overlong text terminalizes and unblocks FIFO',
    () async {
      final result = await _drainBehindCorrupt(
        entityKind: 'library_v2_list',
        entityId: _listId,
        operation: 'library_v2_list_create',
        payloadJson: jsonEncode({
          'list_id': _listId,
          'name': 'x' * 101,
          'description': null,
          'sort_order': 0,
        }),
      );

      _expectCorruptWasTerminalAndLaterAdvanced(result);
    },
  );

  test(
    'operation and entity kind mismatch terminalizes before dispatch',
    () async {
      final result = await _drainBehindCorrupt(
        entityKind: 'library_v2_list',
        entityId: _listId,
        operation: 'library_v2_item_put_active',
        payloadJson: jsonEncode({
          'list_id': _listId,
          'paper_id': samplePaper.paperId,
          'state': 'inbox',
          'private_note': null,
          'save_source_kind': null,
          'reminder_at': null,
        }),
      );

      _expectCorruptWasTerminalAndLaterAdvanced(result);
    },
  );

  test(
    'identity mismatch restores only the operation-owned projection',
    () async {
      final result = await _drainBehindCorrupt(
        entityKind: 'library_v2_list_item',
        entityId: '$_unrelatedListId:${samplePaper.paperId}',
        operation: 'library_v2_list_item_put',
        payloadJson: jsonEncode({
          'list_id': _listId,
          'paper_id': samplePaper.paperId,
          'position_rank': 0,
          'note': null,
        }),
        insertOptimisticMembership: true,
        insertUnrelatedMembership: true,
      );

      expect(result.remainingMembershipKeys, {
        '$_unrelatedListId:${samplePaper.paperId}',
      });
      _expectCorruptWasTerminalAndLaterAdvanced(result);
    },
  );

  test(
    'corrupt identity ignores unrelated active collision during rollback',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      try {
        final legacy = LibraryDao(database, clock: () => _now);
        final repository = LibraryRepository(
          local: legacy,
          remote: const _UnusedLegacyRemote(),
          sessionScope: () => (accountId: _accountId, authEpoch: 7),
          verifiedScope: () => (accountId: _accountId, authEpoch: 7),
          v2Local: LibraryV2Dao(database, clock: () => _now),
          v2Remote: _SuccessfulItemRemote(),
          libraryV2Enabled: true,
        );
        await database
            .into(database.libraryListMemberships)
            .insert(
              LibraryListMembershipsCompanion.insert(
                accountId: _accountId,
                listId: _listId,
                paperId: samplePaper.paperId,
                createdAt: _now,
                updatedAt: _now,
                lastOperationId: const Value(_corruptOperationId),
                canonicalJson: const Value('{'),
              ),
            );
        await database
            .into(database.libraryListMemberships)
            .insert(
              LibraryListMembershipsCompanion.insert(
                accountId: _accountId,
                listId: _unrelatedListId,
                paperId: samplePaper.paperId,
                createdAt: _now,
                updatedAt: _now,
                lastOperationId: const Value(_unrelatedOperationId),
              ),
            );
        await _insertOutbox(
          database,
          operationId: _corruptOperationId,
          entityKind: 'library_v2_list_item',
          entityId: '$_unrelatedListId:${samplePaper.paperId}',
          operation: 'library_v2_list_item_put',
          payloadJson: jsonEncode({
            'list_id': _listId,
            'paper_id': samplePaper.paperId,
            'position_rank': 0,
            'note': null,
          }),
          createdAt: _now,
        );
        final claimed = await legacy.claimNextDue(
          accountId: _accountId,
          now: _now.add(const Duration(minutes: 1)),
        );
        await _insertOutbox(
          database,
          operationId: _collisionOperationId,
          entityKind: 'library_v2_list_item',
          entityId: '$_unrelatedListId:${samplePaper.paperId}',
          operation: 'library_v2_list_item_delete',
          payloadJson: jsonEncode({
            'list_id': _unrelatedListId,
            'paper_id': samplePaper.paperId,
          }),
          createdAt: _now.add(const Duration(seconds: 1)),
        );

        await repository.failPermanently(
          operation: claimed!,
          error: const ApiException(
            code: 'LOCAL_OUTBOX_CORRUPT',
            message: 'Invalid local queue row.',
            retryable: false,
          ),
          scopeGuard: () => true,
        );

        final memberships = await database
            .select(database.libraryListMemberships)
            .get();
        expect(
          memberships.map((row) => '${row.listId}:${row.paperId}').toSet(),
          {'$_unrelatedListId:${samplePaper.paperId}'},
        );
        final outbox = await database.select(database.syncOutbox).get();
        expect(
          {for (final row in outbox) row.operationId: row.state},
          {_corruptOperationId: 'failed', _collisionOperationId: 'queued'},
        );
      } finally {
        await database.close();
      }
    },
  );

  test('V2 mutation identity rejects an unexpected runtime value type', () {
    final operation = LibraryPendingOperation(
      operationId: _corruptOperationId,
      accountId: _accountId,
      entityKind: 'library_v2_item',
      entityId: samplePaper.paperId,
      operation: 'library_v2_item_put_active',
      payloadJson: '{}',
      createdAt: _now,
      attemptCount: 0,
    );

    expect(
      const LibraryV2Mutation<Object>(
        value: 'crossed response',
        replayed: false,
      ).matchesOperation(operation),
      isFalse,
    );
  });

  test(
    'V2 mutation responses are exactly identity-bound before apply',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      try {
        for (final testCase in _invalidResponseCases) {
          final remote = _IdentityResponseRemote(testCase.response);
          final repository = LibraryRepository(
            local: LibraryDao(database, clock: () => _now),
            remote: const _UnusedLegacyRemote(),
            sessionScope: () => (accountId: _accountId, authEpoch: 7),
            verifiedScope: () => (accountId: _accountId, authEpoch: 7),
            v2Local: LibraryV2Dao(database, clock: () => _now),
            v2Remote: remote,
            libraryV2Enabled: true,
          );

          await expectLater(
            repository.upload(
              operation: LibraryPendingOperation(
                operationId: _corruptOperationId,
                accountId: _accountId,
                entityKind: testCase.entityKind,
                entityId: testCase.entityId,
                operation: testCase.operation,
                payloadJson: jsonEncode(testCase.payload),
                createdAt: _now,
                attemptCount: 0,
              ),
              authEpoch: 7,
              scopeGuard: () => true,
            ),
            throwsA(
              isA<ApiException>()
                  .having(
                    (error) => error.code,
                    '${testCase.name} code',
                    'INVALID_API_RESPONSE',
                  )
                  .having(
                    (error) => error.retryable,
                    '${testCase.name} retryable',
                    isTrue,
                  ),
            ),
            reason: testCase.name,
          );
          expect(remote.calls, 1, reason: testCase.name);
        }
      } finally {
        await database.close();
      }
    },
  );

  test('identity mismatch retries and replays the same operation id', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    try {
      final remote = _IdentityResponseRemote(
        _responseItem(paperId: _otherPaperId, operationId: _validOperationId),
      );
      final repository = LibraryRepository(
        local: LibraryDao(database, clock: () => _now),
        remote: const _UnusedLegacyRemote(),
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => (accountId: _accountId, authEpoch: 7),
        v2Local: LibraryV2Dao(database, clock: () => _now),
        v2Remote: remote,
        libraryV2Enabled: true,
      );
      await database
          .into(database.libraryItems)
          .insert(
            LibraryItemsCompanion.insert(
              accountId: _accountId,
              paperId: samplePaper.paperId,
              listState: const Value('inbox'),
              clientUpdatedAt: _now,
              serverUpdatedAt: Value(_now),
              savedAt: Value(_now),
              revision: const Value(9),
              lastOperationId: const Value(_validOperationId),
              canonicalDeleted: const Value(false),
              canonicalSavedAt: Value(_now),
              canonicalListState: const Value('inbox'),
            ),
          );
      await _insertOutbox(
        database,
        operationId: _validOperationId,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        payloadJson: jsonEncode({
          'paper_id': samplePaper.paperId,
          'state': 'inbox',
          'private_note': null,
          'save_source_kind': null,
          'reminder_at': null,
        }),
        createdAt: _now,
      );

      final first = await LibraryOutboxController(
        repository: repository,
        clock: () => _now.add(const Duration(minutes: 1)),
      ).drain(accountId: _accountId, authEpoch: 7);
      final retained = await database.select(database.syncOutbox).getSingle();
      expect(first.pendingCount, 1);
      expect(retained.operationId, _validOperationId);
      expect(retained.state, 'queued');
      expect(retained.lastErrorCode, 'INVALID_API_RESPONSE');

      remote.response = _responseItem(
        paperId: samplePaper.paperId,
        operationId: _validOperationId,
      );
      final replayed = await LibraryOutboxController(
        repository: repository,
        clock: () => _now.add(const Duration(days: 1)),
      ).drain(accountId: _accountId, authEpoch: 7);

      expect(replayed.pendingCount, 0);
      expect(remote.calls, 2);
      expect(await database.select(database.syncOutbox).get(), isEmpty);
    } finally {
      await database.close();
    }
  });

  test('replay accepts a newer same-entity canonical operation id', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    try {
      final remote = _IdentityResponseRemote(
        _responseItem(
          paperId: samplePaper.paperId,
          operationId: _unrelatedOperationId,
        ),
        replayed: true,
      );
      final repository = LibraryRepository(
        local: LibraryDao(database, clock: () => _now),
        remote: const _UnusedLegacyRemote(),
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => (accountId: _accountId, authEpoch: 7),
        v2Local: LibraryV2Dao(database, clock: () => _now),
        v2Remote: remote,
        libraryV2Enabled: true,
      );
      await database
          .into(database.libraryItems)
          .insert(
            LibraryItemsCompanion.insert(
              accountId: _accountId,
              paperId: samplePaper.paperId,
              listState: const Value('inbox'),
              clientUpdatedAt: _now,
              serverUpdatedAt: Value(_now),
              savedAt: Value(_now),
              revision: const Value(9),
              lastOperationId: const Value(_validOperationId),
              canonicalDeleted: const Value(false),
              canonicalSavedAt: Value(_now),
              canonicalListState: const Value('inbox'),
            ),
          );
      await _insertOutbox(
        database,
        operationId: _validOperationId,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        payloadJson: jsonEncode({
          'paper_id': samplePaper.paperId,
          'state': 'inbox',
          'private_note': null,
          'save_source_kind': null,
          'reminder_at': null,
        }),
        createdAt: _now,
      );

      final result = await LibraryOutboxController(
        repository: repository,
        clock: () => _now.add(const Duration(minutes: 1)),
      ).drain(accountId: _accountId, authEpoch: 7);

      expect(result.pendingCount, 0);
      expect(remote.calls, 1);
      expect(await database.select(database.syncOutbox).get(), isEmpty);
      expect(
        (await database.select(database.libraryItems).getSingle())
            .lastOperationId,
        _unrelatedOperationId,
      );
    } finally {
      await database.close();
    }
  });

  test('post-server local apply failure remains retryable', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    try {
      final legacy = LibraryDao(database, clock: () => _now);
      final remote = _SuccessfulItemRemote();
      final repository = LibraryRepository(
        local: legacy,
        remote: const _UnusedLegacyRemote(),
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => (accountId: _accountId, authEpoch: 7),
        v2Local: LibraryV2Dao(database, clock: () => _now),
        v2Remote: remote,
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
              clientUpdatedAt: _now,
              serverUpdatedAt: Value(_now),
              savedAt: Value(_now),
              revision: const Value(9),
              lastOperationId: const Value(_validOperationId),
              canonicalDeleted: const Value(false),
              canonicalSavedAt: Value(_now),
              canonicalListState: const Value('inbox'),
            ),
          );
      await _insertOutbox(
        database,
        operationId: _validOperationId,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        payloadJson: jsonEncode({
          'paper_id': samplePaper.paperId,
          'state': 'inbox',
          'private_note': null,
          'save_source_kind': null,
          'reminder_at': null,
        }),
        createdAt: _now,
      );
      await database.customStatement('''
        CREATE TRIGGER fail_library_item_apply
        BEFORE UPDATE ON library_items
        BEGIN
          SELECT RAISE(ABORT, 'injected library apply failure');
        END
      ''');

      final first = await LibraryOutboxController(
        repository: repository,
        clock: () => _now.add(const Duration(minutes: 1)),
      ).drain(accountId: _accountId, authEpoch: 7);
      final retained = await database.select(database.syncOutbox).getSingle();
      expect(first.pendingCount, 1);
      expect(remote.putCalls, 1);
      expect(retained.state, 'queued');
      expect(retained.lastErrorCode, 'LOCAL_SYNC_UNAVAILABLE');
      expect(
        await repository.watchActionFailureAlerts(_accountId).first,
        isEmpty,
      );

      await database.customStatement('DROP TRIGGER fail_library_item_apply');
      final replayed = await LibraryOutboxController(
        repository: repository,
        clock: () => _now.add(const Duration(days: 1)),
      ).drain(accountId: _accountId, authEpoch: 7);

      expect(replayed.pendingCount, 0);
      expect(remote.putCalls, 2);
      expect(await database.select(database.syncOutbox).get(), isEmpty);
      expect(
        (await database.select(database.libraryItems).getSingle()).revision,
        10,
      );
    } finally {
      await database.close();
    }
  });
}

void _expectCorruptWasTerminalAndLaterAdvanced(_DrainResult result) {
  expect(result.pendingCount, 0);
  expect(result.remotePutCalls, 1);
  expect(result.remainingOutbox, {_corruptOperationId: 'failed'});
  expect(result.alerts, hasLength(1));
  expect(result.alerts.single.kind, LibraryActionFailureKind.localDataIssue);
  expect(result.alerts.single.action, LibraryActionFailureAction.reviewLibrary);
  expect(result.canonicalRevision, 10);
}

Future<_DrainResult> _drainBehindCorrupt({
  required String entityKind,
  required String entityId,
  required String operation,
  required String payloadJson,
  bool insertOptimisticMembership = false,
  bool insertUnrelatedMembership = false,
}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  try {
    final legacy = LibraryDao(database, clock: () => _now);
    final v2 = LibraryV2Dao(database, clock: () => _now);
    final remote = _SuccessfulItemRemote();
    final repository = LibraryRepository(
      local: legacy,
      remote: const _UnusedLegacyRemote(),
      sessionScope: () => (accountId: _accountId, authEpoch: 7),
      verifiedScope: () => (accountId: _accountId, authEpoch: 7),
      v2Local: v2,
      v2Remote: remote,
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
            clientUpdatedAt: _now,
            serverUpdatedAt: Value(_now),
            savedAt: Value(_now),
            revision: const Value(9),
            canonicalDeleted: const Value(false),
            canonicalSavedAt: Value(_now),
            canonicalListState: const Value('inbox'),
          ),
        );
    if (insertOptimisticMembership) {
      await database
          .into(database.libraryListMemberships)
          .insert(
            LibraryListMembershipsCompanion.insert(
              accountId: _accountId,
              listId: _listId,
              paperId: samplePaper.paperId,
              createdAt: _now,
              updatedAt: _now,
              lastOperationId: const Value(_corruptOperationId),
              canonicalJson: const Value('{'),
            ),
          );
    }
    if (insertUnrelatedMembership) {
      await database
          .into(database.libraryListMemberships)
          .insert(
            LibraryListMembershipsCompanion.insert(
              accountId: _accountId,
              listId: _unrelatedListId,
              paperId: samplePaper.paperId,
              createdAt: _now,
              updatedAt: _now,
              lastOperationId: const Value(_unrelatedOperationId),
            ),
          );
    }
    await _insertOutbox(
      database,
      operationId: _corruptOperationId,
      entityKind: entityKind,
      entityId: entityId,
      operation: operation,
      payloadJson: payloadJson,
      createdAt: _now,
    );
    await _insertOutbox(
      database,
      operationId: _validOperationId,
      entityKind: 'library_v2_item',
      entityId: samplePaper.paperId,
      operation: 'library_v2_item_put_active',
      payloadJson: jsonEncode({
        'paper_id': samplePaper.paperId,
        'state': 'inbox',
        'private_note': null,
        'save_source_kind': null,
        'reminder_at': null,
      }),
      createdAt: _now.add(const Duration(seconds: 1)),
    );

    final drained = await LibraryOutboxController(
      repository: repository,
      clock: () => _now.add(const Duration(minutes: 1)),
    ).drain(accountId: _accountId, authEpoch: 7);
    final outbox = await database.select(database.syncOutbox).get();
    final item = await database.select(database.libraryItems).getSingle();
    final alerts = await repository.watchActionFailureAlerts(_accountId).first;
    final memberships = await database
        .select(database.libraryListMemberships)
        .get();
    return _DrainResult(
      pendingCount: drained.pendingCount,
      remotePutCalls: remote.putCalls,
      remainingOutbox: {for (final row in outbox) row.operationId: row.state},
      alerts: alerts,
      canonicalRevision: item.revision,
      remainingMemberships: memberships.length,
      remainingMembershipKeys: {
        for (final row in memberships) '${row.listId}:${row.paperId}',
      },
    );
  } finally {
    await database.close();
  }
}

Future<void> _insertOutbox(
  PakPerkDatabase database, {
  required String operationId,
  required String entityKind,
  required String entityId,
  required String operation,
  required String payloadJson,
  required DateTime createdAt,
}) => database
    .into(database.syncOutbox)
    .insert(
      SyncOutboxCompanion.insert(
        operationId: operationId,
        accountId: const Value(_accountId),
        entityKind: entityKind,
        entityId: entityId,
        operation: operation,
        payloadJson: payloadJson,
        createdAt: createdAt,
        nextAttemptAt: Value(createdAt),
        state: const Value('queued'),
        updatedAt: Value(createdAt),
      ),
    );

final class _DrainResult {
  const _DrainResult({
    required this.pendingCount,
    required this.remotePutCalls,
    required this.remainingOutbox,
    required this.alerts,
    required this.canonicalRevision,
    required this.remainingMemberships,
    required this.remainingMembershipKeys,
  });

  final int pendingCount;
  final int remotePutCalls;
  final Map<String, String> remainingOutbox;
  final List<LibraryActionFailure> alerts;
  final int? canonicalRevision;
  final int remainingMemberships;
  final Set<String> remainingMembershipKeys;
}

final class _InvalidResponseCase {
  const _InvalidResponseCase({
    required this.name,
    required this.entityKind,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.response,
  });

  final String name;
  final String entityKind;
  final String entityId;
  final String operation;
  final Map<String, Object?> payload;
  final Object response;
}

final _invalidResponseCases = <_InvalidResponseCase>[
  _InvalidResponseCase(
    name: 'item entity',
    entityKind: 'library_v2_item',
    entityId: samplePaper.paperId,
    operation: 'library_v2_item_put_active',
    payload: {
      'paper_id': samplePaper.paperId,
      'state': 'inbox',
      'private_note': null,
      'save_source_kind': null,
      'reminder_at': null,
    },
    response: _responseItem(
      paperId: _otherPaperId,
      operationId: _corruptOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'list entity',
    entityKind: 'library_v2_list',
    entityId: _listId,
    operation: 'library_v2_list_create',
    payload: {
      'list_id': _listId,
      'name': 'Methods',
      'description': null,
      'sort_order': 0,
    },
    response: LibraryV2List(
      id: _unrelatedListId,
      name: 'Methods',
      description: null,
      sortOrder: 0,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _corruptOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'tag operation identity',
    entityKind: 'library_v2_tag',
    entityId: _tagId,
    operation: 'library_v2_tag_create',
    payload: {'tag_id': _tagId, 'name': 'Important'},
    response: LibraryV2Tag(
      id: _tagId,
      name: 'Important',
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _unrelatedOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'list membership composite identity',
    entityKind: 'library_v2_list_item',
    entityId: '$_listId:${samplePaper.paperId}',
    operation: 'library_v2_list_item_put',
    payload: {
      'list_id': _listId,
      'paper_id': samplePaper.paperId,
      'position_rank': 0,
      'note': null,
    },
    response: LibraryV2ListItem(
      listId: _unrelatedListId,
      paperId: samplePaper.paperId,
      positionRank: 0,
      note: null,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _corruptOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'tag membership composite identity',
    entityKind: 'library_v2_item_tag',
    entityId: '${samplePaper.paperId}:$_tagId',
    operation: 'library_v2_item_tag_put',
    payload: {'paper_id': samplePaper.paperId, 'tag_id': _tagId},
    response: LibraryV2ItemTag(
      paperId: _otherPaperId,
      tagId: _tagId,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _corruptOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'item operation identity',
    entityKind: 'library_v2_item',
    entityId: samplePaper.paperId,
    operation: 'library_v2_item_put_active',
    payload: {
      'paper_id': samplePaper.paperId,
      'state': 'inbox',
      'private_note': null,
      'save_source_kind': null,
      'reminder_at': null,
    },
    response: _responseItem(
      paperId: samplePaper.paperId,
      operationId: _unrelatedOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'list operation identity',
    entityKind: 'library_v2_list',
    entityId: _listId,
    operation: 'library_v2_list_create',
    payload: {
      'list_id': _listId,
      'name': 'Methods',
      'description': null,
      'sort_order': 0,
    },
    response: LibraryV2List(
      id: _listId,
      name: 'Methods',
      description: null,
      sortOrder: 0,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _unrelatedOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'tag entity',
    entityKind: 'library_v2_tag',
    entityId: _tagId,
    operation: 'library_v2_tag_create',
    payload: {'tag_id': _tagId, 'name': 'Important'},
    response: LibraryV2Tag(
      id: _otherTagId,
      name: 'Important',
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _corruptOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'list membership operation identity',
    entityKind: 'library_v2_list_item',
    entityId: '$_listId:${samplePaper.paperId}',
    operation: 'library_v2_list_item_put',
    payload: {
      'list_id': _listId,
      'paper_id': samplePaper.paperId,
      'position_rank': 0,
      'note': null,
    },
    response: LibraryV2ListItem(
      listId: _listId,
      paperId: samplePaper.paperId,
      positionRank: 0,
      note: null,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _unrelatedOperationId,
    ),
  ),
  _InvalidResponseCase(
    name: 'tag membership operation identity',
    entityKind: 'library_v2_item_tag',
    entityId: '${samplePaper.paperId}:$_tagId',
    operation: 'library_v2_item_tag_put',
    payload: {'paper_id': samplePaper.paperId, 'tag_id': _tagId},
    response: LibraryV2ItemTag(
      paperId: samplePaper.paperId,
      tagId: _tagId,
      revision: 10,
      deletedAt: null,
      createdAt: _now,
      updatedAt: _now,
      lastOperationId: _unrelatedOperationId,
    ),
  ),
];

LibraryV2Item _responseItem({
  required String paperId,
  required String operationId,
}) => LibraryV2Item(
  paperId: paperId,
  state: LibraryItemState.inbox,
  privateNote: null,
  saveSourceKind: null,
  reminderAt: null,
  savedAt: _now,
  updatedAt: _now,
  reviewedAt: null,
  archivedAt: null,
  removed: false,
  removedAt: null,
  revision: 10,
  lastOperationId: operationId,
);

final class _IdentityResponseRemote implements LibraryV2RemoteDataSource {
  _IdentityResponseRemote(this.response, {this.replayed = false});

  Object response;
  final bool replayed;
  int calls = 0;

  T _take<T>() {
    calls += 1;
    return response as T;
  }

  @override
  Future<LibraryV2Mutation<LibraryV2Item>> putItem({
    required String paperId,
    required String operationId,
    required LibraryItemState state,
    required String? privateNote,
    required LibrarySaveSourceKind? saveSourceKind,
    required DateTime? reminderAt,
    required int expectedAuthEpoch,
  }) async =>
      LibraryV2Mutation(value: _take<LibraryV2Item>(), replayed: replayed);

  @override
  Future<LibraryV2Mutation<LibraryV2List>> createList({
    required String operationId,
    required String listId,
    required String name,
    required String? description,
    required int sortOrder,
    required int expectedAuthEpoch,
  }) async =>
      LibraryV2Mutation(value: _take<LibraryV2List>(), replayed: replayed);

  @override
  Future<LibraryV2Mutation<LibraryV2ListItem>> putListItem({
    required String operationId,
    required String listId,
    required String paperId,
    required int positionRank,
    required String? note,
    required int expectedAuthEpoch,
  }) async =>
      LibraryV2Mutation(value: _take<LibraryV2ListItem>(), replayed: replayed);

  @override
  Future<LibraryV2Mutation<LibraryV2Tag>> createTag({
    required String operationId,
    required String tagId,
    required String name,
    required int expectedAuthEpoch,
  }) async =>
      LibraryV2Mutation(value: _take<LibraryV2Tag>(), replayed: replayed);

  @override
  Future<LibraryV2Mutation<LibraryV2ItemTag>> putItemTag({
    required String operationId,
    required String paperId,
    required String tagId,
    required int expectedAuthEpoch,
  }) async =>
      LibraryV2Mutation(value: _take<LibraryV2ItemTag>(), replayed: replayed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SuccessfulItemRemote implements LibraryV2RemoteDataSource {
  int putCalls = 0;

  @override
  Future<LibraryV2Mutation<LibraryV2Item>> putItem({
    required String paperId,
    required String operationId,
    required LibraryItemState state,
    required String? privateNote,
    required LibrarySaveSourceKind? saveSourceKind,
    required DateTime? reminderAt,
    required int expectedAuthEpoch,
  }) async {
    putCalls += 1;
    return LibraryV2Mutation(
      value: LibraryV2Item(
        paperId: paperId,
        state: state,
        privateNote: privateNote,
        saveSourceKind: saveSourceKind,
        reminderAt: reminderAt,
        savedAt: _now,
        updatedAt: _now.add(const Duration(seconds: 2)),
        reviewedAt: null,
        archivedAt: null,
        removed: false,
        removedAt: null,
        revision: 10,
        lastOperationId: operationId,
      ),
      replayed: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnusedLegacyRemote implements LibraryRemoteDataSource {
  const _UnusedLegacyRemote();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _corruptOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _validOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _listId = '018f47a6-4b56-7f4c-8c7a-e2656e820401';
const _unrelatedListId = '018f47a6-4b56-7f4c-8c7a-e2656e820402';
const _unrelatedOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820403';
const _collisionOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820404';
const _tagId = '018f47a6-4b56-7f4c-8c7a-e2656e820405';
const _otherPaperId = '018f47a6-4b56-7f4c-8c7a-e2656e820406';
const _otherTagId = '018f47a6-4b56-7f4c-8c7a-e2656e820407';
final _now = DateTime.utc(2026, 8, 28, 10);
