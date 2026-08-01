import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/application_bootstrap.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/core/cache/local_store.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/core/settings/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  test('session and restoration hydration start concurrently', () async {
    final store = _GatedLocalStore();
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () async => store,
      bundledFeedLoader: _loadBundledFeed,
    );

    final hydration = bootstrapper.hydrateLocalState();
    await _flushMicrotasks();
    expect(store.sessionStarted, isTrue);
    expect(store.restorationStarted, isTrue);
    expect(store.feedStarted, isTrue);

    store.restorationResult.complete(
      const AppRestorationState(activeBranchIndex: 1, feedIndex: 7),
    );
    await _flushMicrotasks();
    expect(bootstrapper.data, isNull);

    store.sessionResult.complete('anonymous-session');
    await hydration;
    expect(bootstrapper.data?.anonymousSessionId, 'anonymous-session');
    expect(bootstrapper.data?.restoration.activeBranchIndex, 1);
    expect(bootstrapper.data?.restoration.feedIndex, 7);
  });

  test('slower stale hydration cannot replace a newer generation', () async {
    final firstFactory = Completer<LocalStore>();
    final secondFactory = Completer<LocalStore>();
    final factories = [firstFactory, secondFactory];
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () => factories.removeAt(0).future,
      bundledFeedLoader: _loadBundledFeed,
    );
    final staleStore = MemoryLocalStore()..sessionId = 'stale-session';
    final currentStore = MemoryLocalStore()..sessionId = 'current-session';

    final staleHydration = bootstrapper.hydrateLocalState();
    final currentHydration = bootstrapper.hydrateLocalState();
    secondFactory.complete(currentStore);
    await currentHydration;
    expect(bootstrapper.data?.store, same(currentStore));
    expect(bootstrapper.data?.anonymousSessionId, 'current-session');

    firstFactory.complete(staleStore);
    await staleHydration;
    expect(bootstrapper.data?.store, same(currentStore));
    expect(bootstrapper.data?.anonymousSessionId, 'current-session');
  });

  test('repair invalidates in-flight hydration before a clean retry', () async {
    final staleFactory = Completer<LocalStore>();
    final currentStore = MemoryLocalStore()..sessionId = 'current-session';
    var factoryCalls = 0;
    var repairCalls = 0;
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () {
        factoryCalls += 1;
        return factoryCalls == 1
            ? staleFactory.future
            : Future<LocalStore>.value(currentStore);
      },
      repairLocalData: () async {
        repairCalls += 1;
      },
      bundledFeedLoader: _loadBundledFeed,
    );

    final staleHydration = bootstrapper.hydrateLocalState();
    await bootstrapper.repairLocalStatePreservingCredentials();
    expect(repairCalls, 1);
    expect(bootstrapper.data, isNull);

    staleFactory.complete(MemoryLocalStore()..sessionId = 'stale-session');
    await staleHydration;
    expect(bootstrapper.data, isNull);

    await bootstrapper.hydrateLocalState();
    expect(bootstrapper.data?.store, same(currentStore));
    expect(bootstrapper.data?.anonymousSessionId, 'current-session');
  });

  test('public-cache repair preserves identity and restoration', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferencesLocalStore.create();
    final sessionId = await store.getOrCreateSessionId();
    const restoration = AppRestorationState(activeBranchIndex: 1, feedIndex: 2);
    await store.saveRestoration(restoration);
    await store.saveAppearance(AppAppearance.dark);
    await store.saveFeed(FeedPage(items: [samplePaper]));
    await store.savePaper(samplePaper);

    await SharedPreferencesLocalStore.repairPublicCache();

    final repaired = await SharedPreferencesLocalStore.create();
    expect(await repaired.getOrCreateSessionId(), sessionId);
    expect((await repaired.loadRestoration()).activeBranchIndex, 1);
    expect((await repaired.loadRestoration()).feedIndex, 2);
    expect(await repaired.loadAppearance(), AppAppearance.dark);
    expect(await repaired.loadFeed(), isNull);
    expect(await repaired.loadPaper(samplePaper.paperId), isNull);
  });

  test(
    'startup preload prefers device cache and applies strict masking',
    () async {
      final derivedPaper = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['capabilities'] = {
            'metadata': true,
            'introduction': true,
            'chat': true,
            'connections': true,
          },
      );
      final store = MemoryLocalStore()
        ..feed = FeedPage(items: [derivedPaper], nextCursor: 'device-cursor');
      var bundledLoads = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: () async {
          bundledLoads += 1;
          return FeedPage(items: [samplePaper]);
        },
        fulltextPolicy: ClientFulltextPolicy.strict,
      );

      await bootstrapper.hydrateLocalState();

      final snapshot = bootstrapper.data!.preloadedFeed;
      expect(snapshot.origin, DataOrigin.deviceCache);
      expect(snapshot.page.nextCursor, 'device-cursor');
      expect(snapshot.page.items.single.paperId, derivedPaper.paperId);
      expect(snapshot.page.items.single.capabilities.introduction, isFalse);
      expect(snapshot.page.items.single.capabilities.chat, isFalse);
      expect(snapshot.page.items.single.capabilities.connections, isFalse);
      expect(bundledLoads, 0);
    },
  );

  test(
    'startup preload falls back to bundled feed when cache is empty',
    () async {
      final store = MemoryLocalStore()..feed = const FeedPage(items: []);
      var bundledLoads = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: () async {
          bundledLoads += 1;
          return FeedPage(items: [samplePaper], nextCursor: 'bundle-cursor');
        },
      );

      await bootstrapper.hydrateLocalState();

      final snapshot = bootstrapper.data!.preloadedFeed;
      expect(snapshot.origin, DataOrigin.bundledDemo);
      expect(snapshot.page.items.single.paperId, samplePaper.paperId);
      expect(snapshot.page.nextCursor, 'bundle-cursor');
      expect(bundledLoads, 1);
    },
  );

  testWidgets(
    'opening child renders preloaded feed before first-frame revalidation',
    (tester) async {
      final store = MemoryLocalStore()..feed = FeedPage(items: [samplePaper]);
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: _loadBundledFeed,
      );
      final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeedCompleter = pendingNetwork;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            startupBootstrapperProvider.overrideWithValue(bootstrapper),
            startupNativeSplashHandoffProvider.overrideWithValue(
              const NoopStartupNativeSplashHandoff(),
            ),
            paperRepositoryProvider.overrideWithValue(repository),
            ...applicationStartupDataOverrides(bootstrapper),
          ],
          child: PakPerkBootstrapApp(bootstrapper: bootstrapper),
        ),
      );

      expect(repository.feedCalls, 0);
      expect(find.text(samplePaper.title), findsNothing);

      for (
        var frame = 0;
        frame < 6 && find.text(samplePaper.title).evaluate().isEmpty;
        frame += 1
      ) {
        expect(repository.feedCalls, 0);
        await tester.pump();
      }

      expect(find.text(samplePaper.title), findsOneWidget);
      expect(repository.feedCalls, 1);
      expect(pendingNetwork.isCompleted, isFalse);

      await tester.pump();
      await tester.pump();
      expect(repository.feedCalls, 1);

      pendingNetwork.complete(
        RepositoryValue(
          value: FeedPage(items: [samplePaper]),
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await tester.pump();
      await tester.pump();
    },
  );

  test('initial route selects cold or shortened deep-link launch', () {
    expect(startupLaunchModeForInitialRoute(''), StartupLaunchMode.cold);
    expect(startupLaunchModeForInitialRoute('/'), StartupLaunchMode.cold);
    expect(
      startupLaunchModeForInitialRoute('/p/${samplePaper.paperId}'),
      StartupLaunchMode.deepLink,
    );
  });
}

Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

Future<FeedPage> _loadBundledFeed() async => FeedPage(items: [samplePaper]);

class _GatedLocalStore extends MemoryLocalStore {
  final sessionResult = Completer<String>();
  final restorationResult = Completer<AppRestorationState>();
  bool sessionStarted = false;
  bool restorationStarted = false;
  bool feedStarted = false;

  @override
  Future<String> getOrCreateSessionId() {
    sessionStarted = true;
    return sessionResult.future;
  }

  @override
  Future<AppRestorationState> loadRestoration() {
    restorationStarted = true;
    return restorationResult.future;
  }

  @override
  Future<FeedPage?> loadFeed() async {
    feedStarted = true;
    return null;
  }
}
