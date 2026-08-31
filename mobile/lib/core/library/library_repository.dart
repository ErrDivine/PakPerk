import 'dart:convert';

import '../api/api_exception.dart';
import '../database/library_dao.dart';
import '../database/library_v2_dao.dart';
import '../models/paper.dart';
import '../telemetry/telemetry.dart';
import 'library_api.dart';
import 'library_action_failure.dart';
import 'library_models.dart';
import 'library_v2_api.dart';
import 'library_v2_models.dart';

typedef LibrarySessionScope = ({String? accountId, int authEpoch});
typedef LibrarySessionScopeReader = LibrarySessionScope Function();
typedef LibraryVerifiedScopeReader = LibrarySessionScope? Function();

final class LibraryRepository {
  const LibraryRepository({
    required LibraryDao local,
    required LibraryRemoteDataSource remote,
    required LibrarySessionScopeReader sessionScope,
    required LibraryVerifiedScopeReader verifiedScope,
    LibraryVerifiedScopeReader? localMutationScope,
    LibraryV2Dao? v2Local,
    LibraryV2RemoteDataSource? v2Remote,
    bool libraryV2Enabled = false,
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _local = local,
       _remote = remote,
       _sessionScope = sessionScope,
       _verifiedScope = verifiedScope,
       _localMutationScope = localMutationScope,
       _v2Local = v2Local,
       _v2Remote = v2Remote,
       _libraryV2Enabled = libraryV2Enabled,
       _telemetry = telemetry;

  final LibraryDao _local;
  final LibraryRemoteDataSource _remote;
  final LibrarySessionScopeReader _sessionScope;
  final LibraryVerifiedScopeReader _verifiedScope;
  final LibraryVerifiedScopeReader? _localMutationScope;
  final LibraryV2Dao? _v2Local;
  final LibraryV2RemoteDataSource? _v2Remote;
  final bool _libraryV2Enabled;
  final TelemetrySink _telemetry;

  Stream<LibrarySavedState> watchSavedState(String accountId, String paperId) =>
      _local.watchSavedState(accountId, paperId);

  Stream<List<LibraryListItem>> watchToRead(String accountId) =>
      _local.watchToRead(accountId);

  Stream<List<LibraryListItem>> watchLibraryItems(String accountId) =>
      _local.watchLibraryItems(accountId);

  Stream<List<LibraryActionFailure>> watchActionFailureAlerts(
    String accountId,
  ) => _local.watchActionFailureAlerts(accountId);

  Stream<List<LibraryV2LocalList>> watchListsV2(String accountId) {
    if (!_libraryV2Enabled) return Stream.value(const []);
    return _requireV2Local.watchLists(accountId);
  }

  Stream<List<LibraryV2LocalTag>> watchTagsV2(String accountId) {
    if (!_libraryV2Enabled) return Stream.value(const []);
    return _requireV2Local.watchTags(accountId);
  }

  Stream<int> watchPendingCount(String accountId) =>
      _local.watchPendingCount(accountId);

  Stream<LibraryPendingIntentCounts> watchPendingIntents(String accountId) =>
      _local.watchPendingIntents(accountId);

  Stream<LibrarySyncCheckpoint> watchSyncCheckpoint(String accountId) =>
      _local.watchSyncCheckpoint(accountId);

  Future<String> setSaved({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required bool saved,
    PaperSummary? paper,
    LibrarySaveSourceKind? saveSourceKind,
  }) {
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _local.enqueueMutation(
      accountId: accountId,
      paperId: paperId,
      saved: saved,
      paper: paper,
      saveSourceKind: saveSourceKind,
      scopeGuard: guard,
    );
  }

  Future<void> clearSyncIssue(String accountId, String paperId) =>
      _local.clearSyncIssue(accountId, paperId);

  Future<bool> dismissActionFailure({
    required String accountId,
    required int authEpoch,
    required String operationId,
  }) async {
    final guard = displayScopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return await _local.dismissActionFailure(
      accountId: accountId,
      operationId: operationId,
      scopeGuard: guard,
    );
  }

  /// Guards local display-state actions without granting mutation or remote
  /// sync authority. This lets a suspended or temporarily offline account
  /// dismiss its own retained notice while preventing stale account screens
  /// from changing another auth epoch's data.
  LibraryScopeGuard displayScopeGuard({
    required String accountId,
    required int authEpoch,
  }) => () {
    final current = _sessionScope();
    return current.accountId == accountId && current.authEpoch == authEpoch;
  };

  LibraryScopeGuard scopeGuard({
    required String accountId,
    required int authEpoch,
  }) => () {
    final current = _sessionScope();
    final allowed = _localMutationScope?.call();
    return current.accountId == accountId &&
        current.authEpoch == authEpoch &&
        ((allowed == null && _localMutationScope == null) ||
            (allowed?.accountId == accountId &&
                allowed?.authEpoch == authEpoch));
  };

  LibraryScopeGuard remoteScopeGuard({
    required String accountId,
    required int authEpoch,
  }) => () {
    final local = _sessionScope();
    final verified = _verifiedScope();
    return local.accountId == accountId &&
        local.authEpoch == authEpoch &&
        verified?.accountId == accountId &&
        verified?.authEpoch == authEpoch;
  };

  bool isRemoteScopeVerified({
    required String accountId,
    required int authEpoch,
  }) => remoteScopeGuard(accountId: accountId, authEpoch: authEpoch)();

  Future<void> recoverInFlight(String accountId) =>
      _local.recoverInFlight(accountId);

  Future<LibraryPendingOperation?> claimNextDue({
    required String accountId,
    required DateTime now,
  }) => _local.claimNextDue(accountId: accountId, now: now);

  Future<DateTime?> nextAttemptAt(String accountId) =>
      _local.nextAttemptAt(accountId);

  Future<int> pendingCount(String accountId) => _local.pendingCount(accountId);

  Future<LibraryPendingIntentCounts> pendingIntents(String accountId) =>
      _local.pendingIntents(accountId);

  Future<LibraryOutboxSnapshot> outboxSnapshot(String accountId) =>
      _local.outboxSnapshot(accountId);

  Future<int> activeToReadCount(String accountId) =>
      _local.activeToReadCount(accountId);

  Future<LibrarySyncIssue?> latestSyncIssue(String accountId) =>
      _local.latestSyncIssue(accountId);

  Future<void> retryLater({
    required LibraryPendingOperation operation,
    required ApiException error,
    required DateTime nextAttemptAt,
    required LibraryScopeGuard scopeGuard,
  }) => _local.markRetry(
    operation: operation,
    errorCode: error.code,
    nextAttemptAt: nextAttemptAt,
    scopeGuard: scopeGuard,
  );

  Future<void> failPermanently({
    required LibraryPendingOperation operation,
    required ApiException error,
    required LibraryScopeGuard scopeGuard,
  }) async {
    if (operation.entityKind.startsWith('library_v2_')) {
      // Keep the terminal notice and the canonical rollback in one commit.
      // Otherwise the alert stream can briefly (or after a crash, durably)
      // claim that confirmed state was restored while the optimistic private
      // projection is still visible.
      await _local.database.transaction(() async {
        await _local.markPermanentFailure(
          operation: operation,
          errorCode: error.code,
          scopeGuard: scopeGuard,
        );
        await _requireV2Local.rollbackPermanentFailure(
          operation: operation,
          scopeGuard: scopeGuard,
        );
      });
    } else {
      await _local.markPermanentFailure(
        operation: operation,
        errorCode: error.code,
        scopeGuard: scopeGuard,
      );
    }
  }

  Future<void> upload({
    required LibraryPendingOperation operation,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    if (!scopeGuard()) return;
    if (operation.entityKind.startsWith('library_v2_')) {
      await _uploadV2(
        operation: operation,
        authEpoch: authEpoch,
        scopeGuard: scopeGuard,
      );
      return;
    }
    final payload = _decodeV2Payload(operation.payloadJson);
    final result = switch (operation.intent) {
      LibraryMutationIntent.save => await _remote.save(
        paperId: operation.paperId,
        operationId: operation.operationId,
        expectedAuthEpoch: authEpoch,
        saveSourceKind: _payloadSource(payload),
      ),
      LibraryMutationIntent.remove => await _remote.remove(
        paperId: operation.paperId,
        operationId: operation.operationId,
        expectedAuthEpoch: authEpoch,
      ),
    };
    if (!scopeGuard()) return;
    await _local.applyMutationSuccess(
      operation: operation,
      item: result.item,
      scopeGuard: scopeGuard,
    );
  }

  Future<LibraryV2EnqueueResult> editItemV2({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required LibraryItemState state,
    required String privateNote,
    required DateTime? reminderAt,
    required Iterable<String> listNames,
    required Iterable<String> tagNames,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueItemEdit(
        accountId: accountId,
        paperId: paperId,
        state: state,
        privateNote: privateNote,
        reminderAt: reminderAt,
        listNames: listNames,
        tagNames: tagNames,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<LibraryV2EnqueueResult> removeItemV2({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueItemRemove(
        accountId: accountId,
        paperId: paperId,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<LibraryV2EnqueueResult> upsertListV2({
    required String accountId,
    required int authEpoch,
    required String? listId,
    required String name,
    required String description,
    required int sortOrder,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueListUpsert(
        accountId: accountId,
        listId: listId,
        name: name,
        description: description,
        sortOrder: sortOrder,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<LibraryV2EnqueueResult> deleteListV2({
    required String accountId,
    required int authEpoch,
    required String listId,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueListDelete(
        accountId: accountId,
        listId: listId,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<LibraryV2EnqueueResult> upsertTagV2({
    required String accountId,
    required int authEpoch,
    required String? tagId,
    required String name,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueTagUpsert(
        accountId: accountId,
        tagId: tagId,
        name: name,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<LibraryV2EnqueueResult> deleteTagV2({
    required String accountId,
    required int authEpoch,
    required String tagId,
    required int expectedRevision,
  }) {
    if (!_libraryV2Enabled) {
      throw StateError('Library v2 is not enabled.');
    }
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.enqueueTagDelete(
        accountId: accountId,
        tagId: tagId,
        expectedRevision: expectedRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<void> applyImportedPaper({
    required String accountId,
    required int authEpoch,
    required LibraryV2Item item,
    required PaperSummary paper,
    required int syncRevision,
  }) {
    final guard = remoteScopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _withRevisionConflictTelemetry(
      () => _requireV2Local.applyImportedPaper(
        accountId: accountId,
        item: item,
        paper: paper,
        syncRevision: syncRevision,
        scopeGuard: guard,
      ),
    );
  }

  Future<void> refresh({
    required String accountId,
    required int authEpoch,
    bool forceFull = false,
  }) async {
    final guard = remoteScopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) return;
    final checkpoint = await _local.syncCheckpoint(accountId);
    if (!guard()) return;
    if (_libraryV2Enabled) {
      if (forceFull || !checkpoint.$1) {
        await _fullRefreshV2(
          accountId: accountId,
          authEpoch: authEpoch,
          scopeGuard: guard,
        );
      } else {
        try {
          await _changesRefreshV2(
            accountId: accountId,
            afterRevision: checkpoint.$2,
            authEpoch: authEpoch,
            scopeGuard: guard,
          );
        } on ApiException catch (error) {
          if (error.statusCode != 410 ||
              error.code != 'LIBRARY_SYNC_RESET_REQUIRED') {
            rethrow;
          }
          await _local.beginSyncReset(accountId: accountId, scopeGuard: guard);
          await _fullRefreshV2(
            accountId: accountId,
            authEpoch: authEpoch,
            scopeGuard: guard,
          );
        }
      }
      return;
    }
    if (forceFull || !checkpoint.$1) {
      await _fullRefresh(
        accountId: accountId,
        authEpoch: authEpoch,
        scopeGuard: guard,
      );
      return;
    }
    try {
      await _changesRefresh(
        accountId: accountId,
        afterRevision: checkpoint.$2,
        authEpoch: authEpoch,
        scopeGuard: guard,
      );
    } on ApiException catch (error) {
      if (error.statusCode != 410 ||
          error.code != 'LIBRARY_SYNC_RESET_REQUIRED') {
        rethrow;
      }
      if (!guard()) return;
      await _local.beginSyncReset(accountId: accountId, scopeGuard: guard);
      if (!guard()) return;
      await _fullRefresh(
        accountId: accountId,
        authEpoch: authEpoch,
        scopeGuard: guard,
      );
    }
  }

  Future<void> _uploadV2({
    required LibraryPendingOperation operation,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    final remote = _requireV2Remote;
    final payload = _decodeV2Payload(operation.payloadJson);
    _validateV2Request(operation, payload, authEpoch);
    late final Future<LibraryV2Mutation<dynamic>> request;
    try {
      // Only synchronous request construction is classified as local durable
      // corruption. Once a Future has been returned, failures may be after
      // server commit and must retain the operation for idempotent replay.
      request = switch (operation.operation) {
        'library_v2_item_put_active' ||
        'library_v2_item_put_inactive' => remote.putItem(
          paperId: _payloadUuid(payload, 'paper_id'),
          operationId: _validUuid(operation.operationId),
          state: _payloadState(payload),
          privateNote: _payloadNullableText(
            payload,
            'private_note',
            maximumLength: 500,
          ),
          saveSourceKind: _payloadSource(payload),
          reminderAt: _payloadNullableDate(payload, 'reminder_at'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_item_delete' => remote.deleteItem(
          paperId: _payloadUuid(payload, 'paper_id'),
          operationId: _validUuid(operation.operationId),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_list_create' => remote.createList(
          operationId: _validUuid(operation.operationId),
          listId: _payloadUuid(payload, 'list_id'),
          name: _payloadRequiredText(payload, 'name', maximumLength: 100),
          description: _payloadNullableText(
            payload,
            'description',
            maximumLength: 500,
          ),
          sortOrder: _payloadInt32(payload, 'sort_order'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_list_update' => remote.updateList(
          operationId: _validUuid(operation.operationId),
          listId: _payloadUuid(payload, 'list_id'),
          name: _payloadRequiredText(payload, 'name', maximumLength: 100),
          description: _payloadNullableText(
            payload,
            'description',
            maximumLength: 500,
          ),
          sortOrder: _payloadInt32(payload, 'sort_order'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_list_delete' => remote.deleteList(
          operationId: _validUuid(operation.operationId),
          listId: _payloadUuid(payload, 'list_id'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_list_item_put' => remote.putListItem(
          operationId: _validUuid(operation.operationId),
          listId: _payloadUuid(payload, 'list_id'),
          paperId: _payloadUuid(payload, 'paper_id'),
          positionRank: _payloadInt(payload, 'position_rank'),
          note: _payloadNullableText(payload, 'note', maximumLength: 500),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_list_item_delete' => remote.deleteListItem(
          operationId: _validUuid(operation.operationId),
          listId: _payloadUuid(payload, 'list_id'),
          paperId: _payloadUuid(payload, 'paper_id'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_tag_create' => remote.createTag(
          operationId: _validUuid(operation.operationId),
          tagId: _payloadUuid(payload, 'tag_id'),
          name: _payloadRequiredText(payload, 'name', maximumLength: 60),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_tag_update' => remote.updateTag(
          operationId: _validUuid(operation.operationId),
          tagId: _payloadUuid(payload, 'tag_id'),
          name: _payloadRequiredText(payload, 'name', maximumLength: 60),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_tag_delete' => remote.deleteTag(
          operationId: _validUuid(operation.operationId),
          tagId: _payloadUuid(payload, 'tag_id'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_item_tag_put' => remote.putItemTag(
          operationId: _validUuid(operation.operationId),
          paperId: _payloadUuid(payload, 'paper_id'),
          tagId: _payloadUuid(payload, 'tag_id'),
          expectedAuthEpoch: authEpoch,
        ),
        'library_v2_item_tag_delete' => remote.deleteItemTag(
          operationId: _validUuid(operation.operationId),
          paperId: _payloadUuid(payload, 'paper_id'),
          tagId: _payloadUuid(payload, 'tag_id'),
          expectedAuthEpoch: authEpoch,
        ),
        _ => throw StateError('Unsupported Library v2 outbox operation.'),
      };
    } on ArgumentError {
      throw _corruptOutbox;
    } on FormatException {
      throw _corruptOutbox;
    } on StateError {
      throw _corruptOutbox;
    }
    final result = await request;
    if (!scopeGuard()) return;
    if (!result.matchesOperation(operation)) throw _invalidSnapshot;
    await _requireV2Local.applyMutationSuccess(
      operation: operation,
      value: result.value,
      scopeGuard: scopeGuard,
    );
  }

  Future<void> _fullRefreshV2({
    required String accountId,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    final remote = _requireV2Remote;
    final lists = await remote.lists(expectedAuthEpoch: authEpoch);
    if (!scopeGuard()) return;
    final tags = await remote.tags(expectedAuthEpoch: authEpoch);
    if (!scopeGuard()) return;
    final items = await _allV2Items(
      authEpoch: authEpoch,
      scopeGuard: scopeGuard,
    );
    if (!scopeGuard()) return;
    final revision = items.$2;
    if (lists.syncRevision != revision || tags.syncRevision != revision) {
      throw _invalidSnapshot;
    }
    final listMemberships = <({String listId, String paperId})>{};
    for (final list in lists.items.where((value) => value.deletedAt == null)) {
      final filtered = await _allV2Items(
        authEpoch: authEpoch,
        scopeGuard: scopeGuard,
        listId: list.id,
      );
      if (filtered.$2 != revision) throw _invalidSnapshot;
      for (final entry in filtered.$1) {
        listMemberships.add((listId: list.id, paperId: entry.item.paperId));
      }
    }
    final tagMemberships = <({String paperId, String tagId})>{};
    for (final tag in tags.items.where((value) => value.deletedAt == null)) {
      final filtered = await _allV2Items(
        authEpoch: authEpoch,
        scopeGuard: scopeGuard,
        tagId: tag.id,
      );
      if (filtered.$2 != revision) throw _invalidSnapshot;
      for (final entry in filtered.$1) {
        tagMemberships.add((paperId: entry.item.paperId, tagId: tag.id));
      }
    }
    if (!scopeGuard()) return;
    await _requireV2Local.applyFullSnapshot(
      accountId: accountId,
      items: items.$1,
      lists: lists.items,
      tags: tags.items,
      listMemberships: listMemberships,
      tagMemberships: tagMemberships,
      syncRevision: revision,
      scopeGuard: scopeGuard,
    );
    await _changesRefreshV2(
      accountId: accountId,
      afterRevision: revision,
      authEpoch: authEpoch,
      scopeGuard: scopeGuard,
    );
  }

  Future<(List<LibraryV2Entry>, int)> _allV2Items({
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
    String? listId,
    String? tagId,
  }) async {
    final entries = <LibraryV2Entry>[];
    final ids = <String>{};
    final cursors = <String>{};
    String? cursor;
    int? revision;
    for (var pageNumber = 0; pageNumber < 1000; pageNumber += 1) {
      if (!scopeGuard()) return (<LibraryV2Entry>[], 0);
      final page = await _requireV2Remote.listItems(
        expectedAuthEpoch: authEpoch,
        listId: listId,
        tagId: tagId,
        cursor: cursor,
      );
      revision ??= page.syncRevision;
      if (page.syncRevision != revision) throw _invalidSnapshot;
      for (final entry in page.items) {
        if (!ids.add(entry.item.paperId)) throw _invalidSnapshot;
        entries.add(entry);
      }
      final next = page.nextCursor;
      if (next == null) {
        return (List<LibraryV2Entry>.unmodifiable(entries), revision);
      }
      if (!cursors.add(next)) throw _invalidSnapshot;
      cursor = next;
    }
    throw _invalidSnapshot;
  }

  Future<void> _changesRefreshV2({
    required String accountId,
    required int afterRevision,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    var checkpoint = afterRevision;
    for (var pageNumber = 0; pageNumber < 1000; pageNumber += 1) {
      if (!scopeGuard()) return;
      final page = await _requireV2Remote.changes(
        afterRevision: checkpoint,
        expectedAuthEpoch: authEpoch,
      );
      await _requireV2Local.applyChanges(
        accountId: accountId,
        page: page,
        scopeGuard: scopeGuard,
      );
      checkpoint = page.nextAfterRevision;
      if (!page.hasMore) return;
    }
    throw _invalidSnapshot;
  }

  Future<T> _withRevisionConflictTelemetry<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on LibraryRevisionConflict {
      emitTelemetry(
        _telemetry,
        PakPerkTelemetryEvent.librarySyncConflict,
        const {'boundary': 'local_revision'},
      );
      rethrow;
    }
  }

  LibraryV2Dao get _requireV2Local =>
      _v2Local ?? (throw StateError('Library v2 local adapter is missing.'));

  LibraryV2RemoteDataSource get _requireV2Remote =>
      _v2Remote ?? (throw StateError('Library v2 remote adapter is missing.'));

  Future<void> _fullRefresh({
    required String accountId,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    final entries = <LibraryRemoteEntry>[];
    final paperIds = <String>{};
    final seenCursors = <String>{};
    String? cursor;
    int? snapshotRevision;
    for (var pageNumber = 0; pageNumber < 1000; pageNumber += 1) {
      if (!scopeGuard()) return;
      final page = await _remote.list(
        cursor: cursor,
        expectedAuthEpoch: authEpoch,
      );
      if (!scopeGuard()) return;
      snapshotRevision ??= page.syncRevision;
      if (page.syncRevision != snapshotRevision) {
        throw _invalidSnapshot;
      }
      for (final entry in page.items) {
        if (!paperIds.add(entry.item.paperId)) throw _invalidSnapshot;
        entries.add(entry);
      }
      final next = page.nextCursor;
      if (next == null) break;
      if (!seenCursors.add(next)) throw _invalidSnapshot;
      cursor = next;
      if (pageNumber == 999) throw _invalidSnapshot;
    }
    if (!scopeGuard()) return;
    final revision = snapshotRevision ?? 0;
    await _local.applyFullSnapshot(
      accountId: accountId,
      entries: entries,
      syncRevision: revision,
      scopeGuard: scopeGuard,
    );
    if (!scopeGuard()) return;
    await _changesRefresh(
      accountId: accountId,
      afterRevision: revision,
      authEpoch: authEpoch,
      scopeGuard: scopeGuard,
    );
  }

  Future<void> _changesRefresh({
    required String accountId,
    required int afterRevision,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    var checkpoint = afterRevision;
    for (var pageNumber = 0; pageNumber < 1000; pageNumber += 1) {
      if (!scopeGuard()) return;
      final page = await _remote.changes(
        afterRevision: checkpoint,
        expectedAuthEpoch: authEpoch,
      );
      if (!scopeGuard()) return;
      if (page.nextAfterRevision < checkpoint) throw _invalidSnapshot;
      await _local.applyChanges(
        accountId: accountId,
        page: page,
        scopeGuard: scopeGuard,
      );
      checkpoint = page.nextAfterRevision;
      if (!page.hasMore) return;
    }
    throw _invalidSnapshot;
  }
}

const _invalidSnapshot = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The library service returned an inconsistent sync snapshot.',
  retryable: true,
  statusCode: 502,
);

const _corruptOutbox = ApiException(
  code: 'LOCAL_OUTBOX_CORRUPT',
  message: 'A queued library change is invalid.',
  retryable: false,
);

Map<String, dynamic> _decodeV2Payload(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    // Converted to a stable local corruption error below.
  }
  throw _corruptOutbox;
}

String _payloadString(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw _corruptOutbox;
  }
  return value;
}

String _validUuid(String value) {
  if (!_uuid.hasMatch(value)) throw _corruptOutbox;
  return value;
}

String _payloadUuid(Map<String, dynamic> payload, String key) =>
    _validUuid(_payloadString(payload, key));

String _payloadRequiredText(
  Map<String, dynamic> payload,
  String key, {
  required int maximumLength,
}) {
  final value = _payloadString(payload, key);
  if (!_validText(value, maximumLength: maximumLength)) {
    throw _corruptOutbox;
  }
  return value;
}

String? _payloadNullableText(
  Map<String, dynamic> payload,
  String key, {
  required int maximumLength,
}) {
  final value = payload[key];
  if (value == null) return null;
  if (value is! String || !_validText(value, maximumLength: maximumLength)) {
    throw _corruptOutbox;
  }
  return value;
}

bool _validText(String value, {required int maximumLength}) =>
    value.length <= maximumLength &&
    !value.runes.any((rune) => rune < 0x20 && rune != 0x0a);

DateTime? _payloadNullableDate(Map<String, dynamic> payload, String key) {
  final raw = payload[key];
  if (raw == null) return null;
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  throw _corruptOutbox;
}

int _payloadInt(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is! int) {
    throw _corruptOutbox;
  }
  return value;
}

int _payloadInt32(Map<String, dynamic> payload, String key) {
  final value = _payloadInt(payload, key);
  if (value < -2147483648 || value > 2147483647) throw _corruptOutbox;
  return value;
}

LibraryItemState _payloadState(Map<String, dynamic> payload) {
  final value = LibraryItemState.tryFromStorage(
    _payloadString(payload, 'state'),
  );
  if (value == null || payload['state'] == 'to_read') {
    throw _corruptOutbox;
  }
  return value;
}

LibrarySaveSourceKind? _payloadSource(Map<String, dynamic> payload) {
  final raw = payload['save_source_kind'];
  if (raw == null) return null;
  final value = LibrarySaveSourceKind.tryFromWire(
    _payloadString(payload, 'save_source_kind'),
  );
  if (value == null) {
    throw _corruptOutbox;
  }
  return value;
}

void _validateV2Request(
  LibraryPendingOperation operation,
  Map<String, dynamic> payload,
  int authEpoch,
) {
  if (authEpoch < 0) throw _corruptOutbox;
  _validUuid(operation.operationId);
  final allowedEntityKind = switch (operation.operation) {
    'library_v2_item_put_active' ||
    'library_v2_item_put_inactive' ||
    'library_v2_item_delete' => 'library_v2_item',
    'library_v2_list_create' ||
    'library_v2_list_update' ||
    'library_v2_list_delete' => 'library_v2_list',
    'library_v2_list_item_put' ||
    'library_v2_list_item_delete' => 'library_v2_list_item',
    'library_v2_tag_create' ||
    'library_v2_tag_update' ||
    'library_v2_tag_delete' => 'library_v2_tag',
    'library_v2_item_tag_put' ||
    'library_v2_item_tag_delete' => 'library_v2_item_tag',
    _ => throw _corruptOutbox,
  };
  if (operation.entityKind != allowedEntityKind) throw _corruptOutbox;
  final expected = switch (operation.entityKind) {
    'library_v2_item' => _payloadUuid(payload, 'paper_id'),
    'library_v2_list' => _payloadUuid(payload, 'list_id'),
    'library_v2_tag' => _payloadUuid(payload, 'tag_id'),
    'library_v2_list_item' =>
      '${_payloadUuid(payload, 'list_id')}:${_payloadUuid(payload, 'paper_id')}',
    'library_v2_item_tag' =>
      '${_payloadUuid(payload, 'paper_id')}:${_payloadUuid(payload, 'tag_id')}',
    _ => throw _corruptOutbox,
  };
  if (operation.entityId != expected) throw _corruptOutbox;
  switch (operation.operation) {
    case 'library_v2_item_put_active':
      final state = _payloadState(payload);
      if (!state.isActive) throw _corruptOutbox;
      _payloadNullableText(payload, 'private_note', maximumLength: 500);
      _payloadSource(payload);
      _payloadNullableDate(payload, 'reminder_at');
    case 'library_v2_item_put_inactive':
      final state = _payloadState(payload);
      if (state.isActive || payload['reminder_at'] != null) {
        throw _corruptOutbox;
      }
      _payloadNullableText(payload, 'private_note', maximumLength: 500);
      _payloadSource(payload);
    case 'library_v2_item_delete':
      break;
    case 'library_v2_list_create' || 'library_v2_list_update':
      _payloadRequiredText(payload, 'name', maximumLength: 100);
      _payloadNullableText(payload, 'description', maximumLength: 500);
      _payloadInt32(payload, 'sort_order');
    case 'library_v2_list_delete':
      break;
    case 'library_v2_list_item_put':
      _payloadInt(payload, 'position_rank');
      _payloadNullableText(payload, 'note', maximumLength: 500);
    case 'library_v2_list_item_delete':
      break;
    case 'library_v2_tag_create' || 'library_v2_tag_update':
      _payloadRequiredText(payload, 'name', maximumLength: 60);
    case 'library_v2_tag_delete' ||
        'library_v2_item_tag_put' ||
        'library_v2_item_tag_delete':
      break;
    default:
      throw _corruptOutbox;
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
