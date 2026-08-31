import '../api/api_exception.dart';
import '../api/request_cancellation.dart';
import '../api/transport_network_status.dart';
import '../account/account_data_write_barrier.dart';
import '../content_policy.dart';
import '../database/document_cache_dao.dart';
import '../models/document_block.dart';
import '../models/reading_checkpoint.dart';
import '../telemetry/telemetry.dart';
import 'document_api.dart';

final class DocumentLoadResult {
  const DocumentLoadResult({required this.snapshot, required this.fromCache});

  final DocumentSnapshot snapshot;
  final bool fromCache;
}

abstract interface class DocumentDataSource {
  bool get isOffline;

  Future<DocumentLoadResult> load({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    required bool force,
    RequestCancellation? cancellation,
  });

  Future<ReadingCheckpoint?> readCheckpoint({
    required String accountId,
    required String paperId,
  });

  Future<ReadingCheckpoint?> fetchCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<void> saveCheckpointLocally(
    ReadingCheckpoint checkpoint, {
    required int expectedAuthEpoch,
  });

  Future<ReadingCheckpoint> syncCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

abstract interface class PagedDocumentDataSource {
  Future<DocumentBlockPage> loadNextPage({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    required String cursor,
    RequestCancellation? cancellation,
  });
}

abstract interface class VisualDocumentDataSource {
  Future<DocumentVisualObjects> loadVisualObjects({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

abstract interface class DocumentSnapshotPersistence {
  Future<void> persistSnapshot({
    required String accountId,
    required int expectedAuthEpoch,
    required DocumentSnapshot snapshot,
  });
}

typedef DocumentAccountScopeFence =
    bool Function(String accountId, int authEpoch);

final class DocumentRepository
    implements
        DocumentDataSource,
        PagedDocumentDataSource,
        VisualDocumentDataSource,
        DocumentSnapshotPersistence {
  const DocumentRepository({
    required DocumentRemoteDataSource remote,
    required DocumentCacheDao? cache,
    required TransportNetworkStatus networkStatus,
    required ClientFulltextPolicy fulltextPolicy,
    required AccountDataWriteBarrier accountWrites,
    required DocumentAccountScopeFence accountScopeIsCurrent,
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _remote = remote,
       _cache = cache,
       _networkStatus = networkStatus,
       _fulltextPolicy = fulltextPolicy,
       _accountWrites = accountWrites,
       _accountScopeIsCurrent = accountScopeIsCurrent,
       _telemetry = telemetry;

  final DocumentRemoteDataSource _remote;
  final DocumentCacheDao? _cache;
  final TransportNetworkStatus _networkStatus;
  final ClientFulltextPolicy _fulltextPolicy;
  final AccountDataWriteBarrier _accountWrites;
  final DocumentAccountScopeFence _accountScopeIsCurrent;
  final TelemetrySink _telemetry;

  @override
  bool get isOffline => _networkStatus.isOffline;

  @override
  Future<DocumentLoadResult> load({
    required String accountId,
    required String paperId,
    required String versionKey,
    required int generation,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    required bool force,
    RequestCancellation? cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    _throwIfScopeChanged(accountId, expectedAuthEpoch);
    if (!force && _fulltextPolicy.allowsDerivedDeviceFallback) {
      final cached = await _cache?.readSnapshot(
        accountId: accountId,
        paperId: paperId,
        versionKey: versionKey,
        generation: generation,
      );
      final cacheSatisfiesRequest =
          cached?.includesCapabilities(
            passport: includePassport,
            semanticFacets: includeSemanticFacets,
            visualObjects: includeVisualObjects,
          ) ??
          false;
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.documentCacheLookup, {
        'outcome': cacheSatisfiesRequest ? 'hit' : 'miss',
        'offline': _networkStatus.isOffline,
      });
      if (cached != null && cacheSatisfiesRequest) {
        _throwIfCancelled(cancellation);
        _throwIfScopeChanged(accountId, expectedAuthEpoch);
        return DocumentLoadResult(snapshot: cached, fromCache: true);
      }
    }
    if (_networkStatus.isOffline) {
      throw const ApiException(
        code: 'OFFLINE_DOCUMENT_UNAVAILABLE',
        message: 'This prepared document is not available offline.',
        retryable: true,
        isOffline: true,
      );
    }
    final snapshot = await _remote.fetchSnapshot(
      paperId: paperId,
      versionKey: versionKey,
      expectedGeneration: generation,
      expectedAuthEpoch: expectedAuthEpoch,
      includePassport: includePassport,
      includeSemanticFacets: includeSemanticFacets,
      includeVisualObjects: includeVisualObjects,
      cancellation: cancellation,
    );
    // Cancellation may happen after transport completion but before this
    // continuation runs. Fence the durable write as well as the UI consumer.
    _throwIfCancelled(cancellation);
    if (_fulltextPolicy.allowsDerivedDeviceFallback) {
      await _writeIfCurrent(
        accountId: accountId,
        authEpoch: expectedAuthEpoch,
        write: () async {
          await _cache?.writeSnapshot(accountId: accountId, snapshot: snapshot);
        },
      );
    }
    _throwIfCancelled(cancellation);
    return DocumentLoadResult(snapshot: snapshot, fromCache: false);
  }

  @override
  Future<ReadingCheckpoint?> readCheckpoint({
    required String accountId,
    required String paperId,
  }) =>
      _cache?.readCheckpoint(accountId: accountId, paperId: paperId) ??
      Future<ReadingCheckpoint?>.value();

  @override
  Future<void> saveCheckpointLocally(
    ReadingCheckpoint checkpoint, {
    required int expectedAuthEpoch,
  }) => _writeIfCurrent(
    accountId: checkpoint.accountId,
    authEpoch: expectedAuthEpoch,
    write: () async {
      await _cache?.writeCheckpoint(checkpoint);
    },
  );

  @override
  Future<ReadingCheckpoint?> fetchCheckpoint({
    required String accountId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _remote.getCheckpoint(
    accountId: accountId,
    paperId: paperId,
    expectedAuthEpoch: expectedAuthEpoch,
    cancellation: cancellation,
  );

  @override
  Future<ReadingCheckpoint> syncCheckpoint({
    required ReadingCheckpoint checkpoint,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _remote.putCheckpoint(
    checkpoint: checkpoint,
    expectedAuthEpoch: expectedAuthEpoch,
    cancellation: cancellation,
  );

  @override
  Future<DocumentBlockPage> loadNextPage({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    required String cursor,
    RequestCancellation? cancellation,
  }) {
    if (_networkStatus.isOffline) {
      throw const ApiException(
        code: 'OFFLINE_DOCUMENT_PAGE_UNAVAILABLE',
        message: 'More of this document needs a connection.',
        retryable: true,
        isOffline: true,
      );
    }
    final remote = _remote;
    if (remote is! PagedDocumentRemoteDataSource) {
      throw const ApiException(
        code: 'DOCUMENT_PAGING_UNAVAILABLE',
        message: 'Document paging is unavailable.',
      );
    }
    final paged = remote as PagedDocumentRemoteDataSource;
    return paged.fetchBlockPage(
      paperId: paperId,
      expectedGeneration: generation,
      expectedAuthEpoch: expectedAuthEpoch,
      cursor: cursor,
      cancellation: cancellation,
    );
  }

  @override
  Future<DocumentVisualObjects> loadVisualObjects({
    required String paperId,
    required int generation,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    if (_networkStatus.isOffline) {
      throw const ApiException(
        code: 'OFFLINE_VISUAL_OBJECTS_UNAVAILABLE',
        message: 'Visual object details need a connection.',
        retryable: true,
        isOffline: true,
      );
    }
    final remote = _remote;
    if (remote is! VisualDocumentRemoteDataSource) {
      throw const ApiException(
        code: 'VISUAL_OBJECTS_UNAVAILABLE',
        message: 'Visual object details are unavailable.',
      );
    }
    return (remote as VisualDocumentRemoteDataSource).fetchVisualObjects(
      paperId: paperId,
      expectedGeneration: generation,
      expectedAuthEpoch: expectedAuthEpoch,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> persistSnapshot({
    required String accountId,
    required int expectedAuthEpoch,
    required DocumentSnapshot snapshot,
  }) {
    if (!_fulltextPolicy.allowsDerivedDeviceFallback) {
      return Future<void>.value();
    }
    return _writeIfCurrent(
      accountId: accountId,
      authEpoch: expectedAuthEpoch,
      write: () async {
        await _cache?.writeSnapshot(accountId: accountId, snapshot: snapshot);
      },
    );
  }

  Future<void> _writeIfCurrent({
    required String accountId,
    required int authEpoch,
    required Future<void> Function() write,
  }) async {
    final written = await _accountWrites.writeIfCurrent(
      accountId: accountId,
      authEpoch: authEpoch,
      isCurrent: () => _accountScopeIsCurrent(accountId, authEpoch),
      write: write,
    );
    if (!written) throw _documentScopeChanged;
  }

  void _throwIfScopeChanged(String accountId, int authEpoch) {
    if (!_accountScopeIsCurrent(accountId, authEpoch)) {
      throw _documentScopeChanged;
    }
  }
}

void _throwIfCancelled(RequestCancellation? cancellation) {
  if (cancellation?.isCancelled ?? false) {
    throw const ApiException(
      code: 'REQUEST_CANCELLED',
      message: 'The document request was cancelled.',
    );
  }
}

const _documentScopeChanged = ApiException(
  code: 'REQUEST_CANCELLED',
  message: 'The account context changed before the document could be cached.',
);
