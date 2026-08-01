import 'dart:async';

/// Provider-neutral boundary for product telemetry.
///
/// Callers never receive a provider SDK and therefore cannot accidentally add
/// content-rich breadcrumbs outside this audited boundary.
abstract interface class TelemetrySink {
  Future<void> event(String name, Map<String, Object?> attributes);

  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  });
}

/// Production-safe default while no telemetry exporter is configured.
final class NoopTelemetrySink implements TelemetrySink {
  const NoopTelemetrySink();

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {}

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

/// The complete v0.0 event vocabulary.
///
/// Keeping names here makes an unreviewed analytics event fail closed rather
/// than silently increasing the app's data collection surface.
abstract final class PakPerkTelemetryEvent {
  static const appColdStart = 'app_cold_start';
  static const startupReady = 'startup_ready';
  static const startupFailure = 'startup_failure';
  static const shellDestinationSelected = 'shell_destination_selected';
  static const paperPageCommitted = 'paper_page_committed';
  static const paperStageCommitted = 'paper_stage_committed';
  static const nextPaperCacheHit = 'next_paper_cache_hit';
  static const nextPaperCacheMiss = 'next_paper_cache_miss';
  static const saveRequested = 'save_requested';
  static const saveSynced = 'save_synced';
  static const saveFailed = 'save_failed';
  static const authStarted = 'auth_started';
  static const authCompleted = 'auth_completed';
  static const authCancelled = 'auth_cancelled';
  static const commentSheetOpened = 'comment_sheet_opened';
  static const commentCreated = 'comment_created';
  static const commentPending = 'comment_pending';
  static const commentRejected = 'comment_rejected';
  static const commentReported = 'comment_reported';
  static const accountDeletionRequested = 'account_deletion_requested';
  static const accountDeletionAccepted = 'account_deletion_accepted';
  static const accountDeletionUnavailable = 'account_deletion_unavailable';
  static const accountDeletionLocalCleanupFailed =
      'account_deletion_local_cleanup_failed';
}

/// Audited event and attribute filter placed in front of every exporter.
///
/// Values are intentionally limited to small enums, booleans, bounded counts,
/// and durations. Paper IDs, account IDs, handles, search text, content,
/// request headers, tokens, and raw exception messages have no permitted key.
final class RedactingTelemetrySink implements TelemetrySink {
  RedactingTelemetrySink(this._delegate);

  final TelemetrySink _delegate;

  static const _environment = _StringEnumPolicy({
    'development',
    'staging',
    'production',
  });
  static const _launchMode = _StringEnumPolicy({'cold', 'warm', 'deepLink'});
  static const _failureCode = _StringEnumPolicy({
    'startup_timeout',
    'startup_local_failure',
    'local_write',
    'remote_sync',
    'unauthenticated',
    'token_expired',
    'paper_not_found',
    'rate_limited',
    'local_sync_unavailable',
    'library_sync_failed',
    'library_sync_reset_required',
    'invalid_library_mutation',
    'invalid_api_response',
    'network_timeout',
    'network_unavailable',
    'service_unavailable',
    'request_cancelled',
    'not_accepted',
    'local_cleanup',
  });
  static const _boolean = _BooleanPolicy();

  static const _eventAttributes = <String, Map<String, _AttributePolicy>>{
    PakPerkTelemetryEvent.appColdStart: {'environment': _environment},
    PakPerkTelemetryEvent.startupReady: {
      'environment': _environment,
      'launch_mode': _launchMode,
      'elapsed_ms': _IntegerRangePolicy(0, 86_400_000),
    },
    PakPerkTelemetryEvent.startupFailure: {
      'environment': _environment,
      'launch_mode': _launchMode,
      'failure_code': _failureCode,
      'timed_out': _boolean,
    },
    PakPerkTelemetryEvent.shellDestinationSelected: {
      'destination': _StringEnumPolicy({'read', 'you'}),
      'reselected': _boolean,
    },
    PakPerkTelemetryEvent.paperPageCommitted: {
      'source': _StringEnumPolicy({'read_feed'}),
      'position_bucket': _IntegerRangePolicy(0, 100),
    },
    PakPerkTelemetryEvent.paperStageCommitted: {
      'stage': _StringEnumPolicy({'abstract', 'introduction', 'connections'}),
    },
    PakPerkTelemetryEvent.nextPaperCacheHit: {
      'cache_tier': _StringEnumPolicy({'device'}),
    },
    PakPerkTelemetryEvent.nextPaperCacheMiss: {
      'cache_tier': _StringEnumPolicy({'device'}),
    },
    PakPerkTelemetryEvent.saveRequested: {
      'intent': _StringEnumPolicy({'save', 'remove'}),
    },
    PakPerkTelemetryEvent.saveSynced: {
      'intent': _StringEnumPolicy({'mutation'}),
    },
    PakPerkTelemetryEvent.saveFailed: {
      'intent': _StringEnumPolicy({'save', 'remove', 'mutation'}),
      'failure_code': _failureCode,
      'retryable': _boolean,
    },
    PakPerkTelemetryEvent.authStarted: {
      'purpose': _StringEnumPolicy({'session', 'account_deletion'}),
    },
    PakPerkTelemetryEvent.authCompleted: {
      'purpose': _StringEnumPolicy({'session', 'account_deletion'}),
    },
    PakPerkTelemetryEvent.authCancelled: {
      'purpose': _StringEnumPolicy({'session', 'account_deletion'}),
    },
    PakPerkTelemetryEvent.commentSheetOpened: {
      'viewer': _StringEnumPolicy({'authenticated', 'guest'}),
    },
    PakPerkTelemetryEvent.commentCreated: {
      'visibility': _StringEnumPolicy({'published'}),
    },
    PakPerkTelemetryEvent.commentPending: {
      'visibility': _StringEnumPolicy({'private_review'}),
    },
    PakPerkTelemetryEvent.commentRejected: {
      'failure_code': _StringEnumPolicy({'not_accepted'}),
      'retryable': _boolean,
    },
    PakPerkTelemetryEvent.commentReported: {
      'outcome': _StringEnumPolicy({'accepted'}),
    },
    PakPerkTelemetryEvent.accountDeletionRequested: {},
    PakPerkTelemetryEvent.accountDeletionAccepted: {
      'server_state': _StringEnumPolicy({
        'requested',
        'sessions_revoked',
        'identity_deleted',
        'app_data_deleted',
        'completed',
        'failed_retryable',
        'failed_terminal',
      }),
    },
    PakPerkTelemetryEvent.accountDeletionUnavailable: {'retryable': _boolean},
    PakPerkTelemetryEvent.accountDeletionLocalCleanupFailed: {
      'failure_code': _StringEnumPolicy({'local_cleanup'}),
    },
  };

