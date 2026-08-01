import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/telemetry/telemetry.dart';

enum StartupPhase {
  bootstrapping,
  localReady,
  authenticatedSessionChecked,
  ready,
  recoverableFailure,
}

enum StartupLaunchMode { cold, warm, deepLink }

/// The local result of inspecting credentials during startup.
///
/// Token refresh is deliberately not part of the startup gate. An expired
/// token should return [refreshRequired], then refresh in post-ready work.
enum StartupSessionStatus { anonymous, authenticated, refreshRequired }

class StartupTimeoutException implements Exception {
  const StartupTimeoutException(this.budget);

  final Duration budget;

  @override
  String toString() =>
      'Local startup exceeded its ${budget.inMilliseconds} ms budget.';
}

class StartupFailure {
  const StartupFailure({
    required this.error,
    required this.stackTrace,
    required this.timedOut,
    this.localStateUsable = false,
  });

  final Object error;
  final StackTrace stackTrace;
  final bool timedOut;
  final bool localStateUsable;
}

class StartupState {
  const StartupState({
    required this.phase,
    required this.launchMode,
    required this.attempt,
    required this.openingCompleted,
    this.sessionStatus,
    this.failure,
  });

  factory StartupState.initial(StartupLaunchMode launchMode) => StartupState(
    phase: StartupPhase.bootstrapping,
    launchMode: launchMode,
    attempt: 0,
    openingCompleted: launchMode == StartupLaunchMode.warm,
  );

  final StartupPhase phase;
  final StartupLaunchMode launchMode;
  final StartupSessionStatus? sessionStatus;
  final StartupFailure? failure;
  final int attempt;
  final bool openingCompleted;

  bool get isReady => phase == StartupPhase.ready;
  bool get hasUsableLocalState =>
      phase == StartupPhase.localReady ||
      phase == StartupPhase.authenticatedSessionChecked ||
      phase == StartupPhase.ready;

  bool get shouldShowOpening => hasUsableLocalState && !openingCompleted;

  StartupState copyWith({
    StartupPhase? phase,
    StartupLaunchMode? launchMode,
    StartupSessionStatus? sessionStatus,
    StartupFailure? failure,
    bool clearFailure = false,
    int? attempt,
    bool? openingCompleted,
  }) {
    return StartupState(
      phase: phase ?? this.phase,
      launchMode: launchMode ?? this.launchMode,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      failure: clearFailure ? null : failure ?? this.failure,
      attempt: attempt ?? this.attempt,
      openingCompleted: openingCompleted ?? this.openingCompleted,
    );
  }
}

typedef StartupTask = Future<void> Function();
typedef StartupSessionTask = Future<StartupSessionStatus> Function();
typedef StartupErrorHandler =
    void Function(Object error, StackTrace stackTrace);

abstract interface class StartupBootstrapper {
  /// Opens local storage, migrates it, and loads lightweight cached state.
  Future<void> hydrateLocalState();

  /// Reads local session metadata only. It must not refresh over the network.
  Future<StartupSessionStatus> checkAuthenticatedSession();

  /// Repairs rebuildable local data without deleting secure credentials.
  Future<void> repairLocalStatePreservingCredentials();

  /// Performs non-gating refreshes after the first usable Flutter frame.
  Future<void> runPostReadyWork();
}

/// Optional coordination seam for startup work that uses the hydration store
/// concurrently with public-cache loading.
///
/// Implementations keep supersession/repair from closing the store until the
/// protected local-only inspection has released it. This never makes network
/// work part of the startup gate.
abstract interface class StartupLocalStoreLeaseCoordinator {
  Future<T> withStartupLocalStoreLease<T>(Future<T> Function() operation);
}

/// A bootstrapper for composing independent local tasks without serializing
/// them unnecessarily. Tasks with ordering requirements can be grouped into a
/// single callback and sequenced within that callback.
class ConcurrentStartupBootstrapper implements StartupBootstrapper {
  const ConcurrentStartupBootstrapper({
    required this.localHydrators,
    required this.sessionCheck,
    this.localRepair,
    this.postReadyTasks = const [],
  });

  final List<StartupTask> localHydrators;
  final StartupSessionTask sessionCheck;
  final StartupTask? localRepair;
  final List<StartupTask> postReadyTasks;

  @override
  Future<void> hydrateLocalState() async {
    await Future.wait([
      for (final hydrate in localHydrators) hydrate(),
    ], eagerError: true);
  }

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() => sessionCheck();

  @override
  Future<void> repairLocalStatePreservingCredentials() async {
    await localRepair?.call();
  }

  @override
  Future<void> runPostReadyWork() async {
    await Future.wait([
      for (final task in postReadyTasks) task(),
    ], eagerError: false);
  }
}

