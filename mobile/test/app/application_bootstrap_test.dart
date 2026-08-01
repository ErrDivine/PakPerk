import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/app/application_bootstrap.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/core/cache/local_store.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/core/settings/appearance.dart';
import 'package:pakperk/features/feed/feed_controller.dart';
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
    expect(await bootstrapper.waitForLocalStore(), same(store));
    expect(bootstrapper.data, isNull);

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

  test(
    'a sibling hydration failure drains every started task before settling',
    () async {
      final store = _GatedLocalStore();
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: _loadBundledFeed,
      );

      final hydration = bootstrapper.hydrateLocalState();
      await _flushMicrotasks();
      var failureObserved = false;
      final failure = expectLater(
        hydration,
        throwsA(isA<StateError>()),
      ).whenComplete(() => failureObserved = true);
      store.restorationResult.completeError(StateError('restoration failed'));

      await _flushMicrotasks();
      expect(failureObserved, isFalse);
      expect(store.sessionResult.isCompleted, isFalse);
      expect(bootstrapper.data, isNull);
      store.sessionResult.complete('unused-session');
      await failure;
    },
  );

  test('slower stale hydration cannot replace a newer generation', () async {
    final firstFactory = Completer<LocalStore>();
    final secondFactory = Completer<LocalStore>();
    final factories = [firstFactory, secondFactory];
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () => factories.removeAt(0).future,
      bundledFeedLoader: _loadBundledFeed,
    );
    final staleStore = _CloseTrackingLocalStore()..sessionId = 'stale-session';
    final currentStore = _CloseTrackingLocalStore()
      ..sessionId = 'current-session';

    final staleHydration = bootstrapper.hydrateLocalState();
    await _flushMicrotasks();
    final currentHydration = bootstrapper.hydrateLocalState();
    secondFactory.complete(currentStore);

    firstFactory.complete(staleStore);
    await staleHydration;
    await currentHydration;
    expect(bootstrapper.data?.store, same(currentStore));
    expect(bootstrapper.data?.anonymousSessionId, 'current-session');
    expect(staleStore.closeCalls, 1);
    expect(currentStore.closeCalls, 0);
  });

  test(
    'ordinary retry closes and drains timed-out hydration before replacement',
    () async {
      final events = <String>[];
      final staleStore = _CloseAbortsHydrationStore(events);
      final currentStore = _CloseTrackingLocalStore()
        ..sessionId = 'current-session';
      var factoryCalls = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async {
          factoryCalls += 1;
          return factoryCalls == 1 ? staleStore : currentStore;
        },
        bundledFeedLoader: _loadBundledFeed,
      );

      final staleHydration = bootstrapper.hydrateLocalState();
      final staleFailure = expectLater(
        staleHydration,
        throwsA(isA<StateError>()),
      );
      await _flushMicrotasks();
      expect(factoryCalls, 1);

      final currentHydration = bootstrapper.hydrateLocalState();
      final currentReadiness = bootstrapper.waitForLocalStore();
      var replacementReady = false;
      currentReadiness.then((_) => replacementReady = true);
      await _flushMicrotasks();

      expect(events, ['close-start']);
      expect(factoryCalls, 1, reason: 'replacement must wait for stale close');
      expect(replacementReady, isFalse);

      staleStore.allowClose.complete();
      await staleFailure;
      await currentHydration;

      expect(events, ['close-start', 'close-end']);
      expect(factoryCalls, 2);
      expect(await currentReadiness, same(currentStore));
      expect(bootstrapper.data?.store, same(currentStore));
      expect(staleStore.closeCalls, 1);
      expect(currentStore.closeCalls, 0);
    },
  );

  test(
    'delayed session lookup stays bound to leased attempt across retry',
    () async {
      final events = <String>[];
      final staleStore = _CloseAbortsHydrationStore(events);
      final replacementStore = _CloseTrackingLocalStore()
        ..sessionId = 'replacement-session';
      final leaseAcquired = Completer<void>();
      final allowStoreLookup = Completer<void>();
      final sessionStarted = Completer<void>();
      final releaseSession = Completer<void>();
      var factoryCalls = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async {
          factoryCalls += 1;
          events.add('factory-$factoryCalls');
          return factoryCalls == 1 ? staleStore : replacementStore;
        },
        bundledFeedLoader: _loadBundledFeed,
      );

      final staleHydration = bootstrapper.hydrateLocalState();
      final staleFailure = expectLater(
        staleHydration,
        throwsA(isA<StateError>()),
      );
      final sessionInspection = bootstrapper.withStartupLocalStoreLease(
        () async {
          events.add('lease-acquired');
          leaseAcquired.complete();
          await allowStoreLookup.future;
          expect(await bootstrapper.waitForLocalStore(), same(staleStore));
          events.add('session-start');
          sessionStarted.complete();
          await releaseSession.future;
          expect(staleStore.closeCalls, 0);
          events.add('session-end');
        },
      );
      await leaseAcquired.future;
      await _flushMicrotasks();
      expect(factoryCalls, 1);

      final replacementHydration = bootstrapper.hydrateLocalState();
      final replacementReadiness = bootstrapper.waitForLocalStore();
      allowStoreLookup.complete();
      await sessionStarted.future;
      await _flushMicrotasks();

      expect(staleStore.closeCalls, 0);
      expect(factoryCalls, 1);
      expect(events, ['lease-acquired', 'factory-1', 'session-start']);

      releaseSession.complete();
      await sessionInspection;
      await _flushMicrotasks();
      expect(events, [
        'lease-acquired',
        'factory-1',
        'session-start',
        'session-end',
        'close-start',
      ]);
      expect(factoryCalls, 1);

      staleStore.allowClose.complete();
      await staleFailure;
      await replacementHydration;

      expect(events, [
        'lease-acquired',
        'factory-1',
        'session-start',
        'session-end',
        'close-start',
        'close-end',
        'factory-2',
      ]);
      expect(await replacementReadiness, same(replacementStore));
      expect(bootstrapper.data?.store, same(replacementStore));
      expect(staleStore.closeCalls, 1);
      expect(replacementStore.closeCalls, 0);
    },
  );

  test('completed local hydration is reused by a session-only retry', () async {
    var factoryCalls = 0;
    final store = _CloseTrackingLocalStore()..sessionId = 'stable-session';
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () async {
        factoryCalls += 1;
        return store;
      },
      bundledFeedLoader: _loadBundledFeed,
    );

    await bootstrapper.hydrateLocalState();
    final firstData = bootstrapper.data;
    await bootstrapper.hydrateLocalState();

    expect(factoryCalls, 1);
    expect(bootstrapper.data, same(firstData));
    expect(await bootstrapper.waitForLocalStore(), same(store));
    expect(store.closeCalls, 0);
  });

  test('mounted-store lease pins delayed lookup while repair waits', () async {
    final store = _CloseTrackingLocalStore()..sessionId = 'mounted-session';
    final leaseAcquired = Completer<void>();
    final allowStoreLookup = Completer<void>();
    final storeResolved = Completer<void>();
    final releaseSession = Completer<void>();
    var repairCalls = 0;
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () async => store,
      repairLocalData: () async {
        repairCalls += 1;
      },
      bundledFeedLoader: _loadBundledFeed,
    );
    await bootstrapper.hydrateLocalState();

    final inspection = bootstrapper.withStartupLocalStoreLease(() async {
      leaseAcquired.complete();
      await allowStoreLookup.future;
      expect(await bootstrapper.waitForLocalStore(), same(store));
      storeResolved.complete();
      await releaseSession.future;
      expect(store.closeCalls, 0);
    });
    await leaseAcquired.future;

    final repair = bootstrapper.repairLocalStatePreservingCredentials();
    allowStoreLookup.complete();
    await storeResolved.future;
    await _flushMicrotasks();
    expect(store.closeCalls, 0);
    expect(repairCalls, 0);

    releaseSession.complete();
    await inspection;
    await repair;
    expect(store.closeCalls, 1);
    expect(repairCalls, 1);
  });

  test(
    'repair drains and closes in-flight hydration before a clean retry',
    () async {
      final staleFactory = Completer<LocalStore>();
      final currentStore = MemoryLocalStore()..sessionId = 'current-session';
      final staleStore = _CloseTrackingLocalStore()
        ..sessionId = 'stale-session';
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
      await _flushMicrotasks();
      final repair = bootstrapper.repairLocalStatePreservingCredentials();
      await _flushMicrotasks();
      expect(repairCalls, 0, reason: 'repair must wait for the prior store');

      staleFactory.complete(staleStore);
      await staleHydration;
      await repair;
      expect(repairCalls, 1);
      expect(bootstrapper.data, isNull);
      expect(staleStore.closeCalls, 1);

      await bootstrapper.hydrateLocalState();
      expect(bootstrapper.data?.store, same(currentStore));
      expect(bootstrapper.data?.anonymousSessionId, 'current-session');
    },
  );

  test('repair waits for close and failed hydration to drain', () async {
    final events = <String>[];
    final store = _CloseAbortsHydrationStore(events);
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () async => store,
      repairLocalData: () async => events.add('repair'),
      bundledFeedLoader: _loadBundledFeed,
    );

    final hydration = bootstrapper.hydrateLocalState();
    final hydrationFailure = expectLater(hydration, throwsA(isA<StateError>()));
    await _flushMicrotasks();
    expect(store.sessionStarted, isTrue);
    expect(store.restorationStarted, isTrue);

    final repair = bootstrapper.repairLocalStatePreservingCredentials();
    await _flushMicrotasks();
    expect(events, ['close-start']);
    expect(store.closeCalls, 1);

    store.allowClose.complete();
    await hydrationFailure;
    await repair;

    expect(events, ['close-start', 'close-end', 'repair']);
    expect(bootstrapper.data, isNull);
  });

  test('repair and replacement drain every failed hydration sibling', () async {
    final events = <String>[];
    final siblingGate = Completer<void>();
    final staleStore = _FailingRestorationCloseStore(events);
    final replacementStore = _CloseTrackingLocalStore()
      ..sessionId = 'replacement-session'
      ..feed = FeedPage(items: [samplePaper]);
    var factoryCalls = 0;
    var repairCalls = 0;
    final bootstrapper = ApplicationStartupBootstrapper(
      storeFactory: () async {
        factoryCalls += 1;
        events.add('factory-$factoryCalls');
        return factoryCalls == 1 ? staleStore : replacementStore;
      },
      repairLocalData: () async {
        repairCalls += 1;
        events.add('repair');
      },
      bundledFeedLoader: () async {
        events.add('sibling-start');
        await siblingGate.future;
        events.add('sibling-end');
        return FeedPage(items: [samplePaper]);
      },
    );

    final staleHydration = bootstrapper.hydrateLocalState();
    var staleSettled = false;
    final staleFailure = expectLater(
      staleHydration,
      throwsA(isA<StateError>()),
    ).whenComplete(() => staleSettled = true);
    await _flushMicrotasks();
    expect(events, ['factory-1', 'restoration-error', 'sibling-start']);

    final repair = bootstrapper.repairLocalStatePreservingCredentials();
    final replacementHydration = bootstrapper.hydrateLocalState();
    final replacementReadiness = bootstrapper.waitForLocalStore();
    await _flushMicrotasks();

    expect(staleStore.closeCalls, 1);
    expect(staleSettled, isFalse);
    expect(repairCalls, 0);
    expect(factoryCalls, 1);
    expect(events, [
      'factory-1',
      'restoration-error',
      'sibling-start',
      'close',
    ]);

    siblingGate.complete();
    await staleFailure;
    await repair;
    await replacementHydration;

    expect(events, [
      'factory-1',
      'restoration-error',
      'sibling-start',
      'close',
      'sibling-end',
      'repair',
      'factory-2',
    ]);
    expect(await replacementReadiness, same(replacementStore));
    expect(bootstrapper.data?.store, same(replacementStore));
    expect(replacementStore.closeCalls, 0);
  });

  test(
    'timed-out repair is single-flight and blocks replacement hydration',
    () async {
      final mountedStore = _CloseTrackingLocalStore()
        ..sessionId = 'mounted-session';
      final replacementStore = _CloseTrackingLocalStore()
        ..sessionId = 'replacement-session';
      final repairGate = Completer<void>();
      var factoryCalls = 0;
      var repairCalls = 0;
      final bootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async {
          factoryCalls += 1;
          return factoryCalls == 1 ? mountedStore : replacementStore;
        },
        repairLocalData: () {
          repairCalls += 1;
          return repairGate.future;
        },
        bundledFeedLoader: _loadBundledFeed,
      );

      await bootstrapper.hydrateLocalState();
      expect(bootstrapper.data?.store, same(mountedStore));

      final firstRepair = bootstrapper.repairLocalStatePreservingCredentials();
      await _flushMicrotasks();
      final repeatedRepair = bootstrapper
          .repairLocalStatePreservingCredentials();
      expect(repeatedRepair, same(firstRepair));
      expect(repairCalls, 1);
      expect(mountedStore.closeCalls, 1);

      final replacementHydration = bootstrapper.hydrateLocalState();
      final replacementReadiness = bootstrapper.waitForLocalStore();
      await _flushMicrotasks();
      expect(factoryCalls, 1, reason: 'repair still owns the lifecycle queue');
      expect(bootstrapper.data, isNull);

      repairGate.complete();
      await firstRepair;
      await replacementHydration;

      expect(repairCalls, 1);
      expect(factoryCalls, 2);
      expect(await replacementReadiness, same(replacementStore));
      expect(bootstrapper.data?.store, same(replacementStore));
      expect(replacementStore.closeCalls, 0);
    },
  );

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

  testWidgets(
    'cached app tree renders while local session inspection is still pending',
    (tester) async {
      final store = MemoryLocalStore()..feed = FeedPage(items: [samplePaper]);
      final applicationBootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async => store,
        bundledFeedLoader: _loadBundledFeed,
      );
      final sessionResult = Completer<StartupSessionStatus>();
      final bootstrapper = _SessionGatedBootstrapper(
        delegate: applicationBootstrapper,
        sessionResult: sessionResult,
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
            ...applicationStartupDataOverrides(applicationBootstrapper),
          ],
          child: PakPerkBootstrapApp(bootstrapper: applicationBootstrapper),
        ),
      );

      for (
        var frame = 0;
        frame < 6 && find.text(samplePaper.title).evaluate().isEmpty;
        frame += 1
      ) {
        await tester.pump();
      }

      expect(bootstrapper.sessionInspectionStarted, isTrue);
      expect(sessionResult.isCompleted, isFalse);
      expect(find.text(samplePaper.title), findsOneWidget);
      expect(find.text(samplePaper.title).hitTestable(), findsOneWidget);
      expect(repository.feedCalls, 1);
      expect(pendingNetwork.isCompleted, isFalse);
      final container = ProviderScope.containerOf(
        tester.element(find.text(samplePaper.title)),
      );
      expect(
        container.read(startupControllerProvider).phase,
        StartupPhase.localReady,
      );

      sessionResult.complete(StartupSessionStatus.anonymous);
      await tester.pump();
      await tester.pump();
      expect(container.read(startupControllerProvider).isReady, isTrue);
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

  testWidgets(
    'post-local session retry keeps the mounted store and feed providers',
    (tester) async {
      var factoryCalls = 0;
      final store = MemoryLocalStore()..feed = FeedPage(items: [samplePaper]);
      final applicationBootstrapper = ApplicationStartupBootstrapper(
        storeFactory: () async {
          factoryCalls += 1;
          return store;
        },
        bundledFeedLoader: _loadBundledFeed,
      );
      final firstSession = Completer<StartupSessionStatus>();
      final bootstrapper = _RetryingSessionBootstrapper(
        delegate: applicationBootstrapper,
        firstSession: firstSession,
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
            ...applicationStartupDataOverrides(applicationBootstrapper),
          ],
          child: PakPerkBootstrapApp(bootstrapper: applicationBootstrapper),
        ),
      );
      for (
        var frame = 0;
        frame < 6 && find.text(samplePaper.title).evaluate().isEmpty;
        frame += 1
      ) {
        await tester.pump();
      }

      final container = ProviderScope.containerOf(
        tester.element(find.text(samplePaper.title)),
      );
      final feedController = container.read(feedControllerProvider.notifier);
      expect(factoryCalls, 1);

      firstSession.completeError(StateError('secure store unavailable'));
      for (
        var frame = 0;
        frame < 6 &&
            find
                .byKey(const ValueKey('startup-recoverable-failure'))
                .evaluate()
                .isEmpty;
        frame += 1
      ) {
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('startup-recoverable-failure')),
        findsOneWidget,
      );
      expect(find.byType(PakPerkApp), findsOneWidget);
      expect(
        container.read(startupControllerProvider).failure?.localStateUsable,
        isTrue,
      );

      await container.read(startupControllerProvider.notifier).retry();
      await tester.pump();
      await tester.pump();

      expect(find.text(samplePaper.title), findsOneWidget);
      expect(factoryCalls, 1);
      expect(
        container.read(feedControllerProvider.notifier),
        same(feedController),
      );
      expect(bootstrapper.sessionChecks, 2);

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

