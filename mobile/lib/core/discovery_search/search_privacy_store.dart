import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/paper.dart';

const searchPrivacyPreferencesPrefix = 'pakperk.search.private.v1.';

enum PrivateSearchHistoryMode { lookup, explore }

final class PrivateSearchHistoryEntry {
  PrivateSearchHistoryEntry({
    required String query,
    required this.mode,
    required this.searchedAt,
  }) : query = _normalizedQuery(query) {
    if (!searchedAt.isUtc) {
      throw ArgumentError('Search-history timestamps must be UTC.');
    }
  }

  final String query;
  final PrivateSearchHistoryMode mode;
  final DateTime searchedAt;

  Map<String, Object?> toJson() => {
    'query': query,
    'mode': mode.name,
    'searched_at': searchedAt.toIso8601String(),
  };

  factory PrivateSearchHistoryEntry.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'query', 'mode', 'searched_at'});
    return PrivateSearchHistoryEntry(
      query: _requiredText(json['query'], maximumLength: 300),
      mode: switch (json['mode']) {
        'lookup' => PrivateSearchHistoryMode.lookup,
        'explore' => PrivateSearchHistoryMode.explore,
        _ => throw const FormatException('Invalid search-history mode.'),
      },
      searchedAt: _utcTimestamp(json['searched_at']),
    );
  }
}

final class PrivateSearchHistorySnapshot {
  PrivateSearchHistorySnapshot({
    required this.enabled,
    required Iterable<PrivateSearchHistoryEntry> entries,
  }) : entries = List<PrivateSearchHistoryEntry>.unmodifiable(entries) {
    if (this.entries.length > maximumEntries ||
        (!enabled && this.entries.isNotEmpty)) {
      throw ArgumentError('Invalid private search-history snapshot.');
    }
  }

  factory PrivateSearchHistorySnapshot.disabled() =>
      PrivateSearchHistorySnapshot(enabled: false, entries: const []);

  static const maximumEntries = 20;
  static const retention = Duration(days: 30);

  final bool enabled;
  final List<PrivateSearchHistoryEntry> entries;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'enabled': enabled,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  factory PrivateSearchHistorySnapshot.fromJson(
    Map<String, dynamic> json, {
    required DateTime now,
  }) {
    _exactKeys(json, const {'schema', 'enabled', 'entries'});
    final enabled = json['enabled'];
    final rawEntries = json['entries'];
    if (json['schema'] != 1 ||
        enabled is! bool ||
        rawEntries is! List ||
        rawEntries.length > maximumEntries) {
      throw const FormatException('Invalid private search-history snapshot.');
    }
    if (!enabled && rawEntries.isNotEmpty) {
      throw const FormatException('Disabled search history retained queries.');
    }
    final cutoff = now.toUtc().subtract(retention);
    final entries = rawEntries
        .map(
          (value) => value is Map
              ? PrivateSearchHistoryEntry.fromJson(
                  Map<String, dynamic>.from(value),
                )
              : throw const FormatException('Invalid search-history entry.'),
        )
        .where((entry) => entry.searchedAt.isAfter(cutoff))
        .toList(growable: false);
    return PrivateSearchHistorySnapshot(enabled: enabled, entries: entries);
  }
}

/// Typed Explore content addressed only by a SHA-256 query/filter fingerprint.
///
/// The raw query is deliberately absent from this envelope as well as its
/// preference key. This is a derived search result, never queue authority.
final class ExploreSearchCacheEntry {
  ExploreSearchCacheEntry({
    required this.queryFingerprint,
    required Iterable<PaperSummary> papers,
    required this.coverageLabel,
    required this.disclaimer,
    required this.cachedAt,
    required this.expiresAt,
  }) : papers = List<PaperSummary>.unmodifiable(papers) {
    _validateFingerprint(queryFingerprint);
    if (this.papers.isEmpty ||
        this.papers.length > maximumPapers ||
        coverageLabel.isEmpty ||
        coverageLabel.length > 300 ||
        disclaimer.isEmpty ||
        disclaimer.length > 600 ||
        !cachedAt.isUtc ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(cachedAt) ||
        expiresAt.difference(cachedAt) > maximumRetention) {
      throw ArgumentError('Invalid Explore search cache entry.');
    }
  }

  static const maximumPapers = 50;
  static const maximumRetention = Duration(hours: 1);

