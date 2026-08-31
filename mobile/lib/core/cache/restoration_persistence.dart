import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_state.dart';

const compactRestorationPreferencesKey = 'pakperk.restoration.drift.v1';
const legacyRestorationPreferencesKey = 'pakperk.restoration.v2';

/// Persistence-side limits matching the navigation controller's runtime
/// restoration bounds. Apply these while decoding so an old or malformed
/// preferences value cannot create an unbounded intermediate state.
const maxDecodedRestorationRouteDepth = 32;
const maxDecodedRestorationReaderStates = 64;

class PersistedFeedPaperReference {
  const PersistedFeedPaperReference({
    required this.paperId,
    required this.arxivId,
  });

  final String paperId;
  final String arxivId;

  static PersistedFeedPaperReference? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final paperId = json['paper_id']?.toString().trim() ?? '';
    final arxivId = json['arxiv_id']?.toString().trim() ?? '';
    if (paperId.isEmpty || arxivId.isEmpty) return null;
    return PersistedFeedPaperReference(paperId: paperId, arxivId: arxivId);
  }

  Map<String, dynamic> toJson() => {'paper_id': paperId, 'arxiv_id': arxivId};
}

/// The only paper data allowed in the small preferences restoration record.
///
/// Full metadata is owned by Drift. The arXiv identifier is retained as a
/// version/identity guard when the reference is hydrated from `cached_papers`.
class PersistedPaperRouteReference {
  const PersistedPaperRouteReference({
    required this.routeId,
    required this.paperId,
    required this.arxivId,
  });

  final String routeId;
  final String paperId;
  final String arxivId;

  factory PersistedPaperRouteReference.fromEntry(PaperRouteEntry entry) =>
      PersistedPaperRouteReference(
        routeId: entry.routeId,
        paperId: entry.paper.paperId,
        arxivId: entry.paper.arxivId,
      );

  static PersistedPaperRouteReference? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final routeId = json['route_id']?.toString().trim() ?? '';
    final paperId = json['paper_id']?.toString().trim() ?? '';
    final arxivId = json['arxiv_id']?.toString().trim() ?? '';
    if (routeId.isEmpty || paperId.isEmpty || arxivId.isEmpty) return null;
    return PersistedPaperRouteReference(
      routeId: routeId,
      paperId: paperId,
      arxivId: arxivId,
    );
  }

  Map<String, dynamic> toJson() => {
    'route_id': routeId,
    'paper_id': paperId,
    'arxiv_id': arxivId,
  };
}

class CompactRestorationRecord {
  const CompactRestorationRecord({
    required this.activeBranchIndex,
    required this.feedIndex,
    required this.feedReference,
    required this.routeReferences,
    required this.readerStates,
  });

  static const format = 'drift_route_refs_v1';

  final int activeBranchIndex;
  final int feedIndex;
  final PersistedFeedPaperReference? feedReference;
  final List<PersistedPaperRouteReference> routeReferences;
  final Map<String, ReaderNavigationState> readerStates;

  factory CompactRestorationRecord.fromState(
    AppRestorationState value, {
    Iterable<PaperRouteEntry>? routes,
  }) => CompactRestorationRecord(
    activeBranchIndex: value.activeBranchIndex,
    feedIndex: value.feedIndex,
    feedReference: value.feedPaperId == null || value.feedArxivId == null
        ? null
        : PersistedFeedPaperReference(
            paperId: value.feedPaperId!,
            arxivId: value.feedArxivId!,
          ),
    routeReferences: (routes ?? value.routeStack)
        .map(PersistedPaperRouteReference.fromEntry)
        .toList(growable: false),
    readerStates: Map<String, ReaderNavigationState>.unmodifiable(
      value.readerStates,
    ),
  );

  static CompactRestorationRecord? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      final json = Map<String, dynamic>.from(value);
      if (json['format'] != format) return null;
      final rawRoutes = json['route_refs'];
      final routes = <PersistedPaperRouteReference>[];
      if (rawRoutes is List) {
        for (final rawRoute in _boundedRouteTail(rawRoutes)) {
          final route = PersistedPaperRouteReference.tryFromJson(rawRoute);
          if (route != null) routes.add(route);
        }
      }
      final feedReference = PersistedFeedPaperReference.tryFromJson(
        json['feed_ref'],
      );
      final routeReaderKeys = {
        for (final route in routes) _routeReaderKey(route),
      };
      return CompactRestorationRecord(
        activeBranchIndex: _safeBranchIndex(json['active_branch_index']),
        feedIndex: _safeFeedIndex(json['feed_index']),
        feedReference: feedReference,
        routeReferences: List.unmodifiable(routes),
        readerStates: _decodeReaderStates(
          json['reader_states'],
          validRouteReaderKeys: routeReaderKeys,
          protectedReaderKeys: {
            ...routeReaderKeys,
            if (feedReference != null) _feedReaderKey(feedReference),
          },
        ),
      );
    } on Object {
      return null;
    }
  }

  AppRestorationState hydrate(Iterable<PaperRouteEntry> routes) =>
      AppRestorationState(
        activeBranchIndex: activeBranchIndex,
        feedIndex: feedIndex,
        feedPaperId: feedReference?.paperId,
        feedArxivId: feedReference?.arxivId,
        routeStack: List<PaperRouteEntry>.unmodifiable(routes),
        readerStates: readerStates,
      );

  Map<String, dynamic> toJson() => {
    'format': format,
    'active_branch_index': activeBranchIndex,
    'feed_index': feedIndex,
    if (feedReference != null) 'feed_ref': feedReference!.toJson(),
    'route_refs': routeReferences
        .map((reference) => reference.toJson())
        .toList(growable: false),
    'reader_states': readerStates.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };
}

