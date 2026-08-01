import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import '../database/library_dao.dart';
import '../library/library_models.dart';
import '../library/library_repository.dart';
import 'outbox_controller.dart';
import '../telemetry/telemetry.dart';

abstract interface class LibrarySyncWakeup {
  void cancel();
}

typedef LibrarySyncWakeupFactory =
    LibrarySyncWakeup Function(Duration delay, void Function() callback);

final class LibrarySyncController extends StateNotifier<LibrarySyncStatus> {
  LibrarySyncController({
    required LibraryRepository repository,
    required LibraryOutboxController outbox,
    LibrarySyncWakeupFactory? wakeupFactory,
    DateTime Function()? clock,
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _repository = repository,
       _outbox = outbox,
       _wakeupFactory = wakeupFactory ?? _timerWakeup,
       _clock = clock ?? DateTime.now,
       _telemetry = telemetry,
       super(const LibrarySyncStatus.idle());

  final LibraryRepository _repository;
  final LibraryOutboxController _outbox;
  final LibrarySyncWakeupFactory _wakeupFactory;
  final DateTime Function() _clock;
  final TelemetrySink _telemetry;
  LibrarySyncWakeup? _wakeup;
  _ActiveLibraryScope? _active;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;

  Future<void> start({required String accountId, required int authEpoch}) {
    _validateScope(accountId: accountId, authEpoch: authEpoch);
    if (!_repository.isRemoteScopeVerified(
      accountId: accountId,
      authEpoch: authEpoch,
    )) {
      stop();
      return Future<void>.value();
    }
    final scope = _activate(accountId: accountId, authEpoch: authEpoch);
    return _serialize(() async {
      if (!_isRunnable(scope)) return;
      await _repository.recoverInFlight(accountId);
      if (!_isRunnable(scope)) return;
      await _runCycle(scope, refreshRemote: true);
    });
  }

  Future<void> drain() {
    final scope = _active;
    if (scope == null) return Future<void>.value();
    return _serialize(() => _runCycle(scope, refreshRemote: false));
  }

  Future<void> refresh({bool forceFull = false}) {
    final scope = _active;
    if (scope == null) return Future<void>.value();
    return _serialize(
      () => _runCycle(scope, refreshRemote: true, forceFull: forceFull),
    );
  }

  Future<void> onNetworkRecovered() => refresh();

  Future<void> onForeground() => refresh();

  void stop() {
    _generation += 1;
    _active = null;
    _wakeup?.cancel();
    _wakeup = null;
    if (!_disposed) state = const LibrarySyncStatus.idle();
  }

  _ActiveLibraryScope _activate({
    required String accountId,
    required int authEpoch,
  }) {
    _wakeup?.cancel();
    _wakeup = null;
    final scope = _ActiveLibraryScope(
      accountId: accountId,
      authEpoch: authEpoch,
      generation: ++_generation,
    );
    _active = scope;
    return scope;
  }

  Future<void> _runCycle(
    _ActiveLibraryScope scope, {
    required bool refreshRemote,
    bool forceFull = false,
  }) async {
    if (!_isRunnable(scope)) return;
    _wakeup?.cancel();
    _wakeup = null;
    final initialPendingCount = await _repository.pendingCount(scope.accountId);
    if (!_isRunnable(scope)) return;
    state = LibrarySyncStatus(
      phase: LibrarySyncPhase.syncing,
      pendingCount: initialPendingCount,
    );
    try {
      final drained = await _outbox.drain(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
      );
      if (!_isRunnable(scope) || drained.scopeChanged) return;
      if (refreshRemote) {
        await _repository.refresh(
          accountId: scope.accountId,
          authEpoch: scope.authEpoch,
          forceFull: forceFull,
        );
      }
      if (!_isRunnable(scope)) return;
      final pendingCount = await _repository.pendingCount(scope.accountId);
      if (!_isRunnable(scope)) return;
      state = LibrarySyncStatus(
        phase: drained.issue != null
            ? LibrarySyncPhase.failed
            : pendingCount > 0
            ? LibrarySyncPhase.pending
            : LibrarySyncPhase.idle,
        pendingCount: pendingCount,
        issue: drained.issue,
      );
      if (drained.issue == null &&
          initialPendingCount > 0 &&
          pendingCount == 0) {
        emitTelemetry(_telemetry, PakPerkTelemetryEvent.saveSynced, const {
          'intent': 'mutation',
        });
      } else if (drained.issue != null) {
        emitTelemetry(_telemetry, PakPerkTelemetryEvent.saveFailed, {
          'intent': 'mutation',
          'failure_code': drained.issue!.code.toLowerCase(),
          'retryable': pendingCount > 0,
        });
      }
      _schedule(scope, drained.nextAttemptAt);
    } on LibraryScopeChanged {
      // The auth/account epoch changed while local work was being committed.
      // Its transaction rolled back and the replacement scope owns recovery.
    } on ApiException catch (error) {
      if (!_isRunnable(scope)) return;
      final pendingCount = await _repository.pendingCount(scope.accountId);
      if (!_isRunnable(scope)) return;
      state = LibrarySyncStatus(
        phase: LibrarySyncPhase.failed,
        pendingCount: pendingCount,
        issue: LibrarySyncIssue.fromCode(error.code),
      );
      emitTelemetry(_telemetry, PakPerkTelemetryEvent.saveFailed, {
        'intent': 'mutation',
        'failure_code': 'remote_sync',
        'retryable': error.retryable,
      });
      _schedule(scope, await _repository.nextAttemptAt(scope.accountId));
    } on Object {
      if (!_isRunnable(scope)) return;
      final pendingCount = await _repository.pendingCount(scope.accountId);
      if (!_isRunnable(scope)) return;
      state = LibrarySyncStatus(
        phase: LibrarySyncPhase.failed,
        pendingCount: pendingCount,
        issue: LibrarySyncIssue.fromCode('LOCAL_SYNC_UNAVAILABLE'),
      );
      _schedule(scope, await _repository.nextAttemptAt(scope.accountId));
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _tail.then((_) => action(), onError: (_) => action());
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  void _schedule(_ActiveLibraryScope scope, DateTime? nextAttemptAt) {
    _wakeup?.cancel();
    _wakeup = null;
    if (!_isRunnable(scope) || nextAttemptAt == null) return;
    final delay = nextAttemptAt.toUtc().difference(_clock().toUtc());
    _wakeup = _wakeupFactory(delay.isNegative ? Duration.zero : delay, () {
      if (_isRunnable(scope)) unawaited(drain());
    });
  }

  void _validateScope({required String accountId, required int authEpoch}) {
    if (accountId.isEmpty || accountId.length > 128 || authEpoch < 0) {
      throw ArgumentError('Invalid library sync scope.');
    }
  }

  bool _isRunnable(_ActiveLibraryScope scope) =>
      _isActive(scope) &&
      _repository.isRemoteScopeVerified(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
      );

  bool _isActive(_ActiveLibraryScope scope) =>
      !_disposed &&
      identical(_active, scope) &&
      scope.generation == _generation;

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}

final class _ActiveLibraryScope {
  const _ActiveLibraryScope({
    required this.accountId,
    required this.authEpoch,
    required this.generation,
  });

  final String accountId;
  final int authEpoch;
  final int generation;
}

final class _TimerWakeup implements LibrarySyncWakeup {
  _TimerWakeup(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

LibrarySyncWakeup _timerWakeup(Duration delay, void Function() callback) =>
    _TimerWakeup(delay, callback);
