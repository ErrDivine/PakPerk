import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/cache/drift_local_store.dart';
import '../../core/database/document_cache_dao.dart';
import '../../core/document/document_api.dart';
import '../../core/document/document_repository.dart';
import '../../core/document/visual_asset_repository.dart';
import '../../core/models/document_block.dart';
import '../../core/models/paper.dart';
import '../../core/models/reading_checkpoint.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../paper_reader/paper_processing_controller.dart';
import '../reader_modes/reader_mode.dart';

const documentExactNavigationMaximumPageRequests = 20;

enum DocumentAvailability {
  idle,
  loading,
  ready,
  offlineUnavailable,
  unavailable,
  failed,
}

final class DocumentState {
  const DocumentState({
    this.availability = DocumentAvailability.idle,
    this.snapshot,
    this.checkpoint,
    this.fromCache = false,
    this.savingCheckpoint = false,
    this.highlightedBlockId,
    this.errorMessage,
    this.loadingMore = false,
    this.loadingVisualObjects = false,
    this.visualObjectsFailed = false,
  });

  final DocumentAvailability availability;
  final DocumentSnapshot? snapshot;
  final ReadingCheckpoint? checkpoint;
  final bool fromCache;
  final bool savingCheckpoint;
  final String? highlightedBlockId;
  final String? errorMessage;
  final bool loadingMore;
  final bool loadingVisualObjects;
  final bool visualObjectsFailed;

  bool get hasReadableDocument => snapshot != null;

  DocumentState copyWith({
    DocumentAvailability? availability,
    DocumentSnapshot? snapshot,
    ReadingCheckpoint? checkpoint,
    bool? fromCache,
    bool? savingCheckpoint,
    String? highlightedBlockId,
    bool clearHighlight = false,
    String? errorMessage,
    bool clearError = false,
    bool? loadingMore,
    bool? loadingVisualObjects,
    bool? visualObjectsFailed,
  }) => DocumentState(
    availability: availability ?? this.availability,
    snapshot: snapshot ?? this.snapshot,
    checkpoint: checkpoint ?? this.checkpoint,
    fromCache: fromCache ?? this.fromCache,
    savingCheckpoint: savingCheckpoint ?? this.savingCheckpoint,
    highlightedBlockId: clearHighlight
        ? null
        : highlightedBlockId ?? this.highlightedBlockId,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    loadingMore: loadingMore ?? this.loadingMore,
    loadingVisualObjects: loadingVisualObjects ?? this.loadingVisualObjects,
    visualObjectsFailed: visualObjectsFailed ?? this.visualObjectsFailed,
  );
}

final class DocumentControllerArgs {
  const DocumentControllerArgs({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.includePassport,
    required this.includeSemanticFacets,
    required this.includeVisualObjects,
  });

  final String accountId;
  final int authEpoch;
  final String paperId;
  final String versionKey;
  final int generation;
  final bool includePassport;
  final bool includeSemanticFacets;
  final bool includeVisualObjects;

  @override
  bool operator ==(Object other) =>
      other is DocumentControllerArgs &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.paperId == paperId &&
      other.versionKey == versionKey &&
      other.generation == generation &&
      other.includePassport == includePassport &&
      other.includeSemanticFacets == includeSemanticFacets &&
      other.includeVisualObjects == includeVisualObjects;

  @override
  int get hashCode => Object.hash(
    accountId,
    authEpoch,
    paperId,
    versionKey,
    generation,
    includePassport,
    includeSemanticFacets,
    includeVisualObjects,
  );
}

final documentRemoteDataSourceProvider = Provider<DocumentRemoteDataSource>((
  ref,
) {
  return DocumentApi(ref.watch(pakPerkDioProvider));
});

final documentDataSourceProvider = Provider<DocumentDataSource>((ref) {
  final store = ref.watch(localStoreProvider);
  final telemetry = ref.watch(telemetrySinkProvider);
  return DocumentRepository(
    remote: ref.watch(documentRemoteDataSourceProvider),
    cache: store is DriftLocalStore
        ? DocumentCacheDao(store.database, telemetry: telemetry)
        : null,
    networkStatus: ref.watch(transportNetworkStatusProvider),
    fulltextPolicy: ref.watch(clientFulltextPolicyProvider),
    accountWrites: ref.watch(accountDataWriteBarrierProvider),
    accountScopeIsCurrent: (accountId, authEpoch) {
      final scope = ref.read(verifiedLibraryScopeProvider);
      return scope?.accountId == accountId && scope?.authEpoch == authEpoch;
    },
    telemetry: telemetry,
  );
});

