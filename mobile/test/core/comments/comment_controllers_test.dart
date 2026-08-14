import 'dart:async';

import 'package:drift/drift.dart' show Value;
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

  test(
    'invalid visible input cannot replace, persist, or send the prior draft',
    () async {
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
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
      await controller.saveDraft('Prior valid draft');

      for (final invalidBody in <String>[
        _repeat('x', commentMaximumRawCodeUnits + 1),
        'before${String.fromCharCode(0xd800)}',
        _repeat('\u0301', commentMaximumRawClusterScalars + 1),
      ]) {
        await controller.saveDraft(invalidBody);
        expect(controller.state.draft, 'Prior valid draft');
        expect(controller.state.draftInputIssue, isNotNull);
        expect(
          (await fixture.local.loadDraft(accountA, samplePaper.paperId))?.body,
          'Prior valid draft',
        );
        expect(await controller.send(), isNull);
        expect(remote.createCalls, 0);
      }

      await controller.saveDraft('Recovered valid draft');
      expect(controller.state.draftInputIssue, isNull);
      expect(controller.state.errorMessage, isNull);
      expect(await controller.send(), isNotNull);
      expect(remote.createCalls, 1);
    },
  );

  test(
    'only the current completed normalized validation enables send',
    () async {
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
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
      final body = _repeat('x', 300);
      await controller.saveDraft(body);

      expect(controller.state.draftValidationPending, isTrue);
      controller.completeDraftValidation(body: 'stale body', issue: null);
      expect(controller.state.draftValidationPending, isTrue);
      controller.completeDraftValidation(
        body: body,
        issue: 'Comments may contain at most three links.',
      );
      expect(controller.state.draftValidationPending, isFalse);
      expect(
        controller.state.draftInputIssue,
        'Comments may contain at most three links.',
      );
      expect(await controller.send(), isNull);
      expect(remote.createCalls, 0);

      await controller.saveDraft('Recovered valid draft');
      expect(controller.state.draftValidationPending, isTrue);
      controller.completeDraftValidation(
        body: 'Recovered valid draft',
        issue: null,
      );
      expect(controller.state.draftValidationPending, isFalse);
      expect(await controller.send(), isNotNull);
      expect(remote.createCalls, 1);
    },
  );

  test(
    'late draft hydration cannot clear a newer invalid input issue',
    () async {
      final remote = _Remote(
        page: const CommentPage(items: [], nextCursor: null),
      );
      final fixture = await _fixture(remote: remote);
      addTearDown(fixture.database.close);
      await fixture.local.saveDraft(
        accountId: accountA,
        paperId: samplePaper.paperId,
        body: 'Saved database draft',
        clientRequestId: '018f47a6-4b56-7f4c-8c7a-e2656e820099',
      );
      final controller = CommentThreadController(
        repository: fixture.repository,
        paperId: samplePaper.paperId,
        viewer: const CommentViewerScope.authenticated(
          accountId: accountA,
          authEpoch: 1,
        ),
      );
      addTearDown(controller.dispose);

      final transactionStarted = Completer<void>();
      final releaseTransaction = Completer<void>();
      final blockingTransaction = fixture.database.transaction(() async {
        transactionStarted.complete();
        await releaseTransaction.future;
      });
      addTearDown(() async {
        if (!releaseTransaction.isCompleted) releaseTransaction.complete();
        await blockingTransaction;
      });
      await transactionStarted.future;

      final load = controller.load();
      await Future<void>.delayed(Duration.zero);
      final invalidVisibleInput = _repeat('x', commentMaximumRawCodeUnits + 1);
      await controller.saveDraft(invalidVisibleInput);
      expect(controller.state.draftInputIssue, commentRawInputTooLargeMessage);

      releaseTransaction.complete();
      await blockingTransaction;
      await load;

      expect(controller.state.draft, isEmpty);
      expect(controller.state.draftInputIssue, commentRawInputTooLargeMessage);
      expect(await controller.send(), isNull);
      expect(remote.createCalls, 0);
    },
  );

  test('legacy invalid draft hydrates with an issue and cannot send', () async {
    final remote = _Remote(
      page: const CommentPage(items: [], nextCursor: null),
    );
    final fixture = await _fixture(remote: remote);
    addTearDown(fixture.database.close);
    final legacyDraft = _repeat('x', commentMaximumRawCodeUnits + 1);
    final timestamp = DateTime.utc(2026, 8, 1);
    await fixture.database
        .into(fixture.database.commentDrafts)
        .insert(
          CommentDraftsCompanion.insert(
            draftId: '$accountA:${samplePaper.paperId}',
            accountId: const Value(accountA),
            paperId: samplePaper.paperId,
            body: legacyDraft,
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
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

    expect(controller.state.draft, legacyDraft);
    expect(controller.state.draftInputIssue, commentRawInputTooLargeMessage);
    expect(await controller.send(), isNull);
    expect(remote.createCalls, 0);
  });
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
  int createCalls = 0;

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
    createCalls += 1;
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

String _repeat(String value, int count) => List.filled(count, value).join();

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
