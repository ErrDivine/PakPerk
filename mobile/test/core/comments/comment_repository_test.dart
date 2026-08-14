import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/comments/comment_cache_barrier.dart';
import 'package:pakperk/core/comments/comment_controllers.dart';
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
      final bodies = <String>[];
      const rawBody = '  Ａ useful point\r\n\r\n\r\nnext\tline  ';
      const equivalentRetryBody = 'A useful point\n\nnext line   ';
      const canonicalBody = 'A useful point\n\nnext line';
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
              bodies.add(body);
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
          body: rawBody,
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
      expect(kept?.body, canonicalBody);
      expect(kept?.lastAttemptedBody, canonicalBody);
      expect(bodies, [canonicalBody]);

      // Autosaving a cosmetically different but canonically identical draft
      // must not turn an ambiguous first attempt into a second create intent.
      await fixture.repository.saveDraft(
        accountId: accountA,
        authEpoch: 1,
        paperId: samplePaper.paperId,
        body: equivalentRetryBody,
      );
      disabled = false;
      final accepted = await fixture.repository.create(
        accountId: accountA,
        authEpoch: 1,
        paperId: samplePaper.paperId,
        body: equivalentRetryBody,
      );
      expect(accepted.status, CommentStatus.pendingReview);
      expect(requests, hasLength(2));
      expect(requests.first, requests.last);
      expect(bodies, [canonicalBody, canonicalBody]);
      expect(
        await fixture.local.loadDraft(accountA, samplePaper.paperId),
        isNull,
      );
    },
  );

  test('edit sends the exact NFKC canonical body', () async {
    String? sentBody;
    const rawBody = '  \u212b edit\r\n\u1100\u1161\tline  ';
    const canonicalBody = '\u00c5 edit\n\uac00 line';
    final remote = _Remote(
      page: const CommentPage(items: [], nextCursor: null),
      editHandler:
          ({
            required commentId,
            required body,
            required expectedVersion,
            required expectedAuthEpoch,
          }) async {
            sentBody = body;
            return _comment(authorId: accountA, pending: false, body: body);
          },
    );
    final fixture = await _fixture(
      viewerAccountId: accountA,
      page: const CommentPage(items: [], nextCursor: null),
      remote: remote,
    );
    addTearDown(fixture.database.close);

    final updated = await fixture.repository.edit(
      accountId: accountA,
      authEpoch: 1,
      comment: _comment(authorId: accountA, pending: false),
      body: rawBody,
    );

    expect(sentBody, canonicalBody);
    expect(updated.body, canonicalBody);
    expect(remote.editCalls, 1);
  });

  test(
    'raw oversized and malformed drafts never persist or reach create/edit',
    () async {
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
        createHandler:
            ({
              required paperId,
              required clientRequestId,
              required body,
              required expectedAuthEpoch,
            }) async => throw StateError('create must not be called'),
        editHandler:
            ({
              required commentId,
              required body,
              required expectedVersion,
              required expectedAuthEpoch,
            }) async => throw StateError('edit must not be called'),
      );
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: const CommentPage(items: [], nextCursor: null),
        remote: remote,
      );
      addTearDown(fixture.database.close);
      final invalidBodies = <String>[
        _repeat('x', commentMaximumRawCodeUnits + 1),
        'before${String.fromCharCode(0xd800)}',
        _repeat('\u0301', commentMaximumRawClusterScalars + 1),
      ];

      for (final body in invalidBodies) {
        await expectLater(
          fixture.repository.saveDraft(
            accountId: accountA,
            authEpoch: 1,
            paperId: samplePaper.paperId,
            body: body,
          ),
          throwsArgumentError,
        );
        await expectLater(
          fixture.repository.create(
            accountId: accountA,
            authEpoch: 1,
            paperId: samplePaper.paperId,
            body: body,
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INVALID_COMMENT',
            ),
          ),
        );
        await expectLater(
          fixture.repository.edit(
            accountId: accountA,
            authEpoch: 1,
            comment: _comment(authorId: accountA, pending: false),
            body: body,
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INVALID_COMMENT',
            ),
          ),
        );
      }

      expect(remote.createCalls, 0);
      expect(remote.editCalls, 0);
      expect(
        await fixture.local.loadDraft(accountA, samplePaper.paperId),
        isNull,
      );
    },
  );

  test('comment cache expiry follows the injected cache policy', () async {
    const cachePolicy = FeedPrefetchConfig(
      firstCommentsPageTtl: Duration(seconds: 37),
    );
    final fixture = await _fixture(
      viewerAccountId: null,
      page: const CommentPage(items: [], nextCursor: null),
      cachePolicy: cachePolicy,
    );
    addTearDown(fixture.database.close);

    await fixture.repository.loadPage(
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.guest(),
    );

    final cached = await fixture.database
        .select(fixture.database.cachedCommentPages)
        .getSingle();
    expect(
      cached.expiresAt.difference(cached.fetchedAt),
      cachePolicy.firstCommentsPageTtl,
    );
  });

  test(
    'deletion purge rejects a delayed guest page and reopens a fresh generation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final remote = _Remote(
        page: CommentPage(
          items: [
            _comment(
              authorId: accountA,
              pending: false,
              body: 'Deleted author snapshot must not return or persist.',
            ),
          ],
          nextCursor: null,
        ),
      );
      final fixture = await _fixture(
        viewerAccountId: null,
        page: remote.page,
        remote: remote,
        cacheFactory: (database) =>
            _DelayedCacheDao(database, entered: entered, release: release),
      );
      addTearDown(fixture.database.close);

      final staleRequest = fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.guest(),
      );
      await entered.future;
      final purge = fixture.commentCache.invalidateAndPurge(
        AccountCacheDao(fixture.database).purgeCommentPagesForAccountDeletion,
      );
      release.complete();

      await expectLater(staleRequest, throwsA(isA<CommentScopeChanged>()));
      await purge;
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        isEmpty,
      );

      remote.page = CommentPage(
        items: [
          _comment(
            authorId: accountB,
            pending: false,
            body: 'Fresh public snapshot after cleanup.',
          ),
        ],
        nextCursor: null,
      );
      final fresh = await fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.guest(),
      );
      expect(fresh.items.single.body, 'Fresh public snapshot after cleanup.');
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        hasLength(1),
      );
    },
  );

  test(
    'deletion purge rejects delayed account cache while preserving its draft',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final remote = _Remote(
        page: CommentPage(
          items: [
            _comment(
              authorId: accountA,
              pending: true,
              body: 'Private pending review must not survive deletion purge.',
            ),
          ],
          nextCursor: null,
        ),
        listEntered: entered,
        listRelease: release,
      );
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: remote.page,
        remote: remote,
      );
      addTearDown(fixture.database.close);
      const viewer = CommentViewerScope.authenticated(
        accountId: accountA,
        authEpoch: 1,
      );
      await fixture.repository.saveDraft(
        accountId: accountA,
        authEpoch: 1,
        paperId: samplePaper.paperId,
        body: 'Draft lifetime is controlled by account cleanup.',
      );

      final staleRequest = fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: viewer,
      );
      await entered.future;
      await fixture.commentCache.invalidateAndPurge(
        AccountCacheDao(fixture.database).purgeCommentPagesForAccountDeletion,
      );
      release.complete();

      await expectLater(staleRequest, throwsA(isA<CommentScopeChanged>()));
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        isEmpty,
      );
      expect(
        (await fixture.local.loadDraft(accountA, samplePaper.paperId))?.body,
        'Draft lifetime is controlled by account cleanup.',
      );

      remote.page = CommentPage(
        items: [
          _comment(
            authorId: accountB,
            pending: false,
            body: 'Fresh account snapshot after cleanup.',
          ),
        ],
        nextCursor: null,
      );
      final fresh = await fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: viewer,
      );
      expect(fresh.items.single.body, 'Fresh account snapshot after cleanup.');
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        hasLength(1),
      );
    },
  );

  test(
    'failed deletion purge keeps comment cache reads and writes closed',
    () async {
      final remote = _Remote(
        page: CommentPage(
          items: [
            _comment(
              authorId: accountB,
              pending: false,
              body: 'Pre-purge cached snapshot.',
            ),
          ],
          nextCursor: null,
        ),
      );
      final fixture = await _fixture(
        viewerAccountId: null,
        page: remote.page,
        remote: remote,
      );
      addTearDown(fixture.database.close);
      const viewer = CommentViewerScope.guest();
      await fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: viewer,
      );

      await expectLater(
        fixture.commentCache.invalidateAndPurge(
          () async => throw StateError('injected purge failure'),
        ),
        throwsStateError,
      );
      expect(
        await fixture.repository.loadCachedFirstPage(
          paperId: samplePaper.paperId,
          viewer: viewer,
        ),
        isNull,
      );
      final callsBeforeBlockedRefresh = remote.listAuthEpochs.length;
      await expectLater(
        fixture.repository.loadPage(
          paperId: samplePaper.paperId,
          viewer: viewer,
        ),
        throwsA(isA<CommentScopeChanged>()),
      );
      expect(remote.listAuthEpochs, hasLength(callsBeforeBlockedRefresh));

      await fixture.commentCache.invalidateAndPurge(
        AccountCacheDao(fixture.database).purgeCommentPagesForAccountDeletion,
      );
      expect(
        await fixture.database
            .select(fixture.database.cachedCommentPages)
            .get(),
        isEmpty,
      );
      remote.page = const CommentPage(items: [], nextCursor: null);
      await fixture.repository.loadPage(
        paperId: samplePaper.paperId,
        viewer: viewer,
      );
      expect(
        await fixture.repository.loadCachedFirstPage(
          paperId: samplePaper.paperId,
          viewer: viewer,
        ),
        isNotNull,
      );
    },
  );

  test(
    'cold offline restore reopens account cache and draft without mutation authority',
    () async {
      final cachedPage = CommentPage(
        items: [
          _comment(
            authorId: accountB,
            pending: false,
            body: 'Account-scoped cached observation.',
          ),
        ],
        nextCursor: null,
      );
      final remote = _Remote(
        page: CommentPage(
          items: [
            _comment(
              authorId: accountB,
              pending: false,
              body: 'Anonymous remote observation.',
            ),
          ],
          nextCursor: null,
        ),
      );
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: cachedPage,
        remote: remote,
      );
      addTearDown(fixture.database.close);
      const verifiedViewer = CommentViewerScope.authenticated(
        accountId: accountA,
        authEpoch: 1,
      );
      await fixture.repository.cacheVisibleFirstPage(
        paperId: samplePaper.paperId,
        viewer: verifiedViewer,
        page: cachedPage,
      );
      await fixture.repository.saveDraft(
        accountId: accountA,
        authEpoch: 1,
        paperId: samplePaper.paperId,
        body: 'Draft restored after process death.',
      );
      fixture.scope.remoteVerified = false;
      final controller = CommentThreadController(
        repository: fixture.repository,
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.retained(
          accountId: accountA,
          authEpoch: 1,
        ),
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.state.items, hasLength(1));
      expect(
        controller.state.items.single.body,
        'Account-scoped cached observation.',
      );
      expect(controller.state.showingCached, isTrue);
      expect(controller.state.draft, 'Draft restored after process death.');
      expect(
        remote.listAuthEpochs,
        isEmpty,
        reason: 'retained account cache must never be replaced by a guest read',
      );

      await controller.saveDraft('Updated while still offline.');
      expect(
        (await fixture.local.loadDraft(accountA, samplePaper.paperId))?.body,
        'Updated while still offline.',
      );
      expect(await controller.send(), isNull);
      expect(remote.createCalls, 0);
    },
  );
}

