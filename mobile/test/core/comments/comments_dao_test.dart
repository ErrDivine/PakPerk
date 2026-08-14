import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';

import '../../support/fakes.dart';

void main() {
  const accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const blockedId = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
  const requestOne = '018f47a6-4b56-7f4c-8c7a-e2656e820011';
  const requestTwo = '018f47a6-4b56-7f4c-8c7a-e2656e820012';

  test(
    'explicit send rotates only for a different canonical attempted body',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await PaperCacheDao(database).save(samplePaper);
      final dao = CommentsDao(database);

      await dao.saveDraft(
        accountId: accountId,
        paperId: samplePaper.paperId,
        body: 'first body',
        clientRequestId: requestOne,
      );
      await dao.saveDraft(
        accountId: accountId,
        paperId: samplePaper.paperId,
        body: 'edited before send',
        clientRequestId: requestTwo,
      );
      expect(
        (await dao.loadDraft(accountId, samplePaper.paperId))?.clientRequestId,
        requestOne,
      );

      final firstAttempt = await dao.prepareDraftAttempt(
        accountId: accountId,
        paperId: samplePaper.paperId,
        canonicalBody: 'edited before send',
        nextClientRequestId: requestTwo,
      );
      expect(firstAttempt.clientRequestId, requestOne);
      expect(firstAttempt.lastAttemptedBody, 'edited before send');
      await dao.saveDraft(
        accountId: accountId,
        paperId: samplePaper.paperId,
        body: '  edited before send\r\n ',
        clientRequestId: requestTwo,
      );
      final equivalentAttempt = await dao.prepareDraftAttempt(
        accountId: accountId,
        paperId: samplePaper.paperId,
        canonicalBody: 'edited before send',
        nextClientRequestId: requestTwo,
      );
      expect(equivalentAttempt.clientRequestId, requestOne);
      expect(equivalentAttempt.lastAttemptedBody, 'edited before send');

      await dao.saveDraft(
        accountId: accountId,
        paperId: samplePaper.paperId,
        body: 'new explicit intent',
        clientRequestId: requestTwo,
      );
      final beforeExplicitSend = await dao.loadDraft(
        accountId,
        samplePaper.paperId,
      );
      expect(beforeExplicitSend?.clientRequestId, requestOne);
      expect(beforeExplicitSend?.lastAttemptedBody, 'edited before send');
      final rotated = await dao.prepareDraftAttempt(
        accountId: accountId,
        paperId: samplePaper.paperId,
        canonicalBody: 'new explicit intent',
        nextClientRequestId: requestTwo,
      );
      expect(rotated.clientRequestId, requestTwo);
      expect(rotated.lastAttemptedBody, 'new explicit intent');

      await expectLater(
        dao.saveDraft(
          accountId: accountId,
          paperId: samplePaper.paperId,
          body: 'x' * (commentMaximumRawCodeUnits + 1),
          clientRequestId: requestTwo,
        ),
        throwsArgumentError,
      );
      await expectLater(
        dao.prepareDraftAttempt(
          accountId: accountId,
          paperId: samplePaper.paperId,
          canonicalBody: String.fromCharCode(0xd800),
          nextClientRequestId: requestTwo,
        ),
        throwsArgumentError,
      );
    },
  );

  test('comment cache is bounded per paper and viewer', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await PaperCacheDao(database).save(samplePaper);
    final cache = CommentCacheDao(database);
    final now = DateTime.utc(2026, 8, 1);
    for (var index = 0; index < 4; index += 1) {
      await cache.saveBounded(
        CachedCommentPageValue(
          pageKey: 'comments:v5:$accountId:${samplePaper.paperId}:$index',
          paperId: samplePaper.paperId,
          viewerAccountId: accountId,
          cursor: 'cursor-$index',
          payload: const {'items': [], 'next_cursor': null},
          fetchedAt: now.add(Duration(minutes: index)),
          expiresAt: now.add(const Duration(hours: 1)),
        ),
      );
    }
    await cache.saveBounded(
      CachedCommentPageValue(
        pageKey: 'comments:v5:guest:${samplePaper.paperId}:first',
        paperId: samplePaper.paperId,
        payload: const {'items': [], 'next_cursor': null},
        fetchedAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
      ),
    );

    final rows = await database.select(database.cachedCommentPages).get();
    expect(rows.where((row) => row.viewerAccountId == accountId), hasLength(3));
    expect(rows.where((row) => row.viewerAccountId == null), hasLength(1));
    expect(rows.any((row) => row.pageKey.endsWith(':0')), isFalse);
  });

  test('local block is immediately durable and remains unconfirmed', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final dao = CommentsDao(database);

    await dao.blockLocally(
      accountId: accountId,
      blockedUserId: blockedId,
      handle: 'blocked_reader',
    );

    expect(await dao.blockedUserIds(accountId), {blockedId});
    final pending = await dao.pendingBlocks(accountId);
    expect(pending, hasLength(1));
    expect(pending.single.serverConfirmed, isFalse);
  });
}
