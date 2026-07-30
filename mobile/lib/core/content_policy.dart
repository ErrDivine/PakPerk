import 'models/paper.dart';
import 'models/processing.dart';

/// Client-side policy for device and bundled derived-content fallbacks.
///
/// The backend remains authoritative for network responses. A strict client
/// fails closed while offline because it cannot independently establish that
/// a cached artifact's current license still permits serving it.
enum ClientFulltextPolicy {
  prototype,
  strict;

  static ClientFulltextPolicy fromWire(String value) {
    return value.trim().toLowerCase() == 'prototype'
        ? ClientFulltextPolicy.prototype
        : ClientFulltextPolicy.strict;
  }

  bool get allowsDerivedDeviceFallback =>
      this == ClientFulltextPolicy.prototype;

  PaperSummary maskCachedPaper(PaperSummary paper) {
    if (allowsDerivedDeviceFallback) return paper;
    return paper.copyWith(capabilities: const PaperCapabilities());
  }

  FeedPage maskCachedFeed(FeedPage feed) {
    if (allowsDerivedDeviceFallback) return feed;
    return FeedPage(
      items: feed.items.map(maskCachedPaper).toList(growable: false),
      nextCursor: feed.nextCursor,
    );
  }

  PaperProcessingState maskCachedProcessing(PaperProcessingState processing) {
    if (allowsDerivedDeviceFallback) return processing;
    final hadDerivedState = processing.capabilities.introduction ||
        processing.capabilities.chat ||
        processing.capabilities.connections ||
        switch (processing.stage) {
          ProcessingStage.introductionReady ||
          ProcessingStage.indexingChat ||
          ProcessingStage.resolvingReferences ||
          ProcessingStage.ready =>
            true,
          _ => false,
        };
    return PaperProcessingState(
      paperId: processing.paperId,
      overallState: hadDerivedState ? 'failed' : processing.overallState,
      stage:
          hadDerivedState ? ProcessingStage.failedTerminal : processing.stage,
      capabilities: const PaperCapabilities(),
      retryable: hadDerivedState ? false : processing.retryable,
      updatedAt: processing.updatedAt,
      lastErrorCode:
          hadDerivedState ? 'FULLTEXT_POLICY_DENIED' : processing.lastErrorCode,
      lastErrorMessage: hadDerivedState
          ? 'Derived paper content is unavailable offline in strict mode.'
          : processing.lastErrorMessage,
    );
  }
}

const configuredFulltextPolicyName = String.fromEnvironment(
  'PAKPERK_FULLTEXT_POLICY',
  defaultValue: 'prototype',
);
