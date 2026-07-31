import 'dart:convert';

import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import '../models/reader_state.dart';
import 'restoration_persistence.dart';

typedef PersistRestorationPapers =
    Future<void> Function(Iterable<PaperSummary> papers);
typedef LoadRestorationPaper = Future<PaperSummary?> Function(String paperId);
typedef LoadRestorationFeed = Future<FeedPage?> Function();
typedef NormalizeRestorationPaper = PaperSummary Function(PaperSummary paper);

/// Bridges compact SharedPreferences restoration with full Drift paper rows.
///
/// Writes are serialized in call order. Every referenced paper is committed to
/// Drift before its compact reference can become durable in preferences.
class DriftRestorationPersistence {
  factory DriftRestorationPersistence({
    required RestorationPreferences preferences,
    required PersistRestorationPapers persistPapers,
    required LoadRestorationPaper loadPaper,
    LoadRestorationFeed? loadFeed,
    NormalizeRestorationPaper? normalizePaper,
  }) => DriftRestorationPersistence._(
    preferences,
    persistPapers,
    loadPaper,
    loadFeed,
    normalizePaper ?? _identityPaper,
  );

  DriftRestorationPersistence._(
    this._preferences,
    this._persistPapers,
    this._loadPaper,
    this._loadFeed,
    this._normalizePaper,
  );

  final RestorationPreferences _preferences;
  final PersistRestorationPapers _persistPapers;
  final LoadRestorationPaper _loadPaper;
  final LoadRestorationFeed? _loadFeed;
  final NormalizeRestorationPaper _normalizePaper;
  Future<void> _writeTail = Future.value();

  Future<AppRestorationState> load() async {
    await _writeTail;
    final compact = _preferences.loadCompact();
    if (compact != null) {
      final routes = await _hydrate(compact.routeReferences);
      var hydrated = _withoutUnrestorableRouteReaders(
        compact.hydrate(routes),
        expectedRoutes: compact.routeReferences,
      );
      hydrated = await _rebaseFeed(hydrated);
      if (!_recordMatchesState(compact, hydrated)) {
        await _rewriteWithoutBlockingStartup(hydrated);
      } else {
        await _removeLegacyWithoutBlockingStartup();
      }
      return hydrated;
    }

    final legacy = _preferences.loadLegacy();
    if (legacy == null) return const AppRestorationState();
    final normalizedLegacy = _normalizeState(legacy);
    try {
      return await _persist(normalizedLegacy);
    } on Object {
      // Conversion is best effort: retain the legacy key for a later retry and
      // keep optional navigation restoration from blocking startup.
      return normalizedLegacy;
    }
  }

