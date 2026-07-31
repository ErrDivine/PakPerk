import '../api/api_exception.dart';
import '../database/library_dao.dart';
import '../models/paper.dart';
import 'library_api.dart';
import 'library_models.dart';

typedef LibrarySessionScope = ({String? accountId, int authEpoch});
typedef LibrarySessionScopeReader = LibrarySessionScope Function();
typedef LibraryVerifiedScopeReader = LibrarySessionScope? Function();

final class LibraryRepository {
  const LibraryRepository({
    required LibraryDao local,
    required LibraryRemoteDataSource remote,
    required LibrarySessionScopeReader sessionScope,
    required LibraryVerifiedScopeReader verifiedScope,
  }) : _local = local,
       _remote = remote,
       _sessionScope = sessionScope,
       _verifiedScope = verifiedScope;

  final LibraryDao _local;
  final LibraryRemoteDataSource _remote;
  final LibrarySessionScopeReader _sessionScope;
  final LibraryVerifiedScopeReader _verifiedScope;

  Stream<LibrarySavedState> watchSavedState(String accountId, String paperId) =>
      _local.watchSavedState(accountId, paperId);

  Stream<List<LibraryListItem>> watchToRead(String accountId) =>
      _local.watchToRead(accountId);

  Stream<int> watchPendingCount(String accountId) =>
      _local.watchPendingCount(accountId);

  Future<String> setSaved({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required bool saved,
    PaperSummary? paper,
  }) {
    final guard = scopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) throw const LibraryScopeChanged();
    return _local.enqueueMutation(
      accountId: accountId,
      paperId: paperId,
      saved: saved,
      paper: paper,
      scopeGuard: guard,
    );
  }

  Future<void> clearSyncIssue(String accountId, String paperId) =>
      _local.clearSyncIssue(accountId, paperId);

  LibraryScopeGuard scopeGuard({
    required String accountId,
    required int authEpoch,
  }) => () {
    final current = _sessionScope();
    return current.accountId == accountId && current.authEpoch == authEpoch;
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
  }) => _local.markPermanentFailure(
    operation: operation,
    errorCode: error.code,
    scopeGuard: scopeGuard,
  );

  Future<void> upload({
    required LibraryPendingOperation operation,
    required int authEpoch,
    required LibraryScopeGuard scopeGuard,
  }) async {
    if (!scopeGuard()) return;
    final result = switch (operation.intent) {
      LibraryMutationIntent.save => await _remote.save(
        paperId: operation.paperId,
        operationId: operation.operationId,
        expectedAuthEpoch: authEpoch,
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

  Future<void> refresh({
    required String accountId,
    required int authEpoch,
    bool forceFull = false,
  }) async {
    final guard = remoteScopeGuard(accountId: accountId, authEpoch: authEpoch);
    if (!guard()) return;
    final checkpoint = await _local.syncCheckpoint(accountId);
    if (!guard()) return;
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
      await _fullRefresh(
        accountId: accountId,
        authEpoch: authEpoch,
        scopeGuard: guard,
      );
    }
  }

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
