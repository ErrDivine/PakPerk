import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/app/startup_gate.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/drift_local_store.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/comments/comment_controllers.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/comments/comment_repository.dart';
import 'package:pakperk/core/comments/comments_api.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/cache_maintenance_dao.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/performance/frame_timing_probe.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/feed/feed_controller.dart';
import 'package:pakperk/features/feed/feed_prefetch_coordinator.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Deterministic production-verification paths shared by headless CI and the
/// manually dispatched physical-device lane.
///
/// These tests intentionally do not impersonate real OIDC, two installed
/// devices, OS process death, or store distribution. Those paths require the
/// external runner described in the production plan and release checklist.
void registerProductionVerificationTests({bool physicalDevice = false}) {
  testWidgets('cold cached launch cursor-paginates 200 records under stalled '
      'revalidation with bounded readers', (tester) async {
    final papers = _papers(200);
    final repository = _PagedStalledPaperDataSource(papers);
    final feedCache = _VerificationFeedCache(
      papers.take(_verificationPageSize).map((paper) => paper.paperId),
    );
    final probe = PakPerkFlutterFrameTimingProbe()..start();
    addTearDown(() {
      if (probe.isRunning) probe.stop();
      repository.releaseRevalidation();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          feedCachePersistenceProvider.overrideWithValue(feedCache),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: const PakPerkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final verticalFeed = tester.widget<PageView>(
      find.byKey(const PageStorageKey<String>('vertical-paper-feed')),
    );
    final controller = verticalFeed.controller!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    var maximumLiveReaders = find.byType(PaperReader).evaluate().length;
    var generatedDragCount = 0;
    var generatedFlingCount = 0;
    var controllerCommitCount = 0;

    for (var index = 1; index < papers.length; index += 1) {
      await _waitForFeedRecord(tester, container, index);
      if (index <= _generatedGestureCount) {
        final feedFinder = find.byKey(
          const PageStorageKey<String>('vertical-paper-feed'),
        );
        final verticalDistance = tester.getSize(feedFinder).height * .72;
        if (index.isOdd) {
          await tester.fling(feedFinder, Offset(0, -verticalDistance), 1400);
          generatedFlingCount += 1;
        } else {
          await tester.drag(feedFinder, Offset(0, -verticalDistance));
          generatedDragCount += 1;
        }
        await tester.pumpAndSettle();
      } else {
        controller.jumpToPage(index);
        controllerCommitCount += 1;
        await tester.pumpAndSettle();
      }
      expect(
        container.read(appRestorationControllerProvider).feedIndex,
        index,
        reason: 'every traversal step must commit through PageView',
      );
      final liveReaders = find.byType(PaperReader).evaluate().length;
      if (liveReaders > maximumLiveReaders) maximumLiveReaders = liveReaders;
      expect(
        find.text(papers[index].title),
        findsAtLeastNWidgets(1),
        reason: 'feed page $index must never render as a blank card',
      );
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(appRestorationControllerProvider).feedIndex,
      papers.length - 1,
    );
    expect(container.read(feedControllerProvider).items, hasLength(200));
    expect(maximumLiveReaders, lessThanOrEqualTo(5));
    expect(generatedDragCount, _generatedGestureCount ~/ 2);
    expect(generatedFlingCount, _generatedGestureCount ~/ 2);
    expect(controllerCommitCount, papers.length - 1 - _generatedGestureCount);
    expect(repository.requestedCursors, _expectedVerificationCursors);
    expect(repository.requestedLimits, everyElement(defaultFeedPageLimit));
    expect(repository.feedCalls, 1 + _expectedVerificationCursors.length);
    expect(feedCache.persistedPages, hasLength(6));
    expect(feedCache.paperIds, hasLength(200));
    expect(repository.revalidationPending, isTrue);
    expect(repository.prepareCalls, 0);

    final timing = probe.stop();
    final frameEvidence = {
      ...timing.toJson(),
      'schema': 2,
      'classification':
          'deterministic fixture workload; not staging p95 evidence',
      'physical_device': physicalDevice,
      'metadata_records': papers.length,
      'pagination_path': 'feed_prefetch_coordinator',
      'cached_initial_records': _verificationPageSize,
      'cursor_page_size': _verificationPageSize,
      'cursor_pages_requested': repository.requestedCursors.length,
      'cursor_pages_persisted': feedCache.persistedPages.length,
      'unique_cursors_requested': repository.requestedCursors.toSet().length,
      'generated_flutter_drag_count': generatedDragCount,
      'generated_flutter_fling_count': generatedFlingCount,
      'generated_gesture_source': 'WidgetTester',
      'controller_page_commit_count': controllerCommitCount,
      'blank_cards': 0,
      'revalidation_stalled_during_traversal': repository.revalidationPending,
      'maximum_live_readers': maximumLiveReaders,
    };
    debugPrint('PAKPERK_FRAME_TIMING ${jsonEncode(frameEvidence)}');

    // Dispose the controller before releasing the deliberately stalled
    // first-page request. This preserves the endpoint's 30-row response shape
    // without replacing the already traversed cursor snapshot at test end.
    await tester.pumpWidget(const SizedBox.shrink());
    repository.releaseRevalidation();
    await tester.pump();
  });

  test('500-paper and 100-save Drift workload remains queryable', () async {
    Directory? databaseDirectory;
    late final PakPerkDatabase database;
    if (physicalDevice) {
      final temporaryRoot = await getTemporaryDirectory();
      databaseDirectory = await Directory(
        '${temporaryRoot.path}/pakperk-device-db-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${databaseDirectory.path}/workload.sqlite');
      database = PakPerkDatabase.atPath(NativeDatabase(file), file.path);
    } else {
      database = PakPerkDatabase(NativeDatabase.memory());
    }

    try {
      final papers = _papers(500);
      final paperCache = PaperCacheDao(database);
      final metadataWrite = Stopwatch()..start();
      await paperCache.ensureAll(papers, accessedAt: DateTime.utc(2026, 8, 1));
      metadataWrite.stop();

      var operationIndex = 0;
      final library = LibraryDao(
        database,
        clock: () => DateTime.utc(2026, 8, 1, 12),
        operationId: () => _uuid(++operationIndex, prefix: '018f47a6'),
      );
      final libraryWrite = Stopwatch()..start();
      for (final paper in papers.take(100)) {
        await library.enqueueMutation(
          accountId: _accountId,
          paperId: paper.paperId,
          saved: true,
        );
      }
      libraryWrite.stop();

      final metadataQuery = Stopwatch()..start();
      final existing = await paperCache.existingIds(
        papers.map((paper) => paper.paperId),
      );
      metadataQuery.stop();
      final libraryQuery = Stopwatch()..start();
      final saved = await library.watchToRead(_accountId).first;
      libraryQuery.stop();
      final usage = await CacheMaintenanceDao(database).measure();
      final cachedRows = await database.select(database.cachedPapers).get();
      final outboxRows = await database.select(database.syncOutbox).get();

      expect(existing, hasLength(500));
      expect(usage.metadataRows, 500);
      expect(saved, hasLength(100));
      expect(cachedRows.where((row) => row.pinnedByLibrary), hasLength(100));
      expect(outboxRows, hasLength(100));
      expect(usage.databaseBytes, greaterThan(0));
      if (physicalDevice) {
        expect(usage.physicalDatabaseBytes, greaterThan(0));
      }
      debugPrint(
        'PAKPERK_DB_WORKLOAD ${jsonEncode({'metadata_records': existing.length, 'saved_records': saved.length, 'outbox_records': outboxRows.length, 'live_database_bytes': usage.databaseBytes, if (physicalDevice) 'physical_database_bytes': usage.physicalDatabaseBytes else 'logical_database_bytes': usage.databaseBytes, 'database_file_backed': physicalDevice, 'database_size_kind': physicalDevice ? 'sqlite_file_wal_shm' : 'logical_live_pages', 'metadata_write_ms': metadataWrite.elapsedMilliseconds, 'library_write_ms': libraryWrite.elapsedMilliseconds, 'metadata_query_us': metadataQuery.elapsedMicroseconds, 'library_query_us': libraryQuery.elapsedMicroseconds})}',
      );
    } finally {
      await database.close();
      if (databaseDirectory != null && await databaseDirectory.exists()) {
        await databaseDirectory.delete(recursive: true);
      }
    }
  });

  test('rapid feed commits share one physical prefetch request', () async {
    final papers = _papers(20);
    final remote = _BlockingPrefetchRemote();
    final cache = _VerificationFeedCache(papers.map((paper) => paper.paperId));
    final coordinator = FeedPrefetchCoordinator(
      remote: remote,
      cache: cache,
      scheduler: const _DormantScheduler(),
    );
    addTearDown(coordinator.dispose);

    final first = coordinator.onCommittedPage(
      index: 15,
      items: papers,
      nextCursor: 'cursor-1',
    );
    await remote.started.future;
    final second = coordinator.onCommittedPage(
      index: 15,
      items: papers,
      nextCursor: 'cursor-1',
    );
    await Future<void>.delayed(Duration.zero);

    expect(remote.calls, 1);
    expect(coordinator.hasInFlightRequest, isTrue);
    remote.response.complete(
      RepositoryValue(
        value: FeedPage(items: _papers(10, offset: 20)),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await Future.wait([first, second]);
    expect(remote.calls, 1);
    expect(cache.persistedPages, hasLength(1));
    expect(coordinator.hasInFlightRequest, isFalse);
  });

  test(
    'simulated packet loss is nonblocking and releases single-flight',
    () async {
      final papers = _papers(20);
      final remote = _PacketLossPrefetchRemote();
      final cache = _VerificationFeedCache(
        papers.map((paper) => paper.paperId),
      );
      final coordinator = FeedPrefetchCoordinator(
        remote: remote,
        cache: cache,
        scheduler: const _DormantScheduler(),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.onCommittedPage(
          index: 15,
          items: papers,
          nextCursor: 'cursor-packet-loss',
        ),
        completes,
      );

      expect(remote.calls, 1);
      expect(cache.persistedPages, isEmpty);
      expect(cache.paperIds, containsAll(papers.map((paper) => paper.paperId)));
      expect(coordinator.hasInFlightRequest, isFalse);
    },
  );

  test(
    'in-flight library save recovers with the same UUID after relaunch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pakperk-outbox-verification-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/library.sqlite');
      const operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820099';
      final now = DateTime.utc(2026, 8, 1, 12);

      final firstDatabase = PakPerkDatabase.atPath(
        NativeDatabase(file),
        file.path,
      );
      final firstLibrary = LibraryDao(
        firstDatabase,
        clock: () => now,
        operationId: () => operationId,
      );
      await firstLibrary.enqueueMutation(
        accountId: _accountId,
        paperId: samplePaper.paperId,
        saved: true,
        paper: samplePaper,
      );
      final claimed = await firstLibrary.claimNextDue(
        accountId: _accountId,
        now: now,
      );
      expect(claimed?.operationId, operationId);
      await firstDatabase.close();

      final relaunchedDatabase = PakPerkDatabase.atPath(
        NativeDatabase(file),
        file.path,
      );
      addTearDown(relaunchedDatabase.close);
      final relaunchedLibrary = LibraryDao(
        relaunchedDatabase,
        clock: () => now,
        operationId: () => throw StateError('Recovery must reuse the UUID.'),
      );
      await relaunchedLibrary.recoverInFlight(_accountId);
      final replay = await relaunchedLibrary.claimNextDue(
        accountId: _accountId,
        now: now,
      );
      expect(replay?.operationId, operationId);
      expect(replay?.attemptCount, claimed?.attemptCount);
    },
  );

  test('comment controller fetches only requested cursor pages', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await PaperCacheDao(database).save(samplePaper);
    final remote = _PagingCommentsRemote(totalAvailable: 200, pageSize: 25);
    final repository = CommentRepository(
      cache: CommentCacheDao(database),
      local: CommentsDao(database),
      remote: remote,
      accountWrites: AccountDataWriteBarrier(),
      sessionScope: () => (accountId: null, authEpoch: 0),
      verifiedScope: () => null,
    );
    final controller = CommentThreadController(
      repository: repository,
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.guest(),
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(remote.requestedCursors, [null]);
    expect(controller.state.items, hasLength(25));
    expect(controller.state.nextCursor, 'page-25');

    await controller.loadMore();
    expect(remote.requestedCursors, [null, 'page-25']);
    expect(controller.state.items, hasLength(50));
    expect(controller.state.nextCursor, 'page-50');
    expect(controller.state.items.length, lessThan(remote.totalAvailable));
    expect(
      await database.select(database.cachedCommentPages).get(),
      hasLength(2),
    );
  });

  testWidgets(
    'memory warning and lifecycle callbacks select safe maintenance',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final store = _LifecycleSpyStore(
        preferences: preferences,
        database: PakPerkDatabase(NativeDatabase.memory()),
      );
      // This spy never opens the lazy in-memory executor, so there is no
      // native handle to release. Closing an unopened executor from a widget
      // test's fake-async teardown can wait forever for an isolate that was
      // never started.

      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(store.maintenanceCalls, 0);
      expect(store.memoryPressureCalls, 0);

      store.didHaveMemoryPressure();
      await tester.pump();
      expect(store.memoryPressureCalls, 1);
      expect(store.maintenanceCalls, 0);

      store.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      store.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      store.didChangeAppLifecycleState(AppLifecycleState.detached);
      await tester.pump();
      expect(store.maintenanceCalls, 3);
    },
  );

  testWidgets('reduced-motion startup is a stationary bounded cross-fade', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: StartupOpeningTransition(
          launchMode: StartupLaunchMode.cold,
          reducedMotionPreference: ReducedMotionPreference.reduce,
          onComplete: () => completed += 1,
          child: const ColoredBox(
            key: ValueKey<String>('verification-usable-content'),
            color: Colors.green,
          ),
        ),
      ),
    );
    final content = find.byKey(
      const ValueKey<String>('verification-usable-content'),
    );
    final initialPosition = tester.getTopLeft(content);

    await tester.pump(PakPerkMotion.crossFade ~/ 2);
    expect(tester.getTopLeft(content), initialPosition);
    expect(completed, 0);
    await tester.pump(
      (PakPerkMotion.crossFade ~/ 2) + const Duration(milliseconds: 1),
    );
    await tester.pump();

    expect(completed, 1);
    expect(tester.getTopLeft(content), initialPosition);
    expect(
      PakPerkMotion.crossFade,
      lessThanOrEqualTo(const Duration(milliseconds: 180)),
    );
  });

  test('strict policy masks every cached derived capability', () {
    final derived = samplePaper.copyWith(
      capabilities: const PaperCapabilities(
        introduction: true,
        chat: true,
        connections: true,
      ),
    );
    final masked = ClientFulltextPolicy.strict.maskCachedFeed(
      FeedPage(items: [derived], nextCursor: 'cursor'),
    );

    expect(masked.nextCursor, 'cursor');
    expect(masked.items.single.paperId, derived.paperId);
    expect(masked.items.single.capabilities.metadata, isTrue);
    expect(masked.items.single.capabilities.introduction, isFalse);
    expect(masked.items.single.capabilities.chat, isFalse);
    expect(masked.items.single.capabilities.connections, isFalse);
  });
}