final visualAssetRemoteDataSourceProvider =
    Provider<VisualAssetRemoteDataSource>(
      (ref) => VisualAssetApi(ref.watch(pakPerkDioProvider)),
    );

final visualAssetRepositoryProvider = Provider<VisualAssetRepository>((ref) {
  return VisualAssetRepository(
    remote: ref.watch(visualAssetRemoteDataSourceProvider),
    cache: ref.watch(visualAssetCacheProvider),
    networkStatus: ref.watch(transportNetworkStatusProvider),
    fulltextPolicy: ref.watch(clientFulltextPolicyProvider),
    accountWrites: ref.watch(accountDataWriteBarrierProvider),
    accountScopeIsCurrent: (accountId, authEpoch) {
      final scope = ref.read(verifiedLibraryScopeProvider);
      return scope?.accountId == accountId && scope?.authEpoch == authEpoch;
    },
    telemetry: ref.watch(telemetrySinkProvider),
  );
});

final documentControllerProvider = StateNotifierProvider.autoDispose
    .family<DocumentController, DocumentState, DocumentControllerArgs>((
      ref,
      args,
    ) {
      return DocumentController(
        args: args,
        source: ref.watch(documentDataSourceProvider),
        scopeIsCurrent: () {
          final scope = ref.read(verifiedLibraryScopeProvider);
          final generation = ref
              .read(paperProcessingControllerProvider(_versionKey(args)))
              .processing
              ?.generation;
          return scope?.accountId == args.accountId &&
              scope?.authEpoch == args.authEpoch &&
              generation == args.generation;
        },
      );
    });

PaperVersionKey _versionKey(DocumentControllerArgs args) {
  return PaperVersionKey(paperId: args.paperId, arxivId: args.versionKey);
}

typedef DocumentScopeFence = bool Function();

final class DocumentController extends StateNotifier<DocumentState> {
  DocumentController({
    required this.args,
    required DocumentDataSource source,
    required DocumentScopeFence scopeIsCurrent,
  }) : _source = source,
       _scopeIsCurrent = scopeIsCurrent,
       super(const DocumentState());

  final DocumentControllerArgs args;
  final DocumentDataSource _source;
  final DocumentScopeFence _scopeIsCurrent;
  RequestCancellation? _documentRequest;
  RequestCancellation? _checkpointRequest;
  int _requestSerial = 0;
  RequestCancellation? _pageRequest;
  Future<void>? _pageFlight;
  RequestCancellation? _visualObjectsRequest;
  Future<void>? _visualObjectsFlight;

  Future<void> load({bool force = false}) async {
    if (state.availability == DocumentAvailability.loading && !force) return;
    if (state.hasReadableDocument && !force) return;
    final serial = ++_requestSerial;
    _documentRequest?.cancel('A newer document request replaced this one.');
    _pageRequest?.cancel('A document reload replaced page loading.');
    _pageFlight = null;
    _visualObjectsRequest?.cancel(
      'A document reload replaced visual object loading.',
    );
    _visualObjectsFlight = null;
    final request = RequestCancellation();
    _documentRequest = request;
    state = state.copyWith(
      availability: DocumentAvailability.loading,
      loadingMore: false,
      loadingVisualObjects: false,
      visualObjectsFailed: false,
      clearError: true,
    );
    try {
      final values = await Future.wait<Object?>([
        _source.load(
          accountId: args.accountId,
          paperId: args.paperId,
          versionKey: args.versionKey,
          generation: args.generation,
          expectedAuthEpoch: args.authEpoch,
          includePassport: args.includePassport,
          includeSemanticFacets: args.includeSemanticFacets,
          // Visual metadata is requested only after Inspect is revealed.
          includeVisualObjects: false,
          force: force,
          cancellation: request,
        ),
        _restoreCheckpoint(request),
      ]);
      if (!_accepts(serial, request)) return;
      final loaded = values[0]! as DocumentLoadResult;
      final checkpoint = values[1] as ReadingCheckpoint?;
      state = DocumentState(
        availability: DocumentAvailability.ready,
        snapshot: loaded.snapshot,
        checkpoint: checkpoint?.generation == args.generation
            ? checkpoint
            : null,
        fromCache: loaded.fromCache,
      );
      if (checkpoint != null &&
          checkpoint.generation == args.generation &&
          checkpoint.pendingSync &&
          checkpoint.operationId != null &&
          !_source.isOffline) {
        unawaited(_syncRestoredCheckpoint(checkpoint));
      }
    } on ApiException catch (error) {
      if (error.cancelled || !_accepts(serial, request)) return;
      state = state.copyWith(
        availability: error.isOffline
            ? DocumentAvailability.offlineUnavailable
            : error.fulltextPolicyDenied || error.statusCode == 404
            ? DocumentAvailability.unavailable
            : DocumentAvailability.failed,
        errorMessage: error.isOffline
            ? 'This document is not cached. Reconnect to prepare or load it.'
            : error.fulltextPolicyDenied
            ? 'Document text is unavailable under the current content policy.'
            : error.message,
      );
    } on Object {
      if (!_accepts(serial, request)) return;
      state = state.copyWith(
        availability: DocumentAvailability.failed,
        errorMessage: 'The prepared document could not be loaded safely.',
      );
    }
  }

