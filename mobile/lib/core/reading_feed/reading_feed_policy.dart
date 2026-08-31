import 'reading_feed_models.dart';

enum ReadingFeedAuthentication { signedOut, verified, unknown, changing }

final class ReadingFeedPolicyInput {
  const ReadingFeedPolicyInput({
    required this.authentication,
    required this.localActiveCount,
    required this.pendingSaveCount,
    required this.pendingRemoveCount,
    required this.pendingImportCount,
    required this.syncReset,
    required this.offline,
    this.localRevision,
    this.serverPage,
  });

  final ReadingFeedAuthentication authentication;
  final int localActiveCount;
  final int pendingSaveCount;
  final int pendingRemoveCount;
  final int pendingImportCount;
  final bool syncReset;
  final bool offline;
  final int? localRevision;
  final ReadingFeedPage? serverPage;
}

final class ReadingFeedPolicyDecision {
  const ReadingFeedPolicyDecision({
    required this.mode,
    required this.authority,
    required this.allowRecommendationRequest,
    required this.allowRecommendationPublish,
  });

  final ReadingFeedMode mode;
  final QueueAuthority authority;
  final bool allowRecommendationRequest;
  final bool allowRecommendationPublish;
}

final class ReadingFeedRequestScope {
  const ReadingFeedRequestScope({
    required this.accountId,
    required this.authEpoch,
    required this.generation,
  });

  final String accountId;
  final int authEpoch;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is ReadingFeedRequestScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(accountId, authEpoch, generation);
}

class ReadingFeedPolicy {
  const ReadingFeedPolicy();

  ReadingFeedPolicyDecision evaluate(ReadingFeedPolicyInput input) {
    _validateCounts(input);
    if (input.authentication == ReadingFeedAuthentication.signedOut) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.guestDiscovery,
        authority: QueueAuthority.unknown,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }
    if (input.authentication == ReadingFeedAuthentication.changing ||
        input.syncReset) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.unavailable,
        authority: QueueAuthority.stale,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }
    // Account-scoped local rows are safe to show before remote identity
    // verification completes. This gives an offline/refreshing user their
    // queue immediately while still refusing every recommendation.
    if (input.localActiveCount > 0) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.toRead,
        authority: QueueAuthority.localNonEmpty,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }
    if (input.pendingSaveCount > 0 || input.pendingImportCount > 0) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.toRead,
        authority: QueueAuthority.pendingSave,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }
    if (input.pendingRemoveCount > 0) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.finishingQueue,
        authority: QueueAuthority.stale,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }
    if (input.authentication != ReadingFeedAuthentication.verified) {
      return ReadingFeedPolicyDecision(
        mode: input.offline
            ? ReadingFeedMode.unavailable
            : ReadingFeedMode.checkingQueue,
        authority: QueueAuthority.unknown,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      );
    }

    final page = input.serverPage;
    if (page == null) {
      return ReadingFeedPolicyDecision(
        mode: input.offline
            ? ReadingFeedMode.unavailable
            : ReadingFeedMode.checkingQueue,
        authority: QueueAuthority.unknown,
        allowRecommendationRequest: !input.offline,
        allowRecommendationPublish: false,
      );
    }
    if (input.localRevision case final localRevision?
        when page.decision.libraryRevision < localRevision) {
      return const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.checkingQueue,
        authority: QueueAuthority.stale,
        allowRecommendationRequest: true,
        allowRecommendationPublish: false,
      );
    }
    return switch (page.mode) {
      ReadingFeedServerMode.toRead => const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.toRead,
        authority: QueueAuthority.serverConfirmedNonEmpty,
        allowRecommendationRequest: false,
        allowRecommendationPublish: false,
      ),
      ReadingFeedServerMode.recommendations => const ReadingFeedPolicyDecision(
        mode: ReadingFeedMode.recommendations,
        authority: QueueAuthority.serverConfirmedEmpty,
        allowRecommendationRequest: true,
        allowRecommendationPublish: true,
      ),
    };
  }

  bool canPublishResponse({
    required ReadingFeedPage response,
    required ReadingFeedRequestScope requestScope,
    required ReadingFeedRequestScope currentScope,
    required ReadingFeedPolicyInput currentInput,
  }) {
    if (requestScope != currentScope ||
        response.mode != ReadingFeedServerMode.recommendations ||
        !response.decision.queueProvenEmpty ||
        response.decision.activeToReadCount != 0) {
      return false;
    }
    final evaluated = evaluate(
      ReadingFeedPolicyInput(
        authentication: currentInput.authentication,
        localActiveCount: currentInput.localActiveCount,
        pendingSaveCount: currentInput.pendingSaveCount,
        pendingRemoveCount: currentInput.pendingRemoveCount,
        pendingImportCount: currentInput.pendingImportCount,
        syncReset: currentInput.syncReset,
        offline: currentInput.offline,
        localRevision: currentInput.localRevision,
        serverPage: response,
      ),
    );
    return evaluated.allowRecommendationPublish;
  }

  void _validateCounts(ReadingFeedPolicyInput input) {
    if (input.localActiveCount < 0 ||
        input.pendingSaveCount < 0 ||
        input.pendingRemoveCount < 0 ||
        input.pendingImportCount < 0 ||
        (input.localRevision != null && input.localRevision! < 0)) {
      throw ArgumentError(
        'Reading-feed counts and revisions cannot be negative.',
      );
    }
  }
}
