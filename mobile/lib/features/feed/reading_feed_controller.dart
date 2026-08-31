import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/account_providers.dart';
import '../../app/discovery_providers.dart';
import '../../app/feature_flags.dart';
import '../../app/library_providers.dart';
import '../../core/account/account_data_write_barrier.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/auth/auth_models.dart';
import '../../core/library/library_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../core/reading_feed/reading_feed_models.dart';
import '../../core/reading_feed/reading_feed_page_cache.dart';
import '../../core/reading_feed/reading_feed_policy.dart';
import '../../core/reading_feed/reading_feed_repository.dart';
import '../../core/telemetry/telemetry.dart';
import '../library/paper_import_drafts.dart';

const _readingFeedPageSize = 20;
const _readingFeedLoadTrigger = 3;
const readingFeedRecommendationRecheckInterval = Duration(seconds: 45);

final class ReadingFeedAccountScope {
  const ReadingFeedAccountScope({
    required this.accountId,
    required this.authEpoch,
  });

  final String accountId;
  final int authEpoch;

  @override
  bool operator ==(Object other) =>
      other is ReadingFeedAccountScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch;

  @override
  int get hashCode => Object.hash(accountId, authEpoch);
}

final class ReadingFeedImportActivity {
  const ReadingFeedImportActivity({
    required this.scope,
    required this.operationId,
    required this.label,
  });

  final ReadingFeedAccountScope scope;
  final String operationId;
  final String label;
}

final class ReadingFeedImportActivityController
    extends StateNotifier<ReadingFeedImportActivity?> {
  ReadingFeedImportActivityController() : super(null);

  void begin({
    required ReadingFeedAccountScope scope,
    required String operationId,
    required String label,
  }) {
    state = ReadingFeedImportActivity(
      scope: scope,
      operationId: operationId,
      label: label,
    );
  }

  void end(String operationId) {
    if (state?.operationId == operationId) state = null;
  }

  void clear() => state = null;
}

final readingFeedImportActivityProvider =
    StateNotifierProvider<
      ReadingFeedImportActivityController,
      ReadingFeedImportActivity?
    >((_) => ReadingFeedImportActivityController());

/// One synchronous view of every authority signal that can affect whether a
/// recommendation is safe to display.
final class ReadingFeedControllerInput {
  ReadingFeedControllerInput({
    required this.authentication,
    required this.sessionScope,
    required this.displayScope,
    required this.verifiedScope,
    required List<LibraryListItem> localItems,
    required this.pendingIntents,
    required this.pendingImportCount,
    required this.checkpoint,
    required this.offline,
    required this.dataReady,
    required this.personalizationEnabled,
    this.saveIntent,
    this.finalCompletionAcknowledgement,
  }) : localItems = List<LibraryListItem>.unmodifiable(localItems);

  final ReadingFeedAuthentication authentication;
  final ReadingFeedAccountScope? sessionScope;
  final ReadingFeedAccountScope? displayScope;
  final ReadingFeedAccountScope? verifiedScope;
  final List<LibraryListItem> localItems;
  final LibraryPendingIntentCounts pendingIntents;
  final int pendingImportCount;
  final LibrarySyncCheckpoint checkpoint;
  final bool offline;
  final bool dataReady;
  final bool? personalizationEnabled;
  final LibrarySaveIntentSignal? saveIntent;
  final LibraryFinalCompletionAcknowledgement? finalCompletionAcknowledgement;

  bool get forYouAvailable => personalizationEnabled == true;

  bool get canRequest =>
      authentication == ReadingFeedAuthentication.verified &&
      dataReady &&
      verifiedScope != null &&
      displayScope == verifiedScope &&
      !offline &&
      !checkpoint.resetting &&
      pendingIntents.total == 0 &&
      saveIntent == null &&
      pendingImportCount == 0;

  ReadingFeedPolicyInput policyInput({ReadingFeedPage? serverPage}) {
    final effectiveAuthentication = switch (authentication) {
      ReadingFeedAuthentication.signedOut =>
        ReadingFeedAuthentication.signedOut,
      ReadingFeedAuthentication.changing => ReadingFeedAuthentication.changing,
      _ when !dataReady => ReadingFeedAuthentication.unknown,
      _ => authentication,
    };
    return ReadingFeedPolicyInput(
      authentication: effectiveAuthentication,
      localActiveCount: localItems.length,
      pendingSaveCount: pendingIntents.saves + (saveIntent == null ? 0 : 1),
      pendingRemoveCount: pendingIntents.removes,
      pendingImportCount: pendingImportCount,
      syncReset: checkpoint.resetting,
      offline: offline,
      localRevision: checkpoint.initialized ? checkpoint.lastRevision : null,
      serverPage: serverPage,
    );
  }

  String get authorityKey {
    final buffer = StringBuffer()
      ..write(authentication.name)
      ..write('|session:')
      ..write(_scopeKey(sessionScope))
      ..write('|display:')
      ..write(_scopeKey(displayScope))
      ..write('|verified:')
      ..write(_scopeKey(verifiedScope))
      ..write('|ready:$dataReady|offline:$offline')
      ..write('|personalization:${personalizationEnabled ?? 'unknown'}')
      ..write('|checkpoint:${checkpoint.initialized}:')
      ..write(checkpoint.lastRevision)
      ..write('|pending:${pendingIntents.saves}:')
      ..write(pendingIntents.removes)
      ..write(':$pendingImportCount')
      ..write('|save-intent:${saveIntent?.sequence ?? '-'}');
    for (final item in localItems) {
      buffer
        ..write('|paper:')
        ..write(item.paper.paperId)
        ..write(':')
        ..write(item.savedAt.toUtc().microsecondsSinceEpoch)
        ..write(':')
        ..write(item.savedState.syncPending);
    }
    return buffer.toString();
  }
}

String _scopeKey(ReadingFeedAccountScope? scope) =>
    scope == null ? '-' : '${scope.accountId}:${scope.authEpoch}';