  Future<bool> saveCheckpoint({
    required ReaderDepthMode mode,
    required PaperStage stage,
    required String? blockId,
    required double? scrollFraction,
  }) async {
    if (!_scopeIsCurrent()) return false;
    final local = ReadingCheckpoint(
      accountId: args.accountId,
      paperId: args.paperId,
      generation: args.generation,
      mode: mode,
      stage: stage,
      blockId: blockId,
      scrollFraction: scrollFraction,
      lastReadAt: DateTime.now().toUtc(),
      revision: state.checkpoint?.revision ?? 0,
      pendingSync: true,
      operationId: const Uuid().v7(),
    );
    state = state.copyWith(savingCheckpoint: true, checkpoint: local);
    await _source.saveCheckpointLocally(
      local,
      expectedAuthEpoch: args.authEpoch,
    );
    if (!mounted || !_scopeIsCurrent()) return false;
    if (_source.isOffline) {
      state = state.copyWith(
        savingCheckpoint: false,
        errorMessage:
            'Checkpoint saved on this device. Sync waits for connection.',
      );
      return true;
    }
    _checkpointRequest?.cancel('A newer checkpoint replaced this one.');
    final request = RequestCancellation();
    _checkpointRequest = request;
    try {
      final synced = await _syncCheckpointWithRebase(local, request);
      if (!mounted || request.isCancelled || !_scopeIsCurrent()) return false;
      final settled = synced.copyWith(pendingSync: false);
      await _source.saveCheckpointLocally(
        settled,
        expectedAuthEpoch: args.authEpoch,
      );
      if (!mounted || request.isCancelled || !_scopeIsCurrent()) return false;
      state = state.copyWith(
        checkpoint: settled,
        savingCheckpoint: false,
        clearError: true,
      );
      return true;
    } on ApiException catch (error) {
      if (error.cancelled || !mounted || !_scopeIsCurrent()) return false;
      state = state.copyWith(
        savingCheckpoint: false,
        errorMessage: 'Checkpoint saved on this device. Sync will retry later.',
      );
      return true;
    }
  }

  Future<void> loadNextPage() {
    final existing = _pageFlight;
    if (existing != null) return existing;
    final operation = _loadNextPage();
    _pageFlight = operation;
    return operation.whenComplete(() {
      if (identical(_pageFlight, operation)) _pageFlight = null;
    });
  }

  Future<void> loadVisualObjects() {
    final snapshot = state.snapshot;
    if (!args.includeVisualObjects ||
        snapshot == null ||
        snapshot.visualObjectsIncluded ||
        !_scopeIsCurrent()) {
      return Future<void>.value();
    }
    final existing = _visualObjectsFlight;
    if (existing != null) return existing;
    final operation = _loadVisualObjects();
    _visualObjectsFlight = operation;
    return operation.whenComplete(() {
      if (identical(_visualObjectsFlight, operation)) {
        _visualObjectsFlight = null;
      }
    });
  }

