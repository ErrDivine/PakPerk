import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cache/demo_asset_store.dart';
import '../core/cache/drift_local_store.dart';
import '../core/cache/feed_cache_persistence.dart';
import '../core/cache/feed_prefetch_config.dart';
import '../core/cache/local_store.dart';
import '../core/content_policy.dart';
import '../core/models/paper.dart';
import '../core/models/reader_state.dart';
import '../core/providers.dart';
import '../core/repository/paper_repository.dart';
import '../core/settings/appearance.dart';
import '../features/feed/preloaded_feed_snapshot.dart';
import 'app.dart';
import 'appearance_controller.dart';
import 'startup_controller.dart';
import 'startup_gate.dart';
import 'theme.dart';

class ApplicationStartupData {
  const ApplicationStartupData({
    required this.store,
    required this.anonymousSessionId,
    required this.restoration,
    required this.preloadedFeed,
    required this.appearance,
  });

  final LocalStore store;
  final String anonymousSessionId;
  final AppRestorationState restoration;
  final PreloadedFeedSnapshot preloadedFeed;
  final AppAppearance appearance;
}

/// Installs hydrated values in the application's root provider container.
///
/// Hydrated value providers are first read after [PakPerkBootstrapApp] observes
/// local readiness. The store-readiness callback is the deliberate exception:
/// deletion recovery may await the opened store while the rest of hydration
/// continues. Keeping all of them in the root container is important because
/// storage-dependent providers cannot see overrides from a nested scope.
List<Override> applicationStartupDataOverrides(
  ApplicationStartupBootstrapper bootstrapper,
) {
  ApplicationStartupData requireData() =>
      bootstrapper.data ??
      (throw StateError('Application startup data is not hydrated yet.'));

  return [
    localStoreProvider.overrideWith((ref) => requireData().store),
    localStoreWhenReadyProvider.overrideWithValue(
      bootstrapper.waitForLocalStore,
    ),
    initialAnonymousSessionIdProvider.overrideWith(
      (ref) => requireData().anonymousSessionId,
    ),
    initialRestorationProvider.overrideWith((ref) => requireData().restoration),
    initialAppearanceProvider.overrideWith((ref) => requireData().appearance),
    preloadedFeedSnapshotProvider.overrideWith(
      (ref) => requireData().preloadedFeed,
    ),
  ];
}

