import 'dart:async';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/request_cancellation.dart';
import '../cache/demo_asset_store.dart';
import '../cache/feed_cache_persistence.dart';
import '../cache/local_store.dart';
import '../cache/versioned_derived_cache.dart';
import '../content_policy.dart';
import '../models/chat.dart';
import '../models/connections.dart';
import '../models/introduction.dart';
import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import '../models/processing.dart';

enum DataOrigin { network, deviceCache, bundledDemo }

class RepositoryValue<T> {
  const RepositoryValue({
    required this.value,
    required this.origin,
    required this.offline,
    this.persisted = false,
    this.revalidated = false,
  });

  final T value;
  final DataOrigin origin;
  final bool offline;
  final bool persisted;
  final bool revalidated;
  bool get isStale => origin != DataOrigin.network && !revalidated;
}

abstract interface class PaperDataSource {
  Stream<bool> get offlineChanges;
  bool get isOffline;

  Future<RepositoryValue<FeedPage>> getCachedFeed({String? category});
  Future<RepositoryValue<FeedPage>> getFeed({
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  });
  Future<void> cacheFeed(FeedPage value, {bool replaceFeed = true});
  Future<RepositoryValue<PaperSummary>> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  });
  Future<RepositoryValue<PaperSummary>> getPaperByArxiv(
    String arxivId, {
    RequestCancellation? cancellation,
  });
  Future<RepositoryValue<PaperProcessingState>> prepare(
    String paperId, {
    bool retry = false,
    RequestCancellation? cancellation,
  });
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  });
  Future<RepositoryValue<PaperIntroduction>> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  });
  Future<RepositoryValue<PaperConnections>> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  });
  Future<ChatAnswer> sendChat({
    required String paperId,
    required String message,
    String? threadId,
    RequestCancellation? cancellation,
  });
}

class PaperRepository implements PaperDataSource {
  PaperRepository({
    required ApiClient api,
    required LocalStore localStore,
    required DemoContentStore demoContent,
    this.fulltextPolicy = ClientFulltextPolicy.prototype,
  }) : _api = api,
       _localStore = localStore,
       _demoContent = demoContent;

  final ApiClient _api;
  final LocalStore _localStore;
  final DemoContentStore _demoContent;
  final ClientFulltextPolicy fulltextPolicy;
  final StreamController<bool> _offlineController =
      StreamController<bool>.broadcast(sync: true);
  bool _offline = false;

  @override
  bool get isOffline => _offline;

  @override
  Stream<bool> get offlineChanges => _offlineController.stream;

  void dispose() => _offlineController.close();

  @override
  Future<RepositoryValue<FeedPage>> getCachedFeed({String? category}) async {
    return _loadCachedOrDemoFeed(
      category: category,
      limit: defaultFeedPageLimit,
    );
  }

  Future<RepositoryValue<FeedPage>> _loadCachedOrDemoFeed({
    required String? category,
    required int limit,
  }) async {
    final store = _localStore;
    final queryCache = switch (store) {
      FeedCachePersistence cache => cache,
      _ => null,
    };
    final cached = queryCache == null
        ? await store.loadFeed()
        : await queryCache.loadFeedPage(
            feedQueryKey(category: category, limit: limit),
          );
    final categoryQuery = category != null && category.isNotEmpty;
    // An empty category result is authoritative and must stay empty offline.
    // The all-feed path deliberately retains its bundled resilience behavior
    // when a reachable-but-unseeded backend cached an empty first page.
    final useCached =
        cached != null && (cached.items.isNotEmpty || categoryQuery);
    final staleSource = useCached
        ? cached
        : await _demoContent.loadFallbackFeed();
    final source = await _withLatestStoredVersions(staleSource);
    final filtered = category == null || category.isEmpty
        ? source
        : FeedPage(
            items: source.items
                .where(
                  (paper) =>
                      paper.primaryCategory == category ||
                      paper.categories.contains(category),
                )
                .toList(growable: false),
            // A cursor is scoped to its complete query. Preserve it only when
            // the relational cache supplied the exact category snapshot;
            // filtering an all-feed/demo page must never reuse its cursor.
            nextCursor: useCached && queryCache != null
                ? source.nextCursor
                : null,
          );
    return RepositoryValue(
      value: fulltextPolicy.maskCachedFeed(filtered),
      origin: useCached ? DataOrigin.deviceCache : DataOrigin.bundledDemo,
      offline: _offline,
    );
  }

