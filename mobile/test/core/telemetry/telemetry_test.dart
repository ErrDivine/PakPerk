import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/telemetry/otlp_http_telemetry_sink.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/feed/feed_prefetch_telemetry.dart';

void main() {
  test('error category constructor rejects arbitrary content', () {
    const sentinel = 'Bearer token reader@example.test';
    final category = TelemetryErrorCategory(sentinel);

    expect(category.category, 'unexpected');
    expect(category.toString(), isNot(contains(sentinel)));
  });

  group('RedactingTelemetrySink', () {
    test('unknown events never reach the exporter', () async {
      final delegate = _RecordingSink();
      final sink = RedactingTelemetrySink(delegate);

      await sink.event('unreviewed_event', const {'value': 'hello'});

      expect(delegate.events, isEmpty);
    });

    test('uses exact per-event keys and enum values', () async {
      final delegate = _RecordingSink();
      final sink = RedactingTelemetrySink(delegate);

      await sink.event(PakPerkTelemetryEvent.saveFailed, const {
        'intent': 'save',
        'failure_code': 'hello',
        'retryable': true,
        'paper_id': '00000000-0000-4000-8000-000000000001',
        'handle': 'reader',
        'content': 'private abstract',
        'email': 'reader@example.test',
        'authorization': 'Bearer secret-token',
      });
      await sink.event(PakPerkTelemetryEvent.saveFailed, const {
        'intent': 'mutation',
        'failure_code': 'local_write',
        'retryable': false,
      });
      await sink.event(PakPerkTelemetryEvent.shellDestinationSelected, const {
        'destination': 'abstract',
        'reselected': false,
      });
      await sink.event(PakPerkTelemetryEvent.userReported, const {
        'outcome': 'accepted',
        'user_id': '00000000-0000-4000-8000-000000000001',
        'detail': 'private report context',
      });

      expect(delegate.events, [
        const _RecordedEvent(PakPerkTelemetryEvent.saveFailed, {
          'intent': 'save',
          'retryable': true,
        }),
        const _RecordedEvent(PakPerkTelemetryEvent.saveFailed, {
          'intent': 'mutation',
          'failure_code': 'local_write',
          'retryable': false,
        }),
        const _RecordedEvent(PakPerkTelemetryEvent.userReported, {
          'outcome': 'accepted',
        }),
      ]);
    });

    test('keeps Plan 02 navigation and feed-source labels in sync', () async {
      final delegate = _RecordingSink();
      final sink = RedactingTelemetrySink(delegate);

      for (final destination in const ['read', 'library', 'you']) {
        await sink.event(PakPerkTelemetryEvent.shellDestinationSelected, {
          'destination': destination,
          'reselected': false,
        });
      }
      for (final source in const [
        'to_read',
        'reading_recommendations',
        'public_discovery',
      ]) {
        await sink.event(PakPerkTelemetryEvent.paperPageCommitted, {
          'source': source,
          'position_bucket': 0,
        });
      }
      await sink.event(PakPerkTelemetryEvent.paperPageCommitted, const {
        'source': 'read_feed',
        'position_bucket': 0,
      });

      expect(delegate.events, hasLength(6));
      expect(
        delegate.events.map((event) => event.attributes.values.first),
        containsAll(const [
          'read',
          'library',
          'you',
          'to_read',
          'reading_recommendations',
          'public_discovery',
        ]),
      );
    });

    test('accepts only bounded values from the audited vocabulary', () async {
      final delegate = _RecordingSink();
      final sink = RedactingTelemetrySink(delegate);

      await sink.event(PakPerkTelemetryEvent.startupReady, const {
        'environment': 'production',
        'launch_mode': 'deepLink',
        'elapsed_ms': 1200,
      });
      await sink.event(PakPerkTelemetryEvent.paperPageCommitted, const {
        'source': 'to_read',
        'position_bucket': 100,
      });
      await sink.event(PakPerkTelemetryEvent.readingFeedShadowDecision, const {
        'shadow_decision': 'to_read',
        'queue_authority': 'local_non_empty',
        'legacy_decision': 'public_discovery',
        'server_policy': 'shadow',
        'queue_policy_agrees': false,
        'offline': false,
        'account_id': '00000000-0000-4000-8000-000000000001',
        'paper_title': 'Private paper title',
      });
      await sink.event(PakPerkTelemetryEvent.recommendationCardRendered, const {
        'queue_authority': 'server_empty',
        'server_active_count': 'zero',
        'policy_consistent': true,
        'batch_id': '00000000-0000-4000-8000-000000000001',
        'paper_id': '00000000-0000-4000-8000-000000000002',
      });

      expect(delegate.events.first.attributes, const {
        'environment': 'production',
        'launch_mode': 'deepLink',
        'elapsed_ms': 1200,
      });
      expect(delegate.events[1].attributes, const {
        'source': 'to_read',
        'position_bucket': 100,
      });
      expect(delegate.events.last.attributes, const {
        'queue_authority': 'server_empty',
        'server_active_count': 'zero',
        'policy_consistent': true,
      });
      expect(delegate.events[2].attributes, const {
        'shadow_decision': 'to_read',
        'queue_authority': 'local_non_empty',
        'legacy_decision': 'public_discovery',
        'server_policy': 'shadow',
        'queue_policy_agrees': false,
        'offline': false,
      });
    });

    test('Plan 02 policy telemetry keeps only closed bounded fields', () async {
      final delegate = _RecordingSink();
      final sink = RedactingTelemetrySink(delegate);

      await sink.event(
        PakPerkTelemetryEvent.recommendationPublicationRejected,
        const {
          'reason': 'pending_import',
          'paper_id': '00000000-0000-4000-8000-000000000001',
        },
      );
      await sink.event(PakPerkTelemetryEvent.pendingIntentAge, const {
        'intent_kind': 'import',
        'age_bucket': '15m_1h',
        'created_at': '2026-08-28T00:00:00Z',
      });
      await sink.event(
        PakPerkTelemetryEvent.discoverySuppressionLatency,
        const {'trigger': 'save', 'latency_bucket': 'lt_100ms'},
      );
      await sink.event(PakPerkTelemetryEvent.discoveryUnlockLatency, const {
        'trigger': 'final_completion',
        'latency_bucket': '1s_5s',
        'account_id': '00000000-0000-4000-8000-000000000001',
      });
      await sink.event(PakPerkTelemetryEvent.libraryOutboxBacklog, const {
        'pending_count': 2,
        'oldest_age_bucket': '2m_15m',
        'oldest_created_at': '2026-08-28T00:00:00Z',
      });
      await sink.event(PakPerkTelemetryEvent.librarySyncConflict, const {
        'boundary': 'local_revision',
        'operation_id': '00000000-0000-4000-8000-000000000002',
      });

      expect(delegate.events, const [
        _RecordedEvent(
          PakPerkTelemetryEvent.recommendationPublicationRejected,
          {'reason': 'pending_import'},
        ),
        _RecordedEvent(PakPerkTelemetryEvent.pendingIntentAge, {
          'intent_kind': 'import',
          'age_bucket': '15m_1h',
        }),
        _RecordedEvent(PakPerkTelemetryEvent.discoverySuppressionLatency, {
          'trigger': 'save',
          'latency_bucket': 'lt_100ms',
        }),
        _RecordedEvent(PakPerkTelemetryEvent.discoveryUnlockLatency, {
          'trigger': 'final_completion',
          'latency_bucket': '1s_5s',
        }),
        _RecordedEvent(PakPerkTelemetryEvent.libraryOutboxBacklog, {
          'pending_count': 2,
          'oldest_age_bucket': '2m_15m',
        }),
        _RecordedEvent(PakPerkTelemetryEvent.librarySyncConflict, {
          'boundary': 'local_revision',
        }),
      ]);
    });

    test(
      'Plan 03 telemetry rejects notes, source text, and account identifiers',
      () async {
        final delegate = _RecordingSink();
        final sink = RedactingTelemetrySink(delegate);
        const privateNote = 'private note about a sensitive result';
        const sourceText = 'verbatim selected paper text';
        const privateAccount = '00000000-0000-4000-8000-000000000001';

        await sink.event(PakPerkTelemetryEvent.annotationSyncOutcome, const {
          'action': 'reanchor',
          'outcome': 'orphaned',
          'strategy': 'server',
          'offline': false,
          'note': privateNote,
          'text': sourceText,
          'account_id': privateAccount,
        });
        await sink.event(PakPerkTelemetryEvent.memoryLifecycle, const {
          'action': 'create',
          'source_type': 'annotation',
          'offline': true,
          'prompt_text': privateNote,
          'answer_text': sourceText,
          'account_id': privateAccount,
        });
        await sink.event(PakPerkTelemetryEvent.readerEntryContext, const {
          'source': 'memory',
          'queue_membership': 'outside_to_read',
          'paper_text': sourceText,
          'account_id': privateAccount,
        });

        expect(delegate.events, const [
          _RecordedEvent(PakPerkTelemetryEvent.annotationSyncOutcome, {
            'action': 'reanchor',
            'outcome': 'orphaned',
            'strategy': 'server',
            'offline': false,
          }),
          _RecordedEvent(PakPerkTelemetryEvent.memoryLifecycle, {
            'action': 'create',
            'source_type': 'annotation',
            'offline': true,
          }),
          _RecordedEvent(PakPerkTelemetryEvent.readerEntryContext, {
            'source': 'memory',
            'queue_membership': 'outside_to_read',
          }),
        ]);
        final exported = delegate.events.toString();
        expect(exported, isNot(contains(privateNote)));
        expect(exported, isNot(contains(sourceText)));
        expect(exported, isNot(contains(privateAccount)));
      },
    );

    test(
      'exports every required feed-prefetch metric with closed fields',
      () async {
        final delegate = _RecordingSink();
        final telemetry = PakPerkFeedPrefetchTelemetry(
          sink: RedactingTelemetrySink(delegate),
          timeline: const NoopFeedPrefetchTelemetry(),
        );

        for (final event in const [
          FeedPrefetchEvent(FeedPrefetchMetric.requested),
          FeedPrefetchEvent(FeedPrefetchMetric.succeeded),
          FeedPrefetchEvent(FeedPrefetchMetric.failed, attempt: 2),
          FeedPrefetchEvent(FeedPrefetchMetric.deduplicated),
          FeedPrefetchEvent(FeedPrefetchMetric.nextPaperCacheHit),
          FeedPrefetchEvent(FeedPrefetchMetric.nextPaperCacheMiss),
          FeedPrefetchEvent(FeedPrefetchMetric.blankCard),
          FeedPrefetchEvent(FeedPrefetchMetric.cacheRows, value: 500),
          FeedPrefetchEvent(FeedPrefetchMetric.cacheBytes, value: 67108864),
          FeedPrefetchEvent(FeedPrefetchMetric.timeToReadable, value: 42),
        ]) {
          telemetry.record(event);
        }
        await Future<void>.delayed(Duration.zero);

        expect(delegate.events, const [
          _RecordedEvent(PakPerkTelemetryEvent.feedPrefetchRequested, {}),
          _RecordedEvent(PakPerkTelemetryEvent.feedPrefetchSucceeded, {}),
          _RecordedEvent(PakPerkTelemetryEvent.feedPrefetchFailed, {}),
          _RecordedEvent(PakPerkTelemetryEvent.feedPrefetchDeduplicated, {}),
          _RecordedEvent(PakPerkTelemetryEvent.nextPaperCacheHit, {
            'cache_tier': 'device',
          }),
          _RecordedEvent(PakPerkTelemetryEvent.nextPaperCacheMiss, {
            'cache_tier': 'device',
          }),
          _RecordedEvent(PakPerkTelemetryEvent.feedBlankCard, {}),
          _RecordedEvent(PakPerkTelemetryEvent.feedCacheRows, {'rows': 500}),
          _RecordedEvent(PakPerkTelemetryEvent.feedCacheBytes, {
            'bytes': 67108864,
          }),
          _RecordedEvent(PakPerkTelemetryEvent.feedTimeToReadable, {
            'elapsed_ms': 42,
          }),
        ]);
      },
    );

    test(
      'never delegates raw exceptions, messages, stacks, or context',
      () async {
        final delegate = _RecordingSink();
        final sink = RedactingTelemetrySink(delegate);
        const secret = 'Bearer secret-token reader@example.test';

        await sink.error(
          StateError(secret),
          StackTrace.fromString('private stack $secret'),
          context: const {
            'component': 'startup',
            'operation': 'local_bootstrap',
            'failure_code': 'hello',
            'request_id': '00000000-0000-4000-8000-000000000001',
            'content': secret,
          },
        );

        expect(delegate.errors, hasLength(1));
        final recorded = delegate.errors.single;
        expect(recorded.error, isA<TelemetryErrorCategory>());
        expect((recorded.error as TelemetryErrorCategory).category, 'state');
        expect(recorded.stack.toString(), isEmpty);
        expect(recorded.context, const {
          'component': 'startup',
          'operation': 'local_bootstrap',
        });
        expect('$recorded', isNot(contains(secret)));
      },
    );
  });

  test('duration buckets clamp clock skew without exporting timestamps', () {
    expect(
      telemetryDurationBucket(const Duration(milliseconds: -1)),
      'lt_100ms',
    );
    expect(
      telemetryDurationBucket(const Duration(milliseconds: 100)),
      '100ms_1s',
    );
    expect(telemetryDurationBucket(const Duration(hours: 24)), 'gte_24h');
    expect(telemetryDurationBucket(null), 'unknown');
    expect(telemetryDurationBucket(null, none: true), 'none');
  });

  test('OTLP exporter emits one bounded redacted logs request', () async {
    final transport = _RecordingTransport();
    final exporter = OtlpHttpTelemetrySink(
      endpoint: Uri.parse('https://telemetry.pakperk.app/v1/logs'),
      environment: 'production',
      transport: transport,
      clock: () => DateTime.utc(2030, 1, 2, 3, 4, 5),
    );
    final sink = RedactingTelemetrySink(exporter);

    await sink.event(PakPerkTelemetryEvent.commentCreated, const {
      'visibility': 'published',
      'content': 'private comment',
      'email': 'reader@example.test',
    });

    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.endpoint.path, '/v1/logs');
    expect(utf8.encode(request.body).length, lessThanOrEqualTo(16 * 1024));
    expect(request.body, contains('comment_created'));
    expect(request.body, contains('published'));
    expect(request.body, isNot(contains('private comment')));
    expect(request.body, isNot(contains('reader@example.test')));
    expect(jsonDecode(request.body), isA<Map<String, dynamic>>());
  });

  test('OTLP exporter permits plaintext only for development loopback', () {
    expect(
      () => OtlpHttpTelemetrySink(
        endpoint: Uri.parse('http://localhost:4318/v1/logs'),
        environment: 'development',
      ),
      returnsNormally,
    );
    expect(
      () => OtlpHttpTelemetrySink(
        endpoint: Uri.parse('http://telemetry.pakperk.app/v1/logs'),
        environment: 'production',
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpTelemetrySink(
        endpoint: Uri.parse('https://telemetry.pakperk.app/v1/traces'),
        environment: 'production',
      ),
      throwsArgumentError,
    );
  });

  test('OTLP exporter drops events while its bounded slots are full', () async {
    final transport = _BlockingTransport();
    final exporter = OtlpHttpTelemetrySink(
      endpoint: Uri.parse('https://telemetry.pakperk.app/v1/logs'),
      environment: 'production',
      transport: transport,
      maximumInFlightExports: 2,
    );

    final first = exporter.event(PakPerkTelemetryEvent.startupReady, const {
      'environment': 'production',
    });
    final second = exporter.event(PakPerkTelemetryEvent.startupReady, const {
      'environment': 'production',
    });
    final dropped = exporter.event(PakPerkTelemetryEvent.startupReady, const {
      'environment': 'production',
    });
    await dropped;

    expect(transport.requests, hasLength(2));
    transport.releaseAll();
    await Future.wait([first, second]);

    final resumed = exporter.event(PakPerkTelemetryEvent.startupReady, const {
      'environment': 'production',
    });
    expect(transport.requests, hasLength(3));
    transport.releaseAll();
    await resumed;
  });

  test(
    'Dio OTLP transport cancels response streams without decoding',
    () async {
      final adapter = _StreamingAcknowledgementAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final transport = DioOtlpHttpTransport(client: dio);

      await transport.postJson(
        Uri.parse('https://telemetry.pakperk.app/v1/logs'),
        '{}',
      );

      expect(adapter.requestedResponseType, ResponseType.stream);
      expect(adapter.responseListened, isTrue);
      expect(adapter.responseCancelled, isTrue);
    },
  );
}

