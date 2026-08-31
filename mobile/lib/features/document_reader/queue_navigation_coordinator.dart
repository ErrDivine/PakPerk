import '../../core/library/library_models.dart';
import '../../core/reading_feed/reading_feed_models.dart';
import '../../core/telemetry/telemetry.dart';
import 'reader_entry_context.dart';
import 'reader_interaction_state.dart';

enum QueueNavigationDisposition {
  navigate,
  requestCurrentFeedPage,
  checkingQueue,
  naturalStop,
  verificationRequiresConnection,
  cancelRecommendationNavigation,
  returnToOrigin,
  blockedByInteraction,
  staleAccountScope,
  unavailable,
}

final class QueueNavigationDecision {
  const QueueNavigationDecision._(this.disposition, {this.targetIndex});

  const QueueNavigationDecision.navigate(int targetIndex)
    : this._(QueueNavigationDisposition.navigate, targetIndex: targetIndex);

  const QueueNavigationDecision.requestCurrentFeedPage()
    : this._(QueueNavigationDisposition.requestCurrentFeedPage);

  const QueueNavigationDecision.checkingQueue()
    : this._(QueueNavigationDisposition.checkingQueue);

  const QueueNavigationDecision.naturalStop()
    : this._(QueueNavigationDisposition.naturalStop);

  const QueueNavigationDecision.verificationRequiresConnection()
    : this._(QueueNavigationDisposition.verificationRequiresConnection);

  const QueueNavigationDecision.cancelRecommendationNavigation()
    : this._(QueueNavigationDisposition.cancelRecommendationNavigation);

  const QueueNavigationDecision.returnToOrigin()
    : this._(QueueNavigationDisposition.returnToOrigin);

  const QueueNavigationDecision.blockedByInteraction()
    : this._(QueueNavigationDisposition.blockedByInteraction);

  const QueueNavigationDecision.staleAccountScope()
    : this._(QueueNavigationDisposition.staleAccountScope);

  const QueueNavigationDecision.unavailable()
    : this._(QueueNavigationDisposition.unavailable);

  final QueueNavigationDisposition disposition;
  final int? targetIndex;

  bool get permitsNavigation =>
      disposition == QueueNavigationDisposition.navigate;
}

/// The only Plan 03 component allowed to turn reading-feed authority into a
/// next-paper navigation decision.
///
/// It never queries a recommendation source. Pagination requests go back to
/// the existing reading-feed controller, which owns the canonical queue cursor
/// and its server-confirmed empty-queue transition.
final class QueueNavigationCoordinator {
  const QueueNavigationCoordinator({
    this.telemetry = const NoopTelemetrySink(),
  });

  final TelemetrySink telemetry;

  QueueNavigationDecision decide({
    required ReadingFeedState feed,
    required LibraryPendingIntentCounts pendingIntents,
    required ReaderEntryContext entry,
    required ReaderInteractionState interaction,
    required int currentAuthEpoch,
    required int currentAccountGeneration,
    required int currentIndex,
    required int targetIndex,
    bool explicitActiveStateMutation = false,
  }) {
    QueueNavigationDecision finish(QueueNavigationDecision decision) {
      if (entry.source == ReaderEntrySource.queue &&
          targetIndex > currentIndex) {
        emitTelemetry(telemetry, PakPerkTelemetryEvent.queueAutoAdvance, {
          'outcome': switch (decision.disposition) {
            QueueNavigationDisposition.navigate => 'succeeded',
            QueueNavigationDisposition.requestCurrentFeedPage =>
              'page_requested',
            QueueNavigationDisposition.checkingQueue => 'checking',
            QueueNavigationDisposition.naturalStop => 'natural_stop',
            QueueNavigationDisposition.verificationRequiresConnection =>
              'offline_unknown',
            QueueNavigationDisposition.blockedByInteraction => 'blocked',
            QueueNavigationDisposition.staleAccountScope ||
            QueueNavigationDisposition.unavailable ||
            QueueNavigationDisposition.cancelRecommendationNavigation ||
            QueueNavigationDisposition.returnToOrigin => 'fail_closed',
          },
          'offline': feed.offline,
        });
      }
      return decision;
    }

    if (!interaction.canNavigateVertically) {
      return finish(const QueueNavigationDecision.blockedByInteraction());
    }
    if (entry.isExplicitBranch) {
      return finish(const QueueNavigationDecision.returnToOrigin());
    }
    if (!entry.matchesScope(
          authEpoch: currentAuthEpoch,
          generation: currentAccountGeneration,
        ) ||
        feed.authEpoch != currentAuthEpoch ||
        feed.accountGeneration != currentAccountGeneration) {
      return finish(const QueueNavigationDecision.staleAccountScope());
    }

    if (entry.source == ReaderEntrySource.recommendation) {
      return finish(
        _recommendationDecision(
          feed: feed,
          pendingIntents: pendingIntents,
          currentIndex: currentIndex,
          targetIndex: targetIndex,
        ),
      );
    }
    if (entry.source != ReaderEntrySource.queue) {
      return finish(const QueueNavigationDecision.unavailable());
    }
    return finish(
      _queueDecision(
        feed: feed,
        pendingIntents: pendingIntents,
        currentIndex: currentIndex,
        targetIndex: targetIndex,
        explicitActiveStateMutation: explicitActiveStateMutation,
      ),
    );
  }

