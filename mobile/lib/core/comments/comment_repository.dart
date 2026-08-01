import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../account/account_data_write_barrier.dart';
import '../api/api_exception.dart';
import '../database/comment_cache_dao.dart';
import '../database/comments_dao.dart';
import 'comment_models.dart';
import 'comments_api.dart';

typedef CommentSessionScope = ({String? accountId, int authEpoch});
typedef CommentSessionScopeReader = CommentSessionScope Function();
typedef VerifiedCommentScope = ({String accountId, int authEpoch});
typedef VerifiedCommentScopeReader = VerifiedCommentScope? Function();
typedef CommentScopeGuard = bool Function();

final class CommentViewerScope {
  const CommentViewerScope.guest() : accountId = null, authEpoch = null;

  const CommentViewerScope.authenticated({
    required String this.accountId,
    required int this.authEpoch,
  });

  final String? accountId;
  final int? authEpoch;

  bool get authenticated => accountId != null && authEpoch != null;
}

final class CommentRepository {
  const CommentRepository({
    required CommentCacheDao cache,
    required CommentsDao local,
    required CommentsRemoteDataSource remote,
    required AccountDataWriteBarrier accountWrites,
    required CommentSessionScopeReader sessionScope,
    required VerifiedCommentScopeReader verifiedScope,
  }) : _cache = cache,
       _local = local,
       _remote = remote,
       _accountWrites = accountWrites,
       _sessionScope = sessionScope,
       _verifiedScope = verifiedScope;

  final CommentCacheDao _cache;
  final CommentsDao _local;
  final CommentsRemoteDataSource _remote;
  final AccountDataWriteBarrier _accountWrites;
  final CommentSessionScopeReader _sessionScope;
  final VerifiedCommentScopeReader _verifiedScope;

  CommentScopeGuard viewerGuard(CommentViewerScope viewer) => () {
    if (!viewer.authenticated) return true;
    final verified = _verifiedScope();
    return verified?.accountId == viewer.accountId &&
        verified?.authEpoch == viewer.authEpoch;
  };

  CommentScopeGuard mutationGuard(String accountId, int authEpoch) => () {
    final session = _sessionScope();
    final verified = _verifiedScope();
    return session.accountId == accountId &&
        session.authEpoch == authEpoch &&
        verified?.accountId == accountId &&
        verified?.authEpoch == authEpoch;
  };

  Future<CommentPage?> loadCachedFirstPage({
    required String paperId,
    required CommentViewerScope viewer,
  }) async {
    final guard = viewerGuard(viewer);
    final cached = await _cache.load(
      _pageKey(paperId: paperId, viewerAccountId: viewer.accountId),
      allowExpired: true,
    );
    if (cached == null || !guard()) return null;
    try {
      final page = CommentPage.fromJson(_map(cached.payload));
      _validatePaperPage(page, paperId, viewer.accountId);
      final visible = await _filterBlocked(page, viewer.accountId);
      return guard() ? visible : null;
    } on FormatException {
      return null;
    }
  }

  Future<CommentPage> refreshFirstPage({
    required String paperId,
    required CommentViewerScope viewer,
  }) => loadPage(paperId: paperId, viewer: viewer);