const _verificationPageSize = defaultFeedPageLimit;
const _generatedGestureCount = 20;
const _expectedVerificationCursors = [
  'cursor-30',
  'cursor-60',
  'cursor-90',
  'cursor-120',
  'cursor-150',
  'cursor-180',
];

Future<void> _waitForFeedRecord(
  WidgetTester tester,
  ProviderContainer container,
  int index,
) async {
  for (var attempt = 0; attempt < 50; attempt += 1) {
    if (container.read(feedControllerProvider).items.length > index) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Cursor pagination did not make record $index available.');
}

List<PaperSummary> _papers(int count, {int offset = 0}) =>
    List.generate(count, (index) {
      final ordinal = offset + index + 1;
      final suffix = ordinal.toString().padLeft(12, '0');
      final arxivNumber = ordinal.toString().padLeft(5, '0');
      return PaperSummary(
        paperId: '17060376-2000-4000-8000-$suffix',
        arxivId: '2401.${arxivNumber}v1',
        title: 'Verification paper $ordinal',
        abstractText: 'Cached abstract for deterministic record $ordinal.',
        authors: const ['Pakperk verification'],
        primaryCategory: 'cs.CL',
        categories: const ['cs.CL'],
        publishedAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2026, 8, 1),
        absUrl: 'https://arxiv.org/abs/2401.${arxivNumber}v1',
        pdfUrl: 'https://arxiv.org/pdf/2401.${arxivNumber}v1',
      );
    });

