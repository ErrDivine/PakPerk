import 'dart:convert';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import '../cache/feed_cache_persistence.dart';
import '../cache/feed_prefetch_config.dart';
import '../content_policy.dart';
import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import '../models/reader_state.dart';
import 'app_database.dart';
import 'derived_cache_dao.dart';
import 'feed_cache_dao.dart';
import 'paper_cache_dao.dart';

const legacyPreferencesImportMarker = 'legacy_shared_preferences_import_v1';

final _canonicalAnonymousSessionId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String? _readStringPreference(SharedPreferences preferences, String key) {
  try {
    final value = preferences.get(key);
    return value is String ? value : null;
  } on Object {
    // A corrupt scalar preference must not make store construction fail.
    return null;
  }
}

String? _readCanonicalAnonymousSession(SharedPreferences preferences) {
  final value = _readStringPreference(preferences, 'pakperk.session.v1');
  return value != null && _canonicalAnonymousSessionId.hasMatch(value)
      ? value
      : null;
}

Object _copyPreferenceValue(Object value) =>
    value is List ? List<Object?>.unmodifiable(value) : value;

bool _samePreferenceValue(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
  return left == right;
}

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
    required this.unboundRows,
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
      unboundRows = 0,
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
      unboundRows = 0,
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

  /// Structurally valid legacy rows whose paper version, processing
  /// generation, or anonymous-session scope cannot be proven.
  final int unboundRows;
  final int invalidRows;
  final int removedPreferenceKeys;
  final bool failed;
}

class LegacySharedPreferencesImporter {
  LegacySharedPreferencesImporter({
    required this.preferences,
    required this.database,
    required this.fulltextPolicy,
    this.cachePolicy = const FeedPrefetchConfig(),
    Future<void> Function()? beforeMarkComplete,
    DateTime Function()? clock,
  }) : _beforeMarkComplete = beforeMarkComplete,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _preMigrationSessionId = _readCanonicalAnonymousSession(preferences),
       _preMigrationRestorationJson = _readStringPreference(
         preferences,
         'pakperk.restoration.v2',
       ),
       _papers = PaperCacheDao(database, metadataTtl: cachePolicy.metadataTtl),
       _feeds = FeedCacheDao(
         database,
         PaperCacheDao(database, metadataTtl: cachePolicy.metadataTtl),
       ),
       _derived = DerivedCacheDao(
         database,
         PaperCacheDao(database, metadataTtl: cachePolicy.metadataTtl),
       );

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
  final FeedPrefetchConfig cachePolicy;
  final Future<void> Function()? _beforeMarkComplete;
  final DateTime Function() _clock;
  final String? _preMigrationSessionId;
  final String? _preMigrationRestorationJson;
  final PaperCacheDao _papers;
  final FeedCacheDao _feeds;
  final DerivedCacheDao _derived;

