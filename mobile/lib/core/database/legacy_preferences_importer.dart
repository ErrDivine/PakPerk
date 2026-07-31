import 'dart:convert';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../cache/feed_cache_persistence.dart';
import '../content_policy.dart';
import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import 'app_database.dart';
import 'feed_cache_dao.dart';
import 'paper_cache_dao.dart';

const legacyPreferencesImportMarker = 'legacy_shared_preferences_import_v1';

class LegacyImportStats {
  const LegacyImportStats({
    required this.didRun,
    required this.feedRows,
    required this.paperRows,
    required this.processingRows,
    required this.introductionRows,
    required this.connectionRows,
    required this.chatRows,
    required this.policyDiscardedRows,
    required this.invalidRows,
    required this.removedPreferenceKeys,
    this.failed = false,
  });

  const LegacyImportStats.alreadyComplete()
    : didRun = false,
      feedRows = 0,
      paperRows = 0,
      processingRows = 0,
      introductionRows = 0,
      connectionRows = 0,
      chatRows = 0,
      policyDiscardedRows = 0,
      invalidRows = 0,
      removedPreferenceKeys = 0,
      failed = false;

  const LegacyImportStats.failed()
    : didRun = true,
      feedRows = 0,
      paperRows = 0,
      processingRows = 0,
      introductionRows = 0,
      connectionRows = 0,
      chatRows = 0,
      policyDiscardedRows = 0,
      invalidRows = 0,
      removedPreferenceKeys = 0,
      failed = true;

  final bool didRun;
  final int feedRows;
  final int paperRows;
  final int processingRows;
  final int introductionRows;
  final int connectionRows;
  final int chatRows;
  final int policyDiscardedRows;
  final int invalidRows;
  final int removedPreferenceKeys;
  final bool failed;
}

class LegacySharedPreferencesImporter {
  LegacySharedPreferencesImporter({
    required this.preferences,
    required this.database,
    required this.fulltextPolicy,
    Future<void> Function()? beforeMarkComplete,
    DateTime Function()? clock,
    Future<String> Function()? sessionIdLoader,
  }) : _beforeMarkComplete = beforeMarkComplete,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _sessionIdLoader =
           sessionIdLoader ??
           (() async {
             const key = 'pakperk.session.v1';
             final existing = preferences.getString(key);
             if (existing != null && existing.isNotEmpty) return existing;
             final created = const Uuid().v4();
             await preferences.setString(key, created);
             return created;
           }),
       _papers = PaperCacheDao(database),
       _feeds = FeedCacheDao(database, PaperCacheDao(database));

  static const feedKey = 'pakperk.feed.v1';
  static const bulkPrefixes = <String>[
    'pakperk.paper.v1.',
    'pakperk.processing.v1.',
    'pakperk.introduction.v1.',
    'pakperk.connections.v1.',
    'pakperk.chat.v1.',
  ];

  final SharedPreferences preferences;
  final PakPerkDatabase database;
  final ClientFulltextPolicy fulltextPolicy;
  final Future<void> Function()? _beforeMarkComplete;
  final DateTime Function() _clock;
  final Future<String> Function() _sessionIdLoader;
  final PaperCacheDao _papers;
  final FeedCacheDao _feeds;

