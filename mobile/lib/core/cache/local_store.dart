import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import '../models/reader_state.dart';

abstract interface class LocalStore {
  Future<String> getOrCreateSessionId();
  Future<String> rotateAnonymousSession();
  Future<AppRestorationState> loadRestoration();
  Future<void> saveRestoration(AppRestorationState value);

  Future<FeedPage?> loadFeed();
  Future<void> saveFeed(FeedPage value);
  Future<PaperSummary?> loadPaper(String paperId);
  Future<PaperSummary?> findPaperByArxiv(String arxivBaseId);
  Future<void> savePaper(PaperSummary value);
  Future<void> clearDerived(String paperId);
  Future<PaperProcessingState?> loadProcessing(String paperId);
  Future<void> saveProcessing(PaperProcessingState value);
  Future<PaperIntroduction?> loadIntroduction(String paperId);
  Future<void> saveIntroduction(PaperIntroduction value);
  Future<PaperConnections?> loadConnections(String paperId);
  Future<void> saveConnections(PaperConnections value);
  Future<ChatSnapshot?> loadChat(String readerKey);
  Future<void> saveChat(String readerKey, ChatSnapshot value);
}

class SharedPreferencesLocalStore implements LocalStore {
  SharedPreferencesLocalStore._(this._preferences);

  final SharedPreferences _preferences;
  static const _sessionKey = 'pakperk.session.v1';
  static const _restorationKey = 'pakperk.restoration.v2';
  static const _feedKey = 'pakperk.feed.v1';

  static Future<SharedPreferencesLocalStore> create() async =>
      SharedPreferencesLocalStore._(await SharedPreferences.getInstance());

  /// Removes rebuildable public reading data while preserving the anonymous
  /// identity and lightweight navigation restoration record.
  static Future<void> repairPublicCache() async {
    final preferences = await SharedPreferences.getInstance();
    const rebuildablePrefixes = [
      'pakperk.feed.',
      'pakperk.paper.',
      'pakperk.processing.',
      'pakperk.introduction.',
      'pakperk.connections.',
      'pakperk.chat.',
    ];
    final keys = preferences
        .getKeys()
        .where(
          (key) => rebuildablePrefixes.any(key.startsWith),
        )
        .toList(growable: false);
    for (final key in keys) {
      await preferences.remove(key);
    }
  }

  @override
  Future<String> getOrCreateSessionId() async {
    final existing = _preferences.getString(_sessionKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _preferences.setString(_sessionKey, created);
    return created;
  }

  @override
  Future<String> rotateAnonymousSession() async {
    final created = const Uuid().v4();
    await _preferences.setString(_sessionKey, created);

    for (final key in _preferences.getKeys().where(
          (key) => key.startsWith('pakperk.chat.v1.'),
        )) {
      await _preferences.remove(key);
    }

    final restoration = await loadRestoration();
    await saveRestoration(_withoutAnonymousChat(restoration));
    return created;
  }

  @override
  Future<AppRestorationState> loadRestoration() async {
    final json = _readMap(_restorationKey);
    if (json == null) return const AppRestorationState();
    try {
      return AppRestorationState.fromJson(json);
    } on Object {
      return const AppRestorationState();
    }
  }

  @override
  Future<void> saveRestoration(AppRestorationState value) =>
      _writeMap(_restorationKey, value.toJson());

  @override
  Future<FeedPage?> loadFeed() async {
    final json = _readMap(_feedKey);
    return json == null ? null : FeedPage.fromJson(json);
  }

  @override
  Future<void> saveFeed(FeedPage value) => _writeMap(_feedKey, value.toJson());

  @override
  Future<PaperSummary?> loadPaper(String paperId) async {
    final json = _readMap(_key('paper', paperId));
    return json == null ? null : PaperSummary.fromJson(json);
  }

  @override
  Future<PaperSummary?> findPaperByArxiv(String arxivBaseId) async {
    final target = arxivBaseId.toLowerCase();
    PaperSummary? latest;
    for (final key in _preferences.getKeys().where(
          (value) => value.startsWith('pakperk.paper.v1.'),
        )) {
      final json = _readMap(key);
      if (json == null) continue;
      try {
        final paper = PaperSummary.fromJson(json);
        if (paper.arxivBaseId.toLowerCase() != target) continue;
        if (latest == null || paper.updatedAt.isAfter(latest.updatedAt)) {
          latest = paper;
        }
      } on Object {
        // A corrupt cache record cannot make a validated deep link fail.
      }
    }
    return latest;
  }

  @override
  Future<void> savePaper(PaperSummary value) =>
      _writeMap(_key('paper', value.paperId), value.toJson());

  @override
  Future<void> clearDerived(String paperId) async {
    await _preferences.remove(_key('processing', paperId));
    await _preferences.remove(_key('introduction', paperId));
    await _preferences.remove(_key('connections', paperId));
  }

  @override
  Future<PaperProcessingState?> loadProcessing(String paperId) async {
    final json = _readMap(_key('processing', paperId));
    return json == null ? null : PaperProcessingState.fromJson(json);
  }

  @override
  Future<void> saveProcessing(PaperProcessingState value) =>
      _writeMap(_key('processing', value.paperId), value.toJson());

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async {
    final json = _readMap(_key('introduction', paperId));
    return json == null ? null : PaperIntroduction.fromJson(json);
  }

  @override
  Future<void> saveIntroduction(PaperIntroduction value) =>
      _writeMap(_key('introduction', value.paperId), value.toJson());

  @override
  Future<PaperConnections?> loadConnections(String paperId) async {
    final json = _readMap(_key('connections', paperId));
    return json == null ? null : PaperConnections.fromJson(json);
  }

  @override
  Future<void> saveConnections(PaperConnections value) =>
      _writeMap(_key('connections', value.paperId), value.toJson());

  @override
  Future<ChatSnapshot?> loadChat(String readerKey) async {
    final json = _readMap(_key('chat', readerKey));
    return json == null ? null : ChatSnapshot.fromJson(json);
  }

  @override
  Future<void> saveChat(String readerKey, ChatSnapshot value) =>
      _writeMap(_key('chat', readerKey), value.toJson());

  String _key(String kind, String id) =>
      'pakperk.$kind.v1.${base64Url.encode(utf8.encode(id))}';

  Map<String, dynamic>? _readMap(String key) {
    final value = _preferences.getString(key);
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeMap(String key, Map<String, dynamic> value) async {
    await _preferences.setString(key, jsonEncode(value));
  }
}

AppRestorationState _withoutAnonymousChat(AppRestorationState value) =>
    value.copyWith(
      readerStates: value.readerStates.map(
        (key, reader) => MapEntry(
          key,
          reader.copyWith(
            chatSheetOpen: false,
            clearChatThreadId: true,
          ),
        ),
      ),
    );
