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
  static const feedPrefetchRequested = 'feed_prefetch_requested';
  static const feedPrefetchSucceeded = 'feed_prefetch_succeeded';
  static const feedPrefetchFailed = 'feed_prefetch_failed';
  static const feedPrefetchDeduplicated = 'feed_prefetch_deduplicated';
  static const nextPaperCacheHit = 'next_paper_cache_hit';
  static const nextPaperCacheMiss = 'next_paper_cache_miss';
  static const feedBlankCard = 'feed_blank_card';
  static const feedCacheRows = 'feed_cache_rows';
  static const feedCacheBytes = 'feed_cache_bytes';
  static const feedTimeToReadable = 'feed_time_to_readable_ms';
  static const readingFeedShadowDecision = 'reading_feed_shadow_decision';
  static const recommendationCardRendered = 'recommendation_card_rendered';
  static const recommendationPublicationRejected =
      'recommendation_publication_rejected';
  static const pendingIntentAge = 'pending_intent_age';
  static const discoverySuppressionLatency = 'discovery_suppression_latency';
  static const discoveryUnlockLatency = 'discovery_unlock_latency';
  static const saveRequested = 'save_requested';
  static const saveSynced = 'save_synced';
  static const saveFailed = 'save_failed';
  static const libraryOutboxBacklog = 'library_outbox_backlog';
  static const librarySyncConflict = 'library_sync_conflict';
  static const authStarted = 'auth_started';
  static const authCompleted = 'auth_completed';
  static const authCancelled = 'auth_cancelled';
  static const commentSheetOpened = 'comment_sheet_opened';
  static const commentCreated = 'comment_created';
  static const commentPending = 'comment_pending';
  static const commentRejected = 'comment_rejected';
  static const commentReported = 'comment_reported';
  static const userReported = 'user_reported';
  static const accountDeletionRequested = 'account_deletion_requested';
  static const accountDeletionAccepted = 'account_deletion_accepted';
  static const accountDeletionUnavailable = 'account_deletion_unavailable';
  static const accountDeletionLocalCleanupFailed =
      'account_deletion_local_cleanup_failed';
  static const httpRequestCompleted = 'http_request_completed';
  static const readerEntryContext = 'reader_entry_context';
  static const queueAutoAdvance = 'queue_auto_advance';
  static const queueStaleCursorRecovery = 'queue_stale_cursor_recovery';
  static const recommendationAdvanceCancelledAfterSave =
      'recommendation_advance_cancelled_after_save';
  static const endOfDocumentLibraryMutation =
      'end_of_document_library_mutation';
  static const finalItemCheckingDuration = 'final_item_checking_duration';
  static const documentCacheLookup = 'document_cache_lookup';
  static const documentCacheEviction = 'document_cache_eviction';
  static const documentCacheSize = 'document_cache_size';
  static const annotationSyncOutcome = 'annotation_sync_outcome';
  static const memoryLifecycle = 'memory_lifecycle';
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
  static const _durationBucket = _StringEnumPolicy({
    'none',
    'unknown',
    'lt_100ms',
    '100ms_1s',
    '1s_5s',
    '5s_30s',
    '30s_2m',
    '2m_15m',
    '15m_1h',
    '1h_6h',
    '6h_24h',
    'gte_24h',
  });

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
      'destination': _StringEnumPolicy({'read', 'library', 'you'}),
      'reselected': _boolean,
    },
    PakPerkTelemetryEvent.paperPageCommitted: {
      'source': _StringEnumPolicy({
        'to_read',
        'reading_recommendations',
        'public_discovery',
      }),
      'position_bucket': _IntegerRangePolicy(0, 100),
    },
    PakPerkTelemetryEvent.paperStageCommitted: {
      'stage': _StringEnumPolicy({'abstract', 'introduction', 'connections'}),
    },
    PakPerkTelemetryEvent.feedPrefetchRequested: {},
    PakPerkTelemetryEvent.feedPrefetchSucceeded: {},
    PakPerkTelemetryEvent.feedPrefetchFailed: {},
    PakPerkTelemetryEvent.feedPrefetchDeduplicated: {},
    PakPerkTelemetryEvent.nextPaperCacheHit: {
      'cache_tier': _StringEnumPolicy({'device'}),
    },
    PakPerkTelemetryEvent.nextPaperCacheMiss: {
      'cache_tier': _StringEnumPolicy({'device'}),
    },
    PakPerkTelemetryEvent.feedBlankCard: {},
    PakPerkTelemetryEvent.feedCacheRows: {
      'rows': _IntegerRangePolicy(0, 100000),
    },
    PakPerkTelemetryEvent.feedCacheBytes: {
      'bytes': _IntegerRangePolicy(0, 1073741824),
    },
    PakPerkTelemetryEvent.feedTimeToReadable: {
      'elapsed_ms': _IntegerRangePolicy(0, 86_400_000),
    },
    PakPerkTelemetryEvent.readingFeedShadowDecision: {
      'shadow_decision': _StringEnumPolicy({
        'checking_queue',
        'finishing_queue',
        'to_read',
        'recommendations',
        'fail_closed',
      }),
      'queue_authority': _StringEnumPolicy({
        'unknown',
        'local_non_empty',
        'pending_save',
        'server_non_empty',
        'server_empty',
        'stale',
      }),
      'legacy_decision': _StringEnumPolicy({'public_discovery'}),
      'server_policy': _StringEnumPolicy({'unknown', 'shadow', 'strict'}),
      'queue_policy_agrees': _boolean,
      'offline': _boolean,
    },
    PakPerkTelemetryEvent.recommendationCardRendered: {
      'queue_authority': _StringEnumPolicy({
        'unknown',
        'local_non_empty',
        'pending_save',
        'server_non_empty',
        'server_empty',
        'stale',
      }),
      'server_active_count': _StringEnumPolicy({'zero', 'nonzero', 'unknown'}),
      'policy_consistent': _boolean,
    },
    PakPerkTelemetryEvent.recommendationPublicationRejected: {
      'reason': _StringEnumPolicy({
        'local_queue_non_empty',
        'pending_save',
        'pending_import',
        'pending_remove',
        'sync_reset',
        'revision_stale',
        'server_queue_not_empty',
        'personalization_off',
        'personalization_unknown',
      }),
    },
    PakPerkTelemetryEvent.pendingIntentAge: {
      'intent_kind': _StringEnumPolicy({'save', 'import'}),
      'age_bucket': _durationBucket,
    },
    PakPerkTelemetryEvent.discoverySuppressionLatency: {
      'trigger': _StringEnumPolicy({'save'}),
      'latency_bucket': _durationBucket,
    },
    PakPerkTelemetryEvent.discoveryUnlockLatency: {
      'trigger': _StringEnumPolicy({'final_completion'}),
      'latency_bucket': _durationBucket,
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
    PakPerkTelemetryEvent.libraryOutboxBacklog: {
      'pending_count': _IntegerRangePolicy(0, 100000),
      'oldest_age_bucket': _durationBucket,
    },
    PakPerkTelemetryEvent.librarySyncConflict: {
      'boundary': _StringEnumPolicy({'local_revision', 'remote_operation'}),
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
    PakPerkTelemetryEvent.userReported: {
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
    PakPerkTelemetryEvent.httpRequestCompleted: {
      'method_class': _StringEnumPolicy({'read', 'write', 'delete', 'other'}),
      'route_class': _StringEnumPolicy({
        'health',
        'feed',
        'paper',
        'paper_prepare',
        'paper_chat',
        'account',
        'account_deletion',
        'library',
        'reading_feed',
        'search',
        'profile',
        'recommendations',
        'engagement',
        'events',
        'comments',
        'moderation',
        'unknown',
      }),
      'outcome': _StringEnumPolicy({
        'success',
        'cancelled',
        'timeout',
        'unavailable',
        'client_error',
        'server_error',
        'http_error',
        'transport_error',
      }),
      'status_family': _StringEnumPolicy({
        'none',
        '1xx',
        '2xx',
        '3xx',
        '4xx',
        '5xx',
      }),
      'elapsed_ms': _IntegerRangePolicy(0, 86_400_000),
      'retry_count': _IntegerRangePolicy(0, 1),
    },
    PakPerkTelemetryEvent.readerEntryContext: {
      'source': _StringEnumPolicy({
        'queue',
        'recommendation',
        'library',
        'search',
        'connection',
        'memory',
        'public_discovery',
        'external',
      }),
      'queue_membership': _StringEnumPolicy({
        'in_to_read',
        'outside_to_read',
        'unknown',
      }),
    },
    PakPerkTelemetryEvent.queueAutoAdvance: {
      'outcome': _StringEnumPolicy({
        'succeeded',
        'page_requested',
        'checking',
        'natural_stop',
        'offline_unknown',
        'blocked',
        'fail_closed',
      }),
      'offline': _boolean,
    },
    PakPerkTelemetryEvent.queueStaleCursorRecovery: {
      'outcome': _StringEnumPolicy({'restart_requested'}),
      'surface': _StringEnumPolicy({'queue', 'recommendations'}),
      'offline': _boolean,
    },
    PakPerkTelemetryEvent.recommendationAdvanceCancelledAfterSave: {
      'outcome': _StringEnumPolicy({'cancelled'}),
      'local_intent': _boolean,
    },
    PakPerkTelemetryEvent.endOfDocumentLibraryMutation: {
      'mutation_attempted': _boolean,
      'explicit_user_action': _boolean,
    },
    PakPerkTelemetryEvent.finalItemCheckingDuration: {
      'duration_bucket': _durationBucket,
      'outcome': _StringEnumPolicy({
        'recommendations',
        'queue_active',
        'offline_unknown',
        'unavailable',
        'account_changed',
      }),
    },
    PakPerkTelemetryEvent.documentCacheLookup: {
      'outcome': _StringEnumPolicy({'hit', 'miss'}),
      'offline': _boolean,
    },
    PakPerkTelemetryEvent.documentCacheEviction: {
      'reason': _StringEnumPolicy({
        'expired',
        'invalid',
        'lru',
        'account_cleanup',
      }),
      'count': _IntegerRangePolicy(0, 100000),
    },
    PakPerkTelemetryEvent.documentCacheSize: {
      'bytes': _IntegerRangePolicy(0, 1073741824),
    },
    PakPerkTelemetryEvent.annotationSyncOutcome: {
      'action': _StringEnumPolicy({
        'create',
        'update',
        'reanchor',
        'manual_reattach',
        'refresh',
      }),
      'outcome': _StringEnumPolicy({
        'requested',
        'anchored',
        'uncertain',
        'orphaned',
        'conflict',
      }),
      'strategy': _StringEnumPolicy({
        'exact_quote',
        'quote_context',
        'server',
        'manual',
        'not_applicable',
      }),
      'offline': _boolean,
      'count': _IntegerRangePolicy(0, 100000),
    },
    PakPerkTelemetryEvent.memoryLifecycle: {
      'action': _StringEnumPolicy({'create', 'review', 'snooze', 'retire'}),
      'source_type': _StringEnumPolicy({
        'annotation',
        'evidence_card',
        'passport_field',
        'user_question',
      }),
      'offline': _boolean,
    },
  };

  static const _requiredEventAttributes = <String, Set<String>>{
    PakPerkTelemetryEvent.shellDestinationSelected: {
      'destination',
      'reselected',
    },
    PakPerkTelemetryEvent.paperPageCommitted: {'source', 'position_bucket'},
    PakPerkTelemetryEvent.readingFeedShadowDecision: {
      'shadow_decision',
      'queue_authority',
      'legacy_decision',
      'server_policy',
      'queue_policy_agrees',
      'offline',
    },
    PakPerkTelemetryEvent.recommendationCardRendered: {
      'queue_authority',
      'server_active_count',
      'policy_consistent',
    },
    PakPerkTelemetryEvent.recommendationPublicationRejected: {'reason'},
    PakPerkTelemetryEvent.pendingIntentAge: {'intent_kind', 'age_bucket'},
    PakPerkTelemetryEvent.discoverySuppressionLatency: {
      'trigger',
      'latency_bucket',
    },
    PakPerkTelemetryEvent.discoveryUnlockLatency: {'trigger', 'latency_bucket'},
    PakPerkTelemetryEvent.libraryOutboxBacklog: {
      'pending_count',
      'oldest_age_bucket',
    },
    PakPerkTelemetryEvent.librarySyncConflict: {'boundary'},
    PakPerkTelemetryEvent.httpRequestCompleted: {
      'method_class',
      'route_class',
      'outcome',
      'status_family',
      'elapsed_ms',
      'retry_count',
    },
    PakPerkTelemetryEvent.readerEntryContext: {'source', 'queue_membership'},
    PakPerkTelemetryEvent.queueAutoAdvance: {'outcome', 'offline'},
    PakPerkTelemetryEvent.queueStaleCursorRecovery: {
      'outcome',
      'surface',
      'offline',
    },
    PakPerkTelemetryEvent.recommendationAdvanceCancelledAfterSave: {
      'outcome',
      'local_intent',
    },
    PakPerkTelemetryEvent.endOfDocumentLibraryMutation: {
      'mutation_attempted',
      'explicit_user_action',
    },
    PakPerkTelemetryEvent.finalItemCheckingDuration: {
      'duration_bucket',
      'outcome',
    },
    PakPerkTelemetryEvent.documentCacheLookup: {'outcome', 'offline'},
    PakPerkTelemetryEvent.documentCacheEviction: {'reason', 'count'},
    PakPerkTelemetryEvent.documentCacheSize: {'bytes'},
    PakPerkTelemetryEvent.annotationSyncOutcome: {
      'action',
      'outcome',
      'strategy',
      'offline',
    },
    PakPerkTelemetryEvent.memoryLifecycle: {'action', 'source_type', 'offline'},
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
    final required = _requiredEventAttributes[name];
    if (required != null && !required.every(safe.containsKey)) return;
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
  factory TelemetryErrorCategory(String category) => TelemetryErrorCategory._(
    _allowed.contains(category) ? category : 'unexpected',
  );

  const TelemetryErrorCategory._(this.category);

  static const _allowed = {
    'timeout',
    'format',
    'state',
    'argument',
    'unexpected',
  };

  final String category;

  @override
  String toString() => 'TelemetryErrorCategory($category)';
}

/// Converts an internal monotonic or wall-clock duration into the only age and
/// latency vocabulary accepted by the mobile telemetry boundary.
///
/// Callers keep timestamps in account-scoped memory or storage; only this
/// coarse category may leave the device. Negative clock skew is clamped to the
/// smallest bucket instead of exporting either timestamp.
String telemetryDurationBucket(Duration? duration, {bool none = false}) {
  if (none) return 'none';
  if (duration == null) return 'unknown';
  final value = duration.isNegative ? Duration.zero : duration;
  if (value < const Duration(milliseconds: 100)) return 'lt_100ms';
  if (value < const Duration(seconds: 1)) return '100ms_1s';
  if (value < const Duration(seconds: 5)) return '1s_5s';
  if (value < const Duration(seconds: 30)) return '5s_30s';
  if (value < const Duration(minutes: 2)) return '30s_2m';
  if (value < const Duration(minutes: 15)) return '2m_15m';
  if (value < const Duration(hours: 1)) return '15m_1h';
  if (value < const Duration(hours: 6)) return '1h_6h';
  if (value < const Duration(hours: 24)) return '6h_24h';
  return 'gte_24h';
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