final class _RecordingSink implements TelemetrySink {
  final events = <_RecordedEvent>[];
  final errors = <_RecordedError>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add(_RecordedEvent(name, attributes));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {
    errors.add(_RecordedError(error, stack, context));
  }
}

final class _RecordedEvent {
  const _RecordedEvent(this.name, this.attributes);

  final String name;
  final Map<String, Object?> attributes;

  @override
  bool operator ==(Object other) =>
      other is _RecordedEvent &&
      other.name == name &&
      _mapsEqual(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(attributes.entries));
}

final class _RecordedError {
  const _RecordedError(this.error, this.stack, this.context);

  final Object error;
  final StackTrace stack;
  final Map<String, Object?> context;
}

final class _RecordingTransport implements OtlpHttpTransport {
  final requests = <_RecordedRequest>[];

  @override
  Future<void> postJson(Uri endpoint, String body) async {
    requests.add(_RecordedRequest(endpoint, body));
  }

  @override
  void close() {}
}

final class _BlockingTransport implements OtlpHttpTransport {
  final requests = <_RecordedRequest>[];
  final _pending = <Completer<void>>[];

  @override
  Future<void> postJson(Uri endpoint, String body) {
    requests.add(_RecordedRequest(endpoint, body));
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }

  void releaseAll() {
    for (final completer in _pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  @override
  void close() => releaseAll();
}

final class _StreamingAcknowledgementAdapter implements HttpClientAdapter {
  ResponseType? requestedResponseType;
  bool responseListened = false;
  bool responseCancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedResponseType = options.responseType;
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody(
      Stream<Uint8List>.multi((controller) {
        responseListened = true;
        controller.onCancel = () {
          responseCancelled = true;
        };
      }),
      204,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _RecordedRequest {
  const _RecordedRequest(this.endpoint, this.body);

  final Uri endpoint;
  final String body;
}

bool _mapsEqual(Map<Object?, Object?> left, Map<Object?, Object?> right) {
  if (left.length != right.length) return false;
  return left.entries.every((entry) => right[entry.key] == entry.value);
}