/// Reads both the compact Drift-owned record and the previous full-metadata
/// record. Decoding is deliberately content-tolerant because restoration must
/// never block startup.
class RestorationPreferences {
  const RestorationPreferences(this.preferences);

  final SharedPreferences preferences;

  CompactRestorationRecord? loadCompact() {
    final raw = preferences.getString(compactRestorationPreferencesKey);
    if (raw == null) return null;
    try {
      return CompactRestorationRecord.tryFromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  AppRestorationState? loadLegacy() {
    final raw = preferences.getString(legacyRestorationPreferencesKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      final routes = <PaperRouteEntry>[];
      final rawRoutes = json['route_stack'];
      if (rawRoutes is List) {
        for (final rawRoute in _boundedRouteTail(rawRoutes)) {
          if (rawRoute is! Map) continue;
          try {
            final entry = PaperRouteEntry.fromJson(
              Map<String, dynamic>.from(rawRoute),
            );
            if (entry.routeId.isNotEmpty &&
                entry.paper.paperId.isNotEmpty &&
                entry.paper.arxivId.isNotEmpty) {
              routes.add(entry);
            }
          } on Object {
            // One malformed legacy route must not discard other restoration.
          }
        }
      }
      final feedReference = _legacyFeedReference(json);
      final routeReaderKeys = {for (final route in routes) route.readerKey};
      return AppRestorationState(
        activeBranchIndex: _safeBranchIndex(json['active_branch_index']),
        feedIndex: _safeFeedIndex(json['feed_index']),
        feedPaperId: feedReference?.paperId,
        feedArxivId: feedReference?.arxivId,
        routeStack: List.unmodifiable(routes),
        readerStates: _decodeReaderStates(
          json['reader_states'],
          validRouteReaderKeys: routeReaderKeys,
          protectedReaderKeys: {
            ...routeReaderKeys,
            if (feedReference != null) _feedReaderKey(feedReference),
          },
        ),
      );
    } on Object {
      return null;
    }
  }

  Future<void> saveCompact(CompactRestorationRecord value) async {
    final written = await preferences.setString(
      compactRestorationPreferencesKey,
      jsonEncode(value.toJson()),
    );
    if (!written) {
      throw StateError('Failed to persist compact navigation restoration.');
    }
  }

  Future<void> removeLegacy() async {
    final removed = await preferences.remove(legacyRestorationPreferencesKey);
    if (preferences.containsKey(legacyRestorationPreferencesKey) && !removed) {
      throw StateError('Failed to remove legacy navigation restoration.');
    }
  }
}

Map<String, ReaderNavigationState> _decodeReaderStates(
  Object? value, {
  required Set<String> validRouteReaderKeys,
  required Set<String> protectedReaderKeys,
}) {
  if (value is! Map) return const {};
  final readers = <String, ReaderNavigationState>{};
  for (final entry in value.entries) {
    final key = entry.key.toString();
    if (key.isEmpty ||
        entry.value is! Map ||
        (key.startsWith('route:') && !validRouteReaderKeys.contains(key))) {
      continue;
    }
    try {
      readers[key] = ReaderNavigationState.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (readers.length > maxDecodedRestorationReaderStates) {
        String? evictedKey;
        for (final candidate in readers.keys) {
          if (!protectedReaderKeys.contains(candidate)) {
            evictedKey = candidate;
            break;
          }
        }
        if (evictedKey != null) readers.remove(evictedKey);
      }
    } on Object {
      // Reader restoration is independently rebuildable.
    }
  }
  return Map.unmodifiable(readers);
}

Iterable<dynamic> _boundedRouteTail(List<dynamic> routes) sync* {
  final start = routes.length > maxDecodedRestorationRouteDepth
      ? routes.length - maxDecodedRestorationRouteDepth
      : 0;
  for (var index = start; index < routes.length; index += 1) {
    yield routes[index];
  }
}

String _routeReaderKey(PersistedPaperRouteReference route) =>
    'route:${route.routeId}:${route.arxivId}';

String _feedReaderKey(PersistedFeedPaperReference paper) =>
    'feed:${paper.paperId}:${paper.arxivId}';

int _safeBranchIndex(Object? value) {
  final index = value is num ? value.toInt() : 0;
  return AppBranch.fromIndex(index).index;
}

int _safeFeedIndex(Object? value) {
  final index = value is num ? value.toInt() : 0;
  return index < 0 ? 0 : index;
}

PersistedFeedPaperReference? _legacyFeedReference(Map<String, dynamic> json) =>
    PersistedFeedPaperReference.tryFromJson({
      'paper_id': json['feed_paper_id'],
      'arxiv_id': json['feed_arxiv_id'],
    });