/// Public discovery is visible only after the app has positively established
/// that there is no signed-in account to protect with queue-first authority.
final publicDiscoveryAllowedProvider = Provider<bool>((ref) {
  final flags = ref.watch(featureFlagsProvider);
  if (!flags.accounts ||
      !flags.library ||
      !flags.readingFeed ||
      !flags.toReadFirstEnforcement) {
    return true;
  }
  final session = ref.watch(authSessionProvider);
  ReadingFeedEnforcement? serverEnforcement;
  if (session.phase != AuthSessionPhase.guest) {
    final accountId = session.accountId;
    final verified = ref.watch(verifiedLibraryScopeProvider);
    serverEnforcement = scopedServerEnforcement(
      state: ref.watch(readingFeedControllerProvider),
      sessionScope: accountId == null
          ? null
          : ReadingFeedAccountScope(
              accountId: accountId,
              authEpoch: session.epoch,
            ),
      verifiedScope: verified == null
          ? null
          : ReadingFeedAccountScope(
              accountId: verified.accountId,
              authEpoch: verified.authEpoch,
            ),
    );
  }
  return allowsPublicDiscovery(
    flags: flags,
    authPhase: session.phase,
    serverEnforcement: serverEnforcement,
  );
});

/// Pure rollout boundary shared by presentation and prefetch activation.
/// Shadow builds keep legacy discovery active; strict builds suppress it until
/// the session is positively known to be a guest.
bool allowsPublicDiscovery({
  required FeatureFlags flags,
  required AuthSessionPhase authPhase,
  ReadingFeedEnforcement? serverEnforcement,
}) {
  if (!flags.readingFeed || !flags.toReadFirstEnforcement) return true;
  if (!flags.accounts || !flags.library) return true;
  if (authPhase == AuthSessionPhase.guest) return true;
  return serverEnforcement == ReadingFeedEnforcement.shadow;
}

/// Accepts rollout authority only when the response state belongs to the
/// currently verified account and auth epoch. A prior account's `shadow`
/// response must never reopen public discovery during a scope transition.
ReadingFeedEnforcement? scopedServerEnforcement({
  required ReadingFeedState state,
  required ReadingFeedAccountScope? sessionScope,
  required ReadingFeedAccountScope? verifiedScope,
}) {
  if (sessionScope == null ||
      verifiedScope == null ||
      sessionScope != verifiedScope ||
      state.authEpoch != sessionScope.authEpoch ||
      state.accountScopeFingerprint !=
          readingFeedScopeFingerprint(sessionScope)) {
    return null;
  }
  return state.serverEnforcement;
}

final readingFeedRepositoryProvider = Provider<ReadingFeedRepository>(
  (ref) => ReadingFeedRepository(remote: ref.watch(readingFeedApiProvider)),
);

final readingFeedPageCacheProvider = Provider<ReadingFeedPageCache>(
  (_) => SharedPreferencesReadingFeedPageCache(),
);

final readingFeedAuthorityInputProvider = Provider<ReadingFeedControllerInput>((
  ref,
) {
  final flags = ref.watch(featureFlagsProvider);
  if (!flags.readingFeed || !flags.accounts || !flags.library) {
    return ReadingFeedControllerInput(
      authentication: ReadingFeedAuthentication.signedOut,
      sessionScope: null,
      displayScope: null,
      verifiedScope: null,
      localItems: const [],
      pendingIntents: const LibraryPendingIntentCounts.empty(),
      pendingImportCount: 0,
      checkpoint: const LibrarySyncCheckpoint.unknown(),
      offline: false,
      dataReady: true,
      personalizationEnabled: false,
    );
  }

  final session = ref.watch(authSessionProvider);
  final display = ref.watch(libraryDisplayScopeProvider);
  final verified = ref.watch(verifiedLibraryScopeProvider);
  final network = ref.watch(networkOfflineProvider);
  final importActivity = ref.watch(readingFeedImportActivityProvider);
  final durableImportDrafts = ref.watch(paperImportDraftAuthorityProvider);
  final saveIntentSignal = ref.watch(librarySaveIntentSignalProvider);
  final completionAcknowledgement = ref.watch(
    libraryFinalCompletionAcknowledgementProvider,
  );
  final personalizationEnabled = flags.researchProfilesEnabled
      ? ref.watch(interactionPersonalizationEnabledProvider)
      : false;
  final offlineValue = network.asData?.value;

  final sessionScope = session.accountId == null
      ? null
      : ReadingFeedAccountScope(
          accountId: session.accountId!,
          authEpoch: session.epoch,
        );
  final displayScope = display == null
      ? null
      : ReadingFeedAccountScope(
          accountId: display.accountId,
          authEpoch: display.authEpoch,
        );
  final verifiedScope = verified == null
      ? null
      : ReadingFeedAccountScope(
          accountId: verified.accountId,
          authEpoch: verified.authEpoch,
        );
  final scopedSaveIntent =
      saveIntentSignal != null &&
          saveIntentSignal.accountId == display?.accountId &&
          saveIntentSignal.authEpoch == display?.authEpoch
      ? saveIntentSignal
      : null;
  final scopedCompletionAcknowledgement =
      completionAcknowledgement != null &&
          completionAcknowledgement.accountId == verified?.accountId &&
          completionAcknowledgement.authEpoch == verified?.authEpoch
      ? completionAcknowledgement
      : null;

  AsyncValue<List<LibraryListItem>>? local;
  AsyncValue<LibraryPendingIntentCounts>? pending;
  AsyncValue<LibrarySyncCheckpoint>? checkpoint;
  if (display != null) {
    local = ref.watch(toReadItemsProvider(display));
    pending = ref.watch(libraryPendingIntentsProvider(display));
    checkpoint = ref.watch(librarySyncCheckpointProvider(display));
  }
  final localValue = local?.asData?.value;
  final pendingValue = pending?.asData?.value;
  final checkpointValue = checkpoint?.asData?.value;
  final dataReady =
      display != null &&
      localValue != null &&
      pendingValue != null &&
      checkpointValue != null &&
      offlineValue != null &&
      (verifiedScope == null || durableImportDrafts.scopeReady);

  final authentication = switch (session.phase) {
    AuthSessionPhase.guest => ReadingFeedAuthentication.signedOut,
    AuthSessionPhase.checkingStoredSession ||
    AuthSessionPhase.authenticating ||
    AuthSessionPhase.signingOut ||
    AuthSessionPhase.deletionPending => ReadingFeedAuthentication.changing,
    _ when verifiedScope != null => ReadingFeedAuthentication.verified,
    _ => ReadingFeedAuthentication.unknown,
  };

  return ReadingFeedControllerInput(
    authentication: authentication,
    sessionScope: sessionScope,
    displayScope: displayScope,
    verifiedScope: verifiedScope,
    localItems: localValue ?? const [],
    pendingIntents: pendingValue ?? const LibraryPendingIntentCounts.empty(),
    pendingImportCount:
        (importActivity != null && importActivity.scope == displayScope
            ? 1
            : 0) +
        (verifiedScope == null ? 0 : durableImportDrafts.pendingCount),
    checkpoint: checkpointValue ?? const LibrarySyncCheckpoint.unknown(),
    // Unknown connectivity is treated as offline until the first transport
    // status arrives, preventing an optimistic recommendation request.
    offline: offlineValue ?? true,
    dataReady: dataReady,
    personalizationEnabled: personalizationEnabled,
    saveIntent: scopedSaveIntent,
    finalCompletionAcknowledgement: scopedCompletionAcknowledgement,
  );
});