/// Opens only device-local, non-network dependencies needed for the first
/// readable frame. A generation guard prevents a timed-out attempt from
/// publishing stale data after a retry has started.
class ApplicationStartupBootstrapper
    implements StartupBootstrapper, StartupLocalStoreLeaseCoordinator {
  ApplicationStartupBootstrapper({
    Future<LocalStore> Function()? storeFactory,
    Future<void> Function()? repairLocalData,
    Future<FeedPage> Function()? bundledFeedLoader,
    this.fulltextPolicy = ClientFulltextPolicy.prototype,
    this.cachePolicy = const FeedPrefetchConfig(),
  }) : storeFactory =
           storeFactory ??
           (() => DriftLocalStore.create(
             fulltextPolicy: fulltextPolicy,
             cachePolicy: cachePolicy,
           )),
       repairLocalData =
           repairLocalData ??
           (() => DriftLocalStore.repairPublicCache(
             fulltextPolicy: fulltextPolicy,
             cachePolicy: cachePolicy,
           )),
       bundledFeedLoader =
           bundledFeedLoader ?? BundleDemoContentStore().loadFallbackFeed;

  final Future<LocalStore> Function() storeFactory;
  final Future<void> Function() repairLocalData;
  final Future<FeedPage> Function() bundledFeedLoader;
  final ClientFulltextPolicy fulltextPolicy;
  final FeedPrefetchConfig cachePolicy;

  ApplicationStartupData? _data;
  Future<LocalStore>? _storeReady;
  final Set<_ApplicationHydrationAttempt> _hydrationAttempts = {};
  Future<void> _lifecycleTail = Future.value();
  _ApplicationHydrationRequest? _latestHydrationRequest;
  _StartupStoreLeaseGroup? _mountedStoreLeases;
  Future<void>? _activeRepair;
  final Object _storeLeaseZoneKey = Object();
  int _generation = 0;

  ApplicationStartupData? get data => _data;

  Future<LocalStore> waitForLocalStore() {
    final pinned = Zone.current[_storeLeaseZoneKey];
    if (pinned != null) return pinned as Future<LocalStore>;
    final storeReady = _storeReady;
    if (storeReady == null) {
      return Future.error(
        StateError('Local store startup has not begun for this attempt.'),
      );
    }
    return storeReady;
  }

  @override
  Future<T> withStartupLocalStoreLease<T>(Future<T> Function() operation) {
    final request = _latestHydrationRequest;
    final mountedStore = _data?.store;
    final leases = request?.leases ?? _mountedStoreLeases;
    final pinnedStore =
        request?.storeReady ??
        (mountedStore == null ? null : Future<LocalStore>.value(mountedStore));
    if (leases == null || pinnedStore == null) {
      return Future<T>.error(
        StateError('No local store lifecycle owner is available.'),
      );
    }
    final lease = leases.tryAcquire();
    if (lease == null) {
      return Future<T>.error(
        StateError('Local store startup is being superseded.'),
      );
    }
    final protected = runZoned<Future<T>>(
      () => Future<T>.sync(operation),
      zoneValues: {_storeLeaseZoneKey: pinnedStore},
    );
    return protected.whenComplete(lease.release);
  }

  @override
  Future<void> hydrateLocalState() {
    // A retry after session inspection failed must retain the already-mounted
    // store and hydrated provider values. Replacing them underneath the root
    // ProviderScope would strand long-lived providers on the prior store.
    if (_data != null) return Future.value();
    final generation = ++_generation;
    _data = null;
    _latestHydrationRequest?.supersede();
    final priorAttempts = _hydrationAttempts.toList(growable: false);
    _supersedeAndStartClosing(priorAttempts);
    final request = _ApplicationHydrationRequest(generation);
    _latestHydrationRequest = request;
    // Publish the replacement barrier synchronously. The concurrent account
    // session/deletion inspection must wait for this queued store rather than
    // retaining the prior attempt's readiness future.
    _storeReady = request.storeReady;

    late final Future<void> operation;
    operation =
        _enqueueLifecycleTransition(() async {
          for (final attempt in priorAttempts) {
            await attempt.closeAndDrain();
          }
          if (request.superseded || request.generation != _generation) {
            request.completeSuperseded();
            return;
          }

          final factoryResult = Future<LocalStore>.sync(storeFactory);
          factoryResult.ignore();
          final attempt = _ApplicationHydrationAttempt(
            generation: generation,
            storeReady: factoryResult,
            leases: request.leases,
          );
          _hydrationAttempts.add(attempt);
          late final Future<void> hydration;
          hydration = _runHydrationAttempt(attempt, request).whenComplete(() {
            _hydrationAttempts.remove(attempt);
          });
          attempt.operation = hydration;
          await hydration;
        }).whenComplete(() {
          if (identical(_latestHydrationRequest, request)) {
            _latestHydrationRequest = null;
          }
          if (identical(_storeReady, request.storeReady) && _data == null) {
            _storeReady = null;
          }
        });
    return operation;
  }

  Future<void> _runHydrationAttempt(
    _ApplicationHydrationAttempt attempt,
    _ApplicationHydrationRequest request,
  ) async {
    try {
      final store = await attempt.storeReady;
      if (attempt.superseded || attempt.generation != _generation) {
        request.completeSuperseded();
        await attempt.closeStore();
        return;
      }
      request.completeStore(store);
      // Attach listeners to every sibling immediately, but do not complete the
      // attempt on the first error. Supersession/repair owns this Future and
      // must not open another database while any started sibling can still
      // issue late work against the old store.
      final results = await Future.wait<Object?>([
        Future<String>.sync(store.getOrCreateSessionId),
        Future<AppRestorationState>.sync(store.loadRestoration),
        Future<AppAppearance>.sync(store.loadAppearance),
        Future<PreloadedFeedSnapshot>.sync(() => _loadPreloadedFeed(store)),
      ], eagerError: false);
      if (attempt.superseded || attempt.generation != _generation) {
        await attempt.closeStore();
        return;
      }
      _data = ApplicationStartupData(
        store: store,
        anonymousSessionId: results[0]! as String,
        restoration: results[1]! as AppRestorationState,
        appearance: results[2]! as AppAppearance,
        preloadedFeed: results[3]! as PreloadedFeedSnapshot,
      );
      _mountedStoreLeases = request.leases;
      attempt.releaseStore();
    } on Object catch (error, stackTrace) {
      request.completeError(error, stackTrace);
      await attempt.closeStore();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _enqueueLifecycleTransition(Future<void> Function() transition) {
    final prior = _lifecycleTail;
    final operation = () async {
      await prior;
      await transition();
    }();
    _lifecycleTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  void _supersedeAndStartClosing(
    Iterable<_ApplicationHydrationAttempt> attempts,
  ) {
    for (final attempt in attempts) {
      attempt.superseded = true;
      attempt.closeStore().ignore();
    }
  }

  Future<PreloadedFeedSnapshot> _loadPreloadedFeed(LocalStore store) async {
    // The importer converts failures into a count-only result. Awaiting it
    // makes a valid legacy offline feed eligible for the first readable frame
    // without allowing a malformed payload to fail startup.
    if (store is DriftLocalStore) await store.startLegacyImportWork();
    final cached = store is FeedCachePersistence
        ? await (store as FeedCachePersistence).loadFeedPage(
            feedQueryKey(limit: cachePolicy.remotePageSize),
          )
        : await store.loadFeed();
    final hasDeviceCache = cached != null && cached.items.isNotEmpty;
    final source = hasDeviceCache ? cached : await bundledFeedLoader();
    return PreloadedFeedSnapshot(
      page: fulltextPolicy.maskCachedFeed(source),
      origin: hasDeviceCache ? DataOrigin.deviceCache : DataOrigin.bundledDemo,
    );
  }

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() async =>
      StartupSessionStatus.anonymous;

  @override
  Future<void> repairLocalStatePreservingCredentials() {
    final active = _activeRepair;
    if (active != null) return active;
    _generation += 1;
    _latestHydrationRequest?.supersede();
    final attempts = _hydrationAttempts.toList(growable: false);
    _supersedeAndStartClosing(attempts);
    final hydratedStore = _data?.store;
    final hydratedStoreLeases = _mountedStoreLeases;
    hydratedStoreLeases?.stopAccepting();
    _data = null;
    _mountedStoreLeases = null;
    _storeReady = null;
    late final Future<void> tracked;
    final operation = _enqueueLifecycleTransition(() async {
      // Future.timeout cannot cancel the underlying startup work. Drain every
      // prior owner before opening a repair connection so a late migration or
      // legacy import cannot race with, or repopulate data after, the repair.
      for (final attempt in attempts) {
        await attempt.closeAndDrain();
      }
      await hydratedStoreLeases?.drained;
      if (hydratedStore is CloseableLocalStore) {
        // This edge is possible when hydration completed immediately before
        // the controller's timeout was delivered. A session-only retry never
        // calls this method and therefore keeps its mounted store/providers.
        await (hydratedStore as CloseableLocalStore).close();
      }
      await repairLocalData();
    });
    tracked = operation.whenComplete(() {
      if (identical(_activeRepair, tracked)) _activeRepair = null;
    });
    _activeRepair = tracked;
    return tracked;
  }

  @override
  Future<void> runPostReadyWork() async {}
}

final class _ApplicationHydrationRequest {
  _ApplicationHydrationRequest(this.generation) {
    // A superseded readiness barrier can fail after its startup controller has
    // already timed out. Keep that expected stale completion out of the
    // uncaught-error path while allowing current session inspection to await
    // the same future normally.
    _storeReady.future.ignore();
  }

  final int generation;
  final Completer<LocalStore> _storeReady = Completer<LocalStore>();
  final _StartupStoreLeaseGroup leases = _StartupStoreLeaseGroup();
  bool superseded = false;

  Future<LocalStore> get storeReady => _storeReady.future;

  void supersede() {
    superseded = true;
    leases.stopAccepting();
  }

  void completeStore(LocalStore store) {
    if (!_storeReady.isCompleted) _storeReady.complete(store);
  }

  void completeSuperseded() {
    supersede();
    if (_storeReady.isCompleted) return;
    _storeReady.completeError(
      StateError('Local store startup was superseded by a newer attempt.'),
      StackTrace.current,
    );
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_storeReady.isCompleted) {
      _storeReady.completeError(error, stackTrace);
    }
  }
}

final class _StartupStoreLeaseGroup {
  bool _accepting = true;
  int _active = 0;
  Completer<void>? _drained;

  _StartupStoreLease? tryAcquire() {
    if (!_accepting) return null;
    _active += 1;
    return _StartupStoreLease(this);
  }

  void stopAccepting() {
    _accepting = false;
  }

  Future<void> get drained {
    if (_active == 0) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  void _release() {
    if (_active <= 0) return;
    _active -= 1;
    if (_active == 0) {
      _drained?.complete();
      _drained = null;
    }
  }
}

final class _StartupStoreLease {
  _StartupStoreLease(this._owner);

  final _StartupStoreLeaseGroup _owner;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release();
  }
}

final class _ApplicationHydrationAttempt {
  _ApplicationHydrationAttempt({
    required this.generation,
    required this.storeReady,
    required this.leases,
  });

  final int generation;
  final Future<LocalStore> storeReady;
  final _StartupStoreLeaseGroup leases;
  late final Future<void> operation;
  bool superseded = false;
  bool _storeReleased = false;
  Future<void>? _closing;

  void releaseStore() {
    _storeReleased = true;
  }

  Future<void> closeStore() {
    if (_storeReleased) return Future.value();
    leases.stopAccepting();
    return _closing ??= _closeStoreWhenReady();
  }

  Future<void> _closeStoreWhenReady() async {
    await leases.drained;
    LocalStore store;
    try {
      store = await storeReady;
    } on Object {
      return;
    }
    if (store is CloseableLocalStore) {
      await (store as CloseableLocalStore).close();
    }
  }

  Future<void> closeAndDrain() async {
    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await closeStore();
    } on Object catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    }
    try {
      await operation;
    } on Object {
      // The original startup surface already owns the hydration failure. A
      // repair only needs to know that the superseded work has stopped.
    }
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStackTrace!);
    }
  }
}

