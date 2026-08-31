import '../api/api_exception.dart';
import '../library/library_models.dart';
import '../library/library_repository.dart';
import '../telemetry/telemetry.dart';
import 'retry_policy.dart';

typedef OutboxClock = DateTime Function();
typedef FinalCompletionAcknowledged =
    void Function({
      required String accountId,
      required int authEpoch,
      required DateTime acknowledgedAt,
    });

final class OutboxDrainResult {
  const OutboxDrainResult({
    required this.pendingCount,
    required this.nextAttemptAt,
    required this.scopeChanged,
    this.issue,
  });

  final int pendingCount;
  final DateTime? nextAttemptAt;
  final bool scopeChanged;
  final LibrarySyncIssue? issue;
}

final class LibraryOutboxController {
  LibraryOutboxController({
    required LibraryRepository repository,
    OutboxRetryPolicy? retryPolicy,
    OutboxClock? clock,
    TelemetrySink telemetry = const NoopTelemetrySink(),
    FinalCompletionAcknowledged? onFinalCompletionAcknowledged,
  }) : _repository = repository,
       _retryPolicy = retryPolicy ?? OutboxRetryPolicy(),
       _clock = clock ?? DateTime.now,
       _telemetry = telemetry,
       _onFinalCompletionAcknowledged = onFinalCompletionAcknowledged;

  final LibraryRepository _repository;
  final OutboxRetryPolicy _retryPolicy;
  final OutboxClock _clock;
  final TelemetrySink _telemetry;
  final FinalCompletionAcknowledged? _onFinalCompletionAcknowledged;
  final Map<_OutboxScope, Future<OutboxDrainResult>> _flights = {};

  Future<OutboxDrainResult> drain({
    required String accountId,
    required int authEpoch,
  }) {
    final scope = _OutboxScope(accountId, authEpoch);
    final active = _flights[scope];
    if (active != null) return active;
    late final Future<OutboxDrainResult> operation;
    operation = _drain(accountId: accountId, authEpoch: authEpoch).whenComplete(
      () {
        if (identical(_flights[scope], operation)) _flights.remove(scope);
      },
    );
    _flights[scope] = operation;
    return operation;
  }

  Future<OutboxDrainResult> _drain({
    required String accountId,
    required int authEpoch,
  }) async {
    final guard = _repository.remoteScopeGuard(
      accountId: accountId,
      authEpoch: authEpoch,
    );
    // A finite pass prevents a producer that continuously enqueues work from
    // monopolizing the event loop. The next lifecycle/network/manual trigger
    // resumes the durable queue.
    for (var processed = 0; processed < 100; processed += 1) {
      if (!guard()) return _scopeChanged(accountId);
      final operation = await _repository.claimNextDue(
        accountId: accountId,
        now: _clock().toUtc(),
      );
      if (operation == null) break;
      if (!guard()) return _scopeChanged(accountId);
      try {
        await _repository.upload(
          operation: operation,
          authEpoch: authEpoch,
          scopeGuard: guard,
        );
        if (guard() && operation.removesFromActiveQueue) {
          await _recordFinalCompletionIfApplicable(
            operation: operation,
            authEpoch: authEpoch,
            scopeGuard: guard,
          );
        }
      } on ApiException catch (error) {
        if (!guard()) return _scopeChanged(accountId);
        if (error.statusCode == 409) {
          emitTelemetry(
            _telemetry,
            PakPerkTelemetryEvent.librarySyncConflict,
            const {'boundary': 'remote_operation'},
          );
        }
        if (_retryPolicy.shouldRetry(error)) {
          final delay = _retryPolicy.delayFor(
            completedAttempts: operation.attemptCount,
            retryAfter: error.retryAfter,
          );
          await _repository.retryLater(
            operation: operation,
            error: error,
            nextAttemptAt: _clock().toUtc().add(delay),
            scopeGuard: guard,
          );
        } else {
          await _repository.failPermanently(
            operation: operation,
            error: error,
            scopeGuard: guard,
          );
        }
      } on Object {
        if (!guard()) return _scopeChanged(accountId);
        const error = ApiException(
          code: 'LOCAL_SYNC_UNAVAILABLE',
          message: 'The local library queue is temporarily unavailable.',
          retryable: true,
        );
        final delay = _retryPolicy.delayFor(
          completedAttempts: operation.attemptCount,
        );
        await _repository.retryLater(
          operation: operation,
          error: error,
          nextAttemptAt: _clock().toUtc().add(delay),
          scopeGuard: guard,
        );
      }
    }
    if (!guard()) return _scopeChanged(accountId);
    return OutboxDrainResult(
      pendingCount: await _repository.pendingCount(accountId),
      nextAttemptAt: await _repository.nextAttemptAt(accountId),
      scopeChanged: false,
      issue: await _repository.latestSyncIssue(accountId),
    );
  }

  Future<void> _recordFinalCompletionIfApplicable({
    required LibraryPendingOperation operation,
    required int authEpoch,
    required bool Function() scopeGuard,
  }) async {
    try {
      final pending = await _repository.pendingIntents(operation.accountId);
      if (!scopeGuard() || pending.removes != 0) return;
      final activeCount = await _repository.activeToReadCount(
        operation.accountId,
      );
      if (!scopeGuard() || activeCount != 0) return;
      _onFinalCompletionAcknowledged?.call(
        accountId: operation.accountId,
        authEpoch: authEpoch,
        acknowledgedAt: _clock().toUtc(),
      );
    } on Object {
      // This best-effort operational signal cannot change outbox convergence.
    }
  }

  Future<OutboxDrainResult> _scopeChanged(String accountId) async =>
      OutboxDrainResult(
        pendingCount: await _repository.pendingCount(accountId),
        nextAttemptAt: await _repository.nextAttemptAt(accountId),
        scopeChanged: true,
      );
}

final class _OutboxScope {
  const _OutboxScope(this.accountId, this.authEpoch);

  final String accountId;
  final int authEpoch;

  @override
  bool operator ==(Object other) =>
      other is _OutboxScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch;

  @override
  int get hashCode => Object.hash(accountId, authEpoch);
}