  @override
  Future<RepositoryValue<FeedPage>> getFeed({
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) async {
    try {
      final store = _localStore;
      var persisted = false;
      var revalidated = false;
      DataOrigin origin = DataOrigin.network;
      late FeedPage value;
      if (cursor == null &&
          store is FeedConditionalCache &&
          store is FeedCachePersistence) {
        final conditionalCache = store as FeedConditionalCache;
        final feedCache = store as FeedCachePersistence;
        final queryKey = feedQueryKey(category: category, limit: limit);
        final validator = await conditionalCache.loadFeedValidator(queryKey);
        var response = await _api.getFeedConditional(
          category: category,
          limit: limit,
          ifNoneMatch: validator?.etag,
          cancellation: cancellation,
        );
        if (response.notModified) {
          final cached = await feedCache.loadFeedPage(queryKey);
          // Eviction or a concurrent refresh can invalidate the validator
          // while the conditional request is in flight. A body-less response
          // is usable only when the representation and exact request ETag are
          // still paired after the cache read.
          final currentValidator = await conditionalCache.loadFeedValidator(
            queryKey,
          );
          final validatorStillCurrent =
              validator?.etag != null &&
              currentValidator?.etag == validator?.etag &&
              (response.etag == null || response.etag == validator?.etag);
          if (cached != null && validatorStillCurrent) {
            final refreshedAt = DateTime.now().toUtc();
            await conditionalCache.storeFeedValidator(
              queryKey,
              // A 304 validator is optional. Retain the validator that made
              // this representation conditional when the response omits it.
              etag: response.etag ?? validator?.etag,
              refreshedAt: refreshedAt,
            );
            value = await _withLatestStoredVersions(
              fulltextPolicy.maskCachedFeed(cached),
            );
            persisted = true;
            revalidated = true;
            origin = DataOrigin.deviceCache;
          } else {
            // A validator without its representation is incomplete local
            // state. Repair it with one unconditional request rather than
            // treating a body-less response as an empty feed.
            response = await _api.getFeedConditional(
              category: category,
              limit: limit,
              cancellation: cancellation,
            );
          }
        }
        if (!revalidated) {
          final page = response.page;
          if (page == null) {
            throw const ApiException(
              code: 'UNEXPECTED_NOT_MODIFIED',
              message: 'The feed cache validator could not be repaired.',
              retryable: true,
              statusCode: 502,
            );
          }
          await feedCache.persistFeedPage(
            queryKey: queryKey,
            page: fulltextPolicy.maskCachedFeed(page),
            replace: true,
            category: category,
            etag: response.etag,
            refreshedAt: DateTime.now().toUtc(),
          );
          value = await _withLatestStoredVersions(page);
          persisted = true;
        }
      } else {
        value = await _api.getFeed(
          category: category,
          cursor: cursor,
          limit: limit,
          cancellation: cancellation,
        );
        value = await _withLatestStoredVersions(value);
      }
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: origin,
        offline: false,
        persisted: persisted,
        revalidated: revalidated,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      if (cursor != null) rethrow;

      return _loadCachedOrDemoFeed(category: category, limit: limit);
    }
  }

  @override
  Future<void> cacheFeed(FeedPage value, {bool replaceFeed = true}) async {
    final cacheValue = fulltextPolicy.maskCachedFeed(value);
    for (final paper in cacheValue.items) {
      await _savePaperKeepingNewest(paper);
    }
    if (replaceFeed) {
      await _localStore.saveFeed(await _withLatestStoredVersions(cacheValue));
    }
  }

  @override
  Future<RepositoryValue<PaperSummary>> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final value = await _api.getPaper(paperId, cancellation: cancellation);
      if (value.paperId != paperId) {
        throw const ApiException(
          code: 'INVALID_PAPER_RESPONSE',
          message: 'The service returned a different paper.',
          retryable: true,
          statusCode: 502,
        );
      }
      final effective = await _savePaperKeepingNewest(
        fulltextPolicy.maskCachedPaper(value),
      );
      _markOnline();
      return RepositoryValue(
        // Preserve the unmasked network representation when it won. A stale
        // response is replaced by the newer, policy-safe device record.
        value: _preferStoredPaper(effective, value) ? effective : value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      final cached = await _localStore.loadPaper(paperId);
      if (cached != null) {
        return RepositoryValue(
          value: fulltextPolicy.maskCachedPaper(cached),
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      final bundled = await _demoContent.findFallbackPaper(paperId);
      if (bundled != null) {
        return RepositoryValue(
          value: fulltextPolicy.maskCachedPaper(bundled),
          origin: DataOrigin.bundledDemo,
          offline: _offline,
        );
      }
      rethrow;
    }
  }

  @override
  Future<RepositoryValue<PaperSummary>> getPaperByArxiv(
    String arxivId, {
    RequestCancellation? cancellation,
  }) async {
    final normalized = ArxivIdentifier.tryParse(arxivId);
    if (normalized == null) {
      throw const ApiException(
        code: 'INVALID_ARXIV_ID',
        message: 'The arXiv identifier is malformed.',
        statusCode: 400,
      );
    }
    try {
      final value = await _api.getPaperByArxiv(
        normalized.queryId,
        cancellation: cancellation,
      );
      if (value.arxivBaseId.toLowerCase() != normalized.baseId.toLowerCase()) {
        throw const ApiException(
          code: 'INVALID_ARXIV_RESPONSE',
          message: 'The service returned a different paper for this link.',
          retryable: true,
          statusCode: 502,
        );
      }
      final effective = await _savePaperKeepingNewest(
        fulltextPolicy.maskCachedPaper(value),
      );
      _markOnline();
      return RepositoryValue(
        value: _preferStoredPaper(effective, value) ? effective : value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      final cached = await _localStore.findPaperByArxiv(normalized.baseId);
      if (cached != null) {
        return RepositoryValue(
          value: fulltextPolicy.maskCachedPaper(cached),
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      final bundled = await _demoContent.findFallbackPaperByArxiv(
        normalized.baseId,
      );
      if (bundled != null) {
        return RepositoryValue(
          value: fulltextPolicy.maskCachedPaper(bundled),
          origin: DataOrigin.bundledDemo,
          offline: _offline,
        );
      }
      rethrow;
    }
  }

  @override
  Future<RepositoryValue<PaperProcessingState>> prepare(
    String paperId, {
    bool retry = false,
    RequestCancellation? cancellation,
  }) async {
    final expectedVersion = await _currentVersionKey(paperId);
    try {
      final value = await _api.prepare(
        paperId,
        retry: retry,
        cancellation: cancellation,
      );
      _validateProcessingResponse(paperId, value);
      final saved = await _saveProcessingForVersion(
        fulltextPolicy.maskCachedProcessing(value),
        expectedVersion,
      );
      if (!saved) throw _staleDerivedResponse;
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      final fallback = await _offlineProcessing(paperId);
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  @override
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    final expectedVersion = await _currentVersionKey(paperId);
    try {
      final value = await _api.getProcessing(
        paperId,
        cancellation: cancellation,
      );
      _validateProcessingResponse(paperId, value);
      final saved = await _saveProcessingForVersion(
        fulltextPolicy.maskCachedProcessing(value),
        expectedVersion,
      );
      if (!saved) throw _staleDerivedResponse;
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      final fallback = await _offlineProcessing(paperId);
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  Future<RepositoryValue<PaperProcessingState>?> _offlineProcessing(
    String paperId,
  ) async {
    final cached = await _localStore.loadProcessing(paperId);
    if (cached != null) {
      return RepositoryValue(
        value: fulltextPolicy.maskCachedProcessing(cached),
        origin: DataOrigin.deviceCache,
        offline: _offline,
      );
    }

    if (!fulltextPolicy.allowsDerivedDeviceFallback) return null;
    if (!await _bundledVersionMatches(paperId)) return null;
    final introduction = await _demoContent.loadIntroduction(paperId);
    final connections = await _demoContent.loadConnections(paperId);
    if (introduction == null && connections == null) return null;
    if ((introduction != null && introduction.paperId != paperId) ||
        (connections != null && connections.paperId != paperId)) {
      return null;
    }
    final generation = introduction?.generation ?? connections?.generation ?? 1;
    if (generation <= 0 ||
        (introduction != null && introduction.generation != generation) ||
        (connections != null && connections.generation != generation)) {
      return null;
    }
    final capabilities = PaperCapabilities(
      introduction: introduction != null,
      chat: introduction != null,
      connections: connections?.ready ?? false,
    );
    final processing = PaperProcessingState(
      paperId: paperId,
      generation: generation,
      overallState: capabilities.allReady ? 'ready' : 'processing',
      stage: capabilities.allReady
          ? ProcessingStage.ready
          : ProcessingStage.indexingChat,
      capabilities: capabilities,
      retryable: false,
      updatedAt: DateTime.now().toUtc(),
    );
    return RepositoryValue(
      value: processing,
      origin: DataOrigin.bundledDemo,
      offline: _offline,
    );
  }

  @override
  Future<RepositoryValue<PaperIntroduction>> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    final expectedVersion = await _currentVersionKey(paperId);
    try {
      final value = await _api.getIntroduction(
        paperId,
        cancellation: cancellation,
      );
      _validateDerivedResponse(
        requestedPaperId: paperId,
        responsePaperId: value.paperId,
        generation: value.generation,
      );
      final generationRelation = await _generationRelation(
        paperId,
        value.generation,
      );
      if (generationRelation == _GenerationRelation.responseOlder) {
        throw _staleDerivedResponse;
      }
      if (fulltextPolicy.allowsDerivedDeviceFallback &&
          generationRelation == _GenerationRelation.current) {
        final saved = await _saveIntroductionForVersion(value, expectedVersion);
        if (!saved) throw _staleDerivedResponse;
      } else if (!await _versionStillCurrent(expectedVersion)) {
        throw _staleDerivedResponse;
      }
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      if (!fulltextPolicy.allowsDerivedDeviceFallback ||
          !error.permitsDerivedFallback) {
        rethrow;
      }
      final cached = await _localStore.loadIntroduction(paperId);
      if (cached != null &&
          await _fallbackGenerationMatches(paperId, cached.generation)) {
        return RepositoryValue(
          value: cached,
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      if (!await _bundledVersionMatches(paperId)) rethrow;
      final bundled = await _demoContent.loadIntroduction(paperId);
      if (bundled != null &&
          bundled.paperId == paperId &&
          await _fallbackGenerationMatches(paperId, bundled.generation)) {
        return RepositoryValue(
          value: bundled,
          origin: DataOrigin.bundledDemo,
          offline: _offline,
        );
      }
      rethrow;
    }
  }

  @override
  Future<RepositoryValue<PaperConnections>> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    final expectedVersion = await _currentVersionKey(paperId);
    try {
      final value = await _api.getConnections(
        paperId,
        cancellation: cancellation,
      );
      _validateDerivedResponse(
        requestedPaperId: paperId,
        responsePaperId: value.paperId,
        generation: value.generation,
      );
      final generationRelation = await _generationRelation(
        paperId,
        value.generation,
      );
      if (generationRelation == _GenerationRelation.responseOlder) {
        throw _staleDerivedResponse;
      }
      if (fulltextPolicy.allowsDerivedDeviceFallback &&
          generationRelation == _GenerationRelation.current) {
        final saved = await _saveConnectionsForVersion(value, expectedVersion);
        if (!saved) throw _staleDerivedResponse;
      } else if (!await _versionStillCurrent(expectedVersion)) {
        throw _staleDerivedResponse;
      }
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      if (!fulltextPolicy.allowsDerivedDeviceFallback ||
          !error.permitsDerivedFallback) {
        rethrow;
      }
      final cached = await _localStore.loadConnections(paperId);
      if (cached != null &&
          await _fallbackGenerationMatches(paperId, cached.generation)) {
        return RepositoryValue(
          value: cached,
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      if (!await _bundledVersionMatches(paperId)) rethrow;
      final bundled = await _demoContent.loadConnections(paperId);
      if (bundled != null &&
          bundled.paperId == paperId &&
          await _fallbackGenerationMatches(paperId, bundled.generation)) {
        return RepositoryValue(
          value: bundled,
          origin: DataOrigin.bundledDemo,
          offline: _offline,
        );
      }
      rethrow;
    }
  }

  @override
  Future<ChatAnswer> sendChat({
    required String paperId,
    required String message,
    String? threadId,
    RequestCancellation? cancellation,
  }) async {
    final expectedVersion = await _currentVersionKey(paperId);
    try {
      final answer = await _api.sendChat(
        paperId: paperId,
        message: message,
        threadId: threadId,
        cancellation: cancellation,
      );
      if (!await _versionStillCurrent(expectedVersion) ||
          await _generationRelation(paperId, answer.generation) ==
              _GenerationRelation.responseOlder) {
        throw _staleDerivedResponse;
      }
      _markOnline();
      return answer;
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      rethrow;
    }
  }

  Future<PaperSummary> _savePaperKeepingNewest(PaperSummary paper) async {
    final previous = await _localStore.loadPaper(paper.paperId);
    if (previous != null && _preferStoredPaper(previous, paper)) {
      return previous;
    }

    // LocalStore.savePaper owns version invalidation and must commit a newer
    // metadata row atomically with clearing derived rows for the prior version.
    await _localStore.savePaper(paper);
    final effective = await _localStore.loadPaper(paper.paperId);
    if (effective != null && _preferStoredPaper(effective, paper)) {
      return effective;
    }
    return paper;
  }

  Future<PaperVersionKey?> _currentVersionKey(String paperId) async =>
      (await _localStore.loadPaper(paperId))?.versionKey;

  Future<bool> _saveProcessingForVersion(
    PaperProcessingState value,
    PaperVersionKey? expected,
  ) async {
    final store = _localStore;
    final versioned = switch (store) {
      VersionedDerivedCache cache => cache,
      _ => null,
    };
    if (expected != null && versioned != null) {
      return versioned.saveProcessingForVersion(
        value,
        expectedVersionKey: expected,
      );
    }
    final current = await store.loadProcessing(value.paperId);
    if (current != null &&
        (current.generation > value.generation ||
            (current.generation == value.generation &&
                current.updatedAt.isAfter(value.updatedAt)))) {
      return false;
    }
    await store.saveProcessing(value);
    return _versionStillCurrent(expected);
  }

  Future<bool> _saveIntroductionForVersion(
    PaperIntroduction value,
    PaperVersionKey? expected,
  ) async {
    final store = _localStore;
    final versioned = switch (store) {
      VersionedDerivedCache cache => cache,
      _ => null,
    };
    if (expected != null && versioned != null) {
      return versioned.saveIntroductionForVersion(
        value,
        expectedVersionKey: expected,
      );
    }
    await store.saveIntroduction(value);
    return _versionStillCurrent(expected);
  }

  Future<bool> _saveConnectionsForVersion(
    PaperConnections value,
    PaperVersionKey? expected,
  ) async {
    final store = _localStore;
    final versioned = switch (store) {
      VersionedDerivedCache cache => cache,
      _ => null,
    };
    if (expected != null && versioned != null) {
      return versioned.saveConnectionsForVersion(
        value,
        expectedVersionKey: expected,
      );
    }
    await store.saveConnections(value);
    return _versionStillCurrent(expected);
  }

  Future<bool> _versionStillCurrent(PaperVersionKey? expected) async {
    if (expected == null) return true;
    return (await _localStore.loadPaper(expected.paperId))?.versionKey ==
        expected;
  }

  Future<_GenerationRelation> _generationRelation(
    String paperId,
    int responseGeneration,
  ) async {
    final current = await _localStore.loadProcessing(paperId);
    if (current == null) return _GenerationRelation.unknown;
    if (responseGeneration < current.generation) {
      return _GenerationRelation.responseOlder;
    }
    if (responseGeneration > current.generation) {
      return _GenerationRelation.responseNewer;
    }
    return _GenerationRelation.current;
  }

  Future<bool> _fallbackGenerationMatches(
    String paperId,
    int generation,
  ) async {
    if (generation <= 0) return false;
    final current = await _localStore.loadProcessing(paperId);
    return current == null || current.generation == generation;
  }

  Future<bool> _bundledVersionMatches(String paperId) async {
    final latest = await _localStore.loadPaper(paperId);
    if (latest == null) return true;
    final bundled = await _demoContent.findFallbackPaper(paperId);
    return bundled != null && bundled.arxivId == latest.arxivId;
  }

  Future<FeedPage> _withLatestStoredVersions(FeedPage source) async {
    var changed = false;
    final items = <PaperSummary>[];
    for (final paper in source.items) {
      final latest = await _localStore.loadPaper(paper.paperId);
      if (latest != null && _preferStoredPaper(latest, paper)) {
        items.add(latest);
        changed = true;
      } else {
        items.add(paper);
      }
    }
    return changed
        ? FeedPage(items: items, nextCursor: source.nextCursor)
        : source;
  }

  void _markFrom(ApiException error) {
    if (error.isOffline) _setOffline(true);
  }

  void _markOnline() => _setOffline(false);

  void _setOffline(bool value) {
    if (_offline == value) return;
    _offline = value;
    _offlineController.add(value);
  }
}

enum _GenerationRelation { unknown, current, responseNewer, responseOlder }

void _validateProcessingResponse(
  String requestedPaperId,
  PaperProcessingState value,
) {
  _validateDerivedResponse(
    requestedPaperId: requestedPaperId,
    responsePaperId: value.paperId,
    generation: value.generation,
  );
}

void _validateDerivedResponse({
  required String requestedPaperId,
  required String responsePaperId,
  required int generation,
}) {
  if (responsePaperId != requestedPaperId || generation <= 0) {
    throw const ApiException(
      code: 'INVALID_DERIVED_RESPONSE',
      message: 'The service returned content for a different paper generation.',
      retryable: true,
      statusCode: 502,
    );
  }
}

bool _preferStoredPaper(PaperSummary candidate, PaperSummary reference) {
  if (candidate.arxivBaseId.toLowerCase() !=
      reference.arxivBaseId.toLowerCase()) {
    // A stable paper ID must never silently move to another arXiv work.
    return true;
  }
  final candidateVersion = ArxivIdentifier.tryParse(candidate.arxivId)?.version;
  final referenceVersion = ArxivIdentifier.tryParse(reference.arxivId)?.version;
  if ((candidateVersion ?? 0) != (referenceVersion ?? 0)) {
    return (candidateVersion ?? 0) > (referenceVersion ?? 0);
  }
  return candidate.updatedAt.isAfter(reference.updatedAt);
}

const _staleDerivedResponse = ApiException(
  code: 'STALE_PAPER_VERSION',
  message:
      'The paper changed version or generation while this content was loading.',
  retryable: true,
  statusCode: 409,
);