  Future<void> _loadVisualObjects() async {
    final snapshot = state.snapshot;
    final source = _source;
    if (snapshot == null ||
        source is! VisualDocumentDataSource ||
        !_scopeIsCurrent()) {
      if (mounted && _scopeIsCurrent()) {
        state = state.copyWith(visualObjectsFailed: true);
      }
      return;
    }
    final visualSource = source as VisualDocumentDataSource;
    final serial = _requestSerial;
    final request = RequestCancellation();
    _visualObjectsRequest?.cancel(
      'A newer visual object request replaced this one.',
    );
    _visualObjectsRequest = request;
    state = state.copyWith(
      loadingVisualObjects: true,
      visualObjectsFailed: false,
    );
    try {
      final objects = await visualSource.loadVisualObjects(
        paperId: args.paperId,
        generation: args.generation,
        expectedAuthEpoch: args.authEpoch,
        cancellation: request,
      );
      if (!_accepts(serial, request) || !_scopeIsCurrent()) return;
      if (objects.paperId != args.paperId ||
          objects.generation != args.generation) {
        throw const FormatException('Visual object scope mismatch.');
      }
      final next = snapshot.withVisualObjects(
        figures: objects.figures,
        tables: objects.tables,
        equations: objects.equations,
      );
      state = state.copyWith(
        snapshot: next,
        loadingVisualObjects: false,
        visualObjectsFailed: false,
      );
      if (source is DocumentSnapshotPersistence) {
        try {
          await (source as DocumentSnapshotPersistence).persistSnapshot(
            accountId: args.accountId,
            expectedAuthEpoch: args.authEpoch,
            snapshot: next,
          );
        } on Object {
          // The verified objects remain readable in memory. A later load may
          // retry the offline copy without hiding already-present content.
        }
      }
    } on ApiException catch (error) {
      if (!error.cancelled && _accepts(serial, request)) {
        state = state.copyWith(
          loadingVisualObjects: false,
          visualObjectsFailed: true,
        );
      }
    } on Object {
      if (_accepts(serial, request)) {
        state = state.copyWith(
          loadingVisualObjects: false,
          visualObjectsFailed: true,
        );
      }
    }
  }