/// Phase 1 performs its concrete preference hydration before `runApp`; later
/// phases can override [startupBootstrapperProvider] with database/auth work.
class PrehydratedStartupBootstrapper implements StartupBootstrapper {
  const PrehydratedStartupBootstrapper();

  @override
  Future<void> hydrateLocalState() async {}

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() async =>
      StartupSessionStatus.anonymous;

  @override
  Future<void> repairLocalStatePreservingCredentials() async {}

  @override
  Future<void> runPostReadyWork() async {}
}

abstract interface class StartupNativeSplashHandoff {
  /// Releases the native launch surface after a Flutter frame is laid out.
  /// This method must be idempotent.
  void releaseToFlutter();
}

class FlutterNativeSplashHandoff implements StartupNativeSplashHandoff {
  FlutterNativeSplashHandoff({WidgetsBinding? binding})
    : _binding = binding ?? WidgetsBinding.instance;

  final WidgetsBinding _binding;
  bool _releaseScheduled = false;

  /// Call immediately after binding initialization and before asynchronous
  /// local hydration. [releaseToFlutter] will allow the first frame once the
  /// controller reaches local-ready or needs to show a recovery surface.
  static void preserve(WidgetsBinding binding) {
    FlutterNativeSplash.preserve(widgetsBinding: binding);
  }

  @override
  void releaseToFlutter() {
    if (_releaseScheduled) return;
    _releaseScheduled = true;
    _binding.addPostFrameCallback((_) => FlutterNativeSplash.remove());
  }
}

class NoopStartupNativeSplashHandoff implements StartupNativeSplashHandoff {
  const NoopStartupNativeSplashHandoff();

  @override
  void releaseToFlutter() {}
}