final readingFeedControllerProvider =
    StateNotifierProvider<ReadingFeedController, ReadingFeedState>((ref) {
      final flags = ref.watch(featureFlagsProvider);
      final controller = ReadingFeedController(
        repository: ref.watch(readingFeedRepositoryProvider),
        pageCache: ref.watch(readingFeedPageCacheProvider),
        accountDataWriteBarrier: ref.watch(accountDataWriteBarrierProvider),
        telemetry: ref.watch(telemetrySinkProvider),
        shadowMode: flags.readingFeed && !flags.toReadFirstEnforcement,
      );
      ref.listen<ReadingFeedControllerInput>(
        readingFeedAuthorityInputProvider,
        (_, next) {
          controller.updateInput(next);
          final acknowledgement = next.finalCompletionAcknowledgement;
          if (acknowledgement != null) {
            scheduleMicrotask(
              () => ref
                  .read(libraryFinalCompletionAcknowledgementProvider.notifier)
                  .end(acknowledgement.sequence),
            );
          }
          final signal = next.saveIntent;
          if (signal != null &&
              (next.pendingIntents.saves > 0 || next.localItems.isNotEmpty)) {
            scheduleMicrotask(
              () => ref
                  .read(librarySaveIntentSignalProvider.notifier)
                  .end(signal.sequence),
            );
          }
        },
        fireImmediately: true,
      );
      return controller;
    });

/// Keeps authority cancellation and refresh listeners alive even when a
/// different navigation branch temporarily covers the Read branch. With
/// enforcement off, the same runtime supplies privacy-safe shadow decisions
/// while the legacy public surface remains visible.
final readingFeedRuntimeProvider = Provider<void>((ref) {
  if (!ref.watch(featureFlagsProvider).readingFeed) return;
  ref.watch(readingFeedControllerProvider);
});

final class ReadingFeedController extends StateNotifier<ReadingFeedState> {
  ReadingFeedController({
    required ReadingFeedRepository repository,
    ReadingFeedPageCache? pageCache,
    AccountDataWriteBarrier? accountDataWriteBarrier,
    ReadingFeedPolicy policy = const ReadingFeedPolicy(),
    TelemetrySink telemetry = const NoopTelemetrySink(),
    ReadingFeedRecommendationMode? recommendationMode,
    Duration recommendationRecheckInterval =
        readingFeedRecommendationRecheckInterval,
    DateTime Function()? clock,
    bool shadowMode = false,
    bool autoRefresh = true,
  }) : assert(recommendationRecheckInterval > Duration.zero),
       _repository = repository,
       _pageCache = pageCache,
       _accountDataWriteBarrier = accountDataWriteBarrier,
       _policy = policy,
       _telemetry = telemetry,
       _recommendationMode = recommendationMode,
       _recommendationRecheckInterval = recommendationRecheckInterval,
       _clock = clock ?? DateTime.now,
       _shadowMode = shadowMode,
       _autoRefresh = autoRefresh,
       super(const ReadingFeedState());

  final ReadingFeedRepository _repository;
  final ReadingFeedPageCache? _pageCache;
  final AccountDataWriteBarrier? _accountDataWriteBarrier;
  final ReadingFeedPolicy _policy;
  final TelemetrySink _telemetry;
  ReadingFeedRecommendationMode? _recommendationMode;
  final Duration _recommendationRecheckInterval;
  final DateTime Function() _clock;
  final bool _shadowMode;
  final bool _autoRefresh;
  ReadingFeedControllerInput? _input;
  ReadingFeedPage? _serverPage;
  final List<ReadingFeedPage> _continuationPages = [];
  ReadingFeedCachedPage? _cachedQueuePage;
  ReadingFeedCachedPage? _cachedRecommendationPage;
  RequestCancellation? _initialRequest;
  RequestCancellation? _pageRequest;
  Future<void>? _refreshFlight;
  int _generation = 0;
  int _cacheGeneration = 0;
  String? _lastRefreshKey;
  Object? _lastError;
  bool _loadingInitial = false;
  bool _loadingMore = false;
  Timer? _recommendationRecheck;
  String? _lastShadowDecisionKey;
  int? _lastSaveIntentSequence;
  DateTime? _suppressionStartedAt;
  int? _lastCompletionAcknowledgementSequence;
  DateTime? _unlockStartedAt;
  DateTime? _finalItemCheckingStartedAt;

  bool get _forYouAvailable => _input?.forYouAvailable == true;

  ReadingFeedRecommendationMode? get _effectiveRecommendationMode {
    if (_forYouAvailable) return _recommendationMode;
    return switch (_recommendationMode) {
      null || ReadingFeedRecommendationMode.forYou =>
        ReadingFeedRecommendationMode.recent,
      final mode => mode,
    };
  }

