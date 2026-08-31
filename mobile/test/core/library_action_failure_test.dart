import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/library/library_action_failure.dart';

import '../support/fakes.dart';

void main() {
  test(
    'alerts are bounded account-scoped terminal Library actions without payload content',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      final at = DateTime.utc(2026, 8, 28, 10);
      await PaperCacheDao(database).save(samplePaper, accessedAt: at);

      await _insertOutbox(
        database,
        operationId: _operation(1),
        accountId: _accountA,
        entityKind: 'library_item',
        entityId: samplePaper.paperId,
        operation: 'library_save',
        payload: '{"private_note":"do not expose this"}',
        errorCode: 'PRIVATE_UPSTREAM_DETAIL',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(2),
        accountId: _accountA,
        entityKind: 'library_v2_list',
        entityId: _entity(2),
        operation: 'library_v2_list_update',
        payload: '{"name":"Private reading list"}',
        at: at.add(const Duration(seconds: 1)),
      );
      await _insertOutbox(
        database,
        operationId: _operation(3),
        accountId: _accountA,
        entityKind: 'library_v2_tag',
        entityId: _entity(3),
        operation: 'library_v2_tag_update',
        payload: '{"name":"Private tag"}',
        errorCode: 'TOKEN_EXPIRED',
        at: at.add(const Duration(seconds: 2)),
      );
      await _insertOutbox(
        database,
        operationId: _operation(4),
        accountId: _accountA,
        entityKind: 'library_item',
        entityId: _entity(4),
        operation: 'library_remove',
        state: 'recovery',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(5),
        accountId: _accountB,
        entityKind: 'library_v2_list',
        entityId: _entity(5),
        operation: 'library_v2_list_delete',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(6),
        accountId: _accountA,
        entityKind: 'recommendation_worker',
        entityId: _entity(6),
        operation: 'build_batch',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(7),
        accountId: _accountA,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        at: at.add(const Duration(seconds: 3)),
      );

      final alerts = await dao.watchActionFailureAlerts(_accountA).first;

      expect(alerts, hasLength(4));
      expect(alerts.map((alert) => alert.kind).toList(), [
        LibraryActionFailureKind.paperEdit,
        LibraryActionFailureKind.collectionsEdit,
        LibraryActionFailureKind.collectionsEdit,
        LibraryActionFailureKind.paperAdd,
      ]);
      expect(alerts.first.action, LibraryActionFailureAction.reviewItem);
      expect(alerts[1].action, LibraryActionFailureAction.signIn);
      final paperAlert = alerts.last;
      expect(paperAlert.action, LibraryActionFailureAction.reviewPaper);
      expect(paperAlert.paper?.paperId, samplePaper.paperId);
      expect(paperAlert.paper?.title, samplePaper.title);
      final diagnostic = alerts.toString();
      expect(diagnostic, isNot(contains('do not expose this')));
      expect(diagnostic, isNot(contains('Private reading list')));
      expect(diagnostic, isNot(contains('Private tag')));
      expect(diagnostic, isNot(contains('PRIVATE_UPSTREAM_DETAIL')));
      expect(diagnostic, isNot(contains(_accountA)));
    },
  );

  test(
    'alert stream coalesces each entity and has a strict upper bound',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      final at = DateTime.utc(2026, 8, 28, 10);
      for (var index = 0; index < 12; index += 1) {
        await _insertOutbox(
          database,
          operationId: _operation(index + 1),
          accountId: _accountA,
          entityKind: 'library_v2_list',
          entityId: _entity(index + 1),
          operation: 'library_v2_list_update',
          at: at.add(Duration(seconds: index)),
        );
      }
      await _insertOutbox(
        database,
        operationId: _operation(50),
        accountId: _accountA,
        entityKind: 'library_v2_list',
        entityId: _entity(12),
        operation: 'library_v2_list_delete',
        at: at.add(const Duration(minutes: 1)),
      );

      final alerts = await dao.watchActionFailureAlerts(_accountA).first;

      expect(alerts, hasLength(10));
      expect(alerts.first.operationId, _operation(50));
      expect(
        alerts.where((alert) => alert.operationId == _operation(12)),
        isEmpty,
        reason: 'Only the newest failure for one logical entity is presented.',
      );
      expect(
        () => dao.watchActionFailureAlerts(_accountA, limit: 51),
        throwsArgumentError,
      );
    },
  );

  test('a newer active correction suppresses an obsolete failure', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final dao = LibraryDao(database);
    final at = DateTime.utc(2026, 8, 28, 10);
    final entityId = _entity(1);
    await _insertOutbox(
      database,
      operationId: _operation(1),
      accountId: _accountA,
      entityKind: 'library_v2_list',
      entityId: entityId,
      operation: 'library_v2_list_update',
      at: at,
    );
    expect(await dao.watchActionFailureAlerts(_accountA).first, hasLength(1));

    await _insertOutbox(
      database,
      operationId: _operation(2),
      accountId: _accountA,
      entityKind: 'library_v2_list',
      entityId: entityId,
      operation: 'library_v2_list_update',
      state: 'queued',
      at: at.add(const Duration(seconds: 1)),
    );

    expect(
      await dao.watchActionFailureAlerts(_accountA).first,
      isEmpty,
      reason: 'The active correction is the current truth for this entity.',
    );
  });

  test(
    'newer paper correction also suppresses generic and item issues',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      final at = DateTime.utc(2026, 8, 28, 10);
      await PaperCacheDao(database).save(samplePaper, accessedAt: at);
      await database
          .into(database.libraryItems)
          .insert(
            LibraryItemsCompanion.insert(
              accountId: _accountA,
              paperId: samplePaper.paperId,
              clientUpdatedAt: at,
              savedAt: Value(at),
            ),
          );
      await _insertOutbox(
        database,
        operationId: _operation(1),
        accountId: _accountA,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(2),
        accountId: _accountA,
        entityKind: 'library_v2_item',
        entityId: samplePaper.paperId,
        operation: 'library_v2_item_put_active',
        state: 'queued',
        at: at.add(const Duration(seconds: 1)),
      );

      final saved = await dao
          .watchSavedState(_accountA, samplePaper.paperId)
          .first;
      final item = (await dao.watchLibraryItems(_accountA).first).single;
      expect(saved.syncPending, isTrue);
      expect(saved.issue, isNull);
      expect(item.savedState.syncPending, isTrue);
      expect(item.savedState.issue, isNull);
      expect(await dao.latestSyncIssue(_accountA), isNull);
      expect(await dao.watchActionFailureAlerts(_accountA).first, isEmpty);
    },
  );

  test(
    'dismissal uses insertion order and preserves newer same-time lower UUID',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      final at = DateTime.utc(2026, 8, 28, 10);
      const oldest = '10000000-0000-4000-8000-000000000003';
      const displayed = 'f0000000-0000-4000-8000-000000000002';
      const newerLowerUuid = '00000000-0000-4000-8000-000000000001';
      final entityId = _entity(1);
      await _insertOutbox(
        database,
        operationId: oldest,
        accountId: _accountA,
        entityKind: 'library_v2_tag',
        entityId: entityId,
        operation: 'library_v2_tag_update',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: displayed,
        accountId: _accountA,
        entityKind: 'library_v2_tag',
        entityId: entityId,
        operation: 'library_v2_tag_delete',
        at: at,
      );
      expect(
        (await dao.watchActionFailureAlerts(_accountA).first)
            .single
            .operationId,
        displayed,
      );

      await _insertOutbox(
        database,
        operationId: newerLowerUuid,
        accountId: _accountA,
        entityKind: 'library_v2_tag',
        entityId: entityId,
        operation: 'library_v2_tag_update',
        at: at,
      );
      await _insertOutbox(
        database,
        operationId: _operation(90),
        accountId: _accountB,
        entityKind: 'library_v2_tag',
        entityId: entityId,
        operation: 'library_v2_tag_update',
        at: at,
      );

      expect(
        await dao.dismissActionFailure(
          accountId: _accountA,
          operationId: displayed,
          scopeGuard: () => true,
        ),
        isTrue,
      );

      final remaining = await database.select(database.syncOutbox).get();
      expect(remaining.map((row) => row.operationId).toSet(), {
        newerLowerUuid,
        _operation(90),
      });
      expect(
        (await dao.watchActionFailureAlerts(_accountA).first)
            .single
            .operationId,
        newerLowerUuid,
      );
    },
  );

  test(
    'scope change after delete rolls the dismissal transaction back',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      await _insertOutbox(
        database,
        operationId: _operation(1),
        accountId: _accountA,
        entityKind: 'library_v2_list',
        entityId: _entity(1),
        operation: 'library_v2_list_update',
        at: DateTime.utc(2026, 8, 28, 10),
      );
      var checks = 0;

      await expectLater(
        dao.dismissActionFailure(
          accountId: _accountA,
          operationId: _operation(1),
          scopeGuard: () => checks++ < 2,
        ),
        throwsA(isA<LibraryScopeChanged>()),
      );

      expect(await database.select(database.syncOutbox).get(), hasLength(1));
    },
  );
}

Future<void> _insertOutbox(
  PakPerkDatabase database, {
  required String operationId,
  required String accountId,
  required String entityKind,
  required String entityId,
  required String operation,
  required DateTime at,
  String payload = '{}',
  String errorCode = 'INVALID_LIBRARY_MUTATION',
  String state = 'failed',
}) => database
    .into(database.syncOutbox)
    .insert(
      SyncOutboxCompanion.insert(
        operationId: operationId,
        accountId: Value(accountId),
        entityKind: entityKind,
        entityId: entityId,
        operation: operation,
        payloadJson: payload,
        createdAt: at,
        lastErrorCode: Value(errorCode),
        state: Value(state),
        updatedAt: Value(at),
      ),
    );

String _operation(int value) =>
    '00000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

String _entity(int value) =>
    '10000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

const _accountA = 'account-a';
const _accountB = 'account-b';
