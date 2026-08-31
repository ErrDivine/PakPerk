import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_feed_models.dart';

const readingFeedPageCachePreferencesPrefix =
    'pakperk.reading_feed.page_cache.v1.';

/// A decoded, expiry-bounded account-private reading-feed representation.
///
/// This is content only. In particular, [page.decision] is retained so cached
/// content can be checked against a fresh decision, but it is never itself
/// treated as evidence that the current queue is empty.
final class ReadingFeedCachedPage {
  ReadingFeedCachedPage({
    required this.page,
    required this.requestedRecommendationMode,
    required this.cachedAt,
    required this.expiresAt,
  }) {
    if (!cachedAt.isUtc ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(cachedAt) ||
        expiresAt.difference(cachedAt) > maximumRetention ||
        page.items.isEmpty) {
      throw ArgumentError('Invalid reading-feed cache retention or content.');
    }
    if (page.mode == ReadingFeedServerMode.toRead &&
        requestedRecommendationMode != null) {
      throw ArgumentError('Queue cache cannot carry a recommendation mode.');
    }
    if (page.mode == ReadingFeedServerMode.recommendations &&
        (page.batchId == null ||
            page.batchMetadata == null ||
            page.items.any(
              (item) =>
                  item.recommendation == null ||
                  (requestedRecommendationMode != null &&
                      item.recommendation?.mode != requestedRecommendationMode),
            ))) {
      throw ArgumentError(
        'Recommendation cache requires batch-bound personalized content.',
      );
    }
  }

  static const maximumRetention = Duration(hours: 24);

  final ReadingFeedPage page;
  final ReadingFeedRecommendationMode? requestedRecommendationMode;
  final DateTime cachedAt;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now.toUtc());

  bool matchesLiveRecommendationDecision(
    ReadingFeedPage live, {
    required ReadingFeedRecommendationMode? requestedMode,
  }) =>
      page.mode == ReadingFeedServerMode.recommendations &&
      live.mode == ReadingFeedServerMode.recommendations &&
      live.items.isEmpty &&
      live.decision.queueProvenEmpty &&
      live.decision.activeToReadCount == 0 &&
      page.decision.queueProvenEmpty &&
      page.decision.activeToReadCount == 0 &&
      live.enforcement == page.enforcement &&
      live.decision.policyVersion == page.decision.policyVersion &&
      page.decision.libraryRevision == live.decision.libraryRevision &&
      live.batchId != null &&
      live.batchId == page.batchId &&
      live.batchMetadata != null &&
      live.batchMetadata == page.batchMetadata &&
      requestedRecommendationMode == requestedMode;

  Map<String, Object?> toJson() => {
    'schema': 2,
    'requested_mode': requestedRecommendationMode?.wireValue,
    'cached_at': cachedAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    'page': page.toJson(),
  };

  factory ReadingFeedCachedPage.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'schema',
      'requested_mode',
      'cached_at',
      'expires_at',
      'page',
    });
    if (json['schema'] != 2 || json['page'] is! Map) {
      throw const FormatException('Invalid reading-feed cache envelope.');
    }
    final rawMode = json['requested_mode'];
    final requestedMode = rawMode == null
        ? null
        : ReadingFeedRecommendationMode.parse(rawMode);
    try {
      return ReadingFeedCachedPage(
        page: ReadingFeedPage.fromJson(
          Map<String, dynamic>.from(json['page']! as Map),
        ),
        requestedRecommendationMode: requestedMode,
        cachedAt: _utcTimestamp(json['cached_at']),
        expiresAt: _utcTimestamp(json['expires_at']),
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid reading-feed cache entry.');
    }
  }
}

abstract interface class ReadingFeedPageCache {
  Future<ReadingFeedCachedPage?> loadQueue(String accountId, {DateTime? now});

  Future<ReadingFeedCachedPage?> loadRecommendations(
    String accountId, {
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  });

  Future<void> save(
    String accountId, {
    required ReadingFeedPage page,
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  });

  Future<void> clear(String accountId);

  Future<void> clearAll();
}

