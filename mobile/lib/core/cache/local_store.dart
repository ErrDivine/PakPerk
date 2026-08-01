import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import '../models/processing.dart';
import '../models/reader_state.dart';
import '../settings/appearance.dart';
import 'restoration_persistence.dart';

abstract interface class LocalStore {
  Future<String> getOrCreateSessionId();
  Future<String> rotateAnonymousSession();
  Future<AppRestorationState> loadRestoration();
  Future<void> saveRestoration(AppRestorationState value);
  Future<AppAppearance> loadAppearance();
  Future<void> saveAppearance(AppAppearance value);

  Future<FeedPage?> loadFeed();
  Future<void> saveFeed(FeedPage value);
  Future<PaperSummary?> loadPaper(String paperId);
  Future<PaperSummary?> findPaperByArxiv(String arxivBaseId);

  /// Keeps the newest arXiv version for a stable paper ID. When a newer
  /// version replaces the current row, implementations must invalidate the
  /// prior version's derived records before the new metadata is observable.
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

  /// Deletes every cached comment snapshot during account deletion.
  /// Implementations must not silently succeed if they can retain comments.
  Future<void> purgeAccountDeletionCommentSnapshots();

  /// Removes user-visible local state, including public cache, account rows,
  /// drafts, outbox, anonymous identity, appearance, and restoration.
  ///
  /// Implementations must preserve the independent account-deletion and auth
  /// invalidation guards. Those records prevent a failed secure erase or an
  /// incomplete server deletion from becoming usable again.
  Future<void> clearAllLocalData();
}

/// Optional lifecycle contract for stores that own resources such as a
/// database connection or application lifecycle observer.
///
/// Startup uses this contract to dispose a hydration store that failed or was
/// superseded before its values could be mounted. Lightweight stores with no
/// owned resources do not need to implement it.
abstract interface class CloseableLocalStore {
  Future<void> close();
}

class SharedPreferencesLocalStore implements LocalStore {
  SharedPreferencesLocalStore(this._preferences);

  final SharedPreferences _preferences;
  static const _sessionKey = 'pakperk.session.v1';
  static const _restorationKey = 'pakperk.restoration.v2';
  static const _feedKey = 'pakperk.feed.v1';
  static const _appearanceKey = 'pakperk.appearance.v1';

  static Future<SharedPreferencesLocalStore> create() async =>
      SharedPreferencesLocalStore(await SharedPreferences.getInstance());

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
        .where((key) => rebuildablePrefixes.any(key.startsWith))
        .toList(growable: false);
    for (final key in keys) {
      await preferences.remove(key);
    }
  }

  @override
  Future<void> clearAllLocalData() async {
    const exactKeys = {
      _sessionKey,
      _restorationKey,
      compactRestorationPreferencesKey,
      _feedKey,
      _appearanceKey,
    };
    const rebuildablePrefixes = [
      'pakperk.paper.',
      'pakperk.processing.',
      'pakperk.introduction.',
      'pakperk.connections.',
      'pakperk.chat.',
    ];
    final keys = _preferences
        .getKeys()
        .where(
          (key) =>
              exactKeys.contains(key) ||
              rebuildablePrefixes.any(key.startsWith),
        )
        .toList(growable: false);
    for (final key in keys) {
      final removed = await _preferences.remove(key);
      if (!removed && _preferences.containsKey(key)) {
        throw StateError('Failed to clear local application data.');
      }
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
    for (final key in _preferences.getKeys().where(
      (key) => key.startsWith('pakperk.chat.v1.'),
    )) {
      await _preferences.remove(key);
    }

    final restoration = await loadRestoration();
    await saveRestoration(_withoutAnonymousChat(restoration));
    return rotateAnonymousSessionIdOnly();
  }

  /// Replaces only the anonymous identifier.
  ///
  /// Drift owns chat and compact-restoration cleanup in production, so it
  /// performs those privacy-sensitive writes before calling this method.
  Future<String> rotateAnonymousSessionIdOnly() async {
    final created = const Uuid().v4();
    final written = await _preferences.setString(_sessionKey, created);
    if (!written) throw StateError('Failed to rotate anonymous session.');
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
  Future<AppAppearance> loadAppearance() async =>
      AppAppearance.fromWire(_preferences.getString(_appearanceKey));

  @override
  Future<void> saveAppearance(AppAppearance value) async {
    final written = await _preferences.setString(_appearanceKey, value.name);
    if (!written) throw StateError('Failed to save the appearance setting.');
  }

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
        if (latest == null || _preferPaper(paper, latest)) {
          latest = paper;
        }
      } on Object {
        // A corrupt cache record cannot make a validated deep link fail.
      }
    }
    return latest;
  }

  @override
  Future<void> savePaper(PaperSummary value) async {
    final current = await loadPaper(value.paperId);
    if (current != null && _preferPaper(current, value)) return;
    if (current != null && current.arxivId != value.arxivId) {
      // Clear first: a crash may temporarily lose rebuildable derived data,
      // but can never expose artifacts from the old version as the new one.
      await clearDerived(value.paperId);
      await _clearChatsForArxivVersion(current.arxivId);
    }
    await _writeMap(_key('paper', value.paperId), value.toJson());
  }

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

  @override
  Future<void> purgeAccountDeletionCommentSnapshots() async {
    // This lightweight store has never persisted comment pages. Keeping an
    // explicit implementation makes alternate stores opt into the deletion
    // contract instead of being treated as safe by type inference.
  }

  Future<void> _clearChatsForArxivVersion(String arxivId) async {
    const prefix = 'pakperk.chat.v1.';
    final keys = _preferences
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      try {
        final encoded = key.substring(prefix.length);
        final readerKey = utf8.decode(
          base64Url.decode(base64Url.normalize(encoded)),
        );
        if (readerKey.endsWith(':$arxivId')) {
          await _preferences.remove(key);
        }
      } on Object {
        // Malformed legacy keys are ignored here and removed by cache repair.
      }
    }
  }

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
          reader.copyWith(chatSheetOpen: false, clearChatThreadId: true),
        ),
      ),
    );

bool _preferPaper(PaperSummary candidate, PaperSummary current) {
  if (candidate.arxivBaseId.toLowerCase() !=
      current.arxivBaseId.toLowerCase()) {
    return true;
  }
  final candidateVersion = ArxivIdentifier.tryParse(candidate.arxivId)?.version;
  final currentVersion = ArxivIdentifier.tryParse(current.arxivId)?.version;
  if ((candidateVersion ?? 0) != (currentVersion ?? 0)) {
    return (candidateVersion ?? 0) > (currentVersion ?? 0);
  }
  return candidate.updatedAt.isAfter(current.updatedAt);
}