Future<
  ({
    PakPerkDatabase database,
    CommentRepository repository,
    CommentsDao local,
    AccountDataWriteBarrier barrier,
    CommentCacheBarrier commentCache,
    _MutableScope scope,
  })
>
_fixture({
  required String? viewerAccountId,
  required CommentPage page,
  _Remote? remote,
  FeedPrefetchConfig cachePolicy = const FeedPrefetchConfig(),
  CommentCacheDao Function(PakPerkDatabase database)? cacheFactory,
}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  await PaperCacheDao(database).save(samplePaper);
  final scope = _MutableScope(viewerAccountId, 1);
  final barrier = AccountDataWriteBarrier();
  final commentCache = CommentCacheBarrier();
  final local = CommentsDao(database);
  final repository = CommentRepository(
    cache: cacheFactory?.call(database) ?? CommentCacheDao(database),
    local: local,
    remote: remote ?? _Remote(page: page),
    accountWrites: barrier,
    commentCache: commentCache,
    cachePolicy: cachePolicy,
    sessionScope: () =>
        (accountId: scope.accountId, authEpoch: scope.authEpoch),
    verifiedScope: () => scope.accountId == null || !scope.remoteVerified
        ? null
        : (accountId: scope.accountId!, authEpoch: scope.authEpoch),
  );
  return (
    database: database,
    repository: repository,
    local: local,
    barrier: barrier,
    commentCache: commentCache,
    scope: scope,
  );
}