/// Holds back the data-backed application tree only until root provider
/// overrides can safely resolve the hydrated startup snapshot. Local session
/// inspection may still be completing while the public cached tree is usable.
class PakPerkBootstrapApp extends ConsumerStatefulWidget {
  const PakPerkBootstrapApp({required this.bootstrapper, super.key});

  final ApplicationStartupBootstrapper bootstrapper;

  @override
  ConsumerState<PakPerkBootstrapApp> createState() =>
      _PakPerkBootstrapAppState();
}

class _PakPerkBootstrapAppState extends ConsumerState<PakPerkBootstrapApp> {
  bool _dataTreeMounted = false;

  @override
  void didUpdateWidget(covariant PakPerkBootstrapApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bootstrapper, widget.bootstrapper)) {
      _dataTreeMounted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final startup = ref.watch(startupControllerProvider);
    final data = widget.bootstrapper.data;
    if (data != null &&
        (startup.hasUsableLocalState ||
            startup.failure?.localStateUsable == true)) {
      _dataTreeMounted = true;
    }
    if (_dataTreeMounted && data != null) {
      return const PakPerkApp();
    }

    final controller = ref.read(startupControllerProvider.notifier);
    return MaterialApp(
      title: 'Pakperk',
      debugShowCheckedModeBanner: false,
      theme: buildPakPerkTheme(),
      darkTheme: buildPakPerkDarkTheme(),
      themeMode: data?.appearance.themeMode ?? ThemeMode.system,
      home: StartupGate(
        state: startup,
        openingMotionEnabled: false,
        onRetry: controller.retry,
        onRepairAndRetry: controller.repairAndRetry,
        onFirstUsableFrame: controller.notifyFirstUsableFrame,
        onOpeningComplete: controller.markOpeningComplete,
        child: const SizedBox.expand(),
      ),
    );
  }
}

StartupLaunchMode startupLaunchModeForInitialRoute(String routeName) {
  final route = routeName.trim();
  return route.isNotEmpty && route != '/'
      ? StartupLaunchMode.deepLink
      : StartupLaunchMode.cold;
}
