import 'package:flutter/foundation.dart';

/// Tunable production policy shared by feed requests and durable caches.
///
/// This lives in the cache layer so startup, repositories, DAOs, and feature
/// controllers can all receive the same policy without depending on UI code.
@immutable
class FeedPrefetchConfig {
  const FeedPrefetchConfig({
    this.remotePageSize = defaultRemotePageSize,
    this.loadTrigger = defaultLoadTrigger,
    this.memoryAhead = defaultMemoryAhead,
    this.memoryBehind = defaultMemoryBehind,
    this.durableAhead = defaultDurableAhead,
    this.maxCachedMetadataPapers = defaultMaxCachedMetadataPapers,
    this.maxDatabaseBytes = defaultMaxDatabaseBytes,
    this.metadataTtl = defaultMetadataTtl,
    this.firstCommentsPageTtl = defaultFirstCommentsPageTtl,
    this.retryInitialDelay = defaultRetryInitialDelay,
    this.retryMaximumDelay = defaultRetryMaximumDelay,
    this.retryJitterFraction = defaultRetryJitterFraction,
    this.evictionDelay = defaultEvictionDelay,
  }) : assert(remotePageSize > 0),
       assert(loadTrigger >= 0),
       assert(memoryAhead >= 1),
       assert(memoryBehind >= 0),
       assert(durableAhead >= memoryAhead),
       assert(maxCachedMetadataPapers >= durableAhead),
       assert(maxDatabaseBytes > 0),
       assert(retryJitterFraction >= 0 && retryJitterFraction <= 1);

  static const int defaultRemotePageSize = 30;
  static const int defaultLoadTrigger = 10;
  static const int defaultMemoryAhead = 6;
  static const int defaultMemoryBehind = 2;
  static const int defaultDurableAhead = 60;
  static const int defaultMaxCachedMetadataPapers = 500;
  static const int defaultMaxDatabaseBytes = 64 * 1024 * 1024;
  static const Duration defaultMetadataTtl = Duration(days: 7);
  static const Duration defaultFirstCommentsPageTtl = Duration(minutes: 5);
  static const Duration defaultRetryInitialDelay = Duration(seconds: 1);
  static const Duration defaultRetryMaximumDelay = Duration(seconds: 30);
  static const double defaultRetryJitterFraction = 0.20;
  static const Duration defaultEvictionDelay = Duration(milliseconds: 500);

  final int remotePageSize;
  final int loadTrigger;
  final int memoryAhead;
  final int memoryBehind;
  final int durableAhead;
  final int maxCachedMetadataPapers;
  final int maxDatabaseBytes;
  final Duration metadataTtl;
  final Duration firstCommentsPageTtl;
  final Duration retryInitialDelay;
  final Duration retryMaximumDelay;
  final double retryJitterFraction;
  final Duration evictionDelay;
}