  void updateInput(ReadingFeedControllerInput next) {
    final previous = _input;
    final authorityChanged = previous?.authorityKey != next.authorityKey;
    final scopeChanged =
        previous?.sessionScope != next.sessionScope ||
        previous?.verifiedScope != next.verifiedScope;
    if (scopeChanged) {
      _finishFinalItemChecking('account_changed');
      _lastSaveIntentSequence = null;
      _suppressionStartedAt = null;
      _lastCompletionAcknowledgementSequence = null;
      _unlockStartedAt = null;
    }
    final saveIntent = next.saveIntent;
    if (saveIntent != null && saveIntent.sequence != _lastSaveIntentSequence) {
      _lastSaveIntentSequence = saveIntent.sequence;
      if (state.mode == ReadingFeedMode.recommendations) {
        _suppressionStartedAt = saveIntent.startedAt;
        emitTelemetry(
          _telemetry,
          PakPerkTelemetryEvent.recommendationAdvanceCancelledAfterSave,
          const {'outcome': 'cancelled', 'local_intent': true},
        );
      }
      // A newer active save means the earlier completion is no longer the
      // final queue completion whose unlock latency we intended to measure.
      _unlockStartedAt = null;
    }
    final acknowledgement = next.finalCompletionAcknowledgement;
    if (acknowledgement != null &&
        acknowledgement.sequence != _lastCompletionAcknowledgementSequence) {
      _lastCompletionAcknowledgementSequence = acknowledgement.sequence;
      if (state.mode != ReadingFeedMode.recommendations) {
        _unlockStartedAt = acknowledgement.acknowledgedAt;
      }
    }
    if (next.localItems.isNotEmpty ||
        next.pendingIntents.saves > 0 ||
        next.pendingImportCount > 0) {
      _unlockStartedAt = null;
    }
    if (!next.forYouAvailable &&
        _recommendationMode == ReadingFeedRecommendationMode.forYou) {
      _recommendationMode = ReadingFeedRecommendationMode.recent;
    }
    _input = next;
    if (authorityChanged) {
      _invalidateRequests('Reading-feed authority changed.');
      _serverPage = null;
      _continuationPages.clear();
      _cachedQueuePage = null;
      _cachedRecommendationPage = null;
      final cacheGeneration = ++_cacheGeneration;
      _lastRefreshKey = null;
      _lastError = null;
      _loadingInitial = false;
      _loadingMore = false;
      _lastShadowDecisionKey = null;
      final scope = next.verifiedScope;
      if (scope != null && _pageCache != null) {
        unawaited(
          _loadCachedPages(
            scope: scope,
            requestedMode: _effectiveRecommendationMode,
            cacheGeneration: cacheGeneration,
          ),
        );
      }
    }
    _publish();
    if (_autoRefresh && next.canRequest && _lastRefreshKey == null) {
      unawaited(refresh());
    }
  }

  Future<void> refresh({bool force = false}) {
    final input = _input;
    final scope = input?.verifiedScope;
    if (input == null || !input.canRequest || scope == null) {
      return Future.value();
    }
    final refreshKey = input.authorityKey;
    final active = _refreshFlight;
    if (!force && _lastRefreshKey == refreshKey) {
      return active ?? Future.value();
    }

    _initialRequest?.cancel('A newer reading-feed refresh replaced this one.');
    final request = RequestCancellation();
    _initialRequest = request;
    final generation = ++_generation;
    final requestScope = ReadingFeedRequestScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      generation: generation,
    );
    _lastRefreshKey = refreshKey;
    _loadingInitial = state.items.isEmpty;
    _lastError = null;
    _publish();
    final requestedMode = _effectiveRecommendationMode;

