import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/paper.dart';

const libraryHistoryPreferencesPrefix = 'pakperk.library.history.v1.';

final class LibraryHistoryEntry {
  const LibraryHistoryEntry({required this.paper, required this.openedAt});

  final PaperSummary paper;
  final DateTime openedAt;

  Map<String, Object?> toJson() => {
    'paper': paper.toJson(),
    'opened_at': openedAt.toUtc().toIso8601String(),
  };

  factory LibraryHistoryEntry.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(const {'paper', 'opened_at'}).isNotEmpty ||
        json['paper'] is! Map) {
      throw const FormatException('Invalid library history entry.');
    }
    final openedAt = DateTime.tryParse(json['opened_at']?.toString() ?? '');
    if (openedAt == null) {
      throw const FormatException('Invalid library history timestamp.');
    }
    return LibraryHistoryEntry(
      paper: PaperSummary.fromJson(
        Map<String, dynamic>.from(json['paper']! as Map),
      ),
      openedAt: openedAt.toUtc(),
    );
  }
}

final class LibraryHistorySnapshot {
  LibraryHistorySnapshot({
    required this.enabled,
    Iterable<LibraryHistoryEntry> entries = const [],
  }) : entries = List.unmodifiable(entries.take(100));

  const LibraryHistorySnapshot.disabled() : enabled = false, entries = const [];

  final bool enabled;
  final List<LibraryHistoryEntry> entries;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'enabled': enabled,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  factory LibraryHistorySnapshot.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(const {
          'schema',
          'enabled',
          'entries',
        }).isNotEmpty ||
        json['schema'] != 1 ||
        json['enabled'] is! bool ||
        json['entries'] is! List) {
      throw const FormatException('Invalid library history.');
    }
    final entries = (json['entries']! as List)
        .map(
          (value) => value is Map
              ? LibraryHistoryEntry.fromJson(Map<String, dynamic>.from(value))
              : throw const FormatException('Invalid library history entry.'),
        )
        .toList(growable: false);
    if (entries.length > 100 ||
        entries.map((entry) => entry.paper.paperId).toSet().length !=
            entries.length) {
      throw const FormatException('Invalid library history bounds.');
    }
    final enabled = json['enabled']! as bool;
    if (!enabled && entries.isNotEmpty) {
      throw const FormatException('Disabled history retained entries.');
    }
    return LibraryHistorySnapshot(enabled: enabled, entries: entries);
  }
}

abstract interface class LibraryHistoryStore {
  Future<LibraryHistorySnapshot> load(String accountId);

  Future<void> save(String accountId, LibraryHistorySnapshot snapshot);

  Future<void> clear(String accountId);

  Future<void> clearAll();
}

final class SharedPreferencesLibraryHistoryStore
    implements LibraryHistoryStore {
  SharedPreferencesLibraryHistoryStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<LibraryHistorySnapshot> load(String accountId) async {
    final key = _key(accountId);
    final raw = (await _preferences()).getString(key);
    if (raw == null) return const LibraryHistorySnapshot.disabled();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const LibraryHistorySnapshot.disabled();
      return LibraryHistorySnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } on Object {
      // History is opt-in. Corrupt state fails closed to disabled and empty.
      return const LibraryHistorySnapshot.disabled();
    }
  }

  @override
  Future<void> save(String accountId, LibraryHistorySnapshot snapshot) async {
    final written = await (await _preferences()).setString(
      _key(accountId),
      jsonEncode(snapshot.toJson()),
    );
    if (!written) throw StateError('Library history could not be saved.');
  }

  @override
  Future<void> clear(String accountId) async {
    final preferences = await _preferences();
    final key = _key(accountId);
    final removed = await preferences.remove(key);
    if (!removed && preferences.containsKey(key)) {
      throw StateError('Library history could not be cleared.');
    }
  }

  @override
  Future<void> clearAll() async {
    final preferences = await _preferences();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(libraryHistoryPreferencesPrefix))
        .toList(growable: false);
    for (final key in keys) {
      final removed = await preferences.remove(key);
      if (!removed && preferences.containsKey(key)) {
        throw StateError('Library history could not be cleared.');
      }
    }
  }
}

String _key(String accountId) {
  if (accountId.isEmpty ||
      accountId.length > 128 ||
      accountId.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(accountId, 'accountId', 'Invalid account scope.');
  }
  return '$libraryHistoryPreferencesPrefix$accountId';
}