  Future<CommentPage> loadPage({
    required String paperId,
    required CommentViewerScope viewer,
    String? cursor,
  }) async {
    final guard = viewerGuard(viewer);
    if (!guard()) throw const CommentScopeChanged();
    final page = await _remote.listPaper(
      paperId: paperId,
      expectedAuthEpoch: viewer.authEpoch,
      cursor: cursor,
    );
    if (!guard()) throw const CommentScopeChanged();
    _validatePaperPage(page, paperId, viewer.accountId);
    final cached = await _writeForViewer(
      viewer,
      guard,
      () => _cache.saveBounded(
        CachedCommentPageValue(
          pageKey: _pageKey(
            paperId: paperId,
            viewerAccountId: viewer.accountId,
            cursor: cursor,
          ),
          paperId: paperId,
          viewerAccountId: viewer.accountId,
          cursor: cursor,
          payload: page.toJson(),
          fetchedAt: DateTime.now().toUtc(),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      ),
    );
    if (!cached) throw const CommentScopeChanged();
    if (!guard()) throw const CommentScopeChanged();
    final visible = await _filterBlocked(page, viewer.accountId);
    if (!guard()) throw const CommentScopeChanged();
    return visible;
  }

  Future<void> cacheVisibleFirstPage({
    required String paperId,
    required CommentViewerScope viewer,
    required CommentPage page,
  }) async {
    _validatePaperPage(page, paperId, viewer.accountId);
    final guard = viewerGuard(viewer);
    if (!guard()) return;
    await _writeForViewer(
      viewer,
      guard,
      () => _cache.saveBounded(
        CachedCommentPageValue(
          pageKey: _pageKey(
            paperId: paperId,
            viewerAccountId: viewer.accountId,
          ),
          paperId: paperId,
          viewerAccountId: viewer.accountId,
          payload: page.toJson(),
          fetchedAt: DateTime.now().toUtc(),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      ),
    );
  }

  Future<CommentDraftValue?> loadDraft({
    required String accountId,
    required int authEpoch,
    required String paperId,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) throw const CommentScopeChanged();
    final value = await _local.loadDraft(accountId, paperId);
    if (!guard()) throw const CommentScopeChanged();
    return value;
  }

  Future<void> saveDraft({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required String body,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    final written = await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () => _local.saveDraft(
        accountId: accountId,
        paperId: paperId,
        body: body,
        clientRequestId: const Uuid().v7(),
      ),
    );
    if (!written) throw const CommentScopeChanged();
  }

  Future<PaperComment> create({
    required String accountId,
    required int authEpoch,
    required String paperId,
    required String body,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) throw const CommentScopeChanged();
    final normalized = normalizeCommentDraft(body);
    final issue = validateCommentBody(normalized);
    if (issue != null) {
      throw ApiException(code: 'INVALID_COMMENT', message: issue);
    }
    await saveDraft(
      accountId: accountId,
      authEpoch: authEpoch,
      paperId: paperId,
      body: normalized,
    );
    final draft = await loadDraft(
      accountId: accountId,
      authEpoch: authEpoch,
      paperId: paperId,
    );
    final requestId = draft?.clientRequestId;
    if (requestId == null || !guard()) throw const CommentScopeChanged();
    if (!await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () => _local.markDraftAttempted(
        accountId: accountId,
        paperId: paperId,
        body: normalized,
      ),
    )) {
      throw const CommentScopeChanged();
    }
    final comment = await _remote.create(
      paperId: paperId,
      clientRequestId: requestId,
      body: normalized,
      expectedAuthEpoch: authEpoch,
    );
    if (!guard()) throw const CommentScopeChanged();
    if (comment.paperId != paperId ||
        comment.author.id != accountId ||
        (comment.status != CommentStatus.published &&
            comment.status != CommentStatus.pendingReview)) {
      throw _invalidResponse;
    }
    // Acceptance includes both published and pending_review. The latter is a
    // canonical private server record, not an optimistic local post.
    if (!await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () => _local.clearDraft(accountId, paperId),
    )) {
      throw const CommentScopeChanged();
    }
    return comment;
  }

  Future<PaperComment> edit({
    required String accountId,
    required int authEpoch,
    required PaperComment comment,
    required String body,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard() || comment.author.id != accountId) {
      throw const CommentScopeChanged();
    }
    final normalized = normalizeCommentDraft(body);
    final issue = validateCommentBody(normalized);
    if (issue != null) {
      throw ApiException(code: 'INVALID_COMMENT', message: issue);
    }
    final updated = await _remote.edit(
      commentId: comment.id,
      body: normalized,
      expectedVersion: comment.version,
      expectedAuthEpoch: authEpoch,
    );
    if (!guard() ||
        updated.paperId != comment.paperId ||
        updated.author.id != accountId) {
      throw const CommentScopeChanged();
    }
    return updated;
  }