  Future<void> _loadNextPage() async {
    final snapshot = state.snapshot;
    final cursor = snapshot?.nextCursor;
    final source = _source;
    if (snapshot == null ||
        cursor == null ||
        source is! PagedDocumentDataSource ||
        !_scopeIsCurrent()) {
      return;
    }
    final paged = source as PagedDocumentDataSource;
    final serial = _requestSerial;
    final request = RequestCancellation();
    _pageRequest?.cancel('A newer page request replaced this one.');
    _pageRequest = request;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final page = await paged.loadNextPage(
        paperId: args.paperId,
        generation: args.generation,
        expectedAuthEpoch: args.authEpoch,
        cursor: cursor,
        cancellation: request,
      );
      if (!_accepts(serial, request) || !_scopeIsCurrent()) {
        return;
      }
      if (page.nextCursor == cursor) {
        throw const FormatException('Document cursor did not advance.');
      }
      if (snapshot.blocks.length + page.blocks.length >
          documentSnapshotMaximumBlocks) {
        throw const FormatException(
          'Mobile document page cache limit exceeded.',
        );
      }
      final next = snapshot.appendPage(page);
      state = state.copyWith(snapshot: next, loadingMore: false);
      if (source is DocumentSnapshotPersistence) {
        try {
          await (source as DocumentSnapshotPersistence).persistSnapshot(
            accountId: args.accountId,
            expectedAuthEpoch: args.authEpoch,
            snapshot: next,
          );
        } on Object {
          if (_accepts(serial, request)) {
            state = state.copyWith(
              errorMessage:
                  'This page is readable now, but its offline copy could not be updated.',
            );
          }
        }
      }
    } on Object {
      if (_accepts(serial, request)) {
        state = state.copyWith(
          loadingMore: false,
          errorMessage: 'More of this document could not be loaded.',
        );
      }
    }
  }

  /// Loads bounded subsequent pages until [blockId] is present or the
  /// retained mobile document ceiling is reached. This gives outline and
  /// evidence navigation an exact target beyond the first API page without a
  /// separate unbounded block lookup.
  Future<bool> ensureBlockLoaded(String blockId) async {
    if (blockId.isEmpty || blockId.length > 128 || !_scopeIsCurrent()) {
      return false;
    }
    for (
      var page = 0;
      page < documentExactNavigationMaximumPageRequests;
      page++
    ) {
      final snapshot = state.snapshot;
      if (snapshot == null) return false;
      if (snapshot.blocks.any((block) => block.id == blockId)) return true;
      final cursor = snapshot.nextCursor;
      if (cursor == null ||
          snapshot.blocks.length >= documentSnapshotMaximumBlocks) {
        return false;
      }
      await loadNextPage();
      if (!_scopeIsCurrent()) return false;
      final updated = state.snapshot;
      if (updated == null ||
          (updated.nextCursor == cursor &&
              updated.blocks.length == snapshot.blocks.length)) {
        return false;
      }
    }
    return state.snapshot?.blocks.any((block) => block.id == blockId) ?? false;
  }

  Future<void> _syncRestoredCheckpoint(ReadingCheckpoint checkpoint) async {
    if (!_scopeIsCurrent()) return;
    _checkpointRequest?.cancel('A restored checkpoint sync was replaced.');
    final request = RequestCancellation();
    _checkpointRequest = request;
    try {
      final synced = await _syncCheckpointWithRebase(checkpoint, request);
      if (!mounted || request.isCancelled || !_scopeIsCurrent()) return;
      final settled = synced.copyWith(pendingSync: false);
      await _source.saveCheckpointLocally(
        settled,
        expectedAuthEpoch: args.authEpoch,
      );
      if (!mounted || request.isCancelled || !_scopeIsCurrent()) return;
      state = state.copyWith(checkpoint: settled, clearError: true);
    } on ApiException catch (error) {
      if (!error.cancelled && mounted && _scopeIsCurrent()) {
        state = state.copyWith(
          errorMessage:
              'Checkpoint remains saved on this device and will retry later.',
        );
      }
    }
  }

  Future<ReadingCheckpoint?> _restoreCheckpoint(
    RequestCancellation cancellation,
  ) async {
    final local = await _source.readCheckpoint(
      accountId: args.accountId,
      paperId: args.paperId,
    );
    if (_source.isOffline || cancellation.isCancelled || !_scopeIsCurrent()) {
      return local;
    }
    final ReadingCheckpoint? remote;
    try {
      remote = await _source.fetchCheckpoint(
        accountId: args.accountId,
        paperId: args.paperId,
        expectedAuthEpoch: args.authEpoch,
        cancellation: cancellation,
      );
    } on ApiException catch (error) {
      if (local != null &&
          (error.isOffline ||
              (error.statusCode != null && error.statusCode! >= 500))) {
        return local;
      }
      rethrow;
    }
    if (cancellation.isCancelled || !_scopeIsCurrent()) return null;
    if (remote == null) return local;

    final ReadingCheckpoint reconciled;
    if (local != null &&
        local.pendingSync &&
        local.generation == args.generation) {
      reconciled = local.copyWith(
        revision: remote.revision,
        pendingSync: true,
        operationId: const Uuid().v7(),
      );
    } else {
      reconciled = remote.copyWith(pendingSync: false, clearOperationId: true);
    }
    await _source.saveCheckpointLocally(
      reconciled,
      expectedAuthEpoch: args.authEpoch,
    );
    if (cancellation.isCancelled || !_scopeIsCurrent()) return null;
    return reconciled;
  }

  Future<ReadingCheckpoint> _syncCheckpointWithRebase(
    ReadingCheckpoint checkpoint,
    RequestCancellation cancellation,
  ) async {
    try {
      return await _source.syncCheckpoint(
        checkpoint: checkpoint,
        expectedAuthEpoch: args.authEpoch,
        cancellation: cancellation,
      );
    } on ApiException catch (error) {
      if (error.code != 'RESEARCH_REVISION_CONFLICT' ||
          cancellation.isCancelled ||
          !_scopeIsCurrent()) {
        rethrow;
      }
      final remote = await _source.fetchCheckpoint(
        accountId: args.accountId,
        paperId: args.paperId,
        expectedAuthEpoch: args.authEpoch,
        cancellation: cancellation,
      );
      if (remote == null) rethrow;

      final rebased = checkpoint.copyWith(
        revision: remote.revision,
        pendingSync: true,
        operationId: const Uuid().v7(),
      );
      await _source.saveCheckpointLocally(
        rebased,
        expectedAuthEpoch: args.authEpoch,
      );
      if (cancellation.isCancelled || !_scopeIsCurrent()) {
        throw const ApiException(
          code: 'REQUEST_CANCELLED',
          message: 'Checkpoint scope changed during conflict recovery.',
        );
      }
      return _source.syncCheckpoint(
        checkpoint: rebased,
        expectedAuthEpoch: args.authEpoch,
        cancellation: cancellation,
      );
    }
  }

  void highlightBlock(String? blockId) {
    state = state.copyWith(
      highlightedBlockId: blockId,
      clearHighlight: blockId == null,
    );
  }

  bool _accepts(int serial, RequestCancellation request) =>
      mounted &&
      serial == _requestSerial &&
      !request.isCancelled &&
      _scopeIsCurrent();

  @override
  void dispose() {
    _documentRequest?.cancel('The document reader was disposed.');
    _pageRequest?.cancel('The document reader was disposed.');
    _visualObjectsRequest?.cancel('The document reader was disposed.');
    _checkpointRequest?.cancel('The document reader was disposed.');
    super.dispose();
  }
}