  Future<LegacyImportStats> run() async {
    try {
      final completed = await database.readMetadata(
        legacyPreferencesImportMarker,
      );
      if (completed == true) {
        await _removeBulkPreferenceKeys(
          preferences.getKeys().where(_isBulkKey),
        );
        return const LegacyImportStats.alreadyComplete();
      }

      final snapshot = _readSnapshot();
      final removableKeys = preferences.getKeys().where(_isBulkKey).toSet();
      var feedRows = 0;
      var paperRows = 0;
      var processingRows = 0;
      var introductionRows = 0;
      var connectionRows = 0;
      var chatRows = 0;
      var policyDiscardedRows = 0;
      var invalidRows = snapshot.invalidRows;
      final now = _clock().toUtc();
      final latestPapers = _latestPapers(snapshot);
      await _sessionIdLoader();

      await database.transaction(() async {
        for (final paper in latestPapers.values) {
          await _papers.save(
            fulltextPolicy.maskCachedPaper(paper),
            accessedAt: now,
          );
        }
        paperRows = snapshot.papers.length;

        final feed = snapshot.feed;
        if (feed != null) {
          final masked = fulltextPolicy.maskCachedFeed(
            FeedPage(
              items: feed.items
                  .map((paper) => latestPapers[paper.paperId] ?? paper)
                  .toList(growable: false),
              nextCursor: feed.nextCursor,
            ),
          );
          await _feeds.persistPage(
            queryKey: feedQueryKey(),
            page: masked,
            replace: true,
            refreshedAt: now,
          );
          feedRows = masked.items.length;
        }

        // These legacy blobs contain a paper id, but no trustworthy arXiv
        // version binding. Importing through an unversioned save would stamp
        // stale derived content with whichever metadata version won above.
        invalidRows += snapshot.processing.length;

        if (fulltextPolicy.allowsDerivedDeviceFallback) {
          invalidRows +=
              snapshot.introductions.length +
              snapshot.connections.length +
              snapshot.chats.length;
        } else {
          final deniedKeys = <String>{
            ...snapshot.introductions.keys,
            ...snapshot.connections.keys,
            ...snapshot.chats.keys,
          };
          policyDiscardedRows = deniedKeys.length;
        }

        await _verify(expectedFeedRows: feedRows, expectedPapers: latestPapers);
        await _beforeMarkComplete?.call();
        await database.putMetadata(
          legacyPreferencesImportMarker,
          true,
          updatedAt: now,
        );
      });

      final removed = await _removeBulkPreferenceKeys(removableKeys);
      final stats = LegacyImportStats(
        didRun: true,
        feedRows: feedRows,
        paperRows: paperRows,
        processingRows: processingRows,
        introductionRows: introductionRows,
        connectionRows: connectionRows,
        chatRows: chatRows,
        policyDiscardedRows: policyDiscardedRows,
        invalidRows: invalidRows,
        removedPreferenceKeys: removed,
      );
      _logCounts(stats);
      return stats;
    } on Object {
      const stats = LegacyImportStats.failed();
      _logCounts(stats);
      return stats;
    }
  }

  _LegacySnapshot _readSnapshot() {
    FeedPage? feed;
    var invalidRows = 0;
    final feedJson = _readMap(feedKey);
    if (feedJson != null) {
      try {
        feed = FeedPage.fromJson(feedJson);
      } on Object {
        invalidRows += 1;
      }
    } else if (preferences.containsKey(feedKey)) {
      invalidRows += 1;
    }

    final papers = <String, PaperSummary>{};
    final processing = <String, PaperProcessingState>{};
    final introductions = <String, PaperIntroduction>{};
    final connections = <String, PaperConnections>{};
    final chats = <String, (String, ChatSnapshot)>{};
    for (final key in preferences.getKeys()) {
      if (key == feedKey) continue;
      final parsed = _readMap(key);
      if (parsed == null) {
        if (_isBulkKey(key)) invalidRows += 1;
        continue;
      }
      try {
        if (key.startsWith(bulkPrefixes[0])) {
          final paper = PaperSummary.fromJson(parsed);
          if (!_idMatchesKey(key, bulkPrefixes[0], paper.paperId)) {
            throw const FormatException('Paper key mismatch');
          }
          papers[key] = paper;
        } else if (key.startsWith(bulkPrefixes[1])) {
          final value = PaperProcessingState.fromJson(parsed);
          if (value.paperId.isEmpty ||
              !_idMatchesKey(key, bulkPrefixes[1], value.paperId)) {
            throw const FormatException('Processing key mismatch');
          }
          processing[key] = value;
        } else if (key.startsWith(bulkPrefixes[2])) {
          final value = PaperIntroduction.fromJson(parsed);
          if (value.paperId.isEmpty ||
              !_idMatchesKey(key, bulkPrefixes[2], value.paperId)) {
            throw const FormatException('Introduction key mismatch');
          }
          introductions[key] = value;
        } else if (key.startsWith(bulkPrefixes[3])) {
          final value = PaperConnections.fromJson(parsed);
          if (value.paperId.isEmpty ||
              !_idMatchesKey(key, bulkPrefixes[3], value.paperId)) {
            throw const FormatException('Connections key mismatch');
          }
          connections[key] = value;
        } else if (key.startsWith(bulkPrefixes[4])) {
          final readerKey = _decodeKeyId(key, bulkPrefixes[4]);
          if (readerKey == null || readerKey.isEmpty) {
            throw const FormatException('Chat key mismatch');
          }
          chats[key] = (readerKey, ChatSnapshot.fromJson(parsed));
        }
      } on Object {
        if (_isBulkKey(key)) invalidRows += 1;
      }
    }
    return _LegacySnapshot(
      feed: feed,
      papers: papers,
      processing: processing,
      introductions: introductions,
      connections: connections,
      chats: chats,
      invalidRows: invalidRows,
    );
  }