    late final Future<void> flight;
    flight =
        _performRefresh(
          request: request,
          requestScope: requestScope,
          requestedMode: requestedMode,
        ).whenComplete(() {
          if (identical(_refreshFlight, flight)) _refreshFlight = null;
          if (identical(_initialRequest, request)) _initialRequest = null;
        });
    _refreshFlight = flight;
    return flight;
  }

  Future<void> _performRefresh({
    required RequestCancellation request,
    required ReadingFeedRequestScope requestScope,
    required ReadingFeedRecommendationMode? requestedMode,
  }) async {
    try {
      final response = await _repository.page(
        expectedAuthEpoch: requestScope.authEpoch,
        recommendationMode: requestedMode,
        limit: _readingFeedPageSize,
        cancellation: request,
      );
      final input = _input;
      final currentScope = _currentRequestScope;
      if (input == null ||
          currentScope == null ||
          !_sameAccountEpoch(requestScope, currentScope)) {
        return;
      }
      if (!_isCurrent(requestScope)) {
        _recordRecommendationRejectionIfDenied(response, input);
        return;
      }
      if (response.mode == ReadingFeedServerMode.recommendations &&
          !_policy.canPublishResponse(
            response: response,
            requestScope: requestScope,
            currentScope: currentScope,
            currentInput: input.policyInput(),
          )) {
        _recordRecommendationRejectionIfDenied(response, input);
        return;
      }
      if (!_canPublishRecommendationMode(response)) {
        _recordRecommendationRejectionIfDenied(response, input);
        _serverPage = null;
        _continuationPages.clear();
        _lastError = StateError(
          'The server returned For You while personalization was unavailable.',
        );
        _loadingInitial = false;
        _publish();
        return;
      }
      _serverPage = response;
      _continuationPages.clear();
      _lastError = null;
      _loadingInitial = false;
      _publish();
      unawaited(
        _cachePageIfCurrent(
          page: response,
          requestScope: requestScope,
          requestedMode: requestedMode,
        ),
      );
    } on ApiException catch (error) {
      if (!_isCurrent(requestScope) || error.cancelled) return;
      _loadingInitial = false;
      _lastError = error;
      if (error.code == 'READING_FEED_CURSOR_STALE') {
        _serverPage = null;
        _continuationPages.clear();
        _lastRefreshKey = null;
      }
      _publish();
    } on Object catch (error) {
      if (!_isCurrent(requestScope)) return;
      _loadingInitial = false;
      _lastError = error;
      _publish();
    }
  }

  Future<void> loadMore() async {
    final input = _input;
    final firstPage = _serverPage;
    final existingPages = firstPage == null
        ? const <ReadingFeedPage>[]
        : <ReadingFeedPage>[firstPage, ..._continuationPages];
    final cursor = existingPages.isEmpty ? null : existingPages.last.nextCursor;
    final scope = input?.verifiedScope;
    if (input == null ||
        firstPage == null ||
        cursor == null ||
        cursor.isEmpty ||
        scope == null ||
        !input.canRequest ||
        _loadingMore) {
      return;
    }

    _pageRequest?.cancel(
      'A newer reading-feed page request replaced this one.',
    );
    final request = RequestCancellation();
    _pageRequest = request;
    final generation = ++_generation;
    final requestScope = ReadingFeedRequestScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      generation: generation,
    );
    _loadingMore = true;
    _lastError = null;
    _publish();
    final requestedMode = _effectiveRecommendationMode;
    try {
      final response = await _repository.page(
        expectedAuthEpoch: scope.authEpoch,
        recommendationMode: requestedMode,
        cursor: cursor,
        limit: _readingFeedPageSize,
        cancellation: request,
      );
      final currentInput = _input;
      final currentScope = _currentRequestScope;
      if (currentInput == null ||
          currentScope == null ||
          !_sameAccountEpoch(requestScope, currentScope)) {
        return;
      }
      if (!_isCurrent(requestScope)) {
        _recordRecommendationRejectionIfDenied(response, currentInput);
        return;
      }
      if (!_isValidContinuation(existingPages, response)) {
        _recordRecommendationRejectionIfDenied(response, currentInput);
        _restartAfterStalePage();
        return;
      }
      if (!_canPublishRecommendationMode(response)) {
        _recordRecommendationRejectionIfDenied(response, currentInput);
        _restartAfterStalePage();
        return;
      }
      if (response.mode == ReadingFeedServerMode.recommendations &&
          !_policy.canPublishResponse(
            response: response,
            requestScope: requestScope,
            currentScope: currentScope,
            currentInput: currentInput.policyInput(),
          )) {
        _recordRecommendationRejectionIfDenied(response, currentInput);
        return;
      }
      _continuationPages.add(response);
      _lastError = null;
      // Each persisted recommendation batch owns only its response page. Keep
      // the already-cached first page instead of serializing a heterogeneous
      // cursor walk beneath one page-level batch identity.
    } on ApiException catch (error) {
      if (!_isCurrent(requestScope) || error.cancelled) return;
      if (error.code == 'READING_FEED_CURSOR_STALE') {
        _restartAfterStalePage();
        return;
      }
      _lastError = error;
    } on Object catch (error) {
      if (!_isCurrent(requestScope)) return;
      _lastError = error;
    } finally {
      if (_isCurrent(requestScope)) {
        _loadingMore = false;
        _publish();
      }
      if (identical(_pageRequest, request)) _pageRequest = null;
    }
  }

  Future<void> onCommittedPage(int index) async {
    if (index < 0 || index >= state.items.length) return;
    if (state.items.length - index - 1 <= _readingFeedLoadTrigger) {
      await loadMore();
    }
  }

  Future<void> onForeground() => refresh(force: true);

  /// Selects an explicit fallback mode only while current account-scoped
  /// authority still permits recommendation presentation. Queue/checking
  /// states ignore this request and therefore cannot be bypassed by the UI.
  Future<void> selectRecommendationMode(ReadingFeedRecommendationMode mode) {
    final input = _input;
    if (input == null || !input.canRequest || !state.recommendationsVisible) {
      return Future.value();
    }
    if (mode == ReadingFeedRecommendationMode.forYou &&
        !input.forYouAvailable) {
      return Future.value();
    }
    if (_recommendationMode == mode && state.recommendationMode == mode) {
      return Future.value();
    }
    _recommendationMode = mode;
    _invalidateRequests('The recommendation mode changed.');
    _serverPage = null;
    _continuationPages.clear();
    _cachedRecommendationPage = null;
    final cacheGeneration = ++_cacheGeneration;
    _lastRefreshKey = null;
    _lastError = null;
    _publish();
    final scope = input.verifiedScope;
    if (scope != null && _pageCache != null) {
      unawaited(
        _loadCachedRecommendations(
          scope: scope,
          requestedMode: mode,
          cacheGeneration: cacheGeneration,
        ),
      );
    }
    return refresh(force: true);
  }

  bool _canPublishRecommendationMode(ReadingFeedPage page) {
    if (_forYouAvailable ||
        page.mode != ReadingFeedServerMode.recommendations) {
      return true;
    }
    return page.items.every(
      (item) =>
          item.source != ReadingFeedItemSource.forYouV1 &&
          item.recommendation?.mode != ReadingFeedRecommendationMode.forYou,
    );
  }

  void _recordRecommendationRejectionIfDenied(
    ReadingFeedPage response,
    ReadingFeedControllerInput input,
  ) {
    if (response.mode != ReadingFeedServerMode.recommendations) return;
    String? reason;
    if (!_canPublishRecommendationMode(response)) {
      reason = input.personalizationEnabled == false
          ? 'personalization_off'
          : 'personalization_unknown';
    } else if (!response.decision.queueProvenEmpty ||
        response.decision.activeToReadCount != 0) {
      reason = 'server_queue_not_empty';
    } else if (input.checkpoint.resetting) {
      reason = 'sync_reset';
    } else if (input.localItems.isNotEmpty) {
      reason = 'local_queue_non_empty';
    } else if (input.pendingIntents.saves > 0 || input.saveIntent != null) {
      reason = 'pending_save';
    } else if (input.pendingImportCount > 0) {
      reason = 'pending_import';
    } else if (input.pendingIntents.removes > 0) {
      reason = 'pending_remove';
    } else if (input.checkpoint.initialized &&
        response.decision.libraryRevision < input.checkpoint.lastRevision) {
      reason = 'revision_stale';
    }
    if (reason == null) return;
    emitTelemetry(
      _telemetry,
      PakPerkTelemetryEvent.recommendationPublicationRejected,
      {'reason': reason},
    );
  }

  bool _sameAccountEpoch(
    ReadingFeedRequestScope request,
    ReadingFeedRequestScope current,
  ) =>
      request.accountId == current.accountId &&
      request.authEpoch == current.authEpoch;

  void _restartAfterStalePage() {
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.queueStaleCursorRecovery, {
      'outcome': 'restart_requested',
      'surface': state.mode == ReadingFeedMode.recommendations
          ? 'recommendations'
          : 'queue',
      'offline': state.offline,
    });
    _serverPage = null;
    _continuationPages.clear();
    _lastRefreshKey = null;
    _lastError = null;
    _loadingMore = false;
    _publish();
    unawaited(refresh(force: true));
  }

  List<ReadingFeedPage> get _displayServerPages {
    final live = _serverPage;
    final cached = _cachedRecommendationPage;
    if (live == null) return const [];
    if (live.mode != ReadingFeedServerMode.recommendations ||
        live.items.isNotEmpty ||
        cached == null ||
        !cached.matchesLiveRecommendationDecision(
          live,
          requestedMode: _effectiveRecommendationMode,
        )) {
      return <ReadingFeedPage>[live, ..._continuationPages];
    }
    final content = cached.page;
    return <ReadingFeedPage>[
      ReadingFeedPage(
        enforcement: live.enforcement,
        mode: live.mode,
        decision: live.decision,
        batchId: content.batchId,
        batchMetadata: content.batchMetadata,
        brief: live.brief,
        items: content.items,
        nextCursor: content.nextCursor,
        serverTime: live.serverTime,
      ),
    ];
  }

  Future<void> _loadCachedPages({
    required ReadingFeedAccountScope scope,
    required ReadingFeedRecommendationMode? requestedMode,
    required int cacheGeneration,
  }) async {
    final cache = _pageCache;
    if (cache == null) return;
    List<ReadingFeedCachedPage?> pages;
    try {
      pages = await Future.wait<ReadingFeedCachedPage?>([
        cache.loadQueue(scope.accountId),
        cache.loadRecommendations(
          scope.accountId,
          requestedMode: requestedMode,
        ),
      ]);
    } on Object {
      // Derived cache availability never changes live queue authority.
      return;
    }
    if (!_isCacheScopeCurrent(scope, cacheGeneration) ||
        _effectiveRecommendationMode != requestedMode) {
      return;
    }
    _cachedQueuePage = pages[0];
    _cachedRecommendationPage = pages[1];
    _publish();
  }

  Future<void> _loadCachedRecommendations({
    required ReadingFeedAccountScope scope,
    required ReadingFeedRecommendationMode? requestedMode,
    required int cacheGeneration,
  }) async {
    ReadingFeedCachedPage? cached;
    try {
      cached = await _pageCache?.loadRecommendations(
        scope.accountId,
        requestedMode: requestedMode,
      );
    } on Object {
      // Derived cache availability never changes live queue authority.
      return;
    }
    if (!_isCacheScopeCurrent(scope, cacheGeneration) ||
        _effectiveRecommendationMode != requestedMode) {
      return;
    }
    _cachedRecommendationPage = cached;
    _publish();
  }

  Future<void> _cachePageIfCurrent({
    required ReadingFeedPage page,
    required ReadingFeedRequestScope requestScope,
    required ReadingFeedRecommendationMode? requestedMode,
  }) async {
    final cache = _pageCache;
    if (cache == null || page.items.isEmpty) return;
    bool isCurrentScope() {
      final scope = _input?.verifiedScope;
      return mounted &&
          scope?.accountId == requestScope.accountId &&
          scope?.authEpoch == requestScope.authEpoch &&
          (page.mode == ReadingFeedServerMode.toRead ||
              _effectiveRecommendationMode == requestedMode);
    }

    try {
      final barrier = _accountDataWriteBarrier;
      if (barrier == null) {
        if (!isCurrentScope()) return;
        await cache.save(
          requestScope.accountId,
          page: page,
          requestedMode: requestedMode,
        );
        return;
      }
      await barrier.writeIfCurrent(
        accountId: requestScope.accountId,
        authEpoch: requestScope.authEpoch,
        isCurrent: isCurrentScope,
        write: () => cache.save(
          requestScope.accountId,
          page: page,
          requestedMode: requestedMode,
        ),
      );
    } on Object {
      // This derived cache never blocks or changes live queue authority.
    }
  }

  bool _isCacheScopeCurrent(
    ReadingFeedAccountScope scope,
    int cacheGeneration,
  ) =>
      mounted &&
      _cacheGeneration == cacheGeneration &&
      _input?.verifiedScope == scope;

  ReadingFeedRequestScope? get _currentRequestScope {
    final scope = _input?.verifiedScope;
    if (scope == null) return null;
    return ReadingFeedRequestScope(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      generation: _generation,
    );
  }

  bool _isCurrent(ReadingFeedRequestScope requestScope) {
    final current = _currentRequestScope;
    return mounted && current != null && current == requestScope;
  }

  void _publish() {
    final input = _input;
    if (input == null || !mounted) return;
    final policyInput = input.policyInput(serverPage: _serverPage);
    var decision = _policy.evaluate(policyInput);
    var items = <PaperSummary>[];
    var queueItems = <ReadingFeedQueuePresentation>[];
    var recommendationItems = <ReadingFeedItem>[];
    var recommendationProvenance = <ReadingFeedRecommendationProvenance?>[];
    String? recommendationBatchId;
    final displayServerPages = _displayServerPages;
    final displayServerPage = displayServerPages.isEmpty
        ? null
        : displayServerPages.first;
    var nextCursor = displayServerPages.isEmpty
        ? null
        : displayServerPages.last.nextCursor;

    switch (decision.mode) {
      case ReadingFeedMode.guestDiscovery:
      case ReadingFeedMode.finishingQueue:
        nextCursor = null;
      case ReadingFeedMode.checkingQueue:
      case ReadingFeedMode.unavailable:
        final cached = _cachedQueuePage?.page;
        if (input.localItems.isEmpty &&
            cached != null &&
            cached.mode == ReadingFeedServerMode.toRead &&
            cached.items.isNotEmpty) {
          items = cached.papers;
          queueItems = _queuePresentations(cached.items);
        }
        nextCursor = null;
      case ReadingFeedMode.toRead:
        if (input.localItems.isNotEmpty) {
          final localItems = _fifoLocalItems(input.localItems);
          items = localItems.map((item) => item.paper).toList(growable: false);
          queueItems = localItems
              .map(
                (item) => ReadingFeedQueuePresentation(
                  paper: item.paper,
                  savedAt: item.savedAt,
                  state: item.state,
                  saveSourceKind: item.saveSourceKind,
                  privateNote: item.privateNote,
                ),
              )
              .toList(growable: false);
          nextCursor = null;
        } else if (displayServerPage?.mode == ReadingFeedServerMode.toRead) {
          final serverItems = displayServerPages
              .expand((page) => page.items)
              .toList(growable: false);
          items = serverItems.map((item) => item.paper).toList(growable: false);
          queueItems = _queuePresentations(serverItems);
        } else if (_cachedQueuePage?.page case final cached?
            when cached.mode == ReadingFeedServerMode.toRead &&
                cached.items.isNotEmpty) {
          items = cached.papers;
          queueItems = _queuePresentations(cached.items);
          nextCursor = null;
        } else {
          nextCursor = null;
        }
      case ReadingFeedMode.recommendations:
        final page = displayServerPage;
        if (page != null &&
            page.mode == ReadingFeedServerMode.recommendations &&
            decision.allowRecommendationPublish) {
          recommendationItems = displayServerPages
              .expand((serverPage) => serverPage.items)
              .toList(growable: false);
          items = recommendationItems
              .map((item) => item.paper)
              .toList(growable: false);
          final nextPositionByBatch = <String, int>{};
          for (final serverPage in displayServerPages) {
            final batchId = serverPage.batchId;
            final batchMetadata = serverPage.batchMetadata;
            for (
              var position = 0;
              position < serverPage.items.length;
              position += 1
            ) {
              final item = serverPage.items[position];
              final rerankedPosition = batchId == null
                  ? null
                  : nextPositionByBatch[batchId] ?? 0;
              recommendationProvenance.add(
                batchId == null || batchMetadata == null
                    ? null
                    : ReadingFeedRecommendationProvenance(
                        paperId: item.paper.paperId,
                        batchId: batchId,
                        batchMetadata: batchMetadata,
                        rerankedPosition: rerankedPosition!,
                      ),
              );
              if (batchId != null) {
                nextPositionByBatch[batchId] = rerankedPosition! + 1;
              }
            }
          }
          final batchIds = recommendationProvenance
              .whereType<ReadingFeedRecommendationProvenance>()
              .map((provenance) => provenance.batchId)
              .toSet();
          if (batchIds.length == 1 &&
              recommendationProvenance.every(
                (provenance) => provenance != null,
              )) {
            recommendationBatchId = batchIds.single;
          }
        } else {
          nextCursor = null;
        }
    }

    if (_lastError != null &&
        items.isEmpty &&
        decision.mode == ReadingFeedMode.checkingQueue) {
      decision = const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.unavailable,
        authority: QueueAuthority.unknown,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }

    final serverDecision = _serverPage?.decision;
    state = ReadingFeedState(
      mode: decision.mode,
      queueAuthority: decision.authority,
      items: List<PaperSummary>.unmodifiable(items),
      queueItems: List<ReadingFeedQueuePresentation>.unmodifiable(queueItems),
      recommendationItems: List<ReadingFeedItem>.unmodifiable(
        recommendationItems,
      ),
      recommendationProvenance:
          List<ReadingFeedRecommendationProvenance?>.unmodifiable(
            recommendationProvenance,
          ),
      recommendationBatchId: recommendationBatchId,
      recommendationMode:
          _effectiveRecommendationMode ??
          (recommendationItems.isEmpty
              ? null
              : recommendationItems.first.recommendation?.mode),
      forYouAvailable: input.forYouAvailable,
      libraryRevision:
          serverDecision?.libraryRevision ??
          (input.checkpoint.initialized ? input.checkpoint.lastRevision : null),
      activeToReadCount:
          serverDecision?.activeToReadCount ?? input.localItems.length,
      nextCursor: nextCursor,
      loadingInitial:
          items.isEmpty &&
          (decision.mode == ReadingFeedMode.checkingQueue || _loadingInitial),
      loadingMore: _loadingMore,
      offline: input.offline,
      recoverableError: _lastError,
      authEpoch: input.sessionScope?.authEpoch ?? 0,
      accountGeneration: _generation,
      accountScopeFingerprint: readingFeedScopeFingerprint(input.sessionScope),
      serverEnforcement: _serverPage?.enforcement,
    );
    _updateFinalItemChecking(state.mode);
    _recordPolicyTransitionTelemetry();
    _recordShadowDecision(state);
    _configureRecommendationRecheck(decision.mode);
  }

  void _recordPolicyTransitionTelemetry() {
    final now = _clock().toUtc();
    final suppressionStartedAt = _suppressionStartedAt;
    if (suppressionStartedAt != null &&
        state.mode != ReadingFeedMode.recommendations) {
      _suppressionStartedAt = null;
      emitTelemetry(
        _telemetry,
        PakPerkTelemetryEvent.discoverySuppressionLatency,
        {
          'trigger': 'save',
          'latency_bucket': telemetryDurationBucket(
            now.difference(suppressionStartedAt),
          ),
        },
      );
    }
    final unlockStartedAt = _unlockStartedAt;
    if (unlockStartedAt != null &&
        state.mode == ReadingFeedMode.recommendations &&
        state.queueAuthority == QueueAuthority.serverConfirmedEmpty) {
      _unlockStartedAt = null;
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.discoveryUnlockLatency, {
        'trigger': 'final_completion',
        'latency_bucket': telemetryDurationBucket(
          now.difference(unlockStartedAt),
        ),
      });
    }
  }

  void _updateFinalItemChecking(ReadingFeedMode mode) {
    final checking =
        mode == ReadingFeedMode.checkingQueue ||
        mode == ReadingFeedMode.finishingQueue;
    if (checking) {
      if (_finalItemCheckingStartedAt == null &&
          (mode == ReadingFeedMode.finishingQueue ||
              _lastCompletionAcknowledgementSequence != null)) {
        _finalItemCheckingStartedAt = _clock().toUtc();
      }
      return;
    }
    _finishFinalItemChecking(switch (mode) {
      ReadingFeedMode.recommendations => 'recommendations',
      ReadingFeedMode.toRead => 'queue_active',
      ReadingFeedMode.unavailable when state.offline => 'offline_unknown',
      ReadingFeedMode.unavailable ||
      ReadingFeedMode.guestDiscovery => 'unavailable',
      ReadingFeedMode.checkingQueue ||
      ReadingFeedMode.finishingQueue => 'unavailable',
    });
  }

  void _finishFinalItemChecking(String outcome) {
    final startedAt = _finalItemCheckingStartedAt;
    if (startedAt == null) return;
    _finalItemCheckingStartedAt = null;
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.finalItemCheckingDuration, {
      'duration_bucket': telemetryDurationBucket(
        _clock().toUtc().difference(startedAt),
      ),
      'outcome': outcome,
    });
  }

  void _recordShadowDecision(ReadingFeedState next) {
    final serverPolicy = switch (next.serverEnforcement) {
      ReadingFeedEnforcement.shadow => 'shadow',
      ReadingFeedEnforcement.strict => 'strict',
      null => 'unknown',
    };
    if ((!_shadowMode &&
            next.serverEnforcement != ReadingFeedEnforcement.shadow) ||
        next.accountScopeFingerprint == null ||
        next.mode == ReadingFeedMode.guestDiscovery) {
      return;
    }
    final decision = switch (next.mode) {
      ReadingFeedMode.checkingQueue => 'checking_queue',
      ReadingFeedMode.finishingQueue => 'finishing_queue',
      ReadingFeedMode.toRead => 'to_read',
      ReadingFeedMode.recommendations => 'recommendations',
      ReadingFeedMode.unavailable => 'fail_closed',
      ReadingFeedMode.guestDiscovery => throw StateError(
        'Guest discovery is not a shadow decision.',
      ),
    };
    final authority = switch (next.queueAuthority) {
      QueueAuthority.unknown => 'unknown',
      QueueAuthority.localNonEmpty => 'local_non_empty',
      QueueAuthority.pendingSave => 'pending_save',
      QueueAuthority.serverConfirmedNonEmpty => 'server_non_empty',
      QueueAuthority.serverConfirmedEmpty => 'server_empty',
      QueueAuthority.stale => 'stale',
    };
    final key = '$decision|$authority|$serverPolicy|${next.offline}';
    if (_lastShadowDecisionKey == key) return;
    _lastShadowDecisionKey = key;
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.readingFeedShadowDecision, {
      'shadow_decision': decision,
      'queue_authority': authority,
      'legacy_decision': 'public_discovery',
      'server_policy': serverPolicy,
      'queue_policy_agrees': next.mode == ReadingFeedMode.recommendations,
      'offline': next.offline,
    });
  }

  void _configureRecommendationRecheck(ReadingFeedMode mode) {
    if (mode != ReadingFeedMode.recommendations) {
      _recommendationRecheck?.cancel();
      _recommendationRecheck = null;
      return;
    }
    _recommendationRecheck ??= Timer(_recommendationRecheckInterval, () {
      _recommendationRecheck = null;
      unawaited(refresh(force: true));
    });
  }

  void _invalidateRequests(String reason) {
    _generation += 1;
    _initialRequest?.cancel(reason);
    _pageRequest?.cancel(reason);
    _initialRequest = null;
    _pageRequest = null;
    _refreshFlight = null;
  }

  @override
  void dispose() {
    _invalidateRequests('The reading-feed controller was disposed.');
    _recommendationRecheck?.cancel();
    super.dispose();
  }
}

