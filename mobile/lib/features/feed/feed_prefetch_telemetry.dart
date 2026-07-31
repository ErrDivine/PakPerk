import 'dart:developer' as developer;

/// Content-free counters emitted by the predictive feed cache.
enum FeedPrefetchMetric {
  requested('feed_prefetch_requested'),
  succeeded('feed_prefetch_succeeded'),
  failed('feed_prefetch_failed'),
  deduplicated('feed_prefetch_deduplicated'),
  nextPaperCacheHit('next_paper_cache_hit'),
  nextPaperCacheMiss('next_paper_cache_miss'),
  blankCard('feed_blank_card'),
  cacheRows('feed_cache_rows'),
  cacheBytes('feed_cache_bytes'),
  timeToReadable('feed_time_to_readable_ms');

  const FeedPrefetchMetric(this.wireName);

  final String wireName;
}

/// A deliberately closed telemetry shape.
///
/// There are no string attributes, so callers cannot accidentally include a
/// paper title, abstract, author, category, comment, cursor, or raw identifier.
class FeedPrefetchEvent {
  const FeedPrefetchEvent(this.metric, {this.value, this.attempt});

  final FeedPrefetchMetric metric;
  final int? value;
  final int? attempt;
}

abstract interface class FeedPrefetchTelemetry {
  void record(FeedPrefetchEvent event);
}

class NoopFeedPrefetchTelemetry implements FeedPrefetchTelemetry {
  const NoopFeedPrefetchTelemetry();

  @override
  void record(FeedPrefetchEvent event) {}
}

/// Emits content-free local timeline events without adding an analytics SDK.
///
/// Production diagnostics can observe these immediately. A future centralized
/// sink can implement the same closed interface without changing feed code.
class DeveloperFeedPrefetchTelemetry implements FeedPrefetchTelemetry {
  const DeveloperFeedPrefetchTelemetry();

  @override
  void record(FeedPrefetchEvent event) {
    developer.Timeline.instantSync(
      event.metric.wireName,
      arguments: <String, int>{
        if (event.value case final value?) 'value': value,
        if (event.attempt case final attempt?) 'attempt': attempt,
      },
    );
  }
}
