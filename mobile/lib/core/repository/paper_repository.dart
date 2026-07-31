import 'dart:async';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/request_cancellation.dart';
import '../cache/demo_asset_store.dart';
import '../cache/local_store.dart';
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
  });

  final T value;
  final DataOrigin origin;
  final bool offline;
  bool get isStale => origin != DataOrigin.network;
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
  })  : _api = api,
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
    final cached = await _localStore.loadFeed();
    final staleSource = cached != null && cached.items.isNotEmpty
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
            nextCursor: source.nextCursor,
          );
    return RepositoryValue(
      value: fulltextPolicy.maskCachedFeed(filtered),
      origin: cached != null && cached.items.isNotEmpty
          ? DataOrigin.deviceCache
          : DataOrigin.bundledDemo,
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
      final value = await _api.getFeed(
        category: category,
        cursor: cursor,
        limit: limit,
        cancellation: cancellation,
      );
      _markOnline();
      return RepositoryValue(
        value: value,
        origin: DataOrigin.network,
        offline: false,
      );
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      if (cursor != null) rethrow;

      final cached = await _localStore.loadFeed();
      if (cached != null && cached.items.isNotEmpty) {
        return RepositoryValue(
          value: fulltextPolicy.maskCachedFeed(
            await _withLatestStoredVersions(cached),
          ),
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      final bundled = await _demoContent.loadFallbackFeed();
      return RepositoryValue(
        value: fulltextPolicy.maskCachedFeed(
          await _withLatestStoredVersions(bundled),
        ),
        origin: DataOrigin.bundledDemo,
        offline: _offline,
      );
    }
  }

  @override
  Future<void> cacheFeed(FeedPage value, {bool replaceFeed = true}) async {
    final cacheValue = fulltextPolicy.maskCachedFeed(value);
    for (final paper in cacheValue.items) {
      await _savePaperAndInvalidateOlderVersion(paper);
    }
    if (replaceFeed) await _localStore.saveFeed(cacheValue);
  }

  @override
  Future<RepositoryValue<PaperSummary>> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    try {
      final value = await _api.getPaper(
        paperId,
        cancellation: cancellation,
      );
      await _savePaperAndInvalidateOlderVersion(
        fulltextPolicy.maskCachedPaper(value),
      );
      _markOnline();
      return RepositoryValue(
        value: value,
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
      await _savePaperAndInvalidateOlderVersion(
        fulltextPolicy.maskCachedPaper(value),
      );
      _markOnline();
      return RepositoryValue(
        value: value,
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
    try {
      final value = await _api.prepare(
        paperId,
        retry: retry,
        cancellation: cancellation,
      );
      await _localStore.saveProcessing(
        fulltextPolicy.maskCachedProcessing(value),
      );
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
    try {
      final value = await _api.getProcessing(
        paperId,
        cancellation: cancellation,
      );
      await _localStore.saveProcessing(
        fulltextPolicy.maskCachedProcessing(value),
      );
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
    final capabilities = PaperCapabilities(
      introduction: introduction != null,
      chat: introduction != null,
      connections: connections?.ready ?? false,
    );
    final processing = PaperProcessingState(
      paperId: paperId,
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
    try {
      final value = await _api.getIntroduction(
        paperId,
        cancellation: cancellation,
      );
      if (fulltextPolicy.allowsDerivedDeviceFallback) {
        await _localStore.saveIntroduction(value);
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
      if (cached != null) {
        return RepositoryValue(
          value: cached,
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      if (!await _bundledVersionMatches(paperId)) rethrow;
      final bundled = await _demoContent.loadIntroduction(paperId);
      if (bundled != null) {
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
    try {
      final value = await _api.getConnections(
        paperId,
        cancellation: cancellation,
      );
      if (fulltextPolicy.allowsDerivedDeviceFallback) {
        await _localStore.saveConnections(value);
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
      if (cached != null) {
        return RepositoryValue(
          value: cached,
          origin: DataOrigin.deviceCache,
          offline: _offline,
        );
      }
      if (!await _bundledVersionMatches(paperId)) rethrow;
      final bundled = await _demoContent.loadConnections(paperId);
      if (bundled != null) {
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
    try {
      final answer = await _api.sendChat(
        paperId: paperId,
        message: message,
        threadId: threadId,
        cancellation: cancellation,
      );
      _markOnline();
      return answer;
    } on ApiException catch (error) {
      if (error.cancelled) rethrow;
      _markFrom(error);
      rethrow;
    }
  }

  Future<void> _savePaperAndInvalidateOlderVersion(PaperSummary paper) async {
    final previous = await _localStore.loadPaper(paper.paperId);
    if (previous != null && previous.arxivId != paper.arxivId) {
      await _localStore.clearDerived(paper.paperId);
    }
    await _localStore.savePaper(paper);
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
      if (latest != null && latest.arxivId != paper.arxivId) {
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