  final String queryFingerprint;
  final List<PaperSummary> papers;
  final String coverageLabel;
  final String disclaimer;
  final DateTime cachedAt;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now.toUtc());

  Map<String, Object?> toJson() => {
    'schema': 1,
    'query_fingerprint': queryFingerprint,
    'papers': papers.map((paper) => paper.toJson()).toList(growable: false),
    'coverage_label': coverageLabel,
    'disclaimer': disclaimer,
    'cached_at': cachedAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
  };

  factory ExploreSearchCacheEntry.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'schema',
      'query_fingerprint',
      'papers',
      'coverage_label',
      'disclaimer',
      'cached_at',
      'expires_at',
    });
    final rawPapers = json['papers'];
    if (json['schema'] != 1 ||
        rawPapers is! List ||
        rawPapers.isEmpty ||
        rawPapers.length > maximumPapers) {
      throw const FormatException('Invalid Explore search cache entry.');
    }
    try {
      return ExploreSearchCacheEntry(
        queryFingerprint: _requiredText(
          json['query_fingerprint'],
          maximumLength: 64,
        ),
        papers: rawPapers.map(
          (value) => value is Map
              ? PaperSummary.fromJson(Map<String, dynamic>.from(value))
              : throw const FormatException('Invalid cached search paper.'),
        ),
        coverageLabel: _requiredText(
          json['coverage_label'],
          maximumLength: 300,
        ),
        disclaimer: _requiredText(json['disclaimer'], maximumLength: 600),
        cachedAt: _utcTimestamp(json['cached_at']),
        expiresAt: _utcTimestamp(json['expires_at']),
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid Explore search cache entry.');
    }
  }
}

abstract interface class SearchPrivacyStore {
  Future<PrivateSearchHistorySnapshot> loadHistory(
    String accountId, {
    DateTime? now,
  });

  Future<void> saveHistory(
    String accountId,
    PrivateSearchHistorySnapshot snapshot,
  );

  Future<ExploreSearchCacheEntry?> loadExplore(
    String accountId,
    String queryFingerprint, {
    DateTime? now,
  });

  Future<void> saveExplore(String accountId, ExploreSearchCacheEntry entry);

  Future<void> clear(String accountId);

  Future<void> clearAll();
}

final class SharedPreferencesSearchPrivacyStore implements SearchPrivacyStore {
  SharedPreferencesSearchPrivacyStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const maximumExploreEntries = 8;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<PrivateSearchHistorySnapshot> loadHistory(
    String accountId, {
    DateTime? now,
  }) async {
    final preferences = await _preferences();
    final key = '${_scopePrefix(accountId)}history';
    final raw = preferences.getString(key);
    if (raw == null) return PrivateSearchHistorySnapshot.disabled();
    late final Map<String, dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) {
        throw const FormatException('Invalid search-history snapshot.');
      }
      decoded = Map<String, dynamic>.from(value);
    } on Object {
      await _removeIfUnchanged(preferences, key, raw);
      return PrivateSearchHistorySnapshot.disabled();
    }
    late final PrivateSearchHistorySnapshot snapshot;
    try {
      snapshot = PrivateSearchHistorySnapshot.fromJson(
        decoded,
        now: now ?? DateTime.now(),
      );
    } on Object {
      await _removeIfUnchanged(preferences, key, raw);
      return PrivateSearchHistorySnapshot.disabled();
    }
    final rawEntries = decoded['entries']! as List<dynamic>;
    if (snapshot.entries.length != rawEntries.length) {
      await _replaceIfUnchanged(
        preferences,
        key,
        raw,
        jsonEncode(snapshot.toJson()),
      );
    }
    return snapshot;
  }

  @override
  Future<void> saveHistory(
    String accountId,
    PrivateSearchHistorySnapshot snapshot,
  ) async {
    final written = await (await _preferences()).setString(
      '${_scopePrefix(accountId)}history',
      jsonEncode(snapshot.toJson()),
    );
    if (!written) {
      throw StateError('Private search history could not be saved.');
    }
  }

  @override
  Future<ExploreSearchCacheEntry?> loadExplore(
    String accountId,
    String queryFingerprint, {
    DateTime? now,
  }) async {
    _validateFingerprint(queryFingerprint);
    final preferences = await _preferences();
    final key = '${_scopePrefix(accountId)}explore.$queryFingerprint';
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid Explore search cache entry.');
      }
      final entry = ExploreSearchCacheEntry.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (entry.queryFingerprint != queryFingerprint ||
          entry.isExpired(now ?? DateTime.now())) {
        await _removeIfUnchanged(preferences, key, raw);
        return null;
      }
      return entry;
    } on Object {
      await _removeIfUnchanged(preferences, key, raw);
      return null;
    }
  }

  @override
  Future<void> saveExplore(
    String accountId,
    ExploreSearchCacheEntry entry,
  ) async {
    final preferences = await _preferences();
    final key = '${_scopePrefix(accountId)}explore.${entry.queryFingerprint}';
    final written = await preferences.setString(
      key,
      jsonEncode(entry.toJson()),
    );
    if (!written) throw StateError('Explore search cache could not be saved.');
    await _pruneExplore(preferences, accountId, now: entry.cachedAt);
  }

  Future<void> _pruneExplore(
    SharedPreferences preferences,
    String accountId, {
    required DateTime now,
  }) async {
    final prefix = '${_scopePrefix(accountId)}explore.';
    final entries = <(String, DateTime)>[];
    for (final key in preferences.getKeys().where(
      (candidate) => candidate.startsWith(prefix),
    )) {
      final raw = preferences.getString(key);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw);
        final entry = ExploreSearchCacheEntry.fromJson(
          Map<String, dynamic>.from(decoded as Map),
        );
        if (entry.isExpired(now)) {
          await _removeIfUnchanged(preferences, key, raw);
          continue;
        }
        entries.add((key, entry.cachedAt));
      } on Object {
        await _removeIfUnchanged(preferences, key, raw);
      }
    }
    entries.sort((left, right) => right.$2.compareTo(left.$2));
    for (final stale in entries.skip(maximumExploreEntries)) {
      await _remove(preferences, stale.$1);
    }
  }

  @override
  Future<void> clear(String accountId) async {
    final preferences = await _preferences();
    final prefix = _scopePrefix(accountId);
    for (final key
        in preferences
            .getKeys()
            .where((candidate) => candidate.startsWith(prefix))
            .toList(growable: false)) {
      await _remove(preferences, key);
    }
  }

  @override
  Future<void> clearAll() async {
    final preferences = await _preferences();
    for (final key
        in preferences
            .getKeys()
            .where(
              (candidate) =>
                  candidate.startsWith(searchPrivacyPreferencesPrefix),
            )
            .toList(growable: false)) {
      await _remove(preferences, key);
    }
  }
}