  Future<void> save(AppRestorationState value) {
    final operation = _writeTail.then((_) async {
      await _persist(value);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> waitForWrites() => _writeTail;

  Future<AppRestorationState> _persist(AppRestorationState value) async {
    final normalized = _normalizeState(value);
    await _persistPapers(normalized.routeStack.map((entry) => entry.paper));
    final requested = normalized.routeStack
        .map(PersistedPaperRouteReference.fromEntry)
        .toList(growable: false);
    final routes = await _hydrate(requested);
    var hydrated = _withoutUnrestorableRouteReaders(
      normalized.copyWith(routeStack: routes),
      expectedRoutes: requested,
    );
    hydrated = await _validateFeedReference(hydrated);
    hydrated = await _rebaseFeed(hydrated);
    final compact = CompactRestorationRecord.fromState(hydrated);
    await _saveCompactVerified(compact);
    await _preferences.removeLegacy();
    return hydrated;
  }

  Future<void> _saveCompactVerified(CompactRestorationRecord compact) async {
    await _preferences.saveCompact(compact);
    final verified = _preferences.loadCompact();
    if (verified == null ||
        jsonEncode(verified.toJson()) != jsonEncode(compact.toJson())) {
      throw StateError('Compact navigation restoration verification failed.');
    }
  }

  AppRestorationState _normalizeState(AppRestorationState value) =>
      value.copyWith(
        routeStack: value.routeStack
            .map(
              (entry) => PaperRouteEntry(
                routeId: entry.routeId,
                paper: _normalizePaper(entry.paper),
              ),
            )
            .toList(growable: false),
      );

  Future<List<PaperRouteEntry>> _hydrate(
    Iterable<PersistedPaperRouteReference> references,
  ) async {
    final routes = <PaperRouteEntry>[];
    final routeIds = <String>{};
    for (final reference in references) {
      if (!routeIds.add(reference.routeId)) continue;
      PaperSummary? paper;
      try {
        paper = await _loadPaper(reference.paperId);
      } on Object {
        // One unreadable cache row must not prevent restoration startup.
        continue;
      }
      if (paper == null || !_matchesReference(reference, paper)) continue;
      routes.add(PaperRouteEntry(routeId: reference.routeId, paper: paper));
    }
    return List.unmodifiable(routes);
  }

  Future<AppRestorationState> _validateFeedReference(
    AppRestorationState value,
  ) async {
    final paperId = value.feedPaperId;
    final arxivId = value.feedArxivId;
    if (paperId == null || arxivId == null) return value;
    PaperSummary? paper;
    try {
      paper = await _loadPaper(paperId);
    } on Object {
      return value.copyWith(clearFeedPaperReference: true);
    }
    if (paper == null || !_matchesPaper(paperId, arxivId, paper)) {
      return value.copyWith(clearFeedPaperReference: true);
    }
    return value.copyWith(
      feedPaperId: paper.paperId,
      feedArxivId: paper.arxivId,
    );
  }

  Future<AppRestorationState> _rebaseFeed(AppRestorationState value) async {
    final paperId = value.feedPaperId;
    final arxivId = value.feedArxivId;
    final loadFeed = _loadFeed;
    if (paperId == null || arxivId == null || loadFeed == null) return value;
    FeedPage? page;
    try {
      page = await loadFeed();
    } on Object {
      return value;
    }
    if (page == null || page.items.isEmpty) return value;
    for (var index = 0; index < page.items.length; index += 1) {
      final paper = page.items[index];
      if (_matchesPaper(paperId, arxivId, paper)) {
        return value.copyWith(
          feedIndex: index,
          feedPaperId: paper.paperId,
          feedArxivId: paper.arxivId,
        );
      }
    }
    return value.copyWith(
      feedIndex: value.feedIndex.clamp(0, page.items.length - 1).toInt(),
      clearFeedPaperReference: true,
    );
  }

  Future<void> _rewriteWithoutBlockingStartup(AppRestorationState value) async {
    try {
      await _saveCompactVerified(CompactRestorationRecord.fromState(value));
      await _preferences.removeLegacy();
    } on Object {
      // The hydrated in-memory state remains usable. A later save retries the
      // compact cleanup without turning stale restoration into a boot failure.
    }
  }

  Future<void> _removeLegacyWithoutBlockingStartup() async {
    try {
      await _preferences.removeLegacy();
    } on Object {
      // The verified compact record is authoritative; cleanup retries later.
    }
  }
}

PaperSummary _identityPaper(PaperSummary paper) => paper;

AppRestorationState clearAnonymousChatRestoration(AppRestorationState value) =>
    value.copyWith(
      readerStates: value.readerStates.map(
        (key, reader) => MapEntry(
          key,
          reader.copyWith(chatSheetOpen: false, clearChatThreadId: true),
        ),
      ),
    );

bool _matchesReference(
  PersistedPaperRouteReference reference,
  PaperSummary paper,
) => _matchesPaper(reference.paperId, reference.arxivId, paper);

bool _matchesPaper(String paperId, String arxivId, PaperSummary paper) {
  if (paper.paperId != paperId) return false;
  final expected = ArxivIdentifier.tryParse(arxivId);
  final current = ArxivIdentifier.tryParse(paper.arxivId);
  if (expected == null || current == null) {
    return paper.arxivId == arxivId;
  }
  if (expected.baseId.toLowerCase() != current.baseId.toLowerCase()) {
    return false;
  }
  final expectedVersion = expected.version;
  final currentVersion = current.version;
  if (expectedVersion == null) return true;
  return currentVersion != null && currentVersion >= expectedVersion;
}

bool _recordMatchesState(
  CompactRestorationRecord record,
  AppRestorationState state,
) {
  final references = record.routeReferences;
  final routes = state.routeStack;
  if (references.length != routes.length) return false;
  for (var index = 0; index < routes.length; index += 1) {
    final reference = references[index];
    final route = routes[index];
    if (reference.routeId != route.routeId ||
        reference.paperId != route.paper.paperId ||
        reference.arxivId != route.paper.arxivId) {
      return false;
    }
  }
  return record.feedIndex == state.feedIndex &&
      record.feedReference?.paperId == state.feedPaperId &&
      record.feedReference?.arxivId == state.feedArxivId;
}

AppRestorationState _withoutUnrestorableRouteReaders(
  AppRestorationState value, {
  required Iterable<PersistedPaperRouteReference> expectedRoutes,
}) {
  final expectedRouteIds = expectedRoutes.map((route) => route.routeId).toSet();
  final restoredReaderKeys = {
    for (final route in value.routeStack) route.readerKey,
  };
  final readers = Map<String, ReaderNavigationState>.from(value.readerStates)
    ..removeWhere((key, _) {
      for (final routeId in expectedRouteIds) {
        if (key.startsWith('route:$routeId:')) {
          return !restoredReaderKeys.contains(key);
        }
      }
      return false;
    });
  return value.copyWith(readerStates: Map.unmodifiable(readers));
}
