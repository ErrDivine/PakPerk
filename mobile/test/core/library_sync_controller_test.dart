import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/sync/library_sync_controller.dart';
import 'package:pakperk/core/sync/outbox_controller.dart';
import 'package:pakperk/core/sync/retry_policy.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

import '../support/fakes.dart';

void main() {
  test('start drains, schedules retry, and lifecycle wake converges', () async {
    final harness = await _SyncHarness.create();
    addTearDown(harness.close);
    await harness.repository.setSaved(
      accountId: _accountId,
      authEpoch: 3,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );

    await harness.controller.start(accountId: _accountId, authEpoch: 3);

    expect(harness.controller.state.phase, LibrarySyncPhase.pending);
    expect(harness.controller.state.pendingCount, 1);
    expect(harness.remote.saveCalls, 1);
    expect(harness.wakeups, hasLength(1));
    expect(harness.wakeups.single.delay, const Duration(seconds: 5));

    harness.now = harness.now.add(harness.wakeups.single.delay);
    harness.wakeups.single.fire();
    // Queue behind the unawaited timer-triggered drain so this await observes
    // its canonical commit and final status publication.
    await harness.controller.drain();

    expect(harness.remote.saveCalls, 2);
    expect(harness.controller.state.phase, LibrarySyncPhase.idle);
    expect(harness.controller.state.pendingCount, 0);
    expect(
      await harness.database.select(harness.database.syncOutbox).get(),
      isEmpty,
    );
    expect(
      (await harness.database.select(harness.database.libraryItems).getSingle())
          .revision,
      1,
    );
    final backlog = harness.telemetry.events
        .where(
          (event) => event.$1 == PakPerkTelemetryEvent.libraryOutboxBacklog,
        )
        .toList(growable: false);
    expect(backlog, isNotEmpty);
    expect(backlog.first.$2, const {'pending_count': 1});
    expect(backlog.last.$2, const {'pending_count': 0});
  });

  test('stop cancels scheduled retry and stale callbacks are inert', () async {
    final harness = await _SyncHarness.create(alwaysOffline: true);
    addTearDown(harness.close);
    await harness.repository.setSaved(
      accountId: _accountId,
      authEpoch: 3,
      paperId: samplePaper.paperId,
      saved: true,
      paper: samplePaper,
    );
    await harness.controller.start(accountId: _accountId, authEpoch: 3);
    final wakeup = harness.wakeups.single;

    harness.controller.stop();
    expect(wakeup.cancelled, isTrue);
    expect(harness.controller.state.phase, LibrarySyncPhase.idle);
    wakeup.fire();
    await Future<void>.delayed(Duration.zero);

    expect(harness.remote.saveCalls, 1);
    expect(
      (await harness.database.select(harness.database.syncOutbox).getSingle())
          .state,
      'queued',
    );
  });

  test('stop during initial pending read cannot republish syncing', () async {
    final harness = await _SyncHarness.create();
    addTearDown(harness.close);
    await harness.controller.start(accountId: _accountId, authEpoch: 3);
    expect(harness.controller.state.phase, LibrarySyncPhase.idle);

    final transactionStarted = Completer<void>();
    final releaseTransaction = Completer<void>();
    final blocker = harness.database.transaction<void>(() async {
      transactionStarted.complete();
      await releaseTransaction.future;
    });
    await transactionStarted.future;
    final drain = harness.controller.drain();
    await Future<void>.delayed(Duration.zero);

    harness.controller.stop();
    expect(harness.controller.state.phase, LibrarySyncPhase.idle);
    releaseTransaction.complete();
    await blocker;
    await drain;

    expect(harness.controller.state.phase, LibrarySyncPhase.idle);
  });
}

final class _SyncHarness {
  _SyncHarness._({
    required this.database,
    required this.repository,
    required this.remote,
    required this.controller,
    required this.wakeups,
    required this.telemetry,
    required _MutableClock clock,
  }) : _clock = clock;

  final PakPerkDatabase database;
  final LibraryRepository repository;
  final _RetryThenSuccessRemote remote;
  final LibrarySyncController controller;
  final List<_FakeWakeup> wakeups;
  final _RecordingTelemetry telemetry;
  final _MutableClock _clock;

  DateTime get now => _clock.value;
  set now(DateTime value) => _clock.value = value;

  static Future<_SyncHarness> create({bool alwaysOffline = false}) async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    final clock = _MutableClock(DateTime.utc(2026, 7, 31, 12));
    final dao = LibraryDao(
      database,
      clock: () => clock.value,
      operationId: () => _operationId,
    );
    final remote = _RetryThenSuccessRemote(alwaysOffline: alwaysOffline);
    final repository = LibraryRepository(
      local: dao,
      remote: remote,
      sessionScope: () => (accountId: _accountId, authEpoch: 3),
      verifiedScope: () => (accountId: _accountId, authEpoch: 3),
    );
    await dao.applyFullSnapshot(
      accountId: _accountId,
      entries: const [],
      syncRevision: 0,
      scopeGuard: () => true,
    );
    final wakeups = <_FakeWakeup>[];
    final telemetry = _RecordingTelemetry();
    final controller = LibrarySyncController(
      repository: repository,
      outbox: LibraryOutboxController(
        repository: repository,
        retryPolicy: OutboxRetryPolicy(jitter: () => 0),
        clock: () => clock.value,
      ),
      clock: () => clock.value,
      telemetry: RedactingTelemetrySink(telemetry),
      wakeupFactory: (delay, callback) {
        final wakeup = _FakeWakeup(delay, callback);
        wakeups.add(wakeup);
        return wakeup;
      },
    );
    return _SyncHarness._(
      database: database,
      repository: repository,
      remote: remote,
      controller: controller,
      wakeups: wakeups,
      telemetry: telemetry,
      clock: clock,
    );
  }

  Future<void> close() async {
    controller.dispose();
    await database.close();
  }
}

final class _RecordingTelemetry implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map.unmodifiable(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

final class _MutableClock {
  _MutableClock(this.value);

  DateTime value;
}

final class _FakeWakeup implements LibrarySyncWakeup {
  _FakeWakeup(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool cancelled = false;

  void fire() {
    if (!cancelled) _callback();
  }

  @override
  void cancel() => cancelled = true;
}

final class _RetryThenSuccessRemote implements LibraryRemoteDataSource {
  _RetryThenSuccessRemote({required this.alwaysOffline});

  final bool alwaysOffline;
  int saveCalls = 0;

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) async {
    saveCalls += 1;
    if (alwaysOffline || saveCalls == 1) {
      throw const ApiException(
        code: 'NETWORK_UNAVAILABLE',
        message: 'Offline.',
        retryable: true,
        isOffline: true,
      );
    }
    return LibraryMutationResult(
      LibraryCanonicalItem(
        paperId: paperId,
        state: 'to_read',
        savedAt: DateTime.utc(2026, 7, 31, 12),
        updatedAt: DateTime.utc(2026, 7, 31, 12, 1),
        removed: false,
        removedAt: null,
        revision: 1,
        lastOperationId: operationId,
      ),
    );
  }

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async => LibraryChangesPage(
    items: const [],
    nextAfterRevision: afterRevision,
    hasMore: false,
    syncRevision: afterRevision,
  );

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) => throw UnimplementedError();

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => throw UnimplementedError();
}

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
