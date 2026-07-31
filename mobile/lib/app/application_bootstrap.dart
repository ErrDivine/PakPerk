import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cache/demo_asset_store.dart';
import '../core/cache/drift_local_store.dart';
import '../core/cache/local_store.dart';
import '../core/content_policy.dart';
import '../core/models/paper.dart';
import '../core/models/reader_state.dart';
import '../core/providers.dart';
import '../core/repository/paper_repository.dart';
import '../features/feed/preloaded_feed_snapshot.dart';
import 'app.dart';
import 'startup_controller.dart';
import 'startup_gate.dart';
import 'theme.dart';

class ApplicationStartupData {
  const ApplicationStartupData({
    required this.store,
    required this.anonymousSessionId,
    required this.restoration,
    required this.preloadedFeed,
  });

  final LocalStore store;
  final String anonymousSessionId;
  final AppRestorationState restoration;
  final PreloadedFeedSnapshot preloadedFeed;
}

/// Installs hydrated values in the application's root provider container.
///
/// These providers are first read only after [PakPerkBootstrapApp] observes a
/// ready startup state. Keeping them in the root container is important:
/// providers that depend on local storage are intentionally not Riverpod
/// scoped providers and therefore cannot see overrides from a nested scope.
List<Override> applicationStartupDataOverrides(
  ApplicationStartupBootstrapper bootstrapper,
) {
  ApplicationStartupData requireData() =>
      bootstrapper.data ??
      (throw StateError('Application startup data is not hydrated yet.'));

  return [
    localStoreProvider.overrideWith((ref) => requireData().store),
    initialAnonymousSessionIdProvider.overrideWith(
      (ref) => requireData().anonymousSessionId,
    ),
    initialRestorationProvider.overrideWith((ref) => requireData().restoration),
    preloadedFeedSnapshotProvider.overrideWith(
      (ref) => requireData().preloadedFeed,
    ),
  ];
}

/// Opens only device-local, non-network dependencies needed for the first
/// readable frame. A generation guard prevents a timed-out attempt from
/// publishing stale data after a retry has started.
class ApplicationStartupBootstrapper implements StartupBootstrapper {
  ApplicationStartupBootstrapper({
    Future<LocalStore> Function()? storeFactory,
    Future<void> Function()? repairLocalData,
    Future<FeedPage> Function()? bundledFeedLoader,
    this.fulltextPolicy = ClientFulltextPolicy.prototype,
  }) : storeFactory =
           storeFactory ??
           (() => DriftLocalStore.create(fulltextPolicy: fulltextPolicy)),
       repairLocalData =
           repairLocalData ??
           (() => DriftLocalStore.repairPublicCache(
             fulltextPolicy: fulltextPolicy,
           )),
       bundledFeedLoader =
           bundledFeedLoader ?? BundleDemoContentStore().loadFallbackFeed;

  final Future<LocalStore> Function() storeFactory;
  final Future<void> Function() repairLocalData;
  final Future<FeedPage> Function() bundledFeedLoader;
  final ClientFulltextPolicy fulltextPolicy;

  ApplicationStartupData? _data;
  int _generation = 0;

  ApplicationStartupData? get data => _data;

  @override
  Future<void> hydrateLocalState() async {
    final generation = ++_generation;
    _data = null;
    final store = await storeFactory();
    final sessionFuture = store.getOrCreateSessionId();
    final restorationFuture = store.loadRestoration();
    final preloadedFeedFuture = _loadPreloadedFeed(store);
    final sessionId = await sessionFuture;
    final restoration = await restorationFuture;
    final preloadedFeed = await preloadedFeedFuture;
    if (generation != _generation) return;
    _data = ApplicationStartupData(
      store: store,
      anonymousSessionId: sessionId,
      restoration: restoration,
      preloadedFeed: preloadedFeed,
    );
  }

  Future<PreloadedFeedSnapshot> _loadPreloadedFeed(LocalStore store) async {
    // The importer converts failures into a count-only result. Awaiting it
    // makes a valid legacy offline feed eligible for the first readable frame
    // without allowing a malformed payload to fail startup.
    if (store is DriftLocalStore) await store.startLegacyImportWork();
    final cached = await store.loadFeed();
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
  Future<void> repairLocalStatePreservingCredentials() async {
    _generation += 1;
    _data = null;
    await repairLocalData();
  }

  @override
  Future<void> runPostReadyWork() async {}
}

/// Holds back the data-backed application tree until root provider overrides
/// can safely resolve the hydrated startup snapshot.
class PakPerkBootstrapApp extends ConsumerWidget {
  const PakPerkBootstrapApp({required this.bootstrapper, super.key});

  final ApplicationStartupBootstrapper bootstrapper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startup = ref.watch(startupControllerProvider);
    final data = bootstrapper.data;
    if (startup.isReady && data != null) {
      return const PakPerkApp();
    }

    final controller = ref.read(startupControllerProvider.notifier);
    return MaterialApp(
      title: 'Pakperk',
      debugShowCheckedModeBanner: false,
      theme: buildPakPerkTheme(),
      darkTheme: buildPakPerkDarkTheme(),
      themeMode: ThemeMode.system,
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
