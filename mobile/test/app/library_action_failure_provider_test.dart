import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';

void main() {
  test(
    'provider and dismissal remain bound to account and auth epoch',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      final dao = LibraryDao(database);
      var session = (accountId: _accountA as String?, authEpoch: 4);
      final repository = LibraryRepository(
        local: dao,
        remote: const _UnusedLibraryRemote(),
        sessionScope: () => session,
        verifiedScope: () => null,
      );
      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await _insertFailure(database, _accountA, _operationA);
      await _insertFailure(database, _accountB, _operationB);
      const scopeA = (accountId: _accountA, authEpoch: 4);
      const scopeB = (accountId: _accountB, authEpoch: 5);

      final accountA = await container.read(
        libraryActionFailureAlertsProvider(scopeA).future,
      );
      expect(accountA.map((alert) => alert.operationId).toList(), [
        _operationA,
      ]);

      session = (accountId: _accountB, authEpoch: 5);
      await expectLater(
        repository.dismissActionFailure(
          accountId: _accountA,
          authEpoch: 4,
          operationId: _operationA,
        ),
        throwsA(isA<LibraryScopeChanged>()),
      );
      expect(
        (await database.select(database.syncOutbox).get())
            .map((row) => row.operationId)
            .toSet(),
        {_operationA, _operationB},
      );

      final accountB = await container.read(
        libraryActionFailureAlertsProvider(scopeB).future,
      );
      expect(accountB.map((alert) => alert.operationId).toList(), [
        _operationB,
      ]);
      expect(
        await repository.dismissActionFailure(
          accountId: _accountB,
          authEpoch: 5,
          operationId: _operationB,
        ),
        isTrue,
      );
      expect(
        (await database.select(database.syncOutbox).get())
            .map((row) => row.operationId)
            .toList(),
        [_operationA],
      );
    },
  );
}

Future<void> _insertFailure(
  PakPerkDatabase database,
  String accountId,
  String operationId,
) => database
    .into(database.syncOutbox)
    .insert(
      SyncOutboxCompanion.insert(
        operationId: operationId,
        accountId: Value(accountId),
        entityKind: 'library_v2_list',
        entityId: operationId,
        operation: 'library_v2_list_update',
        payloadJson: '{"name":"private"}',
        createdAt: DateTime.utc(2026, 8, 28),
        lastErrorCode: const Value('INVALID_LIBRARY_MUTATION'),
        state: const Value('failed'),
        updatedAt: Value(DateTime.utc(2026, 8, 28)),
      ),
    );

final class _UnusedLibraryRemote implements LibraryRemoteDataSource {
  const _UnusedLibraryRemote();

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) => throw UnsupportedError('not used');

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) => throw UnsupportedError('not used');

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => throw UnsupportedError('not used');

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
    LibrarySaveSourceKind? saveSourceKind,
  }) => throw UnsupportedError('not used');
}

const _accountA = 'account-a';
const _accountB = 'account-b';
const _operationA = '00000000-0000-4000-8000-000000000001';
const _operationB = '00000000-0000-4000-8000-000000000002';