List<LibraryListItem> _fifoLocalItems(List<LibraryListItem> items) {
  final ordered = List<LibraryListItem>.of(items)
    ..sort((left, right) {
      final time = left.savedAt.compareTo(right.savedAt);
      if (time != 0) return time;
      return left.paper.paperId.compareTo(right.paper.paperId);
    });
  return ordered;
}

List<ReadingFeedQueuePresentation> _queuePresentations(
  List<ReadingFeedItem> items,
) => items
    .map(
      (item) => ReadingFeedQueuePresentation(
        paper: item.paper,
        savedAt: item.queue!.savedAt,
        state: item.queue!.state,
        saveSourceKind: item.queue!.saveSourceKind,
        privateNote: null,
      ),
    )
    .toList(growable: false);

bool _isValidContinuation(
  List<ReadingFeedPage> existingPages,
  ReadingFeedPage incoming,
) {
  if (existingPages.isEmpty || incoming.items.isEmpty) return false;
  final initial = existingPages.first;
  final existingItems = existingPages
      .expand((page) => page.items)
      .toList(growable: false);
  if (existingItems.isEmpty ||
      incoming.mode != initial.mode ||
      incoming.enforcement != initial.enforcement ||
      incoming.decision.policyVersion != initial.decision.policyVersion ||
      incoming.decision.libraryRevision != initial.decision.libraryRevision ||
      incoming.decision.activeToReadCount !=
          initial.decision.activeToReadCount ||
      incoming.decision.queueProvenEmpty != initial.decision.queueProvenEmpty) {
    return false;
  }
  final existingIds = existingItems.map((item) => item.paper.paperId).toSet();
  if (incoming.items.any((item) => existingIds.contains(item.paper.paperId))) {
    return false;
  }
  final previous = existingItems.last;
  final next = incoming.items.first;
  return switch (initial.mode) {
    ReadingFeedServerMode.toRead => _isLaterQueueItem(previous, next),
    ReadingFeedServerMode.recommendations => _isValidRecommendationContinuation(
      initial: initial,
      incoming: incoming,
      previous: previous,
      next: next,
    ),
  };
}

