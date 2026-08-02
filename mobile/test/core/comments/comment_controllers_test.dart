import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/comments/comment_cache_barrier.dart';
import 'package:pakperk/core/comments/comment_controllers.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/comments/comment_repository.dart';
import 'package:pakperk/core/comments/comments_api.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';

import '../../support/fakes.dart';

void main() {
  const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

  test('failed initial local block restores the author honestly', () async {
    final remote = _Remote(
      page: CommentPage(items: [_comment()], nextCursor: null),
    );
    final fixture = await _fixture(remote: remote);
    final controller = CommentThreadController(
      repository: fixture.repository,
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.authenticated(
        accountId: accountA,
        authEpoch: 1,
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await fixture.database.close();

    expect(await controller.block(_author(accountB)), isFalse);
    expect(controller.state.items, hasLength(1));
    expect(controller.state.errorMessage, contains('remains visible'));
    expect(remote.blockCalls, 0);
  });

  test('disposed edit and My Comments ignore late account A results', () async {
    final editStarted = Completer<void>();
    final editRelease = Completer<void>();
    final myStarted = Completer<void>();
    final myRelease = Completer<void>();
    final remote = _Remote(
      page: CommentPage(
        items: [_comment(authorId: accountA)],
        nextCursor: null,
      ),
      editStarted: editStarted,
      editRelease: editRelease,
      myStarted: myStarted,
      myRelease: myRelease,
    );
    final fixture = await _fixture(remote: remote);
    addTearDown(fixture.database.close);
    final thread = CommentThreadController(
      repository: fixture.repository,
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.authenticated(
        accountId: accountA,
        authEpoch: 1,
      ),
    );
    await thread.load();
    final edit = thread.edit(thread.state.items.single, 'Edited body');
    await editStarted.future;

    final mine = MyCommentsController(
      repository: fixture.repository,
      scope: const (accountId: accountA, authEpoch: 1),
    );
    final loadMine = mine.load();
    await myStarted.future;
    fixture.scope
      ..accountId = accountB
      ..authEpoch = 2;
    thread.dispose();
    mine.dispose();
    editRelease.complete();
    myRelease.complete();

    expect(await edit, isFalse);
    await loadMine;
  });

  test(
    'a newer draft is retained when create accepts an older snapshot',
    () async {
      final createStarted = Completer<void>();
      final createRelease = Completer<void>();
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
        createStarted: createStarted,
        createRelease: createRelease,
      );
      final fixture = await _fixture(remote: remote);
      addTearDown(fixture.database.close);
      final controller = CommentThreadController(
        repository: fixture.repository,
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.authenticated(
          accountId: accountA,
          authEpoch: 1,
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.saveDraft('Submitted body');
      final send = controller.send();
      await createStarted.future;
      await controller.saveDraft('A newer unsent draft');
      createRelease.complete();

      expect(await send, isNotNull);
      expect(controller.state.draft, 'A newer unsent draft');
      expect(
        (await fixture.local.loadDraft(accountA, samplePaper.paperId))?.body,
        'A newer unsent draft',
      );
    },
  );
}

Future<
  ({
    PakPerkDatabase database,
    CommentRepository repository,
    CommentsDao local,
    _MutableScope scope,
  })
>
_fixture({required _Remote remote}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  await PaperCacheDao(database).save(samplePaper);
  final local = CommentsDao(database);
  final scope = _MutableScope(accountA, 1);
  return (
    database: database,
    local: local,
    scope: scope,
    repository: CommentRepository(
      cache: CommentCacheDao(database),
      local: local,
      remote: remote,
      accountWrites: AccountDataWriteBarrier(),
      commentCache: CommentCacheBarrier(),
      cachePolicy: const FeedPrefetchConfig(),
      sessionScope: () =>
          (accountId: scope.accountId, authEpoch: scope.authEpoch),
      verifiedScope: () =>
          (accountId: scope.accountId, authEpoch: scope.authEpoch),
    ),
  );
}

const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

final class _MutableScope {
  _MutableScope(this.accountId, this.authEpoch);

  String accountId;
  int authEpoch;
}

final class _Remote implements CommentsRemoteDataSource {
  _Remote({
    required this.page,
    this.editStarted,
    this.editRelease,
    this.myStarted,
    this.myRelease,
    this.createStarted,
    this.createRelease,
  });

  final CommentPage page;
  final Completer<void>? editStarted;
  final Completer<void>? editRelease;
  final Completer<void>? myStarted;
  final Completer<void>? myRelease;
  final Completer<void>? createStarted;
  final Completer<void>? createRelease;
  int blockCalls = 0;

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async => page;

  @override
  Future<PaperComment> edit({
    required String commentId,
    required String body,
    required int expectedVersion,
    required int expectedAuthEpoch,
  }) async {
    editStarted?.complete();
    await editRelease?.future;
    final old = page.items.single;
    return PaperComment(
      id: old.id,
      paperId: old.paperId,
      author: old.author,
      body: body,
      status: old.status,
      version: old.version + 1,
      createdAt: old.createdAt,
      updatedAt: old.updatedAt.add(const Duration(minutes: 1)),
      editedAt: old.updatedAt.add(const Duration(minutes: 1)),
    );
  }

  @override
  Future<CommentPage> listMyComments({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    myStarted?.complete();
    await myRelease?.future;
    return page;
  }

  @override
  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  }) async {
    createStarted?.complete();
    await createRelease?.future;
    return _comment(authorId: accountA, pending: true, body: body);
  }

  @override
  Future<BlockedUser> block({
    required String userId,
    required int expectedAuthEpoch,
  }) async {
    blockCalls += 1;
    return BlockedUser(
      user: _author(userId),
      createdAt: DateTime.utc(2026, 8, 1),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CommentAuthor _author(String id) => CommentAuthor(
  id: id,
  handle: id == accountA ? 'reader_one' : 'reader_two',
  displayName: null,
  status: CommentAccountStatus.active,
);

PaperComment _comment({
  String authorId = accountB,
  bool pending = false,
  String body = 'A useful observation.',
}) => PaperComment(
  id: '018f47a6-4b56-7f4c-8c7a-e2656e820011',
  paperId: samplePaper.paperId,
  author: _author(authorId),
  body: body,
  status: pending ? CommentStatus.pendingReview : CommentStatus.published,
  version: 1,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
  editedAt: null,
);
