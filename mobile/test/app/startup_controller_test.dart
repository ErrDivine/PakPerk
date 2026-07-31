import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/startup_controller.dart';

void main() {
  test(
    'cold startup exposes ordered local/session phases and starts post work once',
    () async {
      final localReady = Completer<void>();
      final sessionChecked = Completer<StartupSessionStatus>();
      final bootstrapper = _FakeBootstrapper(
        hydrate: () => localReady.future,
        checkSession: () => sessionChecked.future,
      );
      final splash = _RecordingSplashHandoff();
      final controller = StartupController(
        bootstrapper: bootstrapper,
        splashHandoff: splash,
        launchMode: StartupLaunchMode.cold,
      );
      final phases = <StartupPhase>[];
      controller.addListener((state) => phases.add(state.phase));

      final startup = controller.start();
      expect(controller.state.phase, StartupPhase.bootstrapping);
      expect(controller.state.attempt, 1);

      localReady.complete();
      await _flushMicrotasks();
      expect(controller.state.phase, StartupPhase.localReady);
      expect(splash.releaseCalls, 1);

      sessionChecked.complete(StartupSessionStatus.refreshRequired);
      await startup;
      expect(controller.state.phase, StartupPhase.ready);
      expect(
        controller.state.sessionStatus,
        StartupSessionStatus.refreshRequired,
      );
      expect(controller.state.shouldShowOpening, isTrue);
      expect(
        phases,
        containsAllInOrder([
          StartupPhase.localReady,
          StartupPhase.authenticatedSessionChecked,
          StartupPhase.ready,
        ]),
      );

      controller.notifyFirstUsableFrame();
      controller.notifyFirstUsableFrame();
      await _flushMicrotasks();
      expect(bootstrapper.postReadyCalls, 1);
      controller.markOpeningComplete();
      expect(controller.state.shouldShowOpening, isFalse);
      controller.dispose();
    },
  );

  test('warm startup never requests the full opening transition', () async {
    final controller = StartupController(
      bootstrapper: _FakeBootstrapper(),
      splashHandoff: _RecordingSplashHandoff(),
      launchMode: StartupLaunchMode.warm,
    );

    expect(controller.state.openingCompleted, isTrue);
    await controller.start();
    expect(controller.state.phase, StartupPhase.ready);
    expect(controller.state.shouldShowOpening, isFalse);
    controller.dispose();
  });

  test('bounded startup becomes recoverable and retry can succeed', () async {
    var hang = true;
    final bootstrapper = _FakeBootstrapper(
      hydrate: () => hang ? Completer<void>().future : Future.value(),
    );
    final splash = _RecordingSplashHandoff();
    final controller = StartupController(
      bootstrapper: bootstrapper,
      splashHandoff: splash,
      bootstrapTimeout: const Duration(milliseconds: 10),
    );

    await controller.start();
    expect(controller.state.phase, StartupPhase.recoverableFailure);
    expect(controller.state.failure?.timedOut, isTrue);
    expect(splash.releaseCalls, 1);

    hang = false;
    await controller.retry();
    expect(controller.state.phase, StartupPhase.ready);
    expect(controller.state.attempt, 2);
    controller.dispose();
  });

  test(
    'migration failure can repair local data without credential deletion',
    () async {
      var migrationBroken = true;
      final bootstrapper = _FakeBootstrapper(
        hydrate: () {
          if (migrationBroken) throw StateError('migration failed');
          return Future.value();
        },
        repair: () async {
          migrationBroken = false;
        },
      );
      final controller = StartupController(
        bootstrapper: bootstrapper,
        splashHandoff: _RecordingSplashHandoff(),
      );

      await controller.start();
      expect(controller.state.phase, StartupPhase.recoverableFailure);
      expect(controller.state.failure?.timedOut, isFalse);

      await controller.repairAndRetry();
      expect(bootstrapper.repairCalls, 1);
      expect(controller.state.phase, StartupPhase.ready);
      expect(controller.state.sessionStatus, StartupSessionStatus.anonymous);
      controller.dispose();
    },
  );

  test('concurrent local hydrators begin before either completes', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    var firstStarted = false;
    var secondStarted = false;
    final bootstrapper = ConcurrentStartupBootstrapper(
      localHydrators: [
        () {
          firstStarted = true;
          return first.future;
        },
        () {
          secondStarted = true;
          return second.future;
        },
      ],
      sessionCheck: () async => StartupSessionStatus.anonymous,
    );

    final hydration = bootstrapper.hydrateLocalState();
    expect(firstStarted, isTrue);
    expect(secondStarted, isTrue);
    first.complete();
    second.complete();
    await hydration;
  });
}

Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

class _FakeBootstrapper implements StartupBootstrapper {
  _FakeBootstrapper({
    Future<void> Function()? hydrate,
    Future<StartupSessionStatus> Function()? checkSession,
    Future<void> Function()? repair,
    Future<void> Function()? postReady,
  }) : _hydrate = hydrate ?? _complete,
       _checkSession = checkSession ?? _anonymous,
       _repair = repair ?? _complete,
       _postReady = postReady ?? _complete;

  final Future<void> Function() _hydrate;
  final Future<StartupSessionStatus> Function() _checkSession;
  final Future<void> Function() _repair;
  final Future<void> Function() _postReady;

  int repairCalls = 0;
  int postReadyCalls = 0;

  static Future<void> _complete() async {}

  static Future<StartupSessionStatus> _anonymous() async =>
      StartupSessionStatus.anonymous;

  @override
  Future<void> hydrateLocalState() => _hydrate();

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() => _checkSession();

  @override
  Future<void> repairLocalStatePreservingCredentials() {
    repairCalls += 1;
    return _repair();
  }

  @override
  Future<void> runPostReadyWork() {
    postReadyCalls += 1;
    return _postReady();
  }
}

class _RecordingSplashHandoff implements StartupNativeSplashHandoff {
  int releaseCalls = 0;

  @override
  void releaseToFlutter() {
    releaseCalls += 1;
  }
}
