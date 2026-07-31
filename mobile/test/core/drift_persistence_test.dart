import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/application_bootstrap.dart';
import 'package:pakperk/core/cache/drift_local_store.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/cache/restoration_persistence.dart';
import 'package:pakperk/core/cache/versioned_derived_cache.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/legacy_preferences_importer.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('schema contains production tables and no credential columns', () async {
    final database = _memoryDatabase();
    addTearDown(database.close);

    final rows = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final names = rows.map((row) => row.read<String>('name')).toSet();
    expect(
      names,
      containsAll(const {
        'cached_papers',
        'feed_queries',
        'feed_entries',
        'cached_processing',
        'cached_introductions',
        'cached_connections',
        'cached_comment_pages',
        'cached_chats',
        'library_items',
        'comment_drafts',
        'blocked_users',
        'sync_outbox',
        'cache_metadata',
      }),
    );

    for (final table in names.where((name) => !name.startsWith('sqlite_'))) {
      final columns = await database
          .customSelect('PRAGMA table_info($table)')
          .get();
      final names = columns
          .map((row) => row.read<String>('name').toLowerCase())
          .toList();
      expect(
        names.where(
          (name) =>
              name.contains('access_token') ||
              name.contains('refresh_token') ||
              name.contains('authorization_code') ||
              name.contains('client_secret'),
        ),
        isEmpty,
        reason: '$table must never persist authentication credentials',
      );
    }
  });

  test(
    'complete v1 migration preserves durable data and drops unbound derived',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      raw.execute(_schemaV1);
      final paperJson = jsonEncode(samplePaper.toJson());
      final queryKey = feedQueryKey(category: 'cs.CL');
      raw.execute(
        'INSERT INTO cached_papers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          samplePaper.paperId,
          samplePaper.arxivBaseId.toLowerCase(),
          7,
          paperJson,
          1,
          2,
          3,
          4,
          1,
        ],
      );
      raw.execute('INSERT INTO feed_queries VALUES (?, ?, ?, ?, ?)', [
        queryKey,
        'cs.CL',
        'opaque-cursor',
        5,
        0,
      ]);
      raw.execute('INSERT INTO feed_entries VALUES (?, ?, ?, ?)', [
        queryKey,
        0,
        samplePaper.paperId,
        6,
      ]);
      raw.execute('INSERT INTO cached_processing VALUES (?, ?, ?, ?, ?)', [
        samplePaper.paperId,
        samplePaper.arxivId,
        jsonEncode(sampleProcessing.toJson()),
        7,
        null,
      ]);
      raw.execute(
        'INSERT INTO cached_introductions VALUES (?, ?, ?, ?, ?, ?)',
        [
          samplePaper.paperId,
          samplePaper.arxivId,
          1,
          jsonEncode(sampleIntroduction.toJson()),
          8,
          null,
        ],
      );
      raw.execute('INSERT INTO cached_connections VALUES (?, ?, ?, ?, ?)', [
        samplePaper.paperId,
        samplePaper.arxivId,
        jsonEncode(sampleConnections.toJson()),
        9,
        null,
      ]);
      raw.execute(
        'INSERT INTO cached_comment_pages VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'comments:first',
          samplePaper.paperId,
          null,
          '{"items":[]}',
          10,
          11,
          '"comments-v1"',
        ],
      );
      raw.execute('INSERT INTO library_items VALUES (?, ?, ?, ?, ?, ?)', [
        'account-1',
        samplePaper.paperId,
        'to_read',
        12,
        null,
        0,
      ]);
      raw.execute('INSERT INTO comment_drafts VALUES (?, ?, ?, ?, ?, ?, ?)', [
        'draft-1',
        'account-1',
        samplePaper.paperId,
        null,
        'draft',
        13,
        14,
      ]);
      raw.execute(
        'INSERT INTO sync_outbox VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'operation-1',
          'account-1',
          'library_item',
          samplePaper.paperId,
          'save',
          '{"state":"to_read"}',
          15,
          0,
          null,
          null,
        ],
      );
      raw.execute('INSERT INTO cache_metadata VALUES (?, ?, ?)', [
        'fixture',
        '{"version":1}',
        16,
      ]);
      raw.execute('PRAGMA user_version = 1');
      final database = PakPerkDatabase(NativeDatabase.opened(raw));
      addTearDown(database.close);

      final feedColumns = await database
          .customSelect('PRAGMA table_info(feed_queries)')
          .get();
      expect(
        feedColumns.map((row) => row.read<String>('name')),
        containsAll(const ['etag', 'entry_count']),
      );
      final query = await database.select(database.feedQueries).getSingle();
      expect(query.queryKey, queryKey);
      expect(query.nextCursor, 'opaque-cursor');
      expect(query.etag, isNull);
      expect(query.entryCount, 1);
      expect(
        (await database.select(database.cachedPapers).getSingle()).metadataJson,
        paperJson,
      );
      expect(await database.select(database.feedEntries).get(), hasLength(1));
      expect(await database.select(database.cachedProcessing).get(), isEmpty);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
      expect(
        await database.select(database.cachedCommentPages).get(),
        hasLength(1),
      );
      expect(await database.select(database.libraryItems).get(), hasLength(1));
      expect(await database.select(database.commentDrafts).get(), hasLength(1));
      expect(await database.select(database.syncOutbox).get(), hasLength(1));
      expect(await database.select(database.cacheMetadata).get(), hasLength(1));
      expect(await database.select(database.cachedChats).get(), isEmpty);
      await database
          .into(database.cachedChats)
          .insert(
            CachedChatsCompanion.insert(
              sessionId: 'anonymous-session',
              readerKey: 'feed:migrated',
              paperId: Value(samplePaper.paperId),
              versionKey: Value(samplePaper.arxivId),
              generation: const Value(1),
              payloadJson: '{"generation":1}',
              updatedAt: DateTime.utc(2026, 7, 31),
              expiresAt: DateTime.utc(2026, 8, 7),
            ),
          );
      expect(await database.select(database.cachedChats).get(), hasLength(1));
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      expect(
        (await database.customSelect('PRAGMA integrity_check').getSingle())
            .data
            .values
            .single,
        'ok',
      );
    },
  );

  test(
    'complete v2 migration backfills completeness and rebuilds chat scope',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      raw.execute(_schemaV2);
      final paperJson = jsonEncode(samplePaper.toJson());
      final queryKey = feedQueryKey(category: 'cs.CL');
      raw.execute(
        'INSERT INTO cached_papers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          samplePaper.paperId,
          samplePaper.arxivBaseId.toLowerCase(),
          7,
          paperJson,
          1,
          2,
          3,
          4,
          1,
        ],
      );
      raw.execute('INSERT INTO feed_queries VALUES (?, ?, ?, ?, ?, ?)', [
        queryKey,
        'cs.CL',
        'cursor-v2',
        5,
        0,
        '"v2-etag"',
      ]);
      raw.execute('INSERT INTO feed_entries VALUES (?, ?, ?, ?)', [
        queryKey,
        0,
        samplePaper.paperId,
        6,
      ]);
      raw.execute('INSERT INTO cached_processing VALUES (?, ?, ?, ?, ?)', [
        samplePaper.paperId,
        samplePaper.arxivId,
        '{}',
        7,
        null,
      ]);
      raw.execute(
        'INSERT INTO cached_introductions VALUES (?, ?, ?, ?, ?, ?)',
        [samplePaper.paperId, samplePaper.arxivId, 1, '{}', 8, null],
      );
      raw.execute('INSERT INTO cached_connections VALUES (?, ?, ?, ?, ?)', [
        samplePaper.paperId,
        samplePaper.arxivId,
        '{}',
        9,
        null,
      ]);
      raw.execute(
        'INSERT INTO cached_comment_pages VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['comments:v2', samplePaper.paperId, null, '{}', 10, 11, null],
      );
      raw.execute('INSERT INTO cached_chats VALUES (?, ?, ?)', [
        'feed:v2',
        '{}',
        12,
      ]);
      raw.execute('INSERT INTO library_items VALUES (?, ?, ?, ?, ?, ?)', [
        'account-v2',
        samplePaper.paperId,
        'to_read',
        13,
        null,
        0,
      ]);
      raw.execute('INSERT INTO comment_drafts VALUES (?, ?, ?, ?, ?, ?, ?)', [
        'draft-v2',
        null,
        samplePaper.paperId,
        null,
        'draft',
        14,
        15,
      ]);
      raw.execute(
        'INSERT INTO sync_outbox VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          'operation-v2',
          null,
          'paper',
          samplePaper.paperId,
          'save',
          '{}',
          16,
          0,
          null,
          null,
        ],
      );
      raw.execute('INSERT INTO cache_metadata VALUES (?, ?, ?)', [
        'v2-fixture',
        'true',
        17,
      ]);
      raw.execute('PRAGMA user_version = 2');
      final database = PakPerkDatabase(NativeDatabase.opened(raw));
      addTearDown(database.close);

      final query = await database.select(database.feedQueries).getSingle();
      expect(query.entryCount, 1);
      expect(query.etag, '"v2-etag"');
      expect(await database.select(database.cachedPapers).get(), hasLength(1));
      expect(await database.select(database.feedEntries).get(), hasLength(1));
      expect(await database.select(database.cachedProcessing).get(), isEmpty);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
      expect(await database.select(database.cachedChats).get(), isEmpty);
      expect(
        await database.select(database.cachedCommentPages).get(),
        hasLength(1),
      );
      expect(await database.select(database.libraryItems).get(), hasLength(1));
      expect(
        await database.select(database.commentDrafts).get(),
        isEmpty,
        reason: 'unbound pre-comments drafts fail closed in v5',
      );
      expect(await database.select(database.syncOutbox).get(), hasLength(1));
      expect(await database.select(database.cacheMetadata).get(), hasLength(1));
      final chatColumns = await database
          .customSelect('PRAGMA table_info(cached_chats)')
          .get();
      expect(
        chatColumns.map((row) => row.read<String>('name')),
        containsAll(const [
          'session_id',
          'paper_id',
          'version_key',
          'generation',
          'expires_at',
        ]),
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      expect(
        (await database.customSelect('PRAGMA integrity_check').getSingle())
            .data
            .values
            .single,
        'ok',
      );
    },
  );

  test(
    'legacy import is transactional, verified, and keeps only small prefs',
    () async {
      final chat = ChatSnapshot(
        threadId: 'thread-1',
        messages: [
          ChatMessage(
            id: 'message-1',
            role: ChatRole.assistant,
            content: 'Cached answer',
            createdAt: DateTime.utc(2026, 7, 30),
          ),
        ],
      );
      final paperKey = _legacyKey('paper', samplePaper.paperId);
      final processingKey = _legacyKey('processing', samplePaper.paperId);
      final introductionKey = _legacyKey('introduction', samplePaper.paperId);
      final connectionsKey = _legacyKey('connections', samplePaper.paperId);
      const readerKey = 'feed:legacy-reader';
      final chatKey = _legacyKey('chat', readerKey);
      const corruptKey = 'pakperk.paper.v1.not-valid-base64';
      SharedPreferences.setMockInitialValues({
        'pakperk.session.v1': 'preserved-session',
        'pakperk.restoration.v2': jsonEncode(
          const AppRestorationState(feedIndex: 4).toJson(),
        ),
        LegacySharedPreferencesImporter.feedKey: jsonEncode(
          FeedPage(items: [samplePaper]).toJson(),
        ),
        paperKey: jsonEncode(samplePaper.toJson()),
        processingKey: jsonEncode(sampleProcessing.toJson()),
        introductionKey: jsonEncode(sampleIntroduction.toJson()),
        connectionsKey: jsonEncode(sampleConnections.toJson()),
        chatKey: jsonEncode(chat.toJson()),
        corruptKey: '{broken',
      });
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
      );
      addTearDown(store.close);

      final stats = await store.startLegacyImportWork();

      expect(stats.failed, isFalse);
      expect(stats.feedRows, 1);
      expect(stats.paperRows, 1);
      expect(stats.processingRows, 0);
      expect(stats.introductionRows, 0);
      expect(stats.connectionRows, 0);
      expect(stats.chatRows, 0);
      expect(stats.invalidRows, 5);
      expect(
        (await store.loadFeed())?.items.single.paperId,
        samplePaper.paperId,
      );
      expect(await store.loadProcessing(samplePaper.paperId), isNull);
      expect(await store.loadIntroduction(samplePaper.paperId), isNull);
      expect(await store.loadConnections(samplePaper.paperId), isNull);
      expect(await store.loadChat(readerKey), isNull);
      expect(preferences.getString('pakperk.session.v1'), 'preserved-session');
      expect(preferences.containsKey('pakperk.restoration.v2'), isTrue);
      for (final key in [
        LegacySharedPreferencesImporter.feedKey,
        paperKey,
        processingKey,
        introductionKey,
        connectionsKey,
        chatKey,
        corruptKey,
      ]) {
        expect(preferences.containsKey(key), isFalse, reason: key);
      }
      expect(
        await database.readMetadata(legacyPreferencesImportMarker),
        isTrue,
      );
    },
  );

  test(
    'failed legacy transaction neither throws nor removes source data',
    () async {
      SharedPreferences.setMockInitialValues({
        LegacySharedPreferencesImporter.feedKey: jsonEncode(
          FeedPage(items: [samplePaper]).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final importer = LegacySharedPreferencesImporter(
        preferences: preferences,
        database: database,
        fulltextPolicy: ClientFulltextPolicy.prototype,
        beforeMarkComplete: () async => throw StateError('injected failure'),
      );
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
        legacyImporter: importer,
      );
      addTearDown(store.close);

      final stats = await store.startLegacyImportWork();

      expect(stats.failed, isTrue);
      expect(await store.loadFeed(), isNull);
      expect(
        preferences.containsKey(LegacySharedPreferencesImporter.feedKey),
        isTrue,
      );
      expect(
        await database.readMetadata(legacyPreferencesImportMarker),
        isNull,
      );
    },
  );

  test('legacy import aborts a stable-id arXiv identity conflict', () async {
    final conflicting = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['arxiv_id'] = '2607.99999v20'
        ..['updated_at'] = DateTime.utc(2030).toIso8601String(),
    );
    final paperKey = _legacyKey('paper', samplePaper.paperId);
    SharedPreferences.setMockInitialValues({
      LegacySharedPreferencesImporter.feedKey: jsonEncode(
        FeedPage(items: [samplePaper]).toJson(),
      ),
      paperKey: jsonEncode(conflicting.toJson()),
    });
    final preferences = await SharedPreferences.getInstance();
    final database = _memoryDatabase();
    final store = DriftLocalStore(preferences: preferences, database: database);
    addTearDown(store.close);

    final stats = await store.startLegacyImportWork();

    expect(stats.failed, isTrue);
    expect(await database.select(database.cachedPapers).get(), isEmpty);
    expect(await database.readMetadata(legacyPreferencesImportMarker), isNull);
    expect(
      preferences.containsKey(LegacySharedPreferencesImporter.feedKey),
      isTrue,
    );
    expect(preferences.containsKey(paperKey), isTrue);
  });

  test(
    'startup imports a valid offline feed before choosing bundled content',
    () async {
      final staleFeedPaper = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['arxiv_id'] = '${samplePaper.arxivBaseId}v6'
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String(),
      );
      SharedPreferences.setMockInitialValues({
        LegacySharedPreferencesImporter.feedKey: jsonEncode(
          FeedPage(items: [staleFeedPaper]).toJson(),
        ),
        _legacyKey('paper', samplePaper.paperId): jsonEncode(
          samplePaper.toJson(),
        ),
      });
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      var bundledLoads = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: () async {
          bundledLoads += 1;
          return const FeedPage(items: []);
        },
      );

      await bootstrapper.hydrateLocalState();

      expect(bootstrapper.data?.preloadedFeed.origin, DataOrigin.deviceCache);
      expect(
        bootstrapper.data?.preloadedFeed.page.items.single.paperId,
        samplePaper.paperId,
      );
      expect(
        bootstrapper.data?.preloadedFeed.page.items.single.arxivId,
        samplePaper.arxivId,
        reason: 'a later timestamp cannot regress the highest arXiv version',
      );
      expect(bundledLoads, 0);
    },
  );

  test(
    'strict migration masks metadata and purges all derived bulk records',
    () async {
      final prepared = _withCapabilities(samplePaper);
      const readerKey = 'feed:strict-reader';
      SharedPreferences.setMockInitialValues({
        LegacySharedPreferencesImporter.feedKey: jsonEncode(
          FeedPage(items: [prepared]).toJson(),
        ),
        _legacyKey('paper', prepared.paperId): jsonEncode(prepared.toJson()),
        _legacyKey('processing', prepared.paperId): jsonEncode(
          sampleProcessing.toJson(),
        ),
        _legacyKey('introduction', prepared.paperId): jsonEncode(
          sampleIntroduction.toJson(),
        ),
        _legacyKey('connections', prepared.paperId): jsonEncode(
          sampleConnections.toJson(),
        ),
        _legacyKey('chat', readerKey): jsonEncode(
          const ChatSnapshot(threadId: 'prototype-thread').toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
        fulltextPolicy: ClientFulltextPolicy.strict,
      );
      addTearDown(store.close);

      final stats = await store.startLegacyImportWork();
      final paper = (await store.loadFeed())!.items.single;

      expect(stats.failed, isFalse);
      expect(stats.policyDiscardedRows, 3);
      expect(paper.capabilities.introduction, isFalse);
      expect(paper.capabilities.chat, isFalse);
      expect(paper.capabilities.connections, isFalse);
      expect(await store.loadIntroduction(prepared.paperId), isNull);
      expect(await store.loadConnections(prepared.paperId), isNull);
      expect(await store.loadChat(readerKey), isNull);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
      expect(await database.select(database.cachedChats).get(), isEmpty);
      expect(preferences.getKeys().where(_isLegacyBulkKey), isEmpty);
    },
  );

  test(
    'Drift restoration persists compact refs and hydrates full paper rows',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
      );
      addTearDown(store.close);
      final feedPaper = _paper(80);
      await store.persistFeedPage(
        queryKey: feedQueryKey(),
        page: FeedPage(items: [feedPaper]),
        replace: true,
      );

      await store.saveRestoration(
        AppRestorationState(
          activeBranchIndex: 1,
          feedIndex: 0,
          feedPaperId: feedPaper.paperId,
          feedArxivId: feedPaper.arxivId,
          routeStack: [
            PaperRouteEntry(routeId: 'restored-route', paper: samplePaper),
          ],
        ),
      );

      final raw = preferences.getString(compactRestorationPreferencesKey)!;
      expect(raw, isNot(contains(samplePaper.title)));
      expect(raw, isNot(contains(samplePaper.abstractText)));
      expect(raw, isNot(contains(samplePaper.authors.first)));
      expect(preferences.containsKey(legacyRestorationPreferencesKey), isFalse);
      expect(await store.loadPaper(samplePaper.paperId), isNotNull);
      final restored = await store.loadRestoration();
      expect(restored.activeBranchIndex, 1);
      expect(restored.feedPaperId, feedPaper.paperId);
      expect(restored.routeStack.single.routeId, 'restored-route');
      expect(restored.routeStack.single.paper.paperId, samplePaper.paperId);
    },
  );

  test(
    'legacy full restoration migrates through Drift before key removal',
    () async {
      SharedPreferences.setMockInitialValues({
        legacyRestorationPreferencesKey: jsonEncode(
          AppRestorationState(
            feedIndex: 4,
            routeStack: [
              PaperRouteEntry(routeId: 'legacy-route', paper: samplePaper),
            ],
          ).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
      );
      addTearDown(store.close);

      final restored = await store.loadRestoration();

      expect(restored.feedIndex, 4);
      expect(restored.routeStack.single.routeId, 'legacy-route');
      expect(await store.loadPaper(samplePaper.paperId), isNotNull);
      expect(preferences.containsKey(compactRestorationPreferencesKey), isTrue);
      expect(preferences.containsKey(legacyRestorationPreferencesKey), isFalse);
    },
  );

  test(
    'feed identity survives eviction and rebases its compacted index',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
        databaseByteMeasurer: () async =>
            1024 * (await database.select(database.cachedPapers).get()).length,
      );
      addTearDown(store.close);
      final papers = List.generate(6, (index) => _paper(index + 90));
      await store.persistFeedPage(
        queryKey: feedQueryKey(),
        page: FeedPage(items: papers),
        replace: true,
        refreshedAt: DateTime.utc(2026, 7, 1),
      );
      final current = papers[3];
      await store.saveRestoration(
        AppRestorationState(
          feedIndex: 3,
          feedPaperId: current.paperId,
          feedArxivId: current.arxivId,
        ),
      );

      await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: 2,
        maxDatabaseBytes: 1 << 30,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );

      final compactedFeed = await store.loadFeed();
      expect(compactedFeed, isNotNull);
      final rebasedIndex = compactedFeed!.items.indexWhere(
        (paper) => paper.paperId == current.paperId,
      );
      expect(rebasedIndex, isNonNegative);
      final restored = await store.loadRestoration();
      expect(restored.feedIndex, rebasedIndex);
      expect(restored.feedPaperId, current.paperId);
      expect(await store.loadPaper(current.paperId), isNotNull);
    },
  );

  test(
    'anonymous identity rotation clears Drift chat and restorable chat IDs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      await store.saveProcessing(sampleProcessing);
      final readerKey = feedReaderKey(samplePaper);
      await store.saveChat(
        readerKey,
        const ChatSnapshot(threadId: 'anonymous-thread', generation: 1),
      );
      await store.saveRestoration(
        AppRestorationState(
          readerStates: {
            readerKey: ReaderNavigationState(
              chatSheetOpen: true,
              chatThreadId: 'anonymous-thread',
            ),
          },
        ),
      );

      await store.rotateAnonymousSession();

      expect(await store.loadChat(readerKey), isNull);
      final restored = (await store.loadRestoration()).readerState(readerKey);
      expect(restored.chatSheetOpen, isFalse);
      expect(restored.chatThreadId, isNull);
    },
  );

  test(
    'anonymous rotation does not commit identity when chat clearing fails',
    () async {
      SharedPreferences.setMockInitialValues({
        'pakperk.session.v1': 'old-anonymous-session',
        'pakperk.restoration.v2': jsonEncode(
          const AppRestorationState(feedIndex: 3).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      await store.saveProcessing(sampleProcessing);
      await store.saveChat(
        feedReaderKey(samplePaper),
        const ChatSnapshot(threadId: 'old-chat', generation: 1),
      );
      await database.customStatement('''
      CREATE TRIGGER fail_chat_clear
      BEFORE DELETE ON cached_chats
      BEGIN
        SELECT RAISE(ABORT, 'injected chat clear failure');
      END
    ''');

      await expectLater(store.rotateAnonymousSession(), throwsA(anything));

      expect(
        preferences.getString('pakperk.session.v1'),
        'old-anonymous-session',
      );
      expect(
        AppRestorationState.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(preferences.getString('pakperk.restoration.v2')!) as Map,
          ),
        ).feedIndex,
        3,
      );
    },
  );

  test('chat cache is session scoped, expiring, and payload bounded', () async {
    SharedPreferences.setMockInitialValues({'pakperk.session.v1': 'session-a'});
    final preferences = await SharedPreferences.getInstance();
    final database = _memoryDatabase();
    final store = DriftLocalStore(preferences: preferences, database: database);
    addTearDown(store.close);
    await store.savePaper(samplePaper);
    await store.saveProcessing(sampleProcessing);
    final readerKey = feedReaderKey(samplePaper);
    await store.saveChat(
      readerKey,
      const ChatSnapshot(threadId: 'session-a-thread', generation: 1),
    );
    expect((await store.loadChat(readerKey))?.threadId, 'session-a-thread');

    await preferences.setString('pakperk.session.v1', 'session-b');
    expect(await store.loadChat(readerKey), isNull);
    expect(
      await database.select(database.cachedChats).get(),
      hasLength(1),
      reason: 'another anonymous identity cannot read or destroy this scope',
    );
    await preferences.setString('pakperk.session.v1', 'session-a');
    expect((await store.loadChat(readerKey))?.threadId, 'session-a-thread');

    await (database.update(database.cachedChats)
          ..where((row) => row.readerKey.equals(readerKey)))
        .write(CachedChatsCompanion(expiresAt: Value(DateTime.utc(2020))));
    expect(await store.loadChat(readerKey), isNull);
    expect(await database.select(database.cachedChats).get(), isEmpty);

    final oversized = List.filled(600 * 1024, 'x').join();
    await store.saveChat(
      readerKey,
      ChatSnapshot(
        generation: 1,
        messages: [
          ChatMessage(
            id: 'oversized',
            role: ChatRole.assistant,
            content: oversized,
            createdAt: DateTime.utc(2026, 7, 31),
          ),
        ],
      ),
    );
    expect(await database.select(database.cachedChats).get(), isEmpty);
  });

  test('chat byte eviction preserves the live restored conversation', () async {
    SharedPreferences.setMockInitialValues({});
    final database = _memoryDatabase();
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: database,
      databaseByteMeasurer: () async =>
          (await database.select(database.cachedChats).get()).fold<int>(
            0,
            (bytes, row) => bytes + utf8.encode(row.payloadJson).length,
          ),
    );
    addTearDown(store.close);
    await store.savePaper(samplePaper);
    await store.saveProcessing(sampleProcessing);
    final keys = [
      'route:first:${samplePaper.arxivId}',
      'route:protected:${samplePaper.arxivId}',
      'route:last:${samplePaper.arxivId}',
    ];
    final content = List.filled(180 * 1024, 'x').join();
    final generationCache = store as GenerationScopedChatCache;
    for (final (index, key) in keys.indexed) {
      await generationCache.saveChatForGeneration(
        key,
        ChatSnapshot(
          threadId: 'thread-$index',
          generation: 1,
          messages: [
            ChatMessage(
              id: 'message-$index',
              role: ChatRole.assistant,
              content: content,
              createdAt: DateTime.utc(2026, 7, 31, 0, index),
            ),
          ],
        ),
        expectedVersionKey: samplePaper.versionKey,
        expectedGeneration: 1,
      );
    }
    (store as LiveRestorationCacheProtection).updateLiveRestorationProtection(
      AppRestorationState(
        readerStates: {
          keys[1]: const ReaderNavigationState(chatThreadId: 'thread-1'),
        },
      ),
    );

    final result = await store.evictCache(
      activeQueryKey: feedQueryKey(),
      protectedPaperIds: const {},
      maxMetadataPapers: 500,
      maxDatabaseBytes: 250 * 1024,
      metadataTtl: const Duration(days: 7),
      now: DateTime.utc(2026, 7, 31),
    );

    expect(result.usageAfter.databaseBytes, lessThanOrEqualTo(250 * 1024));
    expect(
      (await database.select(database.cachedChats).get()).map(
        (row) => row.readerKey,
      ),
      [keys[1]],
    );
    expect(await store.loadPaper(samplePaper.paperId), isNotNull);
    expect(await store.loadProcessing(samplePaper.paperId), isNotNull);
  });

  test(
    'derived-dominated bytes evict non-expiring artifacts under pressure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      Future<int> derivedBytes() async {
        final processing = await database
            .select(database.cachedProcessing)
            .get();
        final introductions = await database
            .select(database.cachedIntroductions)
            .get();
        final connections = await database
            .select(database.cachedConnections)
            .get();
        final chats = await database.select(database.cachedChats).get();
        int payloadBytes(Iterable<String> payloads) => payloads.fold<int>(
          0,
          (bytes, payload) => bytes + utf8.encode(payload).length,
        );

        return payloadBytes(processing.map((row) => row.payloadJson)) +
            payloadBytes(introductions.map((row) => row.payloadJson)) +
            payloadBytes(connections.map((row) => row.payloadJson)) +
            payloadBytes(chats.map((row) => row.payloadJson));
      }

      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
        databaseByteMeasurer: derivedBytes,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      await store.saveProcessing(sampleProcessing);
      final largeText = List.filled(96 * 1024, 'd').join();
      await store.saveIntroduction(
        PaperIntroduction.fromJson(
          sampleIntroduction.toJson()
            ..['paragraphs'] = [
              {'ordinal': 0, 'text': largeText},
            ],
        ),
      );
      await store.saveConnections(
        PaperConnections.fromJson(
          sampleConnections.toJson()
            ..['key_connections'] = [
              {
                'reference_id': 'large-reference',
                'paper_id': 'reference-paper',
                'arxiv_id': '2607.90000v1',
                'title': 'Reference',
                'authors': const ['Researcher'],
                'year': 2026,
                'relation_type': 'builds_on',
                'summary': largeText,
              },
            ],
        ),
      );
      final readerKey = feedReaderKey(samplePaper);
      await store.saveChat(
        readerKey,
        const ChatSnapshot(threadId: 'live-thread', generation: 1),
      );
      (store as LiveRestorationCacheProtection).updateLiveRestorationProtection(
        AppRestorationState(
          readerStates: {
            readerKey: const ReaderNavigationState(chatThreadId: 'live-thread'),
          },
        ),
      );

      const maxBytes = 8 * 1024;
      final result = await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: 500,
        maxDatabaseBytes: maxBytes,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );

      expect(result.usageAfter.databaseBytes, lessThanOrEqualTo(maxBytes));
      expect(result.derivedRows, greaterThanOrEqualTo(2));
      expect(await store.loadPaper(samplePaper.paperId), isNotNull);
      expect(await store.loadProcessing(samplePaper.paperId), isNotNull);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
      expect(
        (await database.select(database.cachedChats).get()).single.readerKey,
        readerKey,
      );
    },
  );

  test(
    'feed pages and validators are query-exact and append preserves ETag',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      final first = _paper(1);
      final second = _paper(2);
      final allKey = feedQueryKey(limit: 30);
      final categoryKey = feedQueryKey(category: 'cs.CL', limit: 30);

      await store.persistFeedPage(
        queryKey: allKey,
        page: FeedPage(items: [first], nextCursor: 'cursor-1'),
        replace: true,
        etag: '"first-page"',
        refreshedAt: DateTime.utc(2026, 7, 30),
      );
      await store.persistFeedPage(
        queryKey: allKey,
        page: FeedPage(items: [second]),
        replace: false,
        refreshedAt: DateTime.utc(2026, 7, 31),
      );
      await store.persistFeedPage(
        queryKey: categoryKey,
        page: FeedPage(items: [second]),
        replace: true,
        category: 'cs.CL',
        etag: '"category"',
      );

      expect(
        (await store.loadFeedPage(allKey))!.items.map((paper) => paper.paperId),
        [first.paperId, second.paperId],
      );
      expect((await store.loadFeedValidator(allKey))?.etag, '"first-page"');
      expect(
        (await store.loadFeedPage(categoryKey))!.items.single.paperId,
        second.paperId,
      );
      expect((await store.loadFeedValidator(categoryKey))?.etag, '"category"');
    },
  );

  test('feed validators fail closed for gaps and corrupt metadata', () async {
    SharedPreferences.setMockInitialValues({});
    final database = _memoryDatabase();
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: database,
    );
    addTearDown(store.close);
    final emptyKey = feedQueryKey(category: 'empty');
    await store.persistFeedPage(
      queryKey: emptyKey,
      page: const FeedPage(items: []),
      replace: true,
      category: 'empty',
      etag: '"empty"',
    );
    expect((await store.loadFeedValidator(emptyKey))?.etag, '"empty"');
    expect((await store.loadFeedPage(emptyKey))?.items, isEmpty);

    final gapKey = feedQueryKey(category: 'gap');
    final gapPapers = [_paper(40), _paper(41), _paper(42)];
    await store.persistFeedPage(
      queryKey: gapKey,
      page: FeedPage(items: gapPapers),
      replace: true,
      category: 'gap',
      etag: '"gap"',
    );
    await database.customStatement(
      'UPDATE feed_entries SET position = 9 '
      'WHERE query_key = ? AND paper_id = ?',
      [gapKey, gapPapers[1].paperId],
    );
    expect((await store.loadFeedValidator(gapKey))?.etag, isNull);
    expect(await store.loadFeedPage(gapKey), isNull);

    final corruptKey = feedQueryKey(category: 'corrupt');
    final corruptPaper = _paper(43);
    await store.persistFeedPage(
      queryKey: corruptKey,
      page: FeedPage(items: [corruptPaper]),
      replace: true,
      category: 'corrupt',
      etag: '"corrupt"',
    );
    await database.customStatement(
      'UPDATE cached_papers SET metadata_json = ? WHERE paper_id = ?',
      ['{broken', corruptPaper.paperId],
    );
    expect((await store.loadFeedValidator(corruptKey))?.etag, isNull);
    expect(await store.loadFeedPage(corruptKey), isNull);
    await store.storeFeedValidator(
      corruptKey,
      etag: '"must-not-return"',
      refreshedAt: DateTime.utc(2026, 7, 31),
    );
    expect((await store.loadFeedValidator(corruptKey))?.etag, isNull);
  });

  test(
    'stale partial membership invalidates a recently touched ETag',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      final queryKey = feedQueryKey(category: 'partial');
      final oldPaper = _paper(44);
      final newPaper = _paper(45);
      final oldTime = DateTime.utc(2026, 7, 1);
      final now = DateTime.utc(2026, 7, 31);
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [oldPaper], nextCursor: 'next'),
        replace: true,
        category: 'partial',
        etag: '"complete"',
        refreshedAt: oldTime,
      );
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [newPaper]),
        replace: false,
        category: 'partial',
        refreshedAt: now,
      );
      await store.storeFeedValidator(
        queryKey,
        etag: '"recently-validated"',
        refreshedAt: now,
      );

      await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: {oldPaper.paperId, newPaper.paperId},
        maxMetadataPapers: 500,
        maxDatabaseBytes: 1 << 30,
        metadataTtl: const Duration(days: 7),
        now: now,
      );

      final query = await (database.select(
        database.feedQueries,
      )..where((row) => row.queryKey.equals(queryKey))).getSingle();
      expect(query.etag, isNull);
      expect(query.refreshedAt.millisecondsSinceEpoch, 0);
      expect(
        (await store.loadFeedPage(
          queryKey,
        ))?.items.map((paper) => paper.paperId),
        [newPaper.paperId],
      );
      final appended = _paper(46);
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [appended]),
        replace: false,
      );
      expect(
        (await store.loadFeedPage(
          queryKey,
        ))?.items.map((paper) => paper.paperId),
        [newPaper.paperId, appended.paperId],
      );
    },
  );

  test('base arXiv lookup prioritizes the highest cached version', () async {
    SharedPreferences.setMockInitialValues({});
    final database = _memoryDatabase();
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: database,
    );
    addTearDown(store.close);
    final newerVersion = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = 'newer-version-row'
        ..['arxiv_id'] = '${samplePaper.arxivBaseId}v9'
        ..['updated_at'] = DateTime.utc(2025).toIso8601String(),
    );
    final newerTimestamp = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = 'newer-timestamp-row'
        ..['arxiv_id'] = '${samplePaper.arxivBaseId}v8'
        ..['updated_at'] = DateTime.utc(2026).toIso8601String(),
    );
    await store.savePaper(newerVersion);
    await store.savePaper(newerTimestamp);

    expect(
      (await store.findPaperByArxiv(samplePaper.arxivBaseId))?.arxivId,
      endsWith('v9'),
    );
  });

  test(
    'paper metadata is monotonic by version, timestamp, and stable identity',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      final freshest = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['title'] = 'Fresh same-version metadata'
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String(),
      );
      await store.savePaper(freshest);
      await store.saveProcessing(sampleProcessing);
      final olderSameVersion = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['title'] = 'Stale same-version metadata'
          ..['updated_at'] = DateTime.utc(2025, 7, 31).toIso8601String(),
      );
      final remappedIdentity = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['arxiv_id'] = '2607.99999v99'
          ..['title'] = 'Different paper under a reused id'
          ..['updated_at'] = DateTime.utc(2030).toIso8601String(),
      );

      await store.savePaper(olderSameVersion);
      await store.savePaper(remappedIdentity);

      final retained = await store.loadPaper(samplePaper.paperId);
      expect(retained?.title, 'Fresh same-version metadata');
      expect(retained?.arxivId, samplePaper.arxivId);
      expect(await store.loadProcessing(samplePaper.paperId), isNotNull);
    },
  );

  test(
    'a stale feed body cannot bind its ETag to newer cached metadata',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      final newer = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['arxiv_id'] = '${samplePaper.arxivBaseId}v8'
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String(),
      );
      await store.savePaper(newer);
      final queryKey = feedQueryKey();

      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [samplePaper]),
        replace: true,
        etag: '"stale-body"',
      );

      expect(
        (await store.loadFeedPage(queryKey))?.items.single.arxivId,
        newer.arxivId,
      );
      expect((await store.loadFeedValidator(queryKey))?.etag, isNull);
    },
  );

  test('processing generations atomically scope every derived cache', () async {
    SharedPreferences.setMockInitialValues({});
    final database = _memoryDatabase();
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: database,
    );
    addTearDown(store.close);
    await store.savePaper(samplePaper);
    await store.saveProcessing(sampleProcessing);
    await store.saveIntroduction(sampleIntroduction);
    await store.saveConnections(sampleConnections);
    final readerKey = feedReaderKey(samplePaper);
    await store.saveChat(
      readerKey,
      const ChatSnapshot(threadId: 'generation-1', generation: 1),
    );
    expect(await database.select(database.cachedChats).get(), hasLength(1));

    final generation2 = PaperProcessingState.fromJson(
      sampleProcessing.toJson()
        ..['generation'] = 2
        ..['updated_at'] = DateTime.utc(2026, 7, 1).toIso8601String(),
    );
    expect(
      await (store as VersionedDerivedCache).saveProcessingForVersion(
        generation2,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isTrue,
    );
    expect((await store.loadProcessing(samplePaper.paperId))?.generation, 2);
    expect(await database.select(database.cachedIntroductions).get(), isEmpty);
    expect(await database.select(database.cachedConnections).get(), isEmpty);
    expect(await database.select(database.cachedChats).get(), isEmpty);

    final lateGeneration1 = PaperProcessingState.fromJson(
      sampleProcessing.toJson()
        ..['generation'] = 1
        ..['updated_at'] = DateTime.utc(2030).toIso8601String(),
    );
    expect(
      await (store as VersionedDerivedCache).saveProcessingForVersion(
        lateGeneration1,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isFalse,
    );
    final introduction2 = PaperIntroduction.fromJson(
      sampleIntroduction.toJson()..['generation'] = 2,
    );
    final connections2 = PaperConnections.fromJson(
      sampleConnections.toJson()..['generation'] = 2,
    );
    expect(
      await (store as VersionedDerivedCache).saveIntroductionForVersion(
        sampleIntroduction,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isFalse,
    );
    expect(
      await (store as VersionedDerivedCache).saveConnectionsForVersion(
        sampleConnections,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isFalse,
    );
    expect(
      await (store as VersionedDerivedCache).saveIntroductionForVersion(
        introduction2,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isTrue,
    );
    expect(
      await (store as VersionedDerivedCache).saveConnectionsForVersion(
        connections2,
        expectedVersionKey: samplePaper.versionKey,
      ),
      isTrue,
    );
    expect(
      await (store as GenerationScopedChatCache).saveChatForGeneration(
        readerKey,
        const ChatSnapshot(threadId: 'late-generation-1', generation: 1),
        expectedVersionKey: samplePaper.versionKey,
        expectedGeneration: 1,
      ),
      isFalse,
    );
    expect(
      await (store as GenerationScopedChatCache).saveChatForGeneration(
        readerKey,
        const ChatSnapshot(threadId: 'generation-2', generation: 2),
        expectedVersionKey: samplePaper.versionKey,
        expectedGeneration: 2,
      ),
      isTrue,
    );
    expect(
      await (store as GenerationScopedChatCache).saveChatForGeneration(
        'feed:00000000-0000-4000-8000-000000000999:${samplePaper.arxivId}',
        const ChatSnapshot(threadId: 'wrong-paper', generation: 2),
        expectedVersionKey: samplePaper.versionKey,
        expectedGeneration: 2,
      ),
      isFalse,
      reason: 'reader identity and explicit paper scope must agree',
    );
    expect((await store.loadChat(readerKey))?.threadId, 'generation-2');
  });

  test(
    'new metadata version invalidates derived rows in the feed transaction',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      await store.saveProcessing(sampleProcessing);
      await store.saveIntroduction(sampleIntroduction);
      await store.saveConnections(sampleConnections);
      final oldReaderKey = feedReaderKey(samplePaper);
      await store.saveChat(
        oldReaderKey,
        const ChatSnapshot(threadId: 'old-version-chat', generation: 1),
      );
      final newer = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['arxiv_id'] = '${samplePaper.arxivBaseId}v8'
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String(),
      );

      await store.persistFeedPage(
        queryKey: feedQueryKey(),
        page: FeedPage(items: [newer]),
        replace: true,
      );

      expect((await store.loadFeed())!.items.single.arxivId, endsWith('v8'));
      expect(await database.select(database.cachedProcessing).get(), isEmpty);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
      expect(await database.select(database.cachedChats).get(), isEmpty);
      expect(await store.loadChat(oldReaderKey), isNull);
      await store.saveChat(
        oldReaderKey,
        const ChatSnapshot(threadId: 'late-old-version-chat', generation: 1),
      );
      expect(
        await database.select(database.cachedChats).get(),
        isEmpty,
        reason: 'a late chat response cannot cross the arXiv version boundary',
      );
    },
  );

  test(
    'stale metadata cannot regress a newer version or clear its derived data',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      await store.saveProcessing(sampleProcessing);
      await store.saveIntroduction(sampleIntroduction);
      await store.saveConnections(sampleConnections);
      final stale = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['arxiv_id'] = '${samplePaper.arxivBaseId}v6'
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String(),
      );

      await store.savePaper(stale);

      expect(
        (await store.loadPaper(samplePaper.paperId))?.arxivId,
        endsWith('v7'),
      );
      expect(await store.loadProcessing(samplePaper.paperId), isNotNull);
      expect(await store.loadIntroduction(samplePaper.paperId), isNotNull);
      expect(await store.loadConnections(samplePaper.paperId), isNotNull);
    },
  );

  test(
    'late derived responses are rejected against the captured version',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      await store.savePaper(samplePaper);
      final requestedVersion = samplePaper.versionKey;
      final newer = PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '${samplePaper.arxivBaseId}v8',
      );
      await store.savePaper(newer);
      final versioned = store as VersionedDerivedCache;

      expect(
        await versioned.saveProcessingForVersion(
          sampleProcessing,
          expectedVersionKey: requestedVersion,
        ),
        isFalse,
      );
      expect(
        await versioned.saveIntroductionForVersion(
          sampleIntroduction,
          expectedVersionKey: requestedVersion,
        ),
        isFalse,
      );
      expect(
        await versioned.saveConnectionsForVersion(
          sampleConnections,
          expectedVersionKey: requestedVersion,
        ),
        isFalse,
      );
      expect(await database.select(database.cachedProcessing).get(), isEmpty);
      expect(
        await database.select(database.cachedIntroductions).get(),
        isEmpty,
      );
      expect(await database.select(database.cachedConnections).get(), isEmpty);
    },
  );

  test(
    'library pin projection and durable ownership protect eviction',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: preferences,
        database: database,
        databaseByteMeasurer: () async =>
            1024 * (await database.select(database.cachedPapers).get()).length,
      );
      addTearDown(store.close);
      final papers = List.generate(5, _paper);
      await store.persistFeedPage(
        queryKey: feedQueryKey(),
        page: FeedPage(items: papers),
        replace: true,
      );
      final accounts = AccountCacheDao(database);
      await accounts.upsertLibraryItem(
        accountId: 'account-1',
        paperId: papers[1].paperId,
        listState: 'to_read',
        clientUpdatedAt: DateTime.utc(2026, 7, 31),
      );
      await accounts.saveCommentDraft(
        draftId: 'draft-1',
        paperId: papers[2].paperId,
        body: 'Unsynced draft',
        createdAt: DateTime.utc(2026, 7, 31),
        updatedAt: DateTime.utc(2026, 7, 31),
      );
      await accounts.enqueue(
        operationId: 'operation-1',
        entityKind: 'paper',
        entityId: papers[3].paperId,
        operation: 'save',
        payload: const {'state': 'to_read'},
        createdAt: DateTime.utc(2026, 7, 31),
      );
      await accounts.upsertLibraryItem(
        accountId: 'account-1',
        paperId: papers[4].paperId,
        listState: 'to_read',
        clientUpdatedAt: DateTime.utc(2026, 7, 31),
        deleted: true,
      );
      await store.saveRestoration(
        AppRestorationState(
          routeStack: [PaperRouteEntry(routeId: 'restored', paper: papers[0])],
        ),
      );
      for (final paper in papers.take(4)) {
        await store.saveProcessing(
          PaperProcessingState.fromJson(
            sampleProcessing.toJson()..['paper_id'] = paper.paperId,
          ),
        );
      }

      final result = await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: 0,
        maxDatabaseBytes: 0,
        now: DateTime.utc(2026, 8, 1),
      );

      expect(result.unpinnedPapers, 1);
      expect(await store.cachedPaperIds(papers.map((paper) => paper.paperId)), {
        papers[0].paperId,
        papers[1].paperId,
        papers[2].paperId,
        papers[3].paperId,
      });
      final pinned = await (database.select(
        database.cachedPapers,
      )..where((table) => table.paperId.equals(papers[1].paperId))).getSingle();
      expect(pinned.pinnedByLibrary, isTrue);
      expect(
        await (database.select(
          database.libraryItems,
        )..where((table) => table.paperId.equals(papers[4].paperId))).get(),
        hasLength(1),
        reason: 'account tombstones survive public metadata eviction',
      );
      expect(
        (await database.select(database.cachedProcessing).get())
            .map((row) => row.paperId)
            .toSet(),
        papers.take(4).map((paper) => paper.paperId).toSet(),
        reason: 'every durable paper owner protects its derived generation',
      );
    },
  );

  test(
    'live restoration protects a route before its debounce is persisted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
        databaseByteMeasurer: () async =>
            1024 * (await database.select(database.cachedPapers).get()).length,
      );
      addTearDown(store.close);
      final protected = _paper(18);
      final disposable = _paper(19);
      await store.savePaper(protected);
      await store.savePaper(disposable);
      (store as LiveRestorationCacheProtection).updateLiveRestorationProtection(
        AppRestorationState(
          routeStack: [
            PaperRouteEntry(routeId: 'just-opened', paper: protected),
          ],
        ),
      );

      await store.evictCache(
        activeQueryKey: feedQueryKey(category: 'not-loaded'),
        protectedPaperIds: const {},
        maxMetadataPapers: 0,
        maxDatabaseBytes: 0,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );

      expect(
        await store.cachedPaperIds([protected.paperId, disposable.paperId]),
        {protected.paperId},
      );
      expect(
        (await store.loadRestoration()).routeStack,
        isEmpty,
        reason: 'the protection came from live state, not persisted prefs',
      );
    },
  );

  test('non-active feed membership is retained until it is stale', () async {
    SharedPreferences.setMockInitialValues({});
    final database = _memoryDatabase();
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: database,
    );
    addTearDown(store.close);
    final activePaper = _paper(20);
    final categoryPaper = _paper(21);
    final activeKey = feedQueryKey();
    final categoryKey = feedQueryKey(category: 'cs.CL');
    final insertedAt = DateTime.utc(2026, 7, 1);
    await store.persistFeedPage(
      queryKey: activeKey,
      page: FeedPage(items: [activePaper]),
      replace: true,
      refreshedAt: insertedAt,
    );
    await store.persistFeedPage(
      queryKey: categoryKey,
      page: FeedPage(items: [categoryPaper]),
      replace: true,
      category: 'cs.CL',
      refreshedAt: insertedAt,
    );

    final fresh = await store.evictCache(
      activeQueryKey: activeKey,
      protectedPaperIds: {activePaper.paperId, categoryPaper.paperId},
      maxMetadataPapers: 500,
      maxDatabaseBytes: 1 << 30,
      metadataTtl: const Duration(days: 7),
      now: insertedAt.add(const Duration(days: 6)),
    );
    expect(fresh.oldFeedEntries, 0);
    expect((await store.loadFeedPage(categoryKey))?.items, isNotEmpty);

    final stale = await store.evictCache(
      activeQueryKey: activeKey,
      protectedPaperIds: {activePaper.paperId, categoryPaper.paperId},
      maxMetadataPapers: 500,
      maxDatabaseBytes: 1 << 30,
      metadataTtl: const Duration(days: 7),
      now: insertedAt.add(const Duration(days: 8)),
    );
    expect(stale.oldFeedEntries, 1);
    expect(await store.loadFeedPage(categoryKey), isNull);
    expect(await store.loadFeedValidator(categoryKey), isNull);
  });

  test(
    'metadata eviction invalidates every affected query validator',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(store.close);
      final papers = [_paper(30), _paper(31), _paper(32)];
      final queryKey = feedQueryKey();
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: papers),
        replace: true,
        etag: '"complete-page"',
        refreshedAt: DateTime.utc(2026, 7, 31),
      );
      await store.recordPaperAccess(
        papers[1].paperId,
        accessedAt: DateTime.utc(2026, 8, 1),
      );
      await store.recordPaperAccess(
        papers[2].paperId,
        accessedAt: DateTime.utc(2026, 8, 1),
      );
      await store.saveRestoration(const AppRestorationState(feedIndex: 1));

      await store.evictCache(
        activeQueryKey: queryKey,
        protectedPaperIds: {papers[1].paperId, papers[2].paperId},
        maxMetadataPapers: 2,
        maxDatabaseBytes: 1 << 30,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );

      final validator = await store.loadFeedValidator(queryKey);
      expect(validator?.etag, isNull);
      expect(validator?.refreshedAt.millisecondsSinceEpoch, 0);
      expect(
        (await store.loadFeedPage(
          queryKey,
        ))?.items.map((paper) => paper.paperId),
        [papers[1].paperId, papers[2].paperId],
      );
      final appended = _paper(33);
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [appended]),
        replace: false,
      );
      expect(
        (await store.loadFeedPage(
          queryKey,
        ))?.items.map((paper) => paper.paperId),
        [papers[1].paperId, papers[2].paperId, appended.paperId],
      );
    },
  );

  test(
    'evicting a category representation does not cache a false empty',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
        databaseByteMeasurer: () async =>
            1024 * (await database.select(database.cachedPapers).get()).length,
      );
      addTearDown(store.close);
      final queryKey = feedQueryKey(category: 'cs.AI');
      await store.persistFeedPage(
        queryKey: queryKey,
        page: FeedPage(items: [_paper(34)], nextCursor: 'category-next'),
        replace: true,
        category: 'cs.AI',
        etag: '"category-one"',
      );

      await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: 0,
        maxDatabaseBytes: 0,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );

      expect(await store.loadFeedPage(queryKey), isNull);
      expect(await store.loadFeedValidator(queryKey), isNull);
      expect(
        await (database.select(
          database.feedQueries,
        )..where((query) => query.queryKey.equals(queryKey))).get(),
        isEmpty,
      );
    },
  );

  test('eviction independently enforces row and live-byte bounds', () async {
    Future<void> exercise({required int maxRows, required int maxBytes}) async {
      SharedPreferences.setMockInitialValues({});
      final database = _memoryDatabase();
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
        databaseByteMeasurer: () async =>
            1024 * (await database.select(database.cachedPapers).get()).length,
      );
      await store.persistFeedPage(
        queryKey: feedQueryKey(),
        page: FeedPage(items: List.generate(6, _paper)),
        replace: true,
      );
      final result = await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: maxRows,
        maxDatabaseBytes: maxBytes,
        metadataTtl: const Duration(days: 365),
        now: DateTime.utc(2026, 7, 31),
      );
      expect(result.usageAfter.metadataRows, lessThanOrEqualTo(maxRows));
      expect(result.usageAfter.databaseBytes, lessThanOrEqualTo(maxBytes));
      expect(
        result.usageAfter.physicalDatabaseBytes,
        greaterThanOrEqualTo(result.usageAfter.databaseBytes),
      );
      await store.close();
    }

    await exercise(maxRows: 2, maxBytes: 1 << 30);
    await exercise(maxRows: 500, maxBytes: 2 * 1024);
  });

  test(
    '64 MiB physical bound is reclaimed only by lifecycle-safe compaction',
    () async {
      const maxBytes = 64 * 1024 * 1024;
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'pakperk-drift-compaction-',
      );
      final file = File('${directory.path}/pakperk_content.sqlite');
      final database = PakPerkDatabase.atPath(NativeDatabase(file), file.path);
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      addTearDown(() async {
        await store.close();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      await database.customSelect('PRAGMA journal_mode = WAL').get();
      final largeAbstract = List.filled(1024 * 1024, 'x').join();
      final now = DateTime.utc(2026, 7, 31);
      await database.batch((batch) {
        for (var index = 0; index < 68; index += 1) {
          final paper = PaperSummary.fromJson(
            _paper(index + 1000).toJson()..['abstract'] = largeAbstract,
          );
          batch.insert(
            database.cachedPapers,
            CachedPapersCompanion.insert(
              paperId: paper.paperId,
              arxivBaseId: paper.arxivBaseId,
              arxivVersion: const Value(1),
              metadataJson: jsonEncode(paper.toJson()),
              publishedAt: paper.publishedAt,
              updatedAt: paper.updatedAt,
              lastAccessedAt: now,
              expiresAt: now.add(const Duration(days: 7)),
            ),
          );
        }
      });
      final allocated = await store.measureCache();
      final physicalFiles = await Future.wait(
        ['', '-wal', '-shm'].map((suffix) async {
          final candidate = File('${file.path}$suffix');
          return await candidate.exists() ? await candidate.length() : 0;
        }),
      );
      expect(
        allocated.physicalDatabaseBytes,
        physicalFiles.fold<int>(0, (sum, bytes) => sum + bytes),
      );
      expect(allocated.physicalDatabaseBytes, greaterThan(maxBytes));

      final evicted = await store.evictCache(
        activeQueryKey: feedQueryKey(),
        protectedPaperIds: const {},
        maxMetadataPapers: 500,
        maxDatabaseBytes: maxBytes,
        metadataTtl: const Duration(days: 365),
        now: now,
      );
      expect(evicted.usageAfter.databaseBytes, lessThanOrEqualTo(maxBytes));
      expect(
        evicted.usageAfter.physicalDatabaseBytes,
        greaterThan(maxBytes),
        reason: 'swipe-time eviction must not run VACUUM',
      );

      final unsafe = await store.compactCacheIfNeeded(
        lifecycleSafe: false,
        maxDatabaseBytes: maxBytes,
      );
      expect(unsafe.ran, isFalse);

      final compacted = await store.runLifecycleSafeMaintenance();
      expect(compacted.ran, isTrue);
      expect(compacted.boundSatisfied, isTrue);
      expect(
        compacted.after.physicalDatabaseBytes,
        lessThanOrEqualTo(maxBytes),
      );
      expect(await file.length(), lessThanOrEqualTo(maxBytes));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

PakPerkDatabase _memoryDatabase() => PakPerkDatabase(NativeDatabase.memory());

String _legacyKey(String kind, String id) =>
    'pakperk.$kind.v1.${base64Url.encode(utf8.encode(id))}';

bool _isLegacyBulkKey(String key) =>
    key == LegacySharedPreferencesImporter.feedKey ||
    LegacySharedPreferencesImporter.bulkPrefixes.any(key.startsWith);

PaperSummary _withCapabilities(PaperSummary paper) => PaperSummary.fromJson(
  paper.toJson()
    ..['capabilities'] = const {
      'metadata': true,
      'introduction': true,
      'chat': true,
      'connections': true,
    },
);

PaperSummary _paper(int index) => PaperSummary.fromJson(
  samplePaper.toJson()
    ..['paper_id'] = 'paper-$index'
    ..['arxiv_id'] = '2607.${index.toString().padLeft(5, '0')}v1'
    ..['title'] = 'Cached paper $index'
    ..['updated_at'] = DateTime.utc(2026, 7, 30, 0, index).toIso8601String(),
);

/// Frozen production schema v1 fixture. Later versions add validators,
/// completeness and generation scopes while preserving durable records.
const _schemaV1 = '''
PRAGMA foreign_keys = ON;
CREATE TABLE cached_papers (
  paper_id TEXT NOT NULL PRIMARY KEY,
  arxiv_base_id TEXT NOT NULL,
  arxiv_version INTEGER NULL,
  metadata_json TEXT NOT NULL,
  published_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_accessed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  pinned_by_library INTEGER NOT NULL DEFAULT 0
    CHECK (pinned_by_library IN (0, 1))
);
CREATE TABLE feed_queries (
  query_key TEXT NOT NULL PRIMARY KEY,
  category TEXT NULL,
  next_cursor TEXT NULL,
  refreshed_at INTEGER NOT NULL,
  exhausted INTEGER NOT NULL DEFAULT 0 CHECK (exhausted IN (0, 1))
);
CREATE TABLE feed_entries (
  query_key TEXT NOT NULL REFERENCES feed_queries(query_key)
    ON DELETE CASCADE,
  position INTEGER NOT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  inserted_at INTEGER NOT NULL,
  PRIMARY KEY (query_key, paper_id),
  UNIQUE (query_key, position)
);
CREATE TABLE cached_processing (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_introductions (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  generation INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_connections (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_comment_pages (
  page_key TEXT NOT NULL PRIMARY KEY,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  cursor TEXT NULL,
  payload_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  etag TEXT NULL
);
CREATE TABLE library_items (
  account_id TEXT NOT NULL,
  paper_id TEXT NOT NULL,
  list_state TEXT NOT NULL DEFAULT 'to_read',
  client_updated_at INTEGER NOT NULL,
  server_updated_at INTEGER NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  PRIMARY KEY (account_id, paper_id)
);
CREATE TABLE comment_drafts (
  draft_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE RESTRICT,
  parent_comment_id TEXT NULL,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE sync_outbox (
  operation_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  entity_kind TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NULL,
  last_error_code TEXT NULL
);
CREATE TABLE cache_metadata (
  key TEXT NOT NULL PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

/// Frozen production schema v2 fixture. It predates feed completeness and
/// generation-scoped processing, connections, and anonymous chat.
const _schemaV2 = '''
PRAGMA foreign_keys = ON;
CREATE TABLE cached_papers (
  paper_id TEXT NOT NULL PRIMARY KEY,
  arxiv_base_id TEXT NOT NULL,
  arxiv_version INTEGER NULL,
  metadata_json TEXT NOT NULL,
  published_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_accessed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  pinned_by_library INTEGER NOT NULL DEFAULT 0
    CHECK (pinned_by_library IN (0, 1))
);
CREATE TABLE feed_queries (
  query_key TEXT NOT NULL PRIMARY KEY,
  category TEXT NULL,
  next_cursor TEXT NULL,
  refreshed_at INTEGER NOT NULL,
  exhausted INTEGER NOT NULL DEFAULT 0 CHECK (exhausted IN (0, 1)),
  etag TEXT NULL
);
CREATE TABLE feed_entries (
  query_key TEXT NOT NULL REFERENCES feed_queries(query_key)
    ON DELETE CASCADE,
  position INTEGER NOT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  inserted_at INTEGER NOT NULL,
  PRIMARY KEY (query_key, paper_id),
  UNIQUE (query_key, position)
);
CREATE TABLE cached_processing (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_introductions (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  generation INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_connections (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_comment_pages (
  page_key TEXT NOT NULL PRIMARY KEY,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE CASCADE,
  cursor TEXT NULL,
  payload_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  etag TEXT NULL
);
CREATE TABLE cached_chats (
  reader_key TEXT NOT NULL PRIMARY KEY,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE library_items (
  account_id TEXT NOT NULL,
  paper_id TEXT NOT NULL,
  list_state TEXT NOT NULL DEFAULT 'to_read',
  client_updated_at INTEGER NOT NULL,
  server_updated_at INTEGER NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  PRIMARY KEY (account_id, paper_id)
);
CREATE TABLE comment_drafts (
  draft_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id)
    ON DELETE RESTRICT,
  parent_comment_id TEXT NULL,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE sync_outbox (
  operation_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  entity_kind TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NULL,
  last_error_code TEXT NULL
);
CREATE TABLE cache_metadata (
  key TEXT NOT NULL PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''';