final class SharedPreferencesReadingFeedPageCache
    implements ReadingFeedPageCache {
  SharedPreferencesReadingFeedPageCache({
    Future<SharedPreferences> Function()? preferences,
    this.queueTtl = const Duration(hours: 24),
    this.recommendationTtl = const Duration(minutes: 15),
  }) : assert(queueTtl > Duration.zero),
       assert(recommendationTtl > Duration.zero),
       assert(queueTtl <= ReadingFeedCachedPage.maximumRetention),
       assert(recommendationTtl <= ReadingFeedCachedPage.maximumRetention),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;
  final Duration queueTtl;
  final Duration recommendationTtl;

  @override
  Future<ReadingFeedCachedPage?> loadQueue(String accountId, {DateTime? now}) =>
      _load(
        accountId,
        suffix: 'queue',
        expectedMode: null,
        expectedServerMode: ReadingFeedServerMode.toRead,
        now: now,
      );

  @override
  Future<ReadingFeedCachedPage?> loadRecommendations(
    String accountId, {
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  }) => _load(
    accountId,
    suffix: _recommendationSuffix(requestedMode),
    expectedMode: requestedMode,
    expectedServerMode: ReadingFeedServerMode.recommendations,
    now: now,
  );

  Future<ReadingFeedCachedPage?> _load(
    String accountId, {
    required String suffix,
    required ReadingFeedRecommendationMode? expectedMode,
    required ReadingFeedServerMode expectedServerMode,
    DateTime? now,
  }) async {
    final preferences = await _preferences();
    final key = _key(accountId, suffix);
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid reading-feed cache entry.');
      }
      final entry = ReadingFeedCachedPage.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (entry.isExpired(now ?? DateTime.now()) ||
          entry.page.mode != expectedServerMode ||
          entry.requestedRecommendationMode != expectedMode) {
        await _remove(preferences, key);
        return null;
      }
      return entry;
    } on Object {
      // A derived cache is never authoritative. Corruption is discarded rather
      // than converted into an empty queue decision.
      await _remove(preferences, key);
      return null;
    }
  }

  @override
  Future<void> save(
    String accountId, {
    required ReadingFeedPage page,
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  }) async {
    if (page.items.isEmpty ||
        (page.mode == ReadingFeedServerMode.recommendations &&
            page.batchId == null)) {
      return;
    }
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final queue = page.mode == ReadingFeedServerMode.toRead;
    final entry = ReadingFeedCachedPage(
      page: page,
      requestedRecommendationMode: queue ? null : requestedMode,
      cachedAt: effectiveNow,
      expiresAt: effectiveNow.add(queue ? queueTtl : recommendationTtl),
    );
    final suffix = queue ? 'queue' : _recommendationSuffix(requestedMode);
    final written = await (await _preferences()).setString(
      _key(accountId, suffix),
      jsonEncode(entry.toJson()),
    );
    if (!written) throw StateError('Reading-feed cache could not be saved.');
  }

  @override
  Future<void> clear(String accountId) async {
    final preferences = await _preferences();
    final prefix = _scopePrefix(accountId);
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      await _remove(preferences, key);
    }
  }

  @override
  Future<void> clearAll() async {
    final preferences = await _preferences();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(readingFeedPageCachePreferencesPrefix))
        .toList(growable: false);
    for (final key in keys) {
      await _remove(preferences, key);
    }
  }
}

String readingFeedCacheScopeFingerprint(String accountId) {
  _validateAccountId(accountId);
  return sha256.convert(utf8.encode(accountId)).toString();
}

String _scopePrefix(String accountId) =>
    '$readingFeedPageCachePreferencesPrefix'
    '${readingFeedCacheScopeFingerprint(accountId)}.';

String _key(String accountId, String suffix) =>
    '${_scopePrefix(accountId)}$suffix';

String _recommendationSuffix(ReadingFeedRecommendationMode? mode) =>
    'recommendations.${mode?.wireValue ?? 'server_default'}';

Future<void> _remove(SharedPreferences preferences, String key) async {
  final removed = await preferences.remove(key);
  if (!removed && preferences.containsKey(key)) {
    throw StateError('Reading-feed cache could not be cleared.');
  }
}

void _validateAccountId(String accountId) {
  if (accountId.isEmpty ||
      accountId.length > 128 ||
      accountId.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(accountId, 'accountId', 'Invalid account scope.');
  }
}

DateTime _utcTimestamp(Object? value) {
  if (value is! String || value.length > 64 || !value.endsWith('Z')) {
    throw const FormatException('Invalid reading-feed cache timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw const FormatException('Invalid reading-feed cache timestamp.');
  }
  return parsed.toUtc();
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final keys = json.keys.toSet();
  if (keys.difference(expected).isNotEmpty ||
      expected.difference(keys).isNotEmpty) {
    throw const FormatException('Unexpected reading-feed cache shape.');
  }
}
