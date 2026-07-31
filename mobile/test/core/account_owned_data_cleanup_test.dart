import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/feed_cache_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/models/paper.dart';

import '../support/fakes.dart';

void main() {
  test(
    'account cleanup removes private rows and preserves public feed cache',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final papers = PaperCacheDao(database);
      final feeds = FeedCacheDao(database, papers);
      final accounts = AccountCacheDao(database);
      final now = DateTime.utc(2026, 7, 31);
      final queryKey = feedQueryKey(category: 'cs.CL');

      await feeds.persistPage(
        queryKey: queryKey,
        page: FeedPage(items: [samplePaper]),
        replace: true,
        category: 'cs.CL',
        etag: '"feed-public"',
        refreshedAt: now,
      );
      await database.putMetadata('feed:public-marker', {'kept': true});
      await accounts.upsertLibraryItem(
        accountId: 'account-a',
        paperId: samplePaper.paperId,
        listState: 'to_read',
        clientUpdatedAt: now,
      );
      await accounts.upsertLibraryItem(
        accountId: 'account-b',
        paperId: samplePaper.paperId,
        listState: 'to_read',
        clientUpdatedAt: now,
      );
      await accounts.saveCommentDraft(
        draftId: 'draft-a',
        accountId: 'account-a',
        paperId: samplePaper.paperId,
        body: 'private draft',
        createdAt: now,
        updatedAt: now,
      );
      await accounts.saveCommentDraft(
        draftId: 'draft-pending-auth',
        paperId: samplePaper.paperId,
        body: 'pending private draft',
        createdAt: now,
        updatedAt: now,
      );
      await accounts.saveCommentDraft(
        draftId: 'draft-b',
        accountId: 'account-b',
        paperId: samplePaper.paperId,
        body: 'other account draft',
        createdAt: now,
        updatedAt: now,
      );
      await accounts.enqueue(
        operationId: 'operation-a',
        accountId: 'account-a',
        entityKind: 'library_item',
        entityId: samplePaper.paperId,
        operation: 'save',
        payload: const {'state': 'to_read'},
        createdAt: now,
      );
      await accounts.enqueue(
        operationId: 'operation-pending-auth',
        entityKind: 'comment',
        entityId: samplePaper.paperId,
        operation: 'create',
        payload: const {'body': 'pending private draft'},
        createdAt: now,
      );
      await accounts.enqueue(
        operationId: 'operation-b',
        accountId: 'account-b',
        entityKind: 'library_item',
        entityId: samplePaper.paperId,
        operation: 'save',
        payload: const {'state': 'to_read'},
        createdAt: now,
      );

      await accounts.clearAccountData('account-a');

      expect(
        (await database.select(database.libraryItems).get()).map(
          (row) => row.accountId,
        ),
        ['account-b'],
      );
      expect(
        (await database.select(database.commentDrafts).get()).map(
          (row) => row.draftId,
        ),
        ['draft-b'],
      );
      expect(
        (await database.select(database.syncOutbox).get()).map(
          (row) => row.operationId,
        ),
        ['operation-b'],
      );
      expect(await feeds.loadPage(queryKey), isNotNull);
      expect(await database.readMetadata('feed:public-marker'), {'kept': true});
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isTrue,
      );

      await accounts.clearAllAccountData();

      expect(await database.select(database.libraryItems).get(), isEmpty);
      expect(await database.select(database.commentDrafts).get(), isEmpty);
      expect(await database.select(database.syncOutbox).get(), isEmpty);
      expect(await feeds.loadPage(queryKey), isNotNull);
      expect(await database.select(database.cachedPapers).get(), hasLength(1));
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isFalse,
      );
    },
  );
}