  Future<void> _verify({
    required int expectedFeedRows,
    required Map<String, PaperSummary> expectedPapers,
  }) async {
    for (final expected in expectedPapers.values) {
      final stored = await _papers.load(expected.paperId, touch: false);
      if (stored == null ||
          stored.arxivBaseId.toLowerCase() !=
              expected.arxivBaseId.toLowerCase() ||
          _isNewerPaper(expected, stored)) {
        throw StateError('Legacy paper cache verification failed');
      }
    }
    if (expectedFeedRows > 0) {
      final feed = await _feeds.loadPage(feedQueryKey());
      if (feed == null || feed.items.length != expectedFeedRows) {
        throw StateError('Legacy feed cache verification failed');
      }
    }
  }

  Map<String, PaperSummary> _latestPapers(_LegacySnapshot snapshot) {
    final latest = <String, PaperSummary>{};
    final candidates = snapshot.papers.values.followedBy(
      snapshot.feed?.items ?? const <PaperSummary>[],
    );
    for (final paper in candidates) {
      final current = latest[paper.paperId];
      if (current != null &&
          current.arxivBaseId.toLowerCase() !=
              paper.arxivBaseId.toLowerCase()) {
        throw const FormatException(
          'Stable paper id maps to conflicting arXiv identities',
        );
      }
      if (current == null || _isNewerPaper(paper, current)) {
        latest[paper.paperId] = paper;
      }
    }
    return latest;
  }

  bool _isNewerPaper(PaperSummary candidate, PaperSummary current) {
    if (candidate.arxivBaseId.toLowerCase() !=
        current.arxivBaseId.toLowerCase()) {
      return false;
    }
    final candidateVersion = _arxivVersion(candidate.arxivId) ?? 0;
    final currentVersion = _arxivVersion(current.arxivId) ?? 0;
    if (candidateVersion != currentVersion) {
      return candidateVersion > currentVersion;
    }
    return candidate.updatedAt.isAfter(current.updatedAt);
  }

  int? _arxivVersion(String arxivId) {
    final match = RegExp(r'v(\d+)$', caseSensitive: false).firstMatch(arxivId);
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<int> _removeBulkPreferenceKeys(Iterable<String> keys) async {
    var removed = 0;
    for (final key in keys.toSet()) {
      if (await preferences.remove(key)) removed += 1;
    }
    return removed;
  }

  Map<String, dynamic>? _readMap(String key) {
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  bool _idMatchesKey(String key, String prefix, String expected) =>
      _decodeKeyId(key, prefix) == expected;

  String? _decodeKeyId(String key, String prefix) {
    if (!key.startsWith(prefix)) return null;
    try {
      return utf8.decode(
        base64Url.decode(base64Url.normalize(key.substring(prefix.length))),
      );
    } on Object {
      return null;
    }
  }

  bool _isBulkKey(String key) =>
      key == feedKey || bulkPrefixes.any(key.startsWith);

  void _logCounts(LegacyImportStats stats) {
    developer.log(
      'legacy cache migration: '
      'feed=${stats.feedRows} papers=${stats.paperRows} '
      'processing=${stats.processingRows} '
      'introductions=${stats.introductionRows} '
      'connections=${stats.connectionRows} chats=${stats.chatRows} '
      'policy_discarded=${stats.policyDiscardedRows} '
      'invalid=${stats.invalidRows} removed=${stats.removedPreferenceKeys} '
      'failed=${stats.failed}',
      name: 'pakperk.cache',
    );
  }
}

class _LegacySnapshot {
  const _LegacySnapshot({
    required this.feed,
    required this.papers,
    required this.processing,
    required this.introductions,
    required this.connections,
    required this.chats,
    required this.invalidRows,
  });

  final FeedPage? feed;
  final Map<String, PaperSummary> papers;
  final Map<String, PaperProcessingState> processing;
  final Map<String, PaperIntroduction> introductions;
  final Map<String, PaperConnections> connections;
  final Map<String, (String, ChatSnapshot)> chats;
  final int invalidRows;
}
