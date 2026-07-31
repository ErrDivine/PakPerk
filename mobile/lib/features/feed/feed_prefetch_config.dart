import 'package:flutter/foundation.dart';

/// Tunable production policy for sequential feed caching.
///
/// Keeping these values together prevents UI code, persistence, and tests from
/// silently drifting to different cache-ahead behavior.
@immutable
class FeedPrefetchConfig {
  const FeedPrefetchConfig({
    this.remotePageSize = 30,
    this.loadTrigger = 10,
    this.memoryAhead = 6,
    this.memoryBehind = 2,
    this.durableAhead = 60,
    this.maxCachedMetadataPapers = 500,
    this.maxDatabaseBytes = 64 * 1024 * 1024,
    this.metadataTtl = const Duration(days: 7),
    this.firstCommentsPageTtl = const Duration(minutes: 5),
    this.retryInitialDelay = const Duration(seconds: 1),
    this.retryMaximumDelay = const Duration(seconds: 30),
    this.retryJitterFraction = 0.20,
    this.evictionDelay = const Duration(milliseconds: 500),
  }) : assert(remotePageSize > 0),
       assert(loadTrigger >= 0),
       assert(memoryAhead >= 1),
       assert(memoryBehind >= 0),
       assert(durableAhead >= memoryAhead),
       assert(maxCachedMetadataPapers >= durableAhead),
       assert(maxDatabaseBytes > 0),
       assert(retryJitterFraction >= 0 && retryJitterFraction <= 1);

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