final class _MutableScope {
  _MutableScope(this.accountId, this.authEpoch);

  String? accountId;
  int authEpoch;
  bool remoteVerified = true;
}

typedef _CreateHandler =
    Future<PaperComment> Function({
      required String paperId,
      required String clientRequestId,
      required String body,
      required int expectedAuthEpoch,
    });

typedef _EditHandler =
    Future<PaperComment> Function({
      required String commentId,
      required String body,
      required int expectedVersion,
      required int expectedAuthEpoch,
    });

final class _Remote implements CommentsRemoteDataSource {
  _Remote({
    required this.page,
    this.createHandler,
    this.editHandler,
    this.listEntered,
    this.listRelease,
  });

  CommentPage page;
  final _CreateHandler? createHandler;
  final _EditHandler? editHandler;
  final Completer<void>? listEntered;
  final Completer<void>? listRelease;
  final List<int?> listAuthEpochs = [];
  int createCalls = 0;
  int editCalls = 0;

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    listAuthEpochs.add(expectedAuthEpoch);
    final entered = listEntered;
    if (entered != null && !entered.isCompleted) {
      entered.complete();
    }
    await listRelease?.future;
    return page;
  }

  @override
  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  }) {
    createCalls += 1;
    return createHandler!(
      paperId: paperId,
      clientRequestId: clientRequestId,
      body: body,
      expectedAuthEpoch: expectedAuthEpoch,
    );
  }

  @override
  Future<PaperComment> edit({
    required String commentId,
    required String body,
    required int expectedVersion,
    required int expectedAuthEpoch,
  }) {
    editCalls += 1;
    return editHandler!(
      commentId: commentId,
      body: body,
      expectedVersion: expectedVersion,
      expectedAuthEpoch: expectedAuthEpoch,
    );
  }

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
    if (!entered.isCompleted) entered.complete();
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

String _repeat(String value, int count) => List.filled(count, value).join();
