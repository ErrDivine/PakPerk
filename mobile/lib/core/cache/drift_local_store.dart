import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../content_policy.dart';
import '../database/app_database.dart';
import '../database/account_cache_dao.dart';
import '../database/cache_maintenance_dao.dart';
import '../database/derived_cache_dao.dart';
import '../database/feed_cache_dao.dart';
import '../database/legacy_preferences_importer.dart';
import '../database/paper_cache_dao.dart';
import '../models/arxiv_identifier.dart';
import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import '../models/reader_state.dart';
import '../settings/appearance.dart';
import 'drift_restoration_persistence.dart';
import 'feed_cache_persistence.dart';
import 'local_store.dart';
import 'restoration_persistence.dart';
import 'versioned_derived_cache.dart';

/// Production local store: lightweight identity/restoration values remain in
/// preferences while all bulk public and account-ready records live in Drift.
class DriftLocalStore
    with WidgetsBindingObserver
    implements
        LocalStore,
        FeedConditionalCache,
        FeedCachePersistence,
        CacheCompactionPersistence,
        PublicCacheControl,
        LiveRestorationCacheProtection,
        VersionedDerivedCache,
        GenerationScopedChatCache {
  static const _physicalMaintenanceReserveBytes = 512 * 1024;
  DriftLocalStore({
    required SharedPreferences preferences,
    required this.database,
    this.fulltextPolicy = ClientFulltextPolicy.prototype,
    bool startLegacyImport = false,
    Future<int> Function()? databaseByteMeasurer,
    LegacySharedPreferencesImporter? legacyImporter,
  }) : _preferences = SharedPreferencesLocalStore(preferences),
       _papers = PaperCacheDao(database),
       _feeds = FeedCacheDao(database, PaperCacheDao(database)),
       _derived = DerivedCacheDao(database, PaperCacheDao(database)),
       _maintenance = CacheMaintenanceDao(
         database,
         databaseByteMeasurer: databaseByteMeasurer,
       ),
       _legacyImporter =
           legacyImporter ??
           LegacySharedPreferencesImporter(
             preferences: preferences,
             database: database,
             fulltextPolicy: fulltextPolicy,
           ) {
    _restoration = DriftRestorationPersistence(
      preferences: RestorationPreferences(preferences),
      persistPapers: (papers) =>
          _papers.ensureAll(papers.map(fulltextPolicy.maskCachedPaper)),
      loadPaper: (paperId) async {
        final paper = await _papers.load(paperId);
        return paper == null ? null : fulltextPolicy.maskCachedPaper(paper);
      },
      loadFeed: () async {
        final page = await _feeds.loadPage(_lastActiveQueryKey);
        return page == null ? null : fulltextPolicy.maskCachedFeed(page);
      },
      normalizePaper: fulltextPolicy.maskCachedPaper,
    );
    if (startLegacyImport) unawaited(startLegacyImportWork());
  }

  static Future<DriftLocalStore> create({
    ClientFulltextPolicy fulltextPolicy = ClientFulltextPolicy.prototype,
  }) async {
    final store = DriftLocalStore(
      preferences: await SharedPreferences.getInstance(),
      database: PakPerkDatabase.defaults(),
      fulltextPolicy: fulltextPolicy,
    );
    store.attachLifecycleMaintenance();
    return store;
  }

  /// Deletes rebuildable public records without touching session,
  /// restoration, library, drafts, or pending sync operations.
  static Future<void> repairPublicCache({
    ClientFulltextPolicy fulltextPolicy = ClientFulltextPolicy.prototype,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final database = PakPerkDatabase.defaults();
    final store = DriftLocalStore(
      preferences: preferences,
      database: database,
      fulltextPolicy: fulltextPolicy,
    );
    try {
      await store.clearRebuildablePublicCache();
    } finally {
      await store.close();
    }
  }

  final PakPerkDatabase database;
  final ClientFulltextPolicy fulltextPolicy;
  final SharedPreferencesLocalStore _preferences;
  final PaperCacheDao _papers;
  final FeedCacheDao _feeds;
  final DerivedCacheDao _derived;
  final CacheMaintenanceDao _maintenance;
  final LegacySharedPreferencesImporter _legacyImporter;
  late final DriftRestorationPersistence _restoration;

  Future<LegacyImportStats>? _legacyImport;
  WidgetsBinding? _lifecycleBinding;
  Future<CacheCompactionResult>? _lifecycleMaintenance;
  Future<CacheEvictionResult>? _memoryPressureMaintenance;
  String _lastActiveQueryKey = feedQueryKey();
  Set<String> _lastProtectedPaperIds = const {};
  int _lastMaxMetadataPapers = 500;
  int _lastMaxDatabaseBytes = 64 * 1024 * 1024;
  Duration _lastMetadataTtl = const Duration(days: 7);
  AppRestorationState? _liveRestoration;

  Future<LegacyImportStats> get legacyImportDone =>
      _legacyImport ?? Future.value(const LegacyImportStats.alreadyComplete());

  /// Starts once before the cached-feed read. Import failures are converted to
  /// count-only results by the importer and cannot fail startup.
  Future<LegacyImportStats> startLegacyImportWork() => _legacyImport ??=
      Future<LegacyImportStats>.microtask(_legacyImporter.run);

  void attachLifecycleMaintenance({WidgetsBinding? binding}) {
    if (_lifecycleBinding != null) return;
    final target = binding ?? WidgetsBinding.instance;
    target.addObserver(this);
    _lifecycleBinding = target;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached) {
      return;
    }
    unawaited(_runLifecycleMaintenanceIgnoringErrors());
  }

  @override
  void didHaveMemoryPressure() {
    final state = _lifecycleBinding?.lifecycleState;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_runLifecycleMaintenanceIgnoringErrors());
      return;
    }
    // A foreground memory warning may arrive during a swipe. Release SQLite's
    // expendable cache and enforce the existing row/live-byte bounds, but do
    // not checkpoint or VACUUM until a non-interactive lifecycle state.
    unawaited(_runMemoryPressureMaintenanceIgnoringErrors());
  }

  Future<void> _runLifecycleMaintenanceIgnoringErrors() async {
    try {
      await runLifecycleSafeMaintenance();
    } on Object catch (error, stackTrace) {
      developer.log(
        'lifecycle-safe cache maintenance failed',
        name: 'pakperk.cache',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _runMemoryPressureMaintenanceIgnoringErrors() async {
    try {
      await runMemoryPressureMaintenance();
    } on Object catch (error, stackTrace) {
      developer.log(
        'foreground memory-pressure cache maintenance failed',
        name: 'pakperk.cache',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> close() async {
    _lifecycleBinding?.removeObserver(this);
    _lifecycleBinding = null;
    await _restoration.waitForWrites();
    await database.close();
  }

  @override
  Future<void> purgeAccountDeletionCommentSnapshots() =>
      AccountCacheDao(database).purgeCommentPagesForAccountDeletion();

  @override
  Future<void> clearAllLocalData() async {
    await legacyImportDone;
    await _restoration.waitForWrites();
    await database.clearAllLocalData();
    await _preferences.clearAllLocalData();
    _liveRestoration = const AppRestorationState();
    _lastActiveQueryKey = feedQueryKey();
    _lastProtectedPaperIds = const {};
  }

  @override
  Future<String> getOrCreateSessionId() => _preferences.getOrCreateSessionId();

  @override
  Future<String> rotateAnonymousSession() async {
    // Privacy wins over availability across the non-transactional SQLite /
    // preferences boundary: old anonymous chat is made unreadable before the
    // identity is committed. A failure can lose cache, but cannot expose it to
    // a newly-created identity.
    await _derived.clearChats();
    final restoration = clearAnonymousChatRestoration(await loadRestoration());
    await saveRestoration(restoration);
    return _preferences.rotateAnonymousSessionIdOnly();
  }

  @override
  Future<AppRestorationState> loadRestoration() => _restoration.load();

  @override
  Future<void> saveRestoration(AppRestorationState value) {
    updateLiveRestorationProtection(value);
    return _restoration.save(value);
  }

  @override
  Future<AppAppearance> loadAppearance() => _preferences.loadAppearance();

  @override
  Future<void> saveAppearance(AppAppearance value) =>
      _preferences.saveAppearance(value);

  @override
  void updateLiveRestorationProtection(AppRestorationState value) {
    _liveRestoration = value;
  }

  @override
  Future<FeedPage?> loadFeed() => loadFeedPage(feedQueryKey());

  @override
  Future<void> saveFeed(FeedPage value) =>
      persistFeedPage(queryKey: feedQueryKey(), page: value, replace: true);

  @override
  Future<FeedPage?> loadFeedPage(String queryKey) async {
    final page = await _feeds.loadPage(queryKey);
    return page == null ? null : fulltextPolicy.maskCachedFeed(page);
  }

  @override
  Future<PaperSummary?> loadPaper(String paperId) async {
    final paper = await _papers.load(paperId);
    return paper == null ? null : fulltextPolicy.maskCachedPaper(paper);
  }

  @override
  Future<PaperSummary?> findPaperByArxiv(String arxivBaseId) async {
    final paper = await _papers.findByArxiv(arxivBaseId);
    return paper == null ? null : fulltextPolicy.maskCachedPaper(paper);
  }

  @override
  Future<void> savePaper(PaperSummary value) =>
      _papers.save(fulltextPolicy.maskCachedPaper(value));

  @override
  Future<void> clearDerived(String paperId) => _derived.clearForPaper(paperId);

  @override
  Future<PaperProcessingState?> loadProcessing(String paperId) async {
    final value = await _derived.loadProcessing(paperId);
    return value == null ? null : fulltextPolicy.maskCachedProcessing(value);
  }

  @override
  Future<void> saveProcessing(PaperProcessingState value) =>
      _derived.saveProcessing(fulltextPolicy.maskCachedProcessing(value));

  @override
  Future<bool> saveProcessingForVersion(
    PaperProcessingState value, {
    required PaperVersionKey expectedVersionKey,
  }) => _derived.saveProcessingForVersion(
    fulltextPolicy.maskCachedProcessing(value),
    expectedVersionKey: expectedVersionKey,
  );

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.loadIntroduction(paperId)
      : Future.value();

  @override
  Future<void> saveIntroduction(PaperIntroduction value) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.saveIntroduction(value)
      : Future.value();

  @override
  Future<bool> saveIntroductionForVersion(
    PaperIntroduction value, {
    required PaperVersionKey expectedVersionKey,
  }) => fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.saveIntroductionForVersion(
          value,
          expectedVersionKey: expectedVersionKey,
        )
      : Future.value(false);

  @override
  Future<PaperConnections?> loadConnections(String paperId) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.loadConnections(paperId)
      : Future.value();

  @override
  Future<void> saveConnections(PaperConnections value) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.saveConnections(value)
      : Future.value();

  @override
  Future<bool> saveConnectionsForVersion(
    PaperConnections value, {
    required PaperVersionKey expectedVersionKey,
  }) => fulltextPolicy.allowsDerivedDeviceFallback
      ? _derived.saveConnectionsForVersion(
          value,
          expectedVersionKey: expectedVersionKey,
        )
      : Future.value(false);

  @override
  Future<ChatSnapshot?> loadChat(String readerKey) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _loadChat(readerKey)
      : Future.value();

  Future<ChatSnapshot?> _loadChat(String readerKey) async => _derived.loadChat(
    readerKey,
    sessionId: await _preferences.getOrCreateSessionId(),
  );

  @override
  Future<void> saveChat(String readerKey, ChatSnapshot value) =>
      fulltextPolicy.allowsDerivedDeviceFallback
      ? _saveChat(readerKey, value)
      : Future.value();

  Future<void> _saveChat(String readerKey, ChatSnapshot value) async {
    final generation = value.generation;
    if (generation == null) return;
    final expectedVersion = _feedReaderVersionKey(readerKey);
    if (expectedVersion == null) return;
    await saveChatForGeneration(
      readerKey,
      value,
      expectedVersionKey: expectedVersion,
      expectedGeneration: generation,
    );
  }

  @override
  Future<bool> saveChatForGeneration(
    String readerKey,
    ChatSnapshot value, {
    required PaperVersionKey expectedVersionKey,
    required int expectedGeneration,
  }) async {
    if (!_readerKeyMatchesVersion(readerKey, expectedVersionKey) ||
        value.generation != expectedGeneration) {
      return false;
    }
    // A reader whose metadata or processing scope advanced is a late write.
    return _derived.saveChat(
      readerKey,
      value,
      sessionId: await _preferences.getOrCreateSessionId(),
      expectedVersionKey: expectedVersionKey,
      expectedGeneration: expectedGeneration,
    );
  }

  PaperVersionKey? _feedReaderVersionKey(String readerKey) {
    final segments = readerKey.split(':');
    if (segments.length != 3 || segments.first != 'feed') return null;
    final arxiv = ArxivIdentifier.tryParse(segments[2]);
    if (segments[1].trim().isEmpty || arxiv == null) return null;
    return PaperVersionKey(paperId: segments[1], arxivId: arxiv.queryId);
  }

  bool _readerKeyMatchesVersion(
    String readerKey,
    PaperVersionKey expectedVersionKey,
  ) {
    final segments = readerKey.split(':');
    if (segments.length != 3 ||
        (segments.first != 'feed' && segments.first != 'route')) {
      return false;
    }
    if (segments.first == 'feed' && segments[1] != expectedVersionKey.paperId) {
      return false;
    }
    final actualArxiv = ArxivIdentifier.tryParse(segments[2]);
    final expectedArxiv = ArxivIdentifier.tryParse(expectedVersionKey.arxivId);
    return actualArxiv != null &&
        expectedArxiv != null &&
        actualArxiv.baseId.toLowerCase() ==
            expectedArxiv.baseId.toLowerCase() &&
        actualArxiv.version == expectedArxiv.version;
  }

  @override
  Future<FeedCacheValidator?> loadFeedValidator(String queryKey) =>
      _feeds.loadValidator(queryKey);

  @override
  Future<void> storeFeedValidator(
    String queryKey, {
    required String? etag,
    required DateTime refreshedAt,
  }) => _feeds.storeValidator(queryKey, etag: etag, refreshedAt: refreshedAt);

  @override
  Future<void> touchFeedRefreshedAt(String queryKey, DateTime refreshedAt) =>
      _feeds.touchRefreshedAt(queryKey, refreshedAt);

  @override
  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds) =>
      _papers.existingIds(paperIds);

  @override
  Future<void> recordPaperAccess(String paperId, {DateTime? accessedAt}) =>
      _papers.recordAccess(paperId, accessedAt: accessedAt);

  @override
  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  }) => _papers.ensureAll(
    papers.map(fulltextPolicy.maskCachedPaper),
    accessedAt: accessedAt,
  );

  @override
  Future<void> persistFeedPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  }) => _feeds.persistPage(
    queryKey: queryKey,
    page: fulltextPolicy.maskCachedFeed(page),
    replace: replace,
    category: category,
    etag: etag,
    refreshedAt: refreshedAt,
  );

  @override
  Future<FeedCacheUsage> measureCache() => _maintenance.measure();

  @override
  Future<FeedCacheUsage> measurePublicCache() => measureCache();

  @override
  Future<PublicCacheClearResult> clearRebuildablePublicCache() async {
    await _restoration.waitForWrites();
    final before = await measureCache();
    final persisted = await loadRestoration();
    final live = _liveRestoration;
    final restorations = <AppRestorationState>[
      persisted,
      if (live != null && live != persisted) live,
    ];

    // Snapshot the minimum content needed to keep every currently restorable
    // paper readable before deleting rebuildable relational data.
    final protectedPapers = <String, PaperSummary>{};
    for (final restoration in restorations) {
      for (final entry in restoration.routeStack) {
        protectedPapers[entry.paper.paperId] = entry.paper;
      }
      if (restoration.feedPaperId case final paperId?) {
        final paper = await loadPaper(paperId);
        if (paper != null) protectedPapers[paper.paperId] = paper;
      }
    }

    PaperSummary? activeFeedPaper;
    final activeFeed = await loadFeedPage(_lastActiveQueryKey);
    if (activeFeed != null && activeFeed.items.isNotEmpty) {
      final preferred = live ?? persisted;
      final referencedId = preferred.feedPaperId;
      if (referencedId != null) {
        activeFeedPaper = activeFeed.items
            .where((paper) => paper.paperId == referencedId)
            .firstOrNull;
      }
      activeFeedPaper ??= activeFeed
          .items[preferred.feedIndex.clamp(0, activeFeed.items.length - 1)];
      protectedPapers[activeFeedPaper.paperId] = activeFeedPaper;
    }

    await database.clearPublicCache();
    await ensurePaperMetadata(protectedPapers.values);
    if (activeFeedPaper != null) {
      await persistFeedPage(
        queryKey: _lastActiveQueryKey,
        page: FeedPage(items: [activeFeedPaper]),
        replace: true,
      );
    }
    await SharedPreferencesLocalStore.repairPublicCache();
    final after = await measureCache();
    return PublicCacheClearResult(before: before, after: after);
  }

  @override
  Future<CacheEvictionResult> evictCache({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    int maxMetadataPapers = 500,
    int maxDatabaseBytes = 64 * 1024 * 1024,
    Duration metadataTtl = const Duration(days: 7),
    DateTime? now,
  }) async {
    _lastActiveQueryKey = activeQueryKey;
    _lastProtectedPaperIds = Set.unmodifiable(protectedPaperIds);
    _lastMaxMetadataPapers = maxMetadataPapers;
    _lastMaxDatabaseBytes = maxDatabaseBytes;
    _lastMetadataTtl = metadataTtl;
    final persistedRestoration = await loadRestoration();
    final restorations = <AppRestorationState>[
      persistedRestoration,
      if (_liveRestoration case final live?) live,
    ];
    final internallyProtected = restorations
        .expand((state) => state.routeStack)
        .map((entry) => entry.paper.paperId)
        .toSet();
    internallyProtected.addAll(
      restorations.map((state) => state.feedPaperId).whereType<String>(),
    );
    final activeFeed = await loadFeedPage(activeQueryKey);
    if (activeFeed != null && activeFeed.items.isNotEmpty) {
      for (final restoration in restorations) {
        if (restoration.feedPaperId != null) continue;
        final index = restoration.feedIndex.clamp(
          0,
          activeFeed.items.length - 1,
        );
        internallyProtected.add(activeFeed.items[index].paperId);
      }
    }
    return _maintenance.evict(
      activeQueryKey: activeQueryKey,
      protectedPaperIds: {...protectedPaperIds, ...internallyProtected},
      maxMetadataPapers: maxMetadataPapers,
      maxDatabaseBytes: maxDatabaseBytes,
      metadataTtl: metadataTtl,
      now: now ?? DateTime.now().toUtc(),
      protectedChatReaderKeys: restorations
          .expand((state) => state.readerStates.entries)
          .where(
            (entry) =>
                entry.value.chatSheetOpen || entry.value.chatThreadId != null,
          )
          .map((entry) => entry.key)
          .toSet(),
    );
  }

  @override
  Future<CacheCompactionResult> compactCacheIfNeeded({
    required bool lifecycleSafe,
    int maxDatabaseBytes = 64 * 1024 * 1024,
  }) => _maintenance.compactIfNeeded(
    lifecycleSafe: lifecycleSafe,
    maxDatabaseBytes: maxDatabaseBytes,
  );

  /// Runs deletion, WAL checkpointing, and VACUUM only after the application
  /// enters a non-interactive lifecycle state. Calls are single-flight.
  Future<CacheCompactionResult> runLifecycleSafeMaintenance() {
    final active = _lifecycleMaintenance;
    if (active != null) return active;
    late final Future<CacheCompactionResult> operation;
    operation = _runLifecycleSafeMaintenance().whenComplete(() {
      if (identical(_lifecycleMaintenance, operation)) {
        _lifecycleMaintenance = null;
      }
    });
    _lifecycleMaintenance = operation;
    return operation;
  }

  /// Handles a foreground OS memory warning without performing physical
  /// compaction. Calls are single-flight so repeated platform warnings cannot
  /// start overlapping eviction transactions.
  Future<CacheEvictionResult> runMemoryPressureMaintenance() {
    final active = _memoryPressureMaintenance;
    if (active != null) return active;
    late final Future<CacheEvictionResult> operation;
    operation = _runMemoryPressureMaintenance().whenComplete(() {
      if (identical(_memoryPressureMaintenance, operation)) {
        _memoryPressureMaintenance = null;
      }
    });
    _memoryPressureMaintenance = operation;
    return operation;
  }

  Future<CacheEvictionResult> _runMemoryPressureMaintenance() async {
    await database.releaseMemory();
    return evictCache(
      activeQueryKey: _lastActiveQueryKey,
      protectedPaperIds: _lastProtectedPaperIds,
      maxMetadataPapers: _lastMaxMetadataPapers,
      maxDatabaseBytes: _lastMaxDatabaseBytes,
      metadataTtl: _lastMetadataTtl,
    );
  }

  Future<CacheCompactionResult> _runLifecycleSafeMaintenance() async {
    final physicalTarget = _lastMaxDatabaseBytes;
    final liveTarget = physicalTarget > _physicalMaintenanceReserveBytes
        ? physicalTarget - _physicalMaintenanceReserveBytes
        : 0;
    try {
      await evictCache(
        activeQueryKey: _lastActiveQueryKey,
        protectedPaperIds: _lastProtectedPaperIds,
        maxMetadataPapers: _lastMaxMetadataPapers,
        maxDatabaseBytes: liveTarget,
        metadataTtl: _lastMetadataTtl,
      );
    } finally {
      _lastMaxDatabaseBytes = physicalTarget;
    }
    return compactCacheIfNeeded(
      lifecycleSafe: true,
      maxDatabaseBytes: physicalTarget,
    );
  }
}