  Future<LegacyImportStats> run() async {
    try {
      final completed = await database.readMetadata(
        legacyPreferencesImportMarker,
      );
      if (completed == true) {
        await _removeBulkPreferenceKeys(_captureBulkPreferences());
        return const LegacyImportStats.alreadyComplete();
      }

      final sourcePreferences = _captureBulkPreferences();
      final snapshot = _readSnapshot(sourcePreferences);
      var feedRows = 0;
      var paperRows = 0;
      var processingRows = 0;
      var introductionRows = 0;
      var connectionRows = 0;
      var chatRows = 0;
      var policyDiscardedRows = 0;
      var unboundRows = 0;
      var invalidRows = snapshot.invalidRows;
      final now = _clock().toUtc();
      final latestPapers = _latestPapers(snapshot);
      final expectedPapers = {
        for (final entry in latestPapers.entries)
          entry.key: fulltextPolicy.maskCachedPaper(entry.value),
      };
      final trustedVersions = _trustedVersions(snapshot, latestPapers);
      final trustedRouteVersions = _trustedRouteVersions(trustedVersions);
      // This was sampled in the constructor, before startup launches session
      // creation and legacy import concurrently. Never mint an identity merely
      // to label old chat or resample a sibling-created identity here.
      final sessionId = _preMigrationSessionId ?? '';
      final chatSessionIsBound = sessionId.isNotEmpty;
      final expectedProcessing = <String, PaperProcessingState>{};
      final expectedIntroductions = <String, PaperIntroduction>{};
      final expectedConnections = <String, PaperConnections>{};
      final expectedChats = <String, ChatSnapshot>{};
      FeedPage? expectedFeed;

      await database.transaction(() async {
        for (final paper in expectedPapers.values) {
          await _papers.save(paper, accessedAt: now);
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
            queryKey: feedQueryKey(limit: cachePolicy.remotePageSize),
            page: masked,
            replace: true,
            refreshedAt: now,
          );
          expectedFeed = masked;
          feedRows = masked.items.length;
        }

        if (fulltextPolicy.allowsDerivedDeviceFallback) {
          for (final legacy in snapshot.processing.values) {
            final value = legacy.value;
            final generation = legacy.explicitGeneration;
            final version = trustedVersions[value.paperId];
            if (generation == null ||
                value.generation != generation ||
                version == null) {
              unboundRows += 1;
              continue;
            }
            final masked = fulltextPolicy.maskCachedProcessing(value);
            if (await _derived.saveProcessingForVersion(
              masked,
              expectedVersionKey: version,
            )) {
              expectedProcessing[value.paperId] = masked;
              processingRows += 1;
            } else {
              unboundRows += 1;
            }
          }

          for (final legacy in snapshot.introductions.values) {
            final value = legacy.value;
            final generation = legacy.explicitGeneration;
            final version = trustedVersions[value.paperId];
            if (generation == null ||
                value.generation != generation ||
                version == null ||
                expectedProcessing[value.paperId]?.generation != generation) {
              unboundRows += 1;
              continue;
            }
            if (await _derived.saveIntroductionForVersion(
              value,
              expectedVersionKey: version,
            )) {
              expectedIntroductions[value.paperId] = value;
              introductionRows += 1;
            } else {
              unboundRows += 1;
            }
          }

          for (final legacy in snapshot.connections.values) {
            final value = legacy.value;
            final generation = legacy.explicitGeneration;
            final version = trustedVersions[value.paperId];
            if (generation == null ||
                value.generation != generation ||
                version == null ||
                expectedProcessing[value.paperId]?.generation != generation) {
              unboundRows += 1;
              continue;
            }
            if (await _derived.saveConnectionsForVersion(
              value,
              expectedVersionKey: version,
            )) {
              expectedConnections[value.paperId] = value;
              connectionRows += 1;
            } else {
              unboundRows += 1;
            }
          }

          for (final legacy in snapshot.chats.values) {
            final generation = legacy.explicitGeneration;
            final version = _trustedChatVersion(
              legacy.readerKey,
              trustedVersions,
              trustedRouteVersions,
            );
            if (generation == null ||
                legacy.value.generation != generation ||
                !chatSessionIsBound ||
                version == null ||
                legacy.explicitSessionId != sessionId ||
                legacy.explicitPaperId != version.paperId ||
                legacy.explicitArxivId != version.arxivId ||
                expectedProcessing[version.paperId]?.generation != generation) {
              unboundRows += 1;
              continue;
            }
            if (await _derived.saveChat(
              legacy.readerKey,
              legacy.value,
              sessionId: sessionId,
              expectedVersionKey: version,
              expectedGeneration: generation,
              now: now,
            )) {
              expectedChats[legacy.readerKey] = legacy.value;
              chatRows += 1;
            } else {
              unboundRows += 1;
            }
          }
        } else {
          policyDiscardedRows =
              snapshot.processing.length +
              snapshot.introductions.length +
              snapshot.connections.length +
              snapshot.chats.length;
        }

        await _beforeMarkComplete?.call();
        await _verify(
          expectedFeed: expectedFeed,
          expectedPapers: expectedPapers,
          expectedProcessing: expectedProcessing,
          expectedIntroductions: expectedIntroductions,
          expectedConnections: expectedConnections,
          expectedChats: expectedChats,
          sessionId: sessionId,
          now: now,
        );
        if (!_bulkPreferencesMatch(sourcePreferences)) {
          throw StateError(
            'Legacy source preferences changed before migration completion',
          );
        }
        if (expectedChats.isNotEmpty &&
            _readCanonicalAnonymousSession(preferences) != sessionId) {
          throw StateError(
            'Anonymous session changed before legacy chat migration completed',
          );
        }
        await database.putMetadata(
          legacyPreferencesImportMarker,
          true,
          updatedAt: now,
        );
      });

      final removed = await _removeBulkPreferenceKeys(sourcePreferences);
      final stats = LegacyImportStats(
        didRun: true,
        feedRows: feedRows,
        paperRows: paperRows,
        processingRows: processingRows,
        introductionRows: introductionRows,
        connectionRows: connectionRows,
        chatRows: chatRows,
        policyDiscardedRows: policyDiscardedRows,
        unboundRows: unboundRows,
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

  _LegacySnapshot _readSnapshot(Map<String, Object> sourcePreferences) {
    FeedPage? feed;
    var invalidRows = 0;
    final feedJson = _decodeMap(sourcePreferences[feedKey]);
    if (feedJson != null) {
      try {
        feed = FeedPage.fromJson(feedJson);
      } on Object {
        invalidRows += 1;
      }
    } else if (sourcePreferences.containsKey(feedKey)) {
      invalidRows += 1;
    }

    final papers = <String, PaperSummary>{};
    final processing = <String, _LegacyProcessing>{};
    final introductions = <String, _LegacyIntroduction>{};
    final connections = <String, _LegacyConnections>{};
    final chats = <String, _LegacyChat>{};
    for (final entry in sourcePreferences.entries) {
      final key = entry.key;
      if (key == feedKey) continue;
      final parsed = _decodeMap(entry.value);
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
          processing[key] = _LegacyProcessing(
            value: value,
            explicitGeneration: _explicitPositiveGeneration(parsed),
          );
        } else if (key.startsWith(bulkPrefixes[2])) {
          final value = PaperIntroduction.fromJson(parsed);
          if (value.paperId.isEmpty ||
              !_idMatchesKey(key, bulkPrefixes[2], value.paperId)) {
            throw const FormatException('Introduction key mismatch');
          }
          introductions[key] = _LegacyIntroduction(
            value: value,
            explicitGeneration: _explicitPositiveGeneration(parsed),
          );
        } else if (key.startsWith(bulkPrefixes[3])) {
          final value = PaperConnections.fromJson(parsed);
          if (value.paperId.isEmpty ||
              !_idMatchesKey(key, bulkPrefixes[3], value.paperId)) {
            throw const FormatException('Connections key mismatch');
          }
          connections[key] = _LegacyConnections(
            value: value,
            explicitGeneration: _explicitPositiveGeneration(parsed),
          );
        } else if (key.startsWith(bulkPrefixes[4])) {
          final readerKey = _decodeKeyId(key, bulkPrefixes[4]);
          if (readerKey == null || readerKey.isEmpty) {
            throw const FormatException('Chat key mismatch');
          }
          chats[key] = _LegacyChat(
            readerKey: readerKey,
            value: ChatSnapshot.fromJson(parsed),
            explicitGeneration: _explicitPositiveGeneration(parsed),
            explicitSessionId: _explicitBoundedString(parsed, 'session_id'),
            explicitPaperId: _explicitBoundedString(parsed, 'paper_id'),
            explicitArxivId: _explicitBoundedString(parsed, 'arxiv_id'),
          );
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
    required FeedPage? expectedFeed,
    required Map<String, PaperSummary> expectedPapers,
    required Map<String, PaperProcessingState> expectedProcessing,
    required Map<String, PaperIntroduction> expectedIntroductions,
    required Map<String, PaperConnections> expectedConnections,
    required Map<String, ChatSnapshot> expectedChats,
    required String sessionId,
    required DateTime now,
  }) async {
    for (final expected in expectedPapers.values) {
      final stored = await _papers.load(expected.paperId, touch: false);
      if (stored == null ||
          stored.arxivBaseId.toLowerCase() !=
              expected.arxivBaseId.toLowerCase() ||
          _isNewerPaper(expected, stored) ||
          (!_isNewerPaper(stored, expected) &&
              !_samePayload(stored.toJson(), expected.toJson()))) {
        throw StateError('Legacy paper cache verification failed');
      }
    }
    if (expectedFeed != null) {
      final feed = await _feeds.loadPage(
        feedQueryKey(limit: cachePolicy.remotePageSize),
      );
      if (feed == null || !_feedMatches(feed, expectedFeed)) {
        throw StateError('Legacy feed cache verification failed');
      }
    }
    for (final expected in expectedProcessing.values) {
      final stored = await _derived.loadProcessing(expected.paperId);
      if (!_samePayload(stored?.toJson(), expected.toJson())) {
        throw StateError('Legacy processing cache verification failed');
      }
    }
    for (final expected in expectedIntroductions.values) {
      final stored = await _derived.loadIntroduction(expected.paperId);
      if (!_samePayload(stored?.toJson(), expected.toJson())) {
        throw StateError('Legacy Introduction cache verification failed');
      }
    }
    for (final expected in expectedConnections.values) {
      final stored = await _derived.loadConnections(expected.paperId);
      if (!_samePayload(stored?.toJson(), expected.toJson())) {
        throw StateError('Legacy Connections cache verification failed');
      }
    }
    for (final entry in expectedChats.entries) {
      final stored = await _derived.loadChat(
        entry.key,
        sessionId: sessionId,
        now: now,
      );
      if (!_samePayload(stored?.toJson(), entry.value.toJson())) {
        throw StateError('Legacy chat cache verification failed');
      }
    }
  }

  bool _samePayload(
    Map<String, dynamic>? stored,
    Map<String, dynamic> expected,
  ) => stored != null && jsonEncode(stored) == jsonEncode(expected);

  bool _feedMatches(FeedPage stored, FeedPage expected) {
    if (stored.nextCursor != expected.nextCursor ||
        stored.items.length != expected.items.length) {
      return false;
    }
    for (var index = 0; index < expected.items.length; index += 1) {
      final expectedPaper = expected.items[index];
      final storedPaper = stored.items[index];
      if (storedPaper.paperId != expectedPaper.paperId ||
          storedPaper.arxivBaseId.toLowerCase() !=
              expectedPaper.arxivBaseId.toLowerCase() ||
          _isNewerPaper(expectedPaper, storedPaper) ||
          (!_isNewerPaper(storedPaper, expectedPaper) &&
              !_samePayload(storedPaper.toJson(), expectedPaper.toJson()))) {
        return false;
      }
    }
    return true;
  }

  Map<String, PaperVersionKey> _trustedVersions(
    _LegacySnapshot snapshot,
    Map<String, PaperSummary> latestPapers,
  ) {
    final trusted = <String, PaperVersionKey>{};
    // A legacy derived key contains only a stable paper id. It is safe to bind
    // only when the previous store also contains that individual paper and it
    // is the exact metadata version selected for import. A newer feed entry
    // must never lend its version to older derived content.
    for (final paper in snapshot.papers.values) {
      final latest = latestPapers[paper.paperId];
      if (latest != null && _sameArxivVersion(latest.arxivId, paper.arxivId)) {
        trusted[paper.paperId] = latest.versionKey;
      }
    }
    return trusted;
  }

  PaperVersionKey? _trustedChatVersion(
    String readerKey,
    Map<String, PaperVersionKey> trustedVersions,
    Map<String, PaperVersionKey> trustedRouteVersions,
  ) {
    final segments = readerKey.split(':');
    if (segments.length != 3 ||
        (segments.first != 'feed' && segments.first != 'route')) {
      return null;
    }
    final readerArxiv = ArxivIdentifier.tryParse(segments[2]);
    if (readerArxiv == null) return null;
    if (segments.first == 'feed') {
      final version = trustedVersions[segments[1]];
      return version != null &&
              readerKey == 'feed:${version.paperId}:${version.arxivId}'
          ? version
          : null;
    }
    return trustedRouteVersions[readerKey];
  }

  Map<String, PaperVersionKey> _trustedRouteVersions(
    Map<String, PaperVersionKey> trustedVersions,
  ) {
    final raw = _decodeMap(_preMigrationRestorationJson);
    if (raw == null) return const {};
    try {
      final state = AppRestorationState.fromJson(raw);
      final routes = <String, PaperVersionKey>{};
      for (final route in state.routeStack) {
        final version = trustedVersions[route.paper.paperId];
        if (route.routeId.isEmpty ||
            version == null ||
            !_sameArxivVersion(version.arxivId, route.paper.arxivId)) {
          continue;
        }
        final readerKey = route.readerKey;
        if (routes.containsKey(readerKey)) return const {};
        routes[readerKey] = version;
      }
      return routes;
    } on Object {
      return const {};
    }
  }

  bool _sameArxivVersion(String left, String right) {
    final leftId = ArxivIdentifier.tryParse(left);
    final rightId = ArxivIdentifier.tryParse(right);
    return leftId != null &&
        rightId != null &&
        leftId.version != null &&
        rightId.version != null &&
        leftId.baseId.toLowerCase() == rightId.baseId.toLowerCase() &&
        leftId.version == rightId.version;
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

  int? _explicitPositiveGeneration(Map<String, dynamic> json) {
    final value = json['generation'];
    return value is int && value > 0 ? value : null;
  }

  String? _explicitBoundedString(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is String &&
            value.isNotEmpty &&
            value.length <= 512 &&
            value.trim() == value
        ? value
        : null;
  }

  Map<String, Object> _captureBulkPreferences() {
    final keys = preferences.getKeys().where(_isBulkKey).toSet();
    final values = <String, Object>{};
    for (final key in keys) {
      final value = preferences.get(key);
      if (value == null || !preferences.containsKey(key)) {
        throw StateError('Legacy source preferences changed while reading');
      }
      values[key] = _copyPreferenceValue(value);
    }
    final after = preferences.getKeys().where(_isBulkKey).toSet();
    if (after.length != keys.length || !after.containsAll(keys)) {
      throw StateError('Legacy source preferences changed while reading');
    }
    return Map.unmodifiable(values);
  }

  bool _bulkPreferencesMatch(Map<String, Object> expected) {
    final current = _captureBulkPreferences();
    if (current.length != expected.length) return false;
    for (final entry in expected.entries) {
      if (!current.containsKey(entry.key) ||
          !_samePreferenceValue(current[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  Future<int> _removeBulkPreferenceKeys(Map<String, Object> snapshot) async {
    var removed = 0;
    for (final entry in snapshot.entries) {
      final current = preferences.get(entry.key);
      if (current == null ||
          !_samePreferenceValue(current, entry.value) ||
          !preferences.containsKey(entry.key)) {
        continue;
      }
      if (await preferences.remove(entry.key)) removed += 1;
    }
    return removed;
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    if (raw is! String) return null;
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
      'unbound=${stats.unboundRows} '
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
  final Map<String, _LegacyProcessing> processing;
  final Map<String, _LegacyIntroduction> introductions;
  final Map<String, _LegacyConnections> connections;
  final Map<String, _LegacyChat> chats;
  final int invalidRows;
}

class _LegacyProcessing {
  const _LegacyProcessing({
    required this.value,
    required this.explicitGeneration,
  });

  final PaperProcessingState value;
  final int? explicitGeneration;
}

class _LegacyIntroduction {
  const _LegacyIntroduction({
    required this.value,
    required this.explicitGeneration,
  });

  final PaperIntroduction value;
  final int? explicitGeneration;
}

class _LegacyConnections {
  const _LegacyConnections({
    required this.value,
    required this.explicitGeneration,
  });

  final PaperConnections value;
  final int? explicitGeneration;
}

class _LegacyChat {
  const _LegacyChat({
    required this.readerKey,
    required this.value,
    required this.explicitGeneration,
    required this.explicitSessionId,
    required this.explicitPaperId,
    required this.explicitArxivId,
  });

  final String readerKey;
  final ChatSnapshot value;
  final int? explicitGeneration;
  final String? explicitSessionId;
  final String? explicitPaperId;
  final String? explicitArxivId;
}