  Future<void> delete({
    required String accountId,
    required int authEpoch,
    required PaperComment comment,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard() || comment.author.id != accountId) {
      throw const CommentScopeChanged();
    }
    await _remote.delete(commentId: comment.id, expectedAuthEpoch: authEpoch);
    if (!guard()) throw const CommentScopeChanged();
  }

  Future<CommentReportReceipt> report({
    required String accountId,
    required int authEpoch,
    required String commentId,
    required CommentReportReason reason,
    String? detail,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) throw const CommentScopeChanged();
    final result = await _remote.report(
      commentId: commentId,
      reason: reason,
      detail: detail,
      expectedAuthEpoch: authEpoch,
    );
    if (!guard()) throw const CommentScopeChanged();
    return result;
  }

  Future<UserReportReceipt> reportUser({
    required String accountId,
    required int authEpoch,
    required String reportedUserId,
    required CommentReportReason reason,
    String? detail,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard() || reportedUserId == accountId) {
      throw const CommentScopeChanged();
    }
    final result = await _remote.reportUser(
      userId: reportedUserId,
      reason: reason,
      detail: detail,
      expectedAuthEpoch: authEpoch,
    );
    if (!guard() || result.reportedUserId != reportedUserId) {
      throw const CommentScopeChanged();
    }
    return result;
  }

  Stream<List<BlockedUserValue>> watchBlockedUsers(String accountId) =>
      _local.watchBlockedUsers(accountId);