class StartupController extends StateNotifier<StartupState> {
  StartupController({
    required StartupBootstrapper bootstrapper,
    required StartupNativeSplashHandoff splashHandoff,
    StartupLaunchMode launchMode = StartupLaunchMode.cold,
    Duration bootstrapTimeout = const Duration(seconds: 5),
    StartupErrorHandler? onPostReadyError,
    TelemetrySink telemetry = const NoopTelemetrySink(),
    String environment = 'development',
  }) : assert(bootstrapTimeout > Duration.zero),
       _bootstrapper = bootstrapper,
       _splashHandoff = splashHandoff,
       _bootstrapTimeout = bootstrapTimeout,
       _onPostReadyError = onPostReadyError,
       _telemetry = telemetry,
       _environment = environment,
       super(StartupState.initial(launchMode)) {
    if (launchMode == StartupLaunchMode.cold) {
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.appColdStart, {
        'environment': _environment,
      });
    }
  }

  final StartupBootstrapper _bootstrapper;
  final StartupNativeSplashHandoff _splashHandoff;
  final Duration _bootstrapTimeout;
  final StartupErrorHandler? _onPostReadyError;
  final TelemetrySink _telemetry;
  final String _environment;

  Future<void>? _activeRun;
  int _runToken = 0;
  bool _postReadyStarted = false;
  bool _firstUsableFramePresented = false;
  bool _disposed = false;
  DateTime? _attemptStartedAt;

  Future<void> start() {
    if (state.isReady) return Future.value();
    return _beginAttempt(repairFirst: false);
  }

  Future<void> retry() {
    if (state.phase != StartupPhase.recoverableFailure) {
      return Future.value();
    }
    return _beginAttempt(repairFirst: false);
  }

  Future<void> repairAndRetry() {
    if (state.phase != StartupPhase.recoverableFailure) {
      return Future.value();
    }
    return _beginAttempt(
      repairFirst: !(state.failure?.localStateUsable ?? false),
    );
  }

  void markOpeningComplete() {
    if (_disposed || state.openingCompleted) return;
    state = state.copyWith(openingCompleted: true);
  }

  /// Starts network refreshes and outbox work once, without changing a ready
  /// app back into a blocking startup state.
  void notifyFirstUsableFrame() {
    if (_disposed || !state.hasUsableLocalState) return;
    _firstUsableFramePresented = true;
    _startPostReadyWorkIfEligible();
  }

  void _startPostReadyWorkIfEligible() {
    if (_disposed ||
        !state.isReady ||
        !_firstUsableFramePresented ||
        _postReadyStarted) {
      return;
    }
    _postReadyStarted = true;
    unawaited(_runPostReadyWork());
  }

  Future<void> _beginAttempt({required bool repairFirst}) {
    final active = _activeRun;
    if (active != null) return active;

    final attempt = state.attempt + 1;
    final runToken = ++_runToken;
    _attemptStartedAt = DateTime.now().toUtc();
    _postReadyStarted = false;
    _firstUsableFramePresented = false;
    state = StartupState(
      phase: StartupPhase.bootstrapping,
      launchMode: state.launchMode,
      attempt: attempt,
      openingCompleted:
          state.launchMode == StartupLaunchMode.warm || state.openingCompleted,
    );

    late final Future<void> operation;
    operation = _runAttempt(runToken: runToken, repairFirst: repairFirst)
        .whenComplete(() {
          if (identical(_activeRun, operation)) _activeRun = null;
        });
    _activeRun = operation;
    return operation;
  }

  Future<void> _runAttempt({
    required int runToken,
    required bool repairFirst,
  }) async {
    try {
      await _advance(runToken: runToken, repairFirst: repairFirst).timeout(
        _bootstrapTimeout,
        onTimeout: () => throw StartupTimeoutException(_bootstrapTimeout),
      );
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(runToken)) return;
      final localStateUsable = state.hasUsableLocalState;
      _runToken += 1;
      state = StartupState(
        phase: StartupPhase.recoverableFailure,
        launchMode: state.launchMode,
        attempt: state.attempt,
        openingCompleted: state.openingCompleted,
        failure: StartupFailure(
          error: error,
          stackTrace: stackTrace,
          timedOut: error is StartupTimeoutException,
          localStateUsable: localStateUsable,
        ),
      );
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.startupFailure, {
        'environment': _environment,
        'launch_mode': state.launchMode.name,
        'failure_code': error is StartupTimeoutException
            ? 'startup_timeout'
            : 'startup_local_failure',
        'timed_out': error is StartupTimeoutException,
      });
      unawaited(
        _telemetry
            .error(
              error,
              stackTrace,
              context: const {
                'component': 'startup',
                'operation': 'local_bootstrap',
              },
            )
            .catchError((Object _) {}),
      );
      // A recovery UI must replace a preserved native launch surface too.
      _splashHandoff.releaseToFlutter();
    }
  }

  Future<void> _advance({
    required int runToken,
    required bool repairFirst,
  }) async {
    if (repairFirst) {
      await _bootstrapper.repairLocalStatePreservingCredentials();
      if (!_isCurrent(runToken)) return;
    }

    // The secure-session/deletion-guard inspection is local and independent
    // of public cache hydration. Start both at once, while keeping their
    // publication phases ordered and fail-closed.
    final hydration = Future<void>.sync(_bootstrapper.hydrateLocalState);
    final sessionCheck = Future<StartupSessionStatus>.sync(
      _bootstrapper.checkAuthenticatedSession,
    );
    // If hydration fails first, the independently running session future must
    // not surface an unhandled asynchronous error after this attempt ends.
    sessionCheck.ignore();

    await hydration;
    if (!_isCurrent(runToken)) return;
    state = state.copyWith(phase: StartupPhase.localReady, clearFailure: true);
    _splashHandoff.releaseToFlutter();

    final sessionStatus = await sessionCheck;
    if (!_isCurrent(runToken)) return;
    state = state.copyWith(
      phase: StartupPhase.authenticatedSessionChecked,
      sessionStatus: sessionStatus,
      clearFailure: true,
    );

    state = state.copyWith(phase: StartupPhase.ready, clearFailure: true);
    _startPostReadyWorkIfEligible();
    final started = _attemptStartedAt;
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.startupReady, {
      'environment': _environment,
      'launch_mode': state.launchMode.name,
      if (started != null)
        'elapsed_ms': DateTime.now().toUtc().difference(started).inMilliseconds,
    });
  }

  Future<void> _runPostReadyWork() async {
    try {
      await _bootstrapper.runPostReadyWork();
    } on Object catch (error, stackTrace) {
      _onPostReadyError?.call(error, stackTrace);
    }
  }

  bool _isCurrent(int runToken) => !_disposed && runToken == _runToken;

  @override
  void dispose() {
    _disposed = true;
    _runToken += 1;
    super.dispose();
  }
}

final startupBootstrapperProvider = Provider<StartupBootstrapper>(
  (ref) => const PrehydratedStartupBootstrapper(),
);

final startupLaunchModeProvider = Provider<StartupLaunchMode>(
  (ref) => StartupLaunchMode.cold,
);

final startupBootstrapTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

final startupNativeSplashHandoffProvider = Provider<StartupNativeSplashHandoff>(
  (ref) => FlutterNativeSplashHandoff(),
);

final startupControllerProvider =
    StateNotifierProvider<StartupController, StartupState>((ref) {
      final controller = StartupController(
        bootstrapper: ref.watch(startupBootstrapperProvider),
        splashHandoff: ref.watch(startupNativeSplashHandoffProvider),
        launchMode: ref.watch(startupLaunchModeProvider),
        bootstrapTimeout: ref.watch(startupBootstrapTimeoutProvider),
        telemetry: ref.watch(telemetrySinkProvider),
        environment: ref.watch(appBuildConfigProvider).environment.name,
      );
      unawaited(controller.start());
      return controller;
    });