  QueueNavigationDecision _queueDecision({
    required ReadingFeedState feed,
    required LibraryPendingIntentCounts pendingIntents,
    required int currentIndex,
    required int targetIndex,
    required bool explicitActiveStateMutation,
  }) {
    if (feed.mode == ReadingFeedMode.finishingQueue) {
      return const QueueNavigationDecision.checkingQueue();
    }
    if (feed.mode == ReadingFeedMode.recommendations ||
        feed.recommendationsVisible) {
      return const QueueNavigationDecision.unavailable();
    }

    final target = feed.queueItemAt(targetIndex);
    if (target != null && targetIndex >= 0 && targetIndex < feed.items.length) {
      return QueueNavigationDecision.navigate(targetIndex);
    }

    final movingForward = targetIndex > currentIndex;
    if (movingForward && targetIndex >= feed.items.length) {
      if (feed.nextCursor != null &&
          _queueAuthorityAllowsExistingQueue(feed.queueAuthority) &&
          pendingIntents.saves == 0) {
        return const QueueNavigationDecision.requestCurrentFeedPage();
      }
      if (explicitActiveStateMutation) {
        if (feed.offline ||
            feed.queueAuthority == QueueAuthority.unknown ||
            feed.queueAuthority == QueueAuthority.stale) {
          return const QueueNavigationDecision.verificationRequiresConnection();
        }
        return const QueueNavigationDecision.checkingQueue();
      }
      // Reading to the document end is not a Library mutation.
      return const QueueNavigationDecision.naturalStop();
    }

    if (feed.offline &&
        (feed.queueAuthority == QueueAuthority.unknown ||
            feed.queueAuthority == QueueAuthority.stale)) {
      return const QueueNavigationDecision.verificationRequiresConnection();
    }
    return const QueueNavigationDecision.unavailable();
  }

  QueueNavigationDecision _recommendationDecision({
    required ReadingFeedState feed,
    required LibraryPendingIntentCounts pendingIntents,
    required int currentIndex,
    required int targetIndex,
  }) {
    if (pendingIntents.saves > 0 ||
        feed.queueAuthority == QueueAuthority.pendingSave ||
        feed.mode != ReadingFeedMode.recommendations ||
        !feed.recommendationsVisible ||
        feed.activeToReadCount != 0) {
      return const QueueNavigationDecision.cancelRecommendationNavigation();
    }
    if (targetIndex >= 0 && feed.recommendationItemAt(targetIndex) != null) {
      return QueueNavigationDecision.navigate(targetIndex);
    }
    if (targetIndex > currentIndex &&
        targetIndex >= feed.items.length &&
        feed.nextCursor != null &&
        !feed.offline) {
      return const QueueNavigationDecision.requestCurrentFeedPage();
    }
    return feed.offline
        ? const QueueNavigationDecision.verificationRequiresConnection()
        : const QueueNavigationDecision.naturalStop();
  }
}

bool _queueAuthorityAllowsExistingQueue(QueueAuthority authority) =>
    switch (authority) {
      QueueAuthority.localNonEmpty ||
      QueueAuthority.serverConfirmedNonEmpty => true,
      QueueAuthority.unknown ||
      QueueAuthority.pendingSave ||
      QueueAuthority.serverConfirmedEmpty ||
      QueueAuthority.stale => false,
    };