  static const _errorContext = <String, _AttributePolicy>{
    'component': _StringEnumPolicy({'startup', 'application'}),
    'failure_code': _failureCode,
    'operation': _StringEnumPolicy({
      'local_bootstrap',
      'flutter_framework',
      'platform_dispatcher',
      'zone',
    }),
    'retryable': _boolean,
  };

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    final allowed = _eventAttributes[name];
    if (allowed == null) return;
    final safe = _sanitize(attributes, allowed);
    await _delegate.event(name, safe);
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {
    // The exporter gets only the runtime type. Exception strings routinely
    // contain URLs, provider responses, user text, or credentials.
    final safeError = classifyError(error);
    await _delegate.error(
      safeError,
      StackTrace.empty,
      context: _sanitize(context, _errorContext),
    );
  }

  Map<String, Object> _sanitize(
    Map<String, Object?> values,
    Map<String, _AttributePolicy> policies,
  ) {
    final result = <String, Object>{};
    for (final entry in values.entries) {
      final policy = policies[entry.key];
      if (policy == null) continue;
      final safeValue = policy.sanitize(entry.value);
      if (safeValue != null) result[entry.key] = safeValue;
    }
    return Map.unmodifiable(result);
  }

  /// Returns the only error object that may cross a Pakperk telemetry or
  /// delegated diagnostic boundary. It contains no exception message, stack,
  /// URL, content, identifier, or credential.
  static TelemetryErrorCategory classifyError(Object error) =>
      TelemetryErrorCategory(switch (error) {
        TimeoutException _ => 'timeout',
        FormatException _ => 'format',
        StateError _ => 'state',
        ArgumentError _ => 'argument',
        TelemetryErrorCategory(:final category)
            when const {
              'timeout',
              'format',
              'state',
              'argument',
              'unexpected',
            }.contains(category) =>
          category,
        _ => 'unexpected',
      });
}

sealed class _AttributePolicy {
  const _AttributePolicy();

  Object? sanitize(Object? value);
}

final class _StringEnumPolicy extends _AttributePolicy {
  const _StringEnumPolicy(this.allowed);

  final Set<String> allowed;

  @override
  Object? sanitize(Object? value) =>
      value is String && allowed.contains(value) ? value : null;
}

final class _BooleanPolicy extends _AttributePolicy {
  const _BooleanPolicy();

  @override
  Object? sanitize(Object? value) => value is bool ? value : null;
}

final class _IntegerRangePolicy extends _AttributePolicy {
  const _IntegerRangePolicy(this.minimum, this.maximum);

  final int minimum;
  final int maximum;

  @override
  Object? sanitize(Object? value) =>
      value is int && value >= minimum && value <= maximum ? value : null;
}

/// Content-free error handed to an exporter instead of the original object.
final class TelemetryErrorCategory implements Exception {
  const TelemetryErrorCategory(this.category);

  final String category;

  @override
  String toString() => 'TelemetryErrorCategory($category)';
}

/// Fire-and-forget helper that prevents an analytics provider from affecting
/// product behavior.
void emitTelemetry(
  TelemetrySink sink,
  String name, [
  Map<String, Object?> attributes = const {},
]) {
  unawaited(sink.event(name, attributes).catchError((Object _) {}));
}
