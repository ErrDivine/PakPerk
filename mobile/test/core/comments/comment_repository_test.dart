import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/comments/comment_repository.dart';
import 'package:pakperk/core/comments/comments_api.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';

import '../../support/fakes.dart';

void main() {
  const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

  test(
    'paper pages reject pending_review belonging to another viewer',
    () async {
      final fixture = await _fixture(
        viewerAccountId: accountB,
        page: CommentPage(
          items: [_comment(authorId: accountA, pending: true)],
          nextCursor: null,
        ),
      );
      addTearDown(fixture.database.close);

      await expectLater(
        fixture.repository.loadPage(
          paperId: samplePaper.paperId,
          viewer: const CommentViewerScope.authenticated(
            accountId: accountB,
            authEpoch: 1,
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_API_RESPONSE',
          ),
        ),
      );
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        isEmpty,
      );
    },
  );

  test(
    'sign-out cleanup removes a delayed own pending_review cache body',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: CommentPage(
          items: [
            _comment(
              authorId: accountA,
              pending: true,
              body: 'private pending-review body',
            ),
          ],
          nextCursor: null,
        ),
        cacheFactory: (database) =>
            _DelayedCacheDao(database, entered: entered, release: release),
      );
      addTearDown(fixture.database.close);
      final request = fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.authenticated(
          accountId: accountA,
          authEpoch: 1,
        ),
      );
      await entered.future;
      fixture.scope.accountId = null;
      fixture.scope.authEpoch = 2;
      final accounts = AccountCacheDao(fixture.database);
      final cleanup = fixture.barrier.clear(
        accountId: accountA,
        invalidatedThroughEpoch: 2,
        clearAccount: accounts.clearAccountData,
        clearAll: accounts.clearAllAccountData,
      );
      release.complete();

      await expectLater(request, throwsA(isA<CommentScopeChanged>()));
      await cleanup;
      final rows = await fixture.database
          .select(fixture.database.cachedCommentPages)
          .get();
      expect(rows, isEmpty);
    },
  );

  test(
    'creation kill keeps draft and accepted retry reuses then clears it',
    () async {
      final requests = <String>[];
      var disabled = true;
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
        createHandler:
            ({
              required paperId,
              required clientRequestId,
              required body,
              required expectedAuthEpoch,
            }) async {
              requests.add(clientRequestId);
              if (disabled) {
                throw const ApiException(
                  code: 'FEATURE_DISABLED',
                  message: 'paused',
                  statusCode: 503,
                );
              }
              return _comment(authorId: accountA, pending: true, body: body);
            },
      );
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: const CommentPage(items: [], nextCursor: null),
        remote: remote,
      );
      addTearDown(fixture.database.close);

      await expectLater(
        fixture.repository.create(
          accountId: accountA,
          authEpoch: 1,
          paperId: samplePaper.paperId,
          body: 'Keep this deliberate draft.',
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'FEATURE_DISABLED',
          ),
        ),
      );
      final kept = await fixture.local.loadDraft(accountA, samplePaper.paperId);
      expect(kept?.body, 'Keep this deliberate draft.');
      expect(kept?.lastAttemptedBody, 'Keep this deliberate draft.');

      disabled = false;
      final accepted = await fixture.repository.create(
        accountId: accountA,
        authEpoch: 1,
        paperId: samplePaper.paperId,
        body: 'Keep this deliberate draft.',
      );
      expect(accepted.status, CommentStatus.pendingReview);
      expect(requests, hasLength(2));
      expect(requests.first, requests.last);
      expect(
        await fixture.local.loadDraft(accountA, samplePaper.paperId),
        isNull,
      );
    },
  );
}

Future<
  ({
    PakPerkDatabase database,
    CommentRepository repository,
    CommentsDao local,
    AccountDataWriteBarrier barrier,
    _MutableScope scope,
  })
>
_fixture({
  required String? viewerAccountId,
  required CommentPage page,
  _Remote? remote,
  CommentCacheDao Function(PakPerkDatabase database)? cacheFactory,
}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  await PaperCacheDao(database).save(samplePaper);
  final scope = _MutableScope(viewerAccountId, 1);
  final barrier = AccountDataWriteBarrier();
  final local = CommentsDao(database);
  final repository = CommentRepository(
    cache: cacheFactory?.call(database) ?? CommentCacheDao(database),
    local: local,
    remote: remote ?? _Remote(page: page),
    accountWrites: barrier,
    sessionScope: () =>
        (accountId: scope.accountId, authEpoch: scope.authEpoch),
    verifiedScope: () => scope.accountId == null
        ? null
        : (accountId: scope.accountId!, authEpoch: scope.authEpoch),
  );
  return (
    database: database,
    repository: repository,
    local: local,
    barrier: barrier,
    scope: scope,
  );
}

final class _MutableScope {
  _MutableScope(this.accountId, this.authEpoch);

  String? accountId;
  int authEpoch;
}

typedef _CreateHandler =
    Future<PaperComment> Function({
      required String paperId,
      required String clientRequestId,
      required String body,
      required int expectedAuthEpoch,
    });

final class _Remote implements CommentsRemoteDataSource {
  _Remote({required this.page, this.createHandler});

  final CommentPage page;
  final _CreateHandler? createHandler;

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async => page;

  @override
  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  }) => createHandler!(
    paperId: paperId,
    clientRequestId: clientRequestId,
    body: body,
    expectedAuthEpoch: expectedAuthEpoch,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DelayedCacheDao extends CommentCacheDao {
  _DelayedCacheDao(
    super.database, {
    required this.entered,
    required this.release,
  });

  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<void> saveBounded(
    CachedCommentPageValue value, {
    int maximumPages = 3,
  }) async {
    entered.complete();
    await release.future;
    await super.saveBounded(value, maximumPages: maximumPages);
  }
}

PaperComment _comment({
  required String authorId,
  required bool pending,
  String body = 'A useful observation.',
}) => PaperComment(
  id: '018f47a6-4b56-7f4c-8c7a-e2656e820011',
  paperId: samplePaper.paperId,
  author: CommentAuthor(
    id: authorId,
    handle: authorId.endsWith('1') ? 'reader_one' : 'reader_two',
    displayName: null,
    status: CommentAccountStatus.active,
  ),
  body: body,
  status: pending ? CommentStatus.pendingReview : CommentStatus.published,
  version: 1,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
  editedAt: null,
);