class _CloseTrackingLocalStore extends MemoryLocalStore
    implements CloseableLocalStore {
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls += 1;
  }
}

final class _FailingRestorationCloseStore extends _CloseTrackingLocalStore {
  _FailingRestorationCloseStore(this.events);

  final List<String> events;

  @override
  Future<AppRestorationState> loadRestoration() {
    events.add('restoration-error');
    return Future.error(StateError('restoration failed'));
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    events.add('close');
  }
}

final class _CloseAbortsHydrationStore extends _GatedLocalStore
    implements CloseableLocalStore {
  _CloseAbortsHydrationStore(this.events);

  final List<String> events;
  final Completer<void> allowClose = Completer<void>();
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls += 1;
    events.add('close-start');
    if (!sessionResult.isCompleted) {
      sessionResult.completeError(StateError('store closed'));
    }
    if (!restorationResult.isCompleted) {
      restorationResult.completeError(StateError('store closed'));
    }
    await allowClose.future;
    events.add('close-end');
  }
}

final class _SessionGatedBootstrapper implements StartupBootstrapper {
  _SessionGatedBootstrapper({
    required StartupBootstrapper delegate,
    required this.sessionResult,
  }) : _delegate = delegate;

  final StartupBootstrapper _delegate;
  final Completer<StartupSessionStatus> sessionResult;
  bool sessionInspectionStarted = false;

  @override
  Future<void> hydrateLocalState() => _delegate.hydrateLocalState();

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() {
    sessionInspectionStarted = true;
    return sessionResult.future;
  }

  @override
  Future<void> repairLocalStatePreservingCredentials() =>
      _delegate.repairLocalStatePreservingCredentials();

  @override
  Future<void> runPostReadyWork() => _delegate.runPostReadyWork();
}

final class _RetryingSessionBootstrapper implements StartupBootstrapper {
  _RetryingSessionBootstrapper({
    required StartupBootstrapper delegate,
    required this.firstSession,
  }) : _delegate = delegate;

  final StartupBootstrapper _delegate;
  final Completer<StartupSessionStatus> firstSession;
  int sessionChecks = 0;

  @override
  Future<void> hydrateLocalState() => _delegate.hydrateLocalState();

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() {
    sessionChecks += 1;
    return sessionChecks == 1
        ? firstSession.future
        : Future.value(StartupSessionStatus.anonymous);
  }

  @override
  Future<void> repairLocalStatePreservingCredentials() =>
      _delegate.repairLocalStatePreservingCredentials();

  @override
  Future<void> runPostReadyWork() => _delegate.runPostReadyWork();
}