String _uuid(int ordinal, {String prefix = '018f47a6'}) =>
    '$prefix-4b56-7f4c-8c7a-${ordinal.toString().padLeft(12, '0')}';

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

final class _PagedStalledPaperDataSource extends FakePaperDataSource {
  _PagedStalledPaperDataSource(this._papers)
    : assert(_papers.length == 200),
      super(
        paper: _papers.first,
        processing: sampleProcessing,
        introduction: sampleIntroduction,
        connections: sampleConnections,
      ) {
    cachedFeed = FeedPage(
      items: _papers.take(_verificationPageSize).toList(growable: false),
      nextCursor: _cursorForOffset(_verificationPageSize),
    );
  }

  final List<PaperSummary> _papers;
  final Completer<RepositoryValue<FeedPage>> _pendingRevalidation =
      Completer<RepositoryValue<FeedPage>>();
  final List<String> requestedCursors = [];
  final List<int> requestedLimits = [];

  bool get revalidationPending => !_pendingRevalidation.isCompleted;

  @override
  Future<RepositoryValue<FeedPage>> getFeed({
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) {
    feedCalls += 1;
    lastFeedCancellation = cancellation;
    if (cursor == null) return _pendingRevalidation.future;
    if (category != null) {
      return Future.error(
        StateError('The verification feed is uncategorized.'),
      );
    }
    if (limit != _verificationPageSize) {
      return Future.error(
        StateError('Unexpected verification page size: $limit.'),
      );
    }

    final offset = _offsetForCursor(cursor);
    if (offset == null) {
      return Future.error(StateError('Unexpected verification cursor.'));
    }
    requestedCursors.add(cursor);
    requestedLimits.add(limit);
    final end = (offset + limit).clamp(0, _papers.length);
    final nextCursor = end < _papers.length ? _cursorForOffset(end) : null;
    return Future.value(
      RepositoryValue(
        value: FeedPage(
          items: _papers.sublist(offset, end),
          nextCursor: nextCursor,
        ),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
  }

  void releaseRevalidation() {
    if (_pendingRevalidation.isCompleted) return;
    _pendingRevalidation.complete(
      RepositoryValue(
        value: FeedPage(
          items: _papers.take(_verificationPageSize).toList(growable: false),
          nextCursor: _cursorForOffset(_verificationPageSize),
        ),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
  }

  static String _cursorForOffset(int offset) => 'cursor-$offset';

  static int? _offsetForCursor(String cursor) {
    if (!cursor.startsWith('cursor-')) return null;
    final offset = int.tryParse(cursor.substring('cursor-'.length));
    if (offset == null ||
        offset < _verificationPageSize ||
        offset >= 200 ||
        offset % _verificationPageSize != 0) {
      return null;
    }
    return offset;
  }
}

final class _BlockingPrefetchRemote implements FeedPrefetchRemoteSource {
  int calls = 0;
  final Completer<void> started = Completer<void>();
  final Completer<RepositoryValue<FeedPage>> response =
      Completer<RepositoryValue<FeedPage>>();

  @override
  Future<RepositoryValue<FeedPage>> fetchFeedPage({
    String? category,
    required String cursor,
    required int limit,
    RequestCancellation? cancellation,
  }) {
    calls += 1;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

final class _PacketLossPrefetchRemote implements FeedPrefetchRemoteSource {
  int calls = 0;

  @override
  Future<RepositoryValue<FeedPage>> fetchFeedPage({
    String? category,
    required String cursor,
    required int limit,
    RequestCancellation? cancellation,
  }) async {
    calls += 1;
    throw const SocketException('simulated packet loss');
  }
}

final class _VerificationFeedCache implements FeedCachePersistence {
  _VerificationFeedCache(Iterable<String> paperIds)
    : paperIds = paperIds.toSet();

  final Set<String> paperIds;
  final List<FeedPage> persistedPages = [];

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> ids) async =>
      ids.where(paperIds.contains).toSet();

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) async {
    paperIds.addAll(papers.map((paper) => paper.paperId));
  }

  @override
  Future<CacheEvictionResult> evictCache({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    int maxMetadataPapers = 500,
    int maxDatabaseBytes = 64 * 1024 * 1024,
    Duration metadataTtl = const Duration(days: 7),
    DateTime? now,
  }) async => CacheEvictionResult(
    expiredCommentPages: 0,
    oldFeedEntries: 0,
    unpinnedPapers: 0,
    derivedRows: 0,
    usageAfter: await measureCache(),
  );

  @override
  Future<FeedPage?> loadFeedPage(String queryKey) async => null;

  @override
  Future<FeedCacheUsage> measureCache() async => FeedCacheUsage(
    metadataRows: paperIds.length,
    databaseBytes: paperIds.length * 100,
  );

  @override
  Future<void> persistFeedPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  }) async {
    persistedPages.add(page);
    paperIds.addAll(page.items.map((paper) => paper.paperId));
  }

  @override
  Future<void> recordPaperAccess(
    String paperId, {
    DateTime? accessedAt,
  }) async {}
}

final class _DormantScheduler implements FeedPrefetchScheduler {
  const _DormantScheduler();

  @override
  FeedScheduledTask schedule(
    Duration delay,
    FutureOr<void> Function() callback,
  ) => const _DormantTask();
}

final class _DormantTask implements FeedScheduledTask {
  const _DormantTask();

  @override
  void cancel() {}
}

final class _PagingCommentsRemote implements CommentsRemoteDataSource {
  _PagingCommentsRemote({required this.totalAvailable, required this.pageSize});

  final int totalAvailable;
  final int pageSize;
  final List<String?> requestedCursors = [];

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    requestedCursors.add(cursor);
    final offset = cursor == null
        ? 0
        : int.parse(cursor.substring('page-'.length));
    final end = (offset + pageSize).clamp(0, totalAvailable);
    return CommentPage(
      items: [
        for (var index = offset; index < end; index += 1) _comment(index),
      ],
      nextCursor: end < totalAvailable ? 'page-$end' : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PaperComment _comment(int ordinal) {
  final timestamp = DateTime.utc(
    2026,
    8,
    1,
  ).subtract(Duration(minutes: ordinal));
  return PaperComment(
    id: _uuid(ordinal + 1),
    paperId: samplePaper.paperId,
    author: const CommentAuthor(
      id: _accountId,
      handle: 'verification_reader',
      displayName: null,
      status: CommentAccountStatus.active,
    ),
    body: 'Paginated comment ${ordinal + 1}',
    status: CommentStatus.published,
    version: 1,
    createdAt: timestamp,
    updatedAt: timestamp,
    editedAt: null,
  );
}

final class _LifecycleSpyStore extends DriftLocalStore {
  _LifecycleSpyStore({required super.preferences, required super.database});

  int maintenanceCalls = 0;
  int memoryPressureCalls = 0;

  @override
  Future<CacheEvictionResult> runMemoryPressureMaintenance() async {
    memoryPressureCalls += 1;
    return const CacheEvictionResult(
      expiredCommentPages: 0,
      oldFeedEntries: 0,
      unpinnedPapers: 0,
      derivedRows: 0,
      usageAfter: FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
    );
  }

  @override
  Future<CacheCompactionResult> runLifecycleSafeMaintenance() async {
    maintenanceCalls += 1;
    const usage = FeedCacheUsage(metadataRows: 0, databaseBytes: 0);
    return const CacheCompactionResult(
      ran: false,
      boundSatisfied: true,
      before: usage,
      after: usage,
    );
  }
}