  Future<void> block({
    required String accountId,
    required int authEpoch,
    required CommentAuthor author,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard() || author.id == accountId || author.handle == null) {
      throw const CommentScopeChanged();
    }
    try {
      if (!await _accountWrite(
        accountId: accountId,
        authEpoch: authEpoch,
        guard: guard,
        write: () => _local.blockLocally(
          accountId: accountId,
          blockedUserId: author.id,
          handle: author.handle!,
          displayName: author.displayName,
        ),
      )) {
        throw const CommentScopeChanged();
      }
    } on CommentScopeChanged {
      rethrow;
    } on Object {
      throw const CommentLocalBlockNotPersisted();
    }
    if (!guard()) return;
    final canonical = await _remote.block(
      userId: author.id,
      expectedAuthEpoch: authEpoch,
    );
    if (!guard()) return;
    await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () => _local.blockLocally(
        accountId: accountId,
        blockedUserId: canonical.user.id,
        handle: canonical.user.handle ?? author.handle!,
        displayName: canonical.user.displayName,
        createdAt: canonical.createdAt,
        serverConfirmed: true,
      ),
    );
  }

  Future<void> unblock({
    required String accountId,
    required int authEpoch,
    required String blockedUserId,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) throw const CommentScopeChanged();
    await _remote.unblock(userId: blockedUserId, expectedAuthEpoch: authEpoch);
    if (!guard()) return;
    await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () => _local.unblockLocally(accountId, blockedUserId),
    );
  }

  Future<void> reconcileBlocks({
    required String accountId,
    required int authEpoch,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) return;
    for (final pending in await _local.pendingBlocks(accountId)) {
      if (!guard()) return;
      final canonical = await _remote.block(
        userId: pending.userId,
        expectedAuthEpoch: authEpoch,
      );
      if (!guard()) return;
      if (!await _accountWrite(
        accountId: accountId,
        authEpoch: authEpoch,
        guard: guard,
        write: () => _local.blockLocally(
          accountId: accountId,
          blockedUserId: canonical.user.id,
          handle: canonical.user.handle ?? pending.handle,
          displayName: canonical.user.displayName,
          createdAt: canonical.createdAt,
          serverConfirmed: true,
        ),
      )) {
        return;
      }
    }

    final values = <BlockedUserValue>[];
    final cursors = <String>{};
    String? cursor;
    for (var pageNumber = 0; pageNumber < 1000; pageNumber += 1) {
      if (!guard()) return;
      final page = await _remote.listBlockedUsers(
        expectedAuthEpoch: authEpoch,
        cursor: cursor,
      );
      if (!guard()) return;
      values.addAll(
        page.items.map(
          (item) => BlockedUserValue(
            userId: item.user.id,
            handle: item.user.handle ?? 'reader',
            displayName: item.user.displayName,
            createdAt: item.createdAt,
            serverConfirmed: true,
          ),
        ),
      );
      final next = page.nextCursor;
      if (next == null) break;
      if (!cursors.add(next)) throw _invalidResponse;
      cursor = next;
      if (pageNumber == 999) throw _invalidResponse;
    }
    if (!guard()) return;
    await _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: () =>
          _local.replaceConfirmedBlocks(accountId: accountId, values: values),
    );
  }

  Future<CommentPage> listMyComments({
    required String accountId,
    required int authEpoch,
    String? cursor,
  }) async {
    final guard = mutationGuard(accountId, authEpoch);
    if (!guard()) throw const CommentScopeChanged();
    final page = await _remote.listMyComments(
      expectedAuthEpoch: authEpoch,
      cursor: cursor,
    );
    if (!guard() || page.items.any((item) => item.author.id != accountId)) {
      throw const CommentScopeChanged();
    }
    return page;
  }

  Future<CommentPage> _filterBlocked(
    CommentPage page,
    String? accountId,
  ) async {
    if (accountId == null) return page;
    final blocked = await _local.blockedUserIds(accountId);
    return CommentPage(
      items: page.items
          .where((item) => !blocked.contains(item.author.id))
          .toList(growable: false),
      nextCursor: page.nextCursor,
    );
  }

  Future<bool> _writeForViewer(
    CommentViewerScope viewer,
    CommentScopeGuard guard,
    Future<void> Function() write,
  ) async {
    final accountId = viewer.accountId;
    final authEpoch = viewer.authEpoch;
    if (accountId == null || authEpoch == null) {
      if (!guard()) return false;
      await write();
      return guard();
    }
    return _accountWrite(
      accountId: accountId,
      authEpoch: authEpoch,
      guard: guard,
      write: write,
    );
  }

  Future<bool> _accountWrite({
    required String accountId,
    required int authEpoch,
    required CommentScopeGuard guard,
    required Future<void> Function() write,
  }) => _accountWrites.writeIfCurrent(
    accountId: accountId,
    authEpoch: authEpoch,
    isCurrent: guard,
    write: write,
  );
}

void _validatePaperPage(
  CommentPage page,
  String paperId,
  String? viewerAccountId,
) {
  if (page.items.any(
    (item) =>
        item.paperId != paperId ||
        (item.status != CommentStatus.published &&
            !(item.status == CommentStatus.pendingReview &&
                item.author.id == viewerAccountId)),
  )) {
    throw _invalidResponse;
  }
}

String _pageKey({
  required String paperId,
  required String? viewerAccountId,
  String? cursor,
}) {
  if (!_uuid.hasMatch(paperId) ||
      (viewerAccountId != null && !_uuid.hasMatch(viewerAccountId))) {
    throw ArgumentError('Invalid comments cache identity.');
  }
  final viewer = viewerAccountId ?? 'guest';
  final page = cursor == null ? 'first' : base64Url.encode(utf8.encode(cursor));
  return 'comments:v5:$viewer:${paperId.toLowerCase()}:$page';
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Invalid cached comment page.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The comments service returned inconsistent data.',
  retryable: true,
  statusCode: 502,
);

final class CommentScopeChanged implements Exception {
  const CommentScopeChanged();

  @override
  String toString() => 'CommentScopeChanged';
}

final class CommentLocalBlockNotPersisted implements Exception {
  const CommentLocalBlockNotPersisted();

  @override
  String toString() => 'CommentLocalBlockNotPersisted';
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