String searchPrivacyScopeFingerprint(String accountId) {
  _validateAccountId(accountId);
  return sha256.convert(utf8.encode(accountId)).toString();
}

String exploreSearchCacheFingerprint({
  required String query,
  required Iterable<String> categories,
  required Iterable<String> topics,
  required String sort,
  required String? publishedAfter,
  required String? publishedBefore,
}) {
  final normalizedCategories =
      categories
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  final normalizedTopics =
      topics
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  final canonical = jsonEncode({
    'schema': 1,
    'source': 'arxiv',
    'query': _normalizedQuery(query).toLowerCase(),
    'categories': normalizedCategories,
    'topics': normalizedTopics,
    'sort': sort,
    'published_after': publishedAfter,
    'published_before': publishedBefore,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _scopePrefix(String accountId) =>
    '$searchPrivacyPreferencesPrefix${searchPrivacyScopeFingerprint(accountId)}.';

String _normalizedQuery(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.runes.length > 300) {
    throw ArgumentError.value(value, 'query', 'Invalid search query.');
  }
  return normalized;
}

void _validateAccountId(String accountId) {
  if (accountId.isEmpty ||
      accountId.length > 128 ||
      accountId.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(accountId, 'accountId', 'Invalid account scope.');
  }
}

void _validateFingerprint(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'queryFingerprint');
  }
}

String _requiredText(Object? value, {required int maximumLength}) {
  if (value is! String ||
      value.isEmpty ||
      value.runes.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20 && rune != 0x09)) {
    throw const FormatException('Invalid private search text.');
  }
  return value;
}

DateTime _utcTimestamp(Object? value) {
  if (value is! String || value.length > 64 || !value.endsWith('Z')) {
    throw const FormatException('Invalid private search timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw const FormatException('Invalid private search timestamp.');
  }
  return parsed.toUtc();
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected private search cache shape.');
  }
}

Future<void> _remove(SharedPreferences preferences, String key) async {
  final removed = await preferences.remove(key);
  if (!removed && preferences.containsKey(key)) {
    throw StateError('Private search data could not be cleared.');
  }
}

Future<void> _removeIfUnchanged(
  SharedPreferences preferences,
  String key,
  String expected,
) async {
  if (preferences.getString(key) != expected) return;
  await _remove(preferences, key);
}

Future<void> _replaceIfUnchanged(
  SharedPreferences preferences,
  String key,
  String expected,
  String replacement,
) async {
  if (preferences.getString(key) != expected) return;
  final written = await preferences.setString(key, replacement);
  if (!written) {
    throw StateError('Private search data could not be compacted.');
  }
}