bool _isValidRecommendationContinuation({
  required ReadingFeedPage initial,
  required ReadingFeedPage incoming,
  required ReadingFeedItem previous,
  required ReadingFeedItem next,
}) {
  final initialBatchId = initial.batchId;
  if (initialBatchId == null) {
    if (initial.batchMetadata != null ||
        incoming.batchId != null ||
        incoming.batchMetadata != null) {
      return false;
    }
    return next.paper.publishedAt.isBefore(previous.paper.publishedAt) ||
        (next.paper.publishedAt.isAtSameMomentAs(previous.paper.publishedAt) &&
            next.paper.paperId.compareTo(previous.paper.paperId) < 0);
  }

  final initialMetadata = initial.batchMetadata;
  if (initialMetadata == null ||
      incoming.batchId == null ||
      incoming.batchMetadata != initialMetadata) {
    return false;
  }
  final initialMode = _batchedRecommendationMode(initial);
  return initialMode != null &&
      _batchedRecommendationMode(incoming) == initialMode;
}

ReadingFeedRecommendationMode? _batchedRecommendationMode(
  ReadingFeedPage page,
) {
  if (page.batchId == null ||
      page.batchMetadata == null ||
      page.items.isEmpty) {
    return null;
  }
  final mode = page.items.first.recommendation?.mode;
  if (mode == null ||
      page.items.any(
        (item) =>
            item.source.recommendationMode != mode ||
            item.recommendation?.mode != mode,
      )) {
    return null;
  }
  return mode;
}

bool _isLaterQueueItem(ReadingFeedItem previous, ReadingFeedItem next) {
  final previousQueue = previous.queue;
  final nextQueue = next.queue;
  if (previousQueue == null || nextQueue == null) return false;
  return nextQueue.savedAt.isAfter(previousQueue.savedAt) ||
      (nextQueue.savedAt.isAtSameMomentAs(previousQueue.savedAt) &&
          next.paper.paperId.compareTo(previous.paper.paperId) > 0);
}

String? readingFeedScopeFingerprint(ReadingFeedAccountScope? scope) {
  if (scope == null) return null;
  // This value is for in-memory equality/diagnostics only. Hashing avoids
  // carrying the raw account UUID into generic presentation state.
  var hash = 0x811c9dc5;
  for (final unit in '${scope.accountId}:${scope.authEpoch}'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
