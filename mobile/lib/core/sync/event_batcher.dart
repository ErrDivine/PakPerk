import 'dart:async';

import 'package:uuid/uuid.dart';

import '../api/api_exception.dart';
import '../interactions/interaction_api.dart';
import '../interactions/interaction_models.dart';

typedef InteractionClock = DateTime Function();
typedef InteractionEventIdFactory = String Function();
typedef InteractionRetryDelay = Future<void> Function(Duration duration);

/// In-memory, best-effort interaction delivery.
///
/// This queue is intentionally non-authoritative and non-durable. Scope
/// changes erase it synchronously, failures never affect product state, and
/// event payloads contain only the closed content-free interaction schema.
final class InteractionEventBatcher {
  InteractionEventBatcher({
    required InteractionRemoteDataSource remote,
    InteractionClock? clock,
    InteractionEventIdFactory? eventId,
    InteractionRetryDelay? delay,
    this.maximumBufferedEvents = 200,
    this.maximumAttempts = 3,
  }) : assert(maximumBufferedEvents >= 50),
       assert(maximumAttempts >= 1 && maximumAttempts <= 5),
       _remote = remote,
       _clock = clock ?? DateTime.now,
       _eventId = eventId ?? const Uuid().v7,
       _delay = delay ?? ((duration) => Future<void>.delayed(duration));

  final InteractionRemoteDataSource _remote;
  final InteractionClock _clock;
  final InteractionEventIdFactory _eventId;
  final InteractionRetryDelay _delay;
  final int maximumBufferedEvents;
  final int maximumAttempts;
  final List<PaperInteractionEvent> _pending = [];

  InteractionScope? _scope;
  bool _behavioralCollectionEnabled = false;
  int _generation = 0;
  Future<void>? _drain;
  bool _disposed = false;

  int get pendingCount => _pending.length;

  void updateConfiguration({
    required InteractionScope? scope,
    required bool behavioralCollectionEnabled,
  }) {
    if (_disposed) return;
    if (_scope != scope) {
      _generation += 1;
      _pending.clear();
      _scope = scope;
    }
    if (_behavioralCollectionEnabled != behavioralCollectionEnabled) {
      _generation += 1;
    }
    _behavioralCollectionEnabled = behavioralCollectionEnabled;
    if (!behavioralCollectionEnabled) {
      if (scope is AnonymousInteractionScope) {
        // This release has no essential anonymous event type and no guest
        // analytics consent surface, so a disabled anonymous scope retains
        // and sends nothing.
        _pending.clear();
      } else {
        _pending.removeWhere((event) => event.eventType.isBehavioral);
      }
    }
  }

  bool record({
    required PaperInteractionEventType eventType,
    required String paperId,
    InteractionFeedMode? feedMode,
    String? batchId,
    int? position,
  }) {
    final scope = _scope;
    if (_disposed ||
        scope == null ||
        (scope is AnonymousInteractionScope && !_behavioralCollectionEnabled) ||
        (eventType.isBehavioral && !_behavioralCollectionEnabled)) {
      return false;
    }
    try {
      final event = PaperInteractionEvent(
        eventId: _eventId().toLowerCase(),
        eventType: eventType,
        paperId: paperId,
        feedMode: feedMode,
        batchId: batchId,
        position: position,
        occurredAt: _clock().toUtc(),
      );
      validateInteractionBatch(scope, [event]);
      if (_pending.length == maximumBufferedEvents) {
        _pending.removeAt(0);
      }
      _pending.add(event);
    } on ArgumentError {
      return false;
    }
    unawaited(flush());
    return true;
  }

  Future<void> flush() {
    if (_disposed || _scope == null || _pending.isEmpty) {
      return Future.value();
    }
    final current = _drain;
    if (current != null) return current;
    late final Future<void> flight;
    flight = _runDrain().whenComplete(() {
      if (identical(_drain, flight)) _drain = null;
      if (!_disposed && _scope != null && _pending.isNotEmpty) {
        scheduleMicrotask(() => unawaited(flush()));
      }
    });
    _drain = flight;
    return flight;
  }

  Future<void> _runDrain() async {
    while (!_disposed && _scope != null && _pending.isNotEmpty) {
      final scope = _scope!;
      final generation = _generation;
      final batch = List<PaperInteractionEvent>.unmodifiable(_pending.take(50));
      var delivered = false;
      for (var attempt = 1; attempt <= maximumAttempts; attempt += 1) {
        if (!_isCurrent(scope, generation)) return;
        try {
          await _remote.sendBatch(scope: scope, events: batch);
          delivered = true;
          break;
        } on ApiException catch (error) {
          final terminal = error.code == 'FEATURE_DISABLED' || !error.retryable;
          if (terminal || attempt == maximumAttempts) break;
          await _delay(error.retryAfter ?? _retryDelay(attempt));
        } on Object {
          // Unknown client failures are terminal for this non-authoritative
          // batch. They must not spin or affect the reading experience.
          break;
        }
      }
      if (!_isCurrent(scope, generation)) return;
      final ids = batch.map((event) => event.eventId).toSet();
      _pending.removeWhere((event) => ids.contains(event.eventId));
      if (!delivered) {
        // Bounded best-effort delivery intentionally drops terminal/exhausted
        // batches. No caller observes delivery as product authority.
      }
    }
  }

  bool _isCurrent(InteractionScope scope, int generation) =>
      !_disposed && _scope == scope && _generation == generation;

  Duration _retryDelay(int attempt) => Duration(milliseconds: 250 * attempt);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _scope = null;
    _pending.clear();
  }
}
