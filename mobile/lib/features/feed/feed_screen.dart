import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/library_providers.dart';
import '../../app/discovery_providers.dart';
import '../../core/interactions/interaction_models.dart';
import '../../core/library/paper_import_draft_store.dart';
import '../../core/library/library_models.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../../core/reading_feed/reading_feed_models.dart';
import '../../core/repository/paper_repository.dart';
import '../../core/telemetry/telemetry.dart';
import '../../core/widgets/responsive_reader_frame.dart';
import '../../core/widgets/status_widgets.dart';
import '../../design_system/motion.dart';
import '../../design_system/skeleton.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import '../library/paper_import_flow.dart';
import '../library/paper_import_drafts.dart';
import '../document_reader/queue_navigation_coordinator.dart';
import '../document_reader/reader_entry_context.dart';
import '../document_reader/reader_interaction_state.dart';
import '../paper_reader/paper_reader.dart';
import '../paper_reader/reader_navigation_controller.dart';
import '../recommendations/recommendation_feed_control.dart';
import 'feed_controller.dart';
import 'guest_category_onboarding.dart';
import 'reading_feed_controller.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({this.onOpenBrief, this.onOpenSearch, super.key});

  final VoidCallback? onOpenBrief;
  final VoidCallback? onOpenSearch;

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  late final PageController _controller;
  ProviderSubscription<EffectiveFeedState>? _feedScopeSubscription;
  late int _currentIndex;
  int? _pendingCommittedIndex;
  int? _explicitHapticTargetIndex;

  // Navigation is fenced by the account scope that owned the last committed
  // page. Rebuilding this entry from the current provider inside a decision
  // would make the stale-account check tautological.
  ReaderEntryContext? _activeNavigationEntry;
  String? _activeNavigationReaderKey;
  int? _activeNavigationIndex;
  var _verticalTransitionActive = false;
  var _scopeResetPending = false;
  var _scopeResetSerial = 0;
  String? _lastCommittedSignature;
  var _guestOnboardingScheduled = false;
  var _guestPreferenceApplied = false;
  var _guestCategorySheetOpen = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = ref
        .read(appRestorationControllerProvider)
        .feedIndex
        .clamp(0, 1000000);
    _controller = PageController(initialPage: _currentIndex);
    _feedScopeSubscription = ref.listenManual<EffectiveFeedState>(
      effectiveFeedProvider,
      _onEffectiveFeedChanged,
    );
  }

  @override
  void dispose() {
    _feedScopeSubscription?.close();
    _controller.dispose();
    super.dispose();
  }

  void _onEffectiveFeedChanged(
    EffectiveFeedState? previous,
    EffectiveFeedState next,
  ) {
    if (previous?.personalized == true && !next.personalized) {
      _guestPreferenceApplied = false;
      _guestOnboardingScheduled = false;
    }
    if (previous?.personalized == false &&
        next.personalized &&
        _guestCategorySheetOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_guestCategorySheetOpen) return;
        if (!ref.read(effectiveFeedProvider).personalized) return;
        unawaited(Navigator.of(context, rootNavigator: true).maybePop());
      });
    }

    if (previous == null) return;
    final identityChanged =
        previous.personalized != next.personalized ||
        previous.authEpoch != next.authEpoch;
    final currentIndex = next.items.isEmpty
        ? 0
        : _currentIndex.clamp(0, next.items.length - 1).toInt();
    final candidate = next.items.isEmpty
        ? null
        : _readerEntryContext(next, currentIndex);
    final entryChanged =
        candidate != null &&
        (_activeNavigationEntry == null ||
            !_sameReaderEntry(_activeNavigationEntry!, candidate));
    if (!identityChanged && !entryChanged) return;

    final transitionInFlight =
        _verticalTransitionActive ||
        _pendingCommittedIndex != null ||
        _explicitHapticTargetIndex != null;
    if (identityChanged || transitionInFlight) {
      _scheduleNavigationScopeReset(next, resetToFirst: identityChanged);
      return;
    }
    if (candidate != null) {
      _captureActiveNavigationEntry(next, currentIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(effectiveFeedProvider);
    final importDraftsEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.libraryImportWrites),
    );
    final importDrafts = importDraftsEnabled
        ? ref.watch(paperImportDraftControllerProvider)
        : const PaperImportDraftState.signedOut();
    final routes = ref.watch(appRestorationControllerProvider).routeStack;
    final readBranchActive =
        ref.watch(activeAppBranchProvider) == AppBranch.read;
    final canImport = ref.watch(paperImportAvailableProvider);
    final recommendationsEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.recommendationsEnabled),
    );
    final deepReaderEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.deepReader),
    );
    final exploreSearchEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.searchExploreEnabled),
    );
    final guestPreferences = feed.personalized
        ? null
        : ref.watch(guestDiscoveryPreferencesControllerProvider);
    if (guestPreferences != null &&
        !guestPreferences.loading &&
        guestPreferences.errorMessage == null &&
        !guestPreferences.preferences.onboardingComplete &&
        !_guestOnboardingScheduled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _guestOnboardingScheduled) return;
        final latest = ref.read(guestDiscoveryPreferencesControllerProvider);
        if (latest.loading || latest.preferences.onboardingComplete) return;
        _guestOnboardingScheduled = true;
        unawaited(_editGuestCategories());
      });
    }
    if (guestPreferences != null &&
        !guestPreferences.loading &&
        guestPreferences.preferences.onboardingComplete &&
        !_guestPreferenceApplied) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _guestPreferenceApplied) return;
        final latest = ref.read(guestDiscoveryPreferencesControllerProvider);
        if (latest.loading || !latest.preferences.onboardingComplete) return;
        _guestPreferenceApplied = true;
        final categories = latest.preferences.categories;
        final currentFeed = ref.read(effectiveFeedProvider);
        if (!currentFeed.personalized &&
            currentFeed.category == null &&
            categories.isNotEmpty) {
          _selectGuestCategory(categories.first);
        }
      });
    }
    final recommendationRemote = recommendationsEnabled
        ? ref.watch(recommendationInteractionApiProvider)
        : null;
    final recommendationAuthorityIsSafe =
        feed.mode == ReadingFeedMode.recommendations &&
        feed.queueAuthority == QueueAuthority.serverConfirmedEmpty &&
        feed.activeToReadCount == 0;
    final recommendationsAreSafe =
        recommendationsEnabled && recommendationAuthorityIsSafe;
    final briefIsSafe =
        widget.onOpenBrief != null &&
        feed.personalized &&
        switch (feed.mode) {
          ReadingFeedMode.toRead =>
            feed.items.isNotEmpty &&
                (feed.queueAuthority == QueueAuthority.localNonEmpty ||
                    feed.queueAuthority ==
                        QueueAuthority.serverConfirmedNonEmpty),
          ReadingFeedMode.recommendations => recommendationAuthorityIsSafe,
          _ => false,
        };
    Widget recommendationModeControls() => _RecommendationModeControls(
      selected: feed.recommendationMode,
      forYouAvailable: feed.forYouAvailable,
      onSelected: (mode) => unawaited(
        ref
            .read(readingFeedControllerProvider.notifier)
            .selectRecommendationMode(mode),
      ),
    );
    Widget guestDiscoveryControls() => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GuestDiscoveryControls(
          exploreEnabled: exploreSearchEnabled && widget.onOpenSearch != null,
          onExplore: widget.onOpenSearch,
        ),
        if (guestPreferences != null && !guestPreferences.loading)
          GuestCategorySelector(
            categories: guestPreferences.preferences.categories,
            activeCategory: feed.category,
            onSelected: _selectGuestCategory,
            onManage: () => unawaited(_editGuestCategories()),
          ),
      ],
    );
    if (feed.loadingInitial && feed.items.isEmpty) {
      if (feed.personalized) {
        return _ReadingFeedStatusScaffold(
          mode: feed.mode,
          authority: feed.queueAuthority,
          offline: feed.offline,
          errorMessage: feed.errorMessage,
          loading: true,
          onRetry: () => _retry(feed),
          onAddPaper: canImport ? _addPaper : null,
          onOpenSearch: widget.onOpenSearch,
          importDrafts: importDrafts.drafts,
          importDraftError: importDrafts.errorMessage,
          onRetryImportDraft: _retryImportDraft,
          onCancelImportDraft: _cancelImportDraft,
          onReloadImportDrafts: _reloadImportDrafts,
          onClearImportDrafts: _confirmClearImportDrafts,
          header: recommendationsAreSafe || briefIsSafe
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (recommendationsAreSafe) recommendationModeControls(),
                    if (briefIsSafe)
                      _ReadingBriefEntry(
                        mode: feed.mode,
                        onOpen: widget.onOpenBrief!,
                      ),
                  ],
                )
              : null,
        );
      }
      return Scaffold(
        floatingActionButton: _FeedFloatingActions(
          onOpenSearch: widget.onOpenSearch,
        ),
        body: Column(
          children: [
            SafeArea(bottom: false, child: guestDiscoveryControls()),
            Expanded(
              child: SafeArea(
                top: false,
                child: ResponsiveReaderFrame(
                  child: const PaperCardSkeleton(
                    key: ValueKey('feed-cache-miss-skeleton'),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (feed.items.isEmpty) {
      if (feed.personalized) {
        return _ReadingFeedStatusScaffold(
          mode: feed.mode,
          authority: feed.queueAuthority,
          offline: feed.offline,
          errorMessage: feed.errorMessage,
          loading: false,
          onRetry: () => _retry(feed),
          onAddPaper: canImport ? _addPaper : null,
          onOpenSearch: widget.onOpenSearch,
          importDrafts: importDrafts.drafts,
          importDraftError: importDrafts.errorMessage,
          onRetryImportDraft: _retryImportDraft,
          onCancelImportDraft: _cancelImportDraft,
          onReloadImportDrafts: _reloadImportDrafts,
          onClearImportDrafts: _confirmClearImportDrafts,
          header: recommendationsAreSafe || briefIsSafe
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (recommendationsAreSafe) recommendationModeControls(),
                    if (briefIsSafe)
                      _ReadingBriefEntry(
                        mode: feed.mode,
                        onOpen: widget.onOpenBrief!,
                      ),
                  ],
                )
              : null,
        );
      }
      return Scaffold(
        floatingActionButton: _FeedFloatingActions(
          onOpenSearch: widget.onOpenSearch,
        ),
        body: Column(
          children: [
            SafeArea(bottom: false, child: guestDiscoveryControls()),
            Expanded(
              child: SafeArea(
                top: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.article_outlined, size: 48),
                        const SizedBox(height: 14),
                        Text(
                          feed.errorMessage ?? 'No papers are cached yet.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _retry(feed),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final showNaturalQueueEnd = _showsNaturalQueueEnd(feed);
    final pageCount = feed.items.length + (showNaturalQueueEnd ? 1 : 0);
    if (_currentIndex >= pageCount) {
      _currentIndex = pageCount - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpToPage(_currentIndex);
      });
    }
    _ensureActiveNavigationEntry(feed);
    if (readBranchActive && routes.isEmpty) {
      _scheduleCommittedPage(feed);
    }
    final atNaturalQueueEnd =
        showNaturalQueueEnd && _currentIndex == feed.items.length;
    final activeInteraction = atNaturalQueueEnd
        ? const ReaderInteractionState()
        : ref.watch(
            readerInteractionControllerProvider(
              feedReaderKey(feed.items[_currentIndex]),
            ),
          );
    final queueItem = atNaturalQueueEnd
        ? null
        : feed.queueItemAt(_currentIndex);

    return Scaffold(
      floatingActionButton: _FeedFloatingActions(
        onOpenSearch: widget.onOpenSearch,
        onAddPaper: feed.personalized && canImport ? _addPaper : null,
      ),
      body: Column(
        children: [
          if (feed.origin == DataOrigin.bundledDemo)
            const SafeArea(
              bottom: false,
              minimum: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: BundledDemoNotice(),
            ),
          if (!feed.personalized)
            SafeArea(bottom: false, child: guestDiscoveryControls())
          else if (recommendationsAreSafe)
            SafeArea(bottom: false, child: recommendationModeControls())
          else if (feed.mode == ReadingFeedMode.toRead)
            SafeArea(
              bottom: false,
              child: _QueueContextHeader(
                item: queueItem,
                atNaturalEnd: atNaturalQueueEnd,
              ),
            ),
          if (briefIsSafe)
            SafeArea(
              top: false,
              bottom: false,
              child: _ReadingBriefEntry(
                mode: feed.mode,
                onOpen: widget.onOpenBrief!,
              ),
            ),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.axis == Axis.vertical) {
                  _settleCommittedPage(feed);
                  _verticalTransitionActive = false;
                }
                return false;
              },
              child: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.vertical) {
                    _verticalTransitionActive = true;
                  }
                  return false;
                },
                child: PageView.builder(
                  key: const PageStorageKey('vertical-paper-feed'),
                  controller: _controller,
                  scrollDirection: Axis.vertical,
                  physics: activeInteraction.canDragPager
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemCount: pageCount,
                  onPageChanged: (index) {
                    final previousIndex = _currentIndex;
                    final currentFeed = ref.read(effectiveFeedProvider);
                    final targetsCurrentPaper =
                        index >= 0 && index < currentFeed.items.length;
                    final targetsCurrentNaturalEnd =
                        _showsNaturalQueueEnd(currentFeed) &&
                        index == currentFeed.items.length;
                    if (deepReaderEnabled &&
                        currentFeed.personalized &&
                        !targetsCurrentNaturalEnd &&
                        (!targetsCurrentPaper ||
                            !_coordinatedDecision(
                              currentIndex: previousIndex,
                              targetIndex: index,
                            ).permitsNavigation)) {
                      final currentPageCount =
                          currentFeed.items.length +
                          (_showsNaturalQueueEnd(currentFeed) ? 1 : 0);
                      final rollbackIndex = currentPageCount == 0
                          ? 0
                          : previousIndex
                                .clamp(0, currentPageCount - 1)
                                .toInt();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _controller.hasClients) {
                          _controller.jumpToPage(rollbackIndex);
                        }
                      });
                      return;
                    }
                    final changed = index != _currentIndex;
                    setState(() {
                      _currentIndex = index;
                      if (changed) _pendingCommittedIndex = index;
                    });
                  },
                  itemBuilder: (context, index) {
                    if (index == feed.items.length) {
                      return ResponsiveReaderFrame(
                        key: const ValueKey('to-read-natural-end-frame'),
                        child: _NaturalQueueEnd(
                          onBackToFirst: () => _goToPaper(0),
                        ),
                      );
                    }
                    final paper = feed.items[index];
                    final recommendationItem = feed.recommendationItemAt(index);
                    final batchId = feed.recommendationBatchIdAt(index);
                    final recommendationControl =
                        recommendationRemote != null &&
                            batchId != null &&
                            recommendationItem != null &&
                            recommendationItem
                                .source
                                .isPersonalizedRecommendation &&
                            recommendationItem.recommendation != null
                        ? RecommendationFeedControl(
                            key: ValueKey(
                              'recommendation-control-$batchId-${paper.paperId}',
                            ),
                            item: recommendationItem,
                            batchId: batchId,
                            authEpoch: feed.authEpoch,
                            accountGeneration: feed.accountGeneration,
                            enabled: true,
                            remote: recommendationRemote,
                          )
                        : null;
                    final readerKey = feedReaderKey(paper);
                    final saveSourceKind = switch (feed.mode) {
                      ReadingFeedMode.toRead ||
                      ReadingFeedMode.checkingQueue ||
                      ReadingFeedMode.unavailable =>
                        feed.queueItemAt(index)?.saveSourceKind,
                      ReadingFeedMode.guestDiscovery ||
                      ReadingFeedMode.recommendations =>
                        LibrarySaveSourceKind.discovery,
                      ReadingFeedMode.finishingQueue => null,
                    };
                    final interactionContext = _interactionContext(feed, index);
                    return ResponsiveReaderFrame(
                      key: ValueKey('responsive-reader-$readerKey'),
                      child: PaperReader(
                        key: ValueKey('feed-paper-$readerKey'),
                        paper: paper,
                        readerKey: readerKey,
                        isActive:
                            readBranchActive &&
                            index == _currentIndex &&
                            routes.isEmpty,
                        entryContext: _entryContextForReader(feed, index),
                        onPreviousPaper: index > 0
                            ? () => _goToPaper(index - 1)
                            : null,
                        onNextPaper: index + 1 < feed.items.length
                            ? () => _goToPaper(index + 1)
                            : null,
                        contextualAction: recommendationControl,
                        saveSourceKind: saveSourceKind,
                        interactionContext: interactionContext,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _goToPaper(int index) async {
    final feed = ref.read(effectiveFeedProvider);
    final deepReaderEnabled = ref.read(featureFlagsProvider).deepReader;
    if (deepReaderEnabled && feed.personalized) {
      final decision = _coordinatedDecision(
        currentIndex: _currentIndex,
        targetIndex: index,
      );
      if (decision.disposition ==
          QueueNavigationDisposition.requestCurrentFeedPage) {
        await ref.read(readingFeedControllerProvider.notifier).loadMore();
        if (!mounted) return;
        final refreshed = ref.read(effectiveFeedProvider);
        if (index >= refreshed.items.length) return;
        return _goToPaper(index);
      }
      if (!decision.permitsNavigation) {
        _announceNavigationDecision(decision);
        return;
      }
    }
    if (platformPrefersReducedMotion(context)) {
      _explicitHapticTargetIndex = index;
      _controller.jumpToPage(index);
      return;
    }
    _explicitHapticTargetIndex = index;
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  ReaderEntryContext _readerEntryContext(EffectiveFeedState feed, int index) {
    return switch (feed.mode) {
      ReadingFeedMode.toRead ||
      ReadingFeedMode.checkingQueue ||
      ReadingFeedMode.finishingQueue ||
      ReadingFeedMode.unavailable => ReaderEntryContext.queue(
        expectedAuthEpoch: feed.authEpoch,
        accountGeneration: feed.accountGeneration,
        libraryRevision: feed.libraryRevision,
      ),
      ReadingFeedMode.recommendations => ReaderEntryContext(
        source: ReaderEntrySource.recommendation,
        queueMembership: ReaderQueueMembership.outsideToRead,
        expectedAuthEpoch: feed.authEpoch,
        accountGeneration: feed.accountGeneration,
        libraryRevision: feed.libraryRevision,
        recommendationBatchId: feed.recommendationBatchIdAt(index),
      ),
      ReadingFeedMode.guestDiscovery =>
        const ReaderEntryContext.publicDiscovery(),
    };
  }

  ReaderEntryContext _entryContextForReader(
    EffectiveFeedState feed,
    int index,
  ) {
    if (_scopeResetPending) return _readerEntryContext(feed, index);
    final active = _activeNavigationEntry;
    if (active != null &&
        index == _activeNavigationIndex &&
        index >= 0 &&
        index < feed.items.length &&
        _activeNavigationReaderKey == feedReaderKey(feed.items[index])) {
      return active;
    }
    return _readerEntryContext(feed, index);
  }

  void _ensureActiveNavigationEntry(EffectiveFeedState feed) {
    if (_scopeResetPending || feed.items.isEmpty) return;
    final index = _currentIndex.clamp(0, feed.items.length - 1).toInt();
    if (_activeNavigationEntry == null) {
      _captureActiveNavigationEntry(feed, index);
      return;
    }
    if (_verticalTransitionActive || _pendingCommittedIndex != null) return;
    final readerKey = feedReaderKey(feed.items[index]);
    final candidate = _readerEntryContext(feed, index);
    if (_activeNavigationReaderKey != readerKey ||
        _activeNavigationIndex != index ||
        !_sameReaderEntry(_activeNavigationEntry!, candidate)) {
      _captureActiveNavigationEntry(feed, index);
    }
  }

  void _captureActiveNavigationEntry(EffectiveFeedState feed, int index) {
    if (index < 0 || index >= feed.items.length) return;
    _activeNavigationEntry = _readerEntryContext(feed, index);
    _activeNavigationReaderKey = feedReaderKey(feed.items[index]);
    _activeNavigationIndex = index;
  }

  void _scheduleNavigationScopeReset(
    EffectiveFeedState feed, {
    required bool resetToFirst,
  }) {
    final serial = ++_scopeResetSerial;
    _scopeResetPending = true;
    _pendingCommittedIndex = null;
    _explicitHapticTargetIndex = null;
    final fallbackIndex = _activeNavigationIndex ?? _currentIndex;
    final targetIndex = feed.items.isEmpty
        ? 0
        : (resetToFirst ? 0 : fallbackIndex)
              .clamp(0, feed.items.length - 1)
              .toInt();
    _currentIndex = targetIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || serial != _scopeResetSerial) return;
      final latest = ref.read(effectiveFeedProvider);
      final latestIndex = latest.items.isEmpty
          ? 0
          : targetIndex.clamp(0, latest.items.length - 1).toInt();
      if (latest.items.isNotEmpty && _controller.hasClients) {
        _controller.jumpToPage(latestIndex);
      }
      if (!mounted || serial != _scopeResetSerial) return;
      setState(() {
        _verticalTransitionActive = false;
        _scopeResetPending = false;
        _currentIndex = latestIndex;
        if (latest.items.isNotEmpty) {
          _captureActiveNavigationEntry(latest, latestIndex);
        }
      });
    });
  }

  bool _sameReaderEntry(ReaderEntryContext left, ReaderEntryContext right) =>
      left.source == right.source &&
      left.queueMembership == right.queueMembership &&
      left.originReaderKey == right.originReaderKey &&
      left.expectedAuthEpoch == right.expectedAuthEpoch &&
      left.accountGeneration == right.accountGeneration &&
      left.libraryRevision == right.libraryRevision &&
      left.recommendationBatchId == right.recommendationBatchId;

  bool _feedSnapshotIsCurrent(
    EffectiveFeedState snapshot,
    EffectiveFeedState current,
    int index,
  ) {
    if (snapshot.personalized != current.personalized ||
        snapshot.authEpoch != current.authEpoch ||
        snapshot.accountGeneration != current.accountGeneration ||
        snapshot.mode != current.mode ||
        snapshot.queueAuthority != current.queueAuthority ||
        snapshot.libraryRevision != current.libraryRevision ||
        snapshot.category != current.category ||
        snapshot.recommendationBatchId != current.recommendationBatchId ||
        index < 0 ||
        index >= snapshot.items.length ||
        index >= current.items.length) {
      return false;
    }
    return snapshot.items[index].versionKey == current.items[index].versionKey;
  }

  QueueNavigationDecision _coordinatedDecision({
    required int currentIndex,
    required int targetIndex,
  }) {
    final feed = ref.read(effectiveFeedProvider);
    final scope = ref.read(libraryDisplayScopeProvider);
    final pending = scope == null
        ? const LibraryPendingIntentCounts.empty()
        : ref.read(libraryPendingIntentsProvider(scope)).asData?.value ??
              const LibraryPendingIntentCounts.empty();
    final readerKey = currentIndex >= 0 && currentIndex < feed.items.length
        ? feedReaderKey(feed.items[currentIndex])
        : null;
    final interaction = readerKey == null
        ? const ReaderInteractionState()
        : ref.read(readerInteractionControllerProvider(readerKey));
    return QueueNavigationCoordinator(
      telemetry: ref.read(telemetrySinkProvider),
    ).decide(
      feed: _navigationFeedState(feed),
      pendingIntents: pending,
      entry:
          _activeNavigationEntry ??
          _readerEntryContext(
            feed,
            currentIndex.clamp(0, feed.items.length - 1).toInt(),
          ),
      interaction: interaction,
      currentAuthEpoch: feed.authEpoch,
      currentAccountGeneration: feed.accountGeneration,
      currentIndex: currentIndex,
      targetIndex: targetIndex,
    );
  }

  ReadingFeedState _navigationFeedState(EffectiveFeedState feed) =>
      ReadingFeedState(
        mode: feed.mode,
        queueAuthority: feed.queueAuthority,
        items: feed.items,
        queueItems: feed.queueItems,
        recommendationItems: feed.recommendationItems,
        recommendationProvenance: feed.recommendationProvenance,
        recommendationBatchId: feed.recommendationBatchId,
        recommendationMode: feed.recommendationMode,
        forYouAvailable: feed.forYouAvailable,
        libraryRevision: feed.libraryRevision,
        activeToReadCount: feed.activeToReadCount,
        nextCursor: feed.nextCursor,
        loadingInitial: feed.loadingInitial,
        loadingMore: feed.loadingMore,
        offline: feed.offline,
        recoverableError: feed.errorMessage,
        authEpoch: feed.authEpoch,
        accountGeneration: feed.accountGeneration,
      );

  void _announceNavigationDecision(QueueNavigationDecision decision) {
    final message = switch (decision.disposition) {
      QueueNavigationDisposition.blockedByInteraction =>
        'Finish the current selection or reader tool before changing papers.',
      QueueNavigationDisposition.verificationRequiresConnection =>
        'Queue verification requires connection.',
      QueueNavigationDisposition.checkingQueue =>
        'Checking your To Read queue…',
      QueueNavigationDisposition.cancelRecommendationNavigation =>
        'Returning to To Read after your save.',
      QueueNavigationDisposition.naturalStop =>
        'This paper remains active. Choose a Library state when you are ready.',
      QueueNavigationDisposition.staleAccountScope =>
        'The account changed. Refreshing the reading queue.',
      QueueNavigationDisposition.returnToOrigin =>
        'Return to the paper that opened this branch.',
      QueueNavigationDisposition.unavailable =>
        'The next paper is not available safely yet.',
      QueueNavigationDisposition.navigate ||
      QueueNavigationDisposition.requestCurrentFeedPage => null,
    };
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _retry(EffectiveFeedState feed) {
    if (feed.personalized) {
      unawaited(() async {
        await ref.read(paperImportDraftControllerProvider.notifier).reload();
        if (!mounted) return;
        await ref
            .read(readingFeedControllerProvider.notifier)
            .refresh(force: true);
      }());
    } else {
      unawaited(ref.read(feedControllerProvider.notifier).loadInitial());
    }
  }

  void _addPaper() {
    unawaited(showAccountAddPaperFlow(context: context, ref: ref));
  }

  void _retryImportDraft(PaperImportDraft draft) {
    unawaited(
      showAccountAddPaperFlow(context: context, ref: ref, resumeDraft: draft),
    );
  }

  void _cancelImportDraft(PaperImportDraft draft) {
    unawaited(
      ref
          .read(paperImportDraftControllerProvider.notifier)
          .remove(draft.operationId),
    );
  }

  void _reloadImportDrafts() {
    unawaited(ref.read(paperImportDraftControllerProvider.notifier).reload());
  }

  Future<void> _confirmClearImportDrafts() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear unresolved drafts?'),
        content: const Text(
          'This removes only the private Add Paper drafts stored on this '
          'device. No paper in your Library is removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep drafts'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear drafts'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(paperImportDraftControllerProvider.notifier).clearCurrent();
  }

  void _selectGuestCategory(String? category) {
    unawaited(
      ref.read(feedControllerProvider.notifier).loadInitial(category: category),
    );
  }

  Future<void> _editGuestCategories() async {
    if (_guestCategorySheetOpen || !mounted) return;
    _guestCategorySheetOpen = true;
    final current = ref
        .read(guestDiscoveryPreferencesControllerProvider)
        .preferences;
    final selected = await showGuestCategoryOnboardingSheet(
      context: context,
      initialSelection: current.categories,
    );
    _guestCategorySheetOpen = false;
    if (selected == null || !mounted) return;
    final saved = await ref
        .read(guestDiscoveryPreferencesControllerProvider.notifier)
        .complete(selected);
    if (!mounted) return;
    if (saved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Category choices could not be saved. Public Recent remains available.',
          ),
        ),
      );
      return;
    }
    _guestPreferenceApplied = true;
    _selectGuestCategory(
      saved.categories.isEmpty ? null : saved.categories.first,
    );
  }

  void _scheduleCommittedPage(EffectiveFeedState feed) {
    if (_pendingCommittedIndex != null) return;
    if (_currentIndex < 0 || _currentIndex >= feed.items.length) return;
    final index = _currentIndex;
    final signature = _commitSignature(feed, index);
    if (_lastCommittedSignature == signature) return;
    _lastCommittedSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastCommittedSignature != signature) return;
      final current = ref.read(effectiveFeedProvider);
      if (!_feedSnapshotIsCurrent(feed, current, index)) return;
      _captureActiveNavigationEntry(current, index);
      ref
          .read(appRestorationControllerProvider.notifier)
          .setFeedPosition(index, current.items[index]);
      if (current.personalized) {
        ref.read(readingFeedControllerProvider.notifier).onCommittedPage(index);
      } else {
        ref.read(feedControllerProvider.notifier).onCommittedPage(index);
      }
    });
  }

  void _settleCommittedPage(EffectiveFeedState feed) {
    final index = _pendingCommittedIndex;
    _pendingCommittedIndex = null;
    if (index == null || index < 0 || index >= feed.items.length) return;
    final committed = _commitPage(feed, index);
    final explicitCommit = _explicitHapticTargetIndex == index;
    _explicitHapticTargetIndex = null;
    if (committed && explicitCommit) unawaited(_provideCommitHaptic());
  }

  bool _commitPage(EffectiveFeedState feed, int index) {
    final current = ref.read(effectiveFeedProvider);
    if (_scopeResetPending || !_feedSnapshotIsCurrent(feed, current, index)) {
      return false;
    }
    _captureActiveNavigationEntry(current, index);
    final signature = _commitSignature(feed, index);
    if (_lastCommittedSignature == signature) return false;
    _lastCommittedSignature = signature;
    ref
        .read(appRestorationControllerProvider.notifier)
        .setFeedPosition(index, current.items[index]);
    _recordCommittedPage(feed, index);
    if (feed.personalized) {
      ref.read(readingFeedControllerProvider.notifier).onCommittedPage(index);
    } else {
      ref.read(feedControllerProvider.notifier).onCommittedPage(index);
    }
    return true;
  }

  Future<void> _provideCommitHaptic() async {
    if (!mounted) return;
    try {
      await HapticFeedback.selectionClick();
    } on Object {
      // Haptics are optional and occur only after an explicit navigation
      // action reaches its committed page.
    }
  }

  void _recordCommittedPage(EffectiveFeedState feed, int index) {
    final telemetry = ref.read(telemetrySinkProvider);
    emitTelemetry(telemetry, PakPerkTelemetryEvent.paperPageCommitted, {
      'source': switch (feed.mode) {
        ReadingFeedMode.toRead => 'to_read',
        ReadingFeedMode.recommendations => 'reading_recommendations',
        _ => 'public_discovery',
      },
      'position_bucket': index.clamp(0, 100),
    });
    final interactionContext = _interactionContext(feed, index);
    ref
        .read(interactionEventBatcherProvider)
        .record(
          eventType: PaperInteractionEventType.impressionQualified,
          paperId: feed.items[index].paperId,
          feedMode: interactionContext.feedMode,
          batchId: interactionContext.batchId,
          position: interactionContext.position,
        );
    final recommendation = feed.recommendationItemAt(index);
    if (recommendation != null &&
        recommendation.source.isPersonalizedRecommendation &&
        recommendation.recommendation != null) {
      emitTelemetry(
        telemetry,
        PakPerkTelemetryEvent.recommendationCardRendered,
        {
          'queue_authority': _queueAuthorityTelemetry(feed.queueAuthority),
          'server_active_count': switch (feed.activeToReadCount) {
            0 => 'zero',
            final int value when value > 0 => 'nonzero',
            _ => 'unknown',
          },
          'policy_consistent':
              feed.queueAuthority == QueueAuthority.serverConfirmedEmpty &&
              feed.activeToReadCount == 0,
        },
      );
    }
  }

  String _commitSignature(EffectiveFeedState feed, int index) => jsonEncode([
    index,
    feed.personalized,
    feed.authEpoch,
    feed.accountGeneration,
    feed.mode.name,
    feed.queueAuthority.name,
    feed.category,
    feed.nextCursor,
    for (final paper in feed.items) [paper.paperId, paper.arxivId],
  ]);

  PaperInteractionContext _interactionContext(
    EffectiveFeedState feed,
    int index,
  ) => PaperInteractionContext(
    feedMode: switch (feed.mode) {
      ReadingFeedMode.toRead => InteractionFeedMode.toRead,
      ReadingFeedMode.recommendations => switch (feed.recommendationMode) {
        ReadingFeedRecommendationMode.recent => InteractionFeedMode.recent,
        ReadingFeedRecommendationMode.following =>
          InteractionFeedMode.following,
        ReadingFeedRecommendationMode.forYou => InteractionFeedMode.forYou,
        ReadingFeedRecommendationMode.explore => InteractionFeedMode.explore,
        null => null,
      },
      ReadingFeedMode.guestDiscovery => InteractionFeedMode.recent,
      ReadingFeedMode.checkingQueue ||
      ReadingFeedMode.finishingQueue ||
      ReadingFeedMode.unavailable => null,
    },
    batchId: feed.mode == ReadingFeedMode.recommendations
        ? feed.recommendationBatchIdAt(index)
        : null,
    position: feed.mode == ReadingFeedMode.recommendations
        ? feed.recommendationPositionAt(index)
        : index,
  );
}

bool _showsNaturalQueueEnd(EffectiveFeedState feed) =>
    feed.personalized &&
    feed.mode == ReadingFeedMode.toRead &&
    !feed.loadingMore &&
    feed.nextCursor == null &&
    feed.activeToReadCount != null &&
    feed.activeToReadCount! > 0 &&
    feed.items.length >= feed.activeToReadCount!;

class _RecommendationModeControls extends StatelessWidget {
  const _RecommendationModeControls({
    required this.selected,
    required this.forYouAvailable,
    required this.onSelected,
  });

  final ReadingFeedRecommendationMode? selected;
  final bool forYouAvailable;
  final ValueChanged<ReadingFeedRecommendationMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final eligibleSelection =
        selected == ReadingFeedRecommendationMode.forYou && !forYouAvailable
        ? null
        : selected;
    final selectedLabel = eligibleSelection == null
        ? 'Profile default'
        : _modeLabel(eligibleSelection);
    return Semantics(
      key: const ValueKey('recommendation-mode-controls'),
      container: true,
      label:
          'Discovery mode. To Read is confirmed empty. Selected $selectedLabel.',
      explicitChildNodes: true,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PakPerkSpacing.md,
            PakPerkSpacing.xs,
            PakPerkSpacing.md,
            PakPerkSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Discovery', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: PakPerkSpacing.xxs),
              _ScrollableModeSegments<ReadingFeedRecommendationMode>(
                segments: [
                  for (final mode in ReadingFeedRecommendationMode.values)
                    if (mode != ReadingFeedRecommendationMode.forYou ||
                        forYouAvailable)
                      ButtonSegment<ReadingFeedRecommendationMode>(
                        value: mode,
                        label: Text(_modeLabel(mode)),
                      ),
                ],
                selected: eligibleSelection == null
                    ? const {}
                    : {eligibleSelection},
                emptySelectionAllowed: true,
                onSelected: (selection) {
                  if (selection.isNotEmpty) onSelected(selection.single);
                },
              ),
              if (!forYouAvailable) ...[
                const SizedBox(height: PakPerkSpacing.xxs),
                Text(
                  'For You is available when personalization is on.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadingBriefEntry extends StatelessWidget {
  const _ReadingBriefEntry({required this.mode, required this.onOpen});

  final ReadingFeedMode mode;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final queueBrief = mode == ReadingFeedMode.toRead;
    final detail = queueBrief
        ? 'A bounded view of To Read. Pause anytime; progress never clears your queue.'
        : 'A bounded discovery view. Pause anytime; there is no streak to keep.';
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PakPerkSizes.minimumInteractive,
        ),
        child: ListTile(
          key: const ValueKey('feed-reading-brief-entry'),
          leading: const Icon(Icons.menu_book_outlined),
          title: const Text('Today’s reading brief'),
          subtitle: Text(detail),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onOpen,
        ),
      ),
    );
  }
}

class _GuestDiscoveryControls extends StatelessWidget {
  const _GuestDiscoveryControls({
    required this.exploreEnabled,
    required this.onExplore,
  });

  final bool exploreEnabled;
  final VoidCallback? onExplore;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('guest-discovery-controls'),
    container: true,
    label:
        'Public discovery. Recent selected. Explore search '
        '${exploreEnabled ? 'available' : 'unavailable in this build'}.',
    explicitChildNodes: true,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PakPerkSpacing.md,
          PakPerkSpacing.xs,
          PakPerkSpacing.md,
          PakPerkSpacing.sm,
        ),
        child: _ScrollableModeSegments<_GuestDiscoveryMode>(
          segments: [
            const ButtonSegment<_GuestDiscoveryMode>(
              value: _GuestDiscoveryMode.recent,
              label: Text('Recent'),
            ),
            ButtonSegment<_GuestDiscoveryMode>(
              value: _GuestDiscoveryMode.explore,
              enabled: exploreEnabled,
              label: const Text('Explore'),
            ),
          ],
          selected: const {_GuestDiscoveryMode.recent},
          onSelected: (selection) {
            if (selection.single == _GuestDiscoveryMode.explore) {
              onExplore?.call();
            }
          },
        ),
      ),
    ),
  );
}

enum _GuestDiscoveryMode { recent, explore }

class _ScrollableModeSegments<T> extends StatelessWidget {
  const _ScrollableModeSegments({
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.emptySelectionAllowed = false,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>> onSelected;
  final bool emptySelectionAllowed;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('discovery-mode-horizontal-scroll'),
    scrollDirection: Axis.horizontal,
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: PakPerkSizes.minimumInteractive,
      ),
      child: SegmentedButton<T>(
        segments: segments,
        selected: selected,
        emptySelectionAllowed: emptySelectionAllowed,
        showSelectedIcon: false,
        onSelectionChanged: onSelected,
      ),
    ),
  );
}

class _QueueContextHeader extends StatelessWidget {
  const _QueueContextHeader({required this.item, this.atNaturalEnd = false});

  final ReadingFeedQueuePresentation? item;
  final bool atNaturalEnd;

  @override
  Widget build(BuildContext context) {
    final value = item;
    final savedDate = value == null
        ? null
        : MaterialLocalizations.of(
            context,
          ).formatMediumDate(value.savedAt.toLocal());
    final details = atNaturalEnd
        ? 'End of the loaded queue. Your saved papers remain in To Read.'
        : value == null
        ? 'Queue details are syncing.'
        : '${value.state.label}. ${value.provenanceLabel}. Saved $savedDate.';
    final note = value?.privateNote;
    final semantics = StringBuffer(
      'To Read. Discovery resumes when To Read is empty. $details',
    );
    if (note != null) semantics.write(' Private note: $note.');

    return Semantics(
      key: const ValueKey('to-read-queue-context'),
      container: true,
      label: semantics.toString(),
      child: ExcludeSemantics(
        child: Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              PakPerkSpacing.md,
              PakPerkSpacing.sm,
              PakPerkSpacing.md,
              PakPerkSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.bookmarks_outlined, size: 20),
                    ),
                    const SizedBox(width: PakPerkSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'To Read',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          Text(
                            atNaturalEnd
                                ? 'Reading to the end does not clear To Read.'
                                : 'Discovery resumes when To Read is empty.',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: PakPerkSpacing.xs),
                Text(details, style: Theme.of(context).textTheme.bodySmall),
                if (note != null) ...[
                  const SizedBox(height: PakPerkSpacing.xxs),
                  Text(
                    'Why save this? $note',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NaturalQueueEnd extends StatelessWidget {
  const _NaturalQueueEnd({required this.onBackToFirst});

  final VoidCallback onBackToFirst;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.all(PakPerkSpacing.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Semantics(
            key: const ValueKey('to-read-natural-end'),
            container: true,
            liveRegion: true,
            label:
                'End of this queue view. Papers remain in To Read until you '
                'mark them Reviewed or Archive them. Discovery remains paused.',
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bookmarks_outlined,
                    size: 52,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: PakPerkSpacing.md),
                  Text(
                    'You’ve reached the end of this queue view',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: PakPerkSpacing.sm),
                  Text(
                    'Nothing was removed. Papers stay in To Read until you '
                    'mark them Reviewed or Archive them. Discovery remains '
                    'paused.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.lg),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: FilledButton.tonalIcon(
                      onPressed: onBackToFirst,
                      icon: const Icon(Icons.vertical_align_top_rounded),
                      label: const Text('Back to first paper'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _modeLabel(ReadingFeedRecommendationMode mode) => switch (mode) {
  ReadingFeedRecommendationMode.recent => 'Recent',
  ReadingFeedRecommendationMode.following => 'Following',
  ReadingFeedRecommendationMode.forYou => 'For You',
  ReadingFeedRecommendationMode.explore => 'Explore',
};

String _queueAuthorityTelemetry(QueueAuthority authority) =>
    switch (authority) {
      QueueAuthority.unknown => 'unknown',
      QueueAuthority.localNonEmpty => 'local_non_empty',
      QueueAuthority.pendingSave => 'pending_save',
      QueueAuthority.serverConfirmedNonEmpty => 'server_non_empty',
      QueueAuthority.serverConfirmedEmpty => 'server_empty',
      QueueAuthority.stale => 'stale',
    };

class _ReadingFeedStatusScaffold extends StatelessWidget {
  const _ReadingFeedStatusScaffold({
    required this.mode,
    required this.authority,
    required this.offline,
    required this.errorMessage,
    required this.loading,
    required this.onRetry,
    required this.onAddPaper,
    required this.onOpenSearch,
    required this.importDrafts,
    required this.importDraftError,
    required this.onRetryImportDraft,
    required this.onCancelImportDraft,
    required this.onReloadImportDrafts,
    required this.onClearImportDrafts,
    this.header,
  });

  final ReadingFeedMode mode;
  final QueueAuthority authority;
  final bool offline;
  final String? errorMessage;
  final bool loading;
  final VoidCallback onRetry;
  final VoidCallback? onAddPaper;
  final VoidCallback? onOpenSearch;
  final List<PaperImportDraft> importDrafts;
  final String? importDraftError;
  final ValueChanged<PaperImportDraft> onRetryImportDraft;
  final ValueChanged<PaperImportDraft> onCancelImportDraft;
  final VoidCallback onReloadImportDrafts;
  final VoidCallback onClearImportDrafts;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _statusCopy;
    final showProgress =
        importDraftError == null &&
        (loading ||
            mode == ReadingFeedMode.checkingQueue ||
            mode == ReadingFeedMode.finishingQueue ||
            authority == QueueAuthority.pendingSave);
    final retryable =
        !showProgress &&
        (mode == ReadingFeedMode.unavailable ||
            errorMessage != null ||
            importDraftError != null);
    final effectiveError = importDraftError ?? errorMessage;
    final showDraftManagement =
        importDrafts.isNotEmpty || importDraftError != null;
    return Scaffold(
      floatingActionButton: _FeedFloatingActions(onOpenSearch: onOpenSearch),
      body: Column(
        children: [
          if (header != null) SafeArea(bottom: false, child: header!),
          Expanded(
            child: SafeArea(
              minimum: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Semantics(
                              liveRegion: true,
                              container: true,
                              label:
                                  '${status.$1}. ${effectiveError ?? status.$2}',
                              child: ExcludeSemantics(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (showProgress)
                                      const SizedBox.square(
                                        dimension: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                        ),
                                      )
                                    else
                                      Icon(
                                        status.$3,
                                        size: 44,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    const SizedBox(height: 18),
                                    Text(
                                      status.$1,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      effectiveError ?? status.$2,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (showDraftManagement) ...[
                              const SizedBox(height: PakPerkSpacing.lg),
                              _UnresolvedImportDrafts(
                                drafts: importDrafts,
                                errorMessage: importDraftError,
                                onRetry: onRetryImportDraft,
                                onCancel: onCancelImportDraft,
                                onReload: onReloadImportDrafts,
                                onClear: onClearImportDrafts,
                              ),
                            ],
                            if (retryable || onAddPaper != null) ...[
                              const SizedBox(height: 20),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 12,
                                runSpacing: 10,
                                children: [
                                  if (onAddPaper != null)
                                    FilledButton.icon(
                                      key: const ValueKey(
                                        'feed-empty-add-paper',
                                      ),
                                      onPressed: onAddPaper,
                                      icon: const Icon(Icons.add_rounded),
                                      label: const Text('Add a paper'),
                                    ),
                                  if (retryable)
                                    FilledButton.tonalIcon(
                                      onPressed: onRetry,
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('Try again'),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  (String, String, IconData) get _statusCopy => switch (mode) {
    ReadingFeedMode.checkingQueue => (
      'Checking To Read',
      'Making sure your saved queue is up to date.',
      Icons.bookmark_outline_rounded,
    ),
    ReadingFeedMode.finishingQueue => (
      'Finishing your queue',
      'Recommendations will appear after the final removal is confirmed.',
      Icons.sync_rounded,
    ),
    ReadingFeedMode.toRead when authority == QueueAuthority.pendingSave => (
      'Adding to To Read',
      'Your paper will appear here as soon as it is ready. Discovery stays hidden until To Read is confirmed empty.',
      Icons.bookmark_add_outlined,
    ),
    ReadingFeedMode.toRead => (
      'To Read is syncing',
      'Your saved papers will appear here shortly. Discovery stays hidden until To Read is confirmed empty.',
      Icons.bookmarks_outlined,
    ),
    ReadingFeedMode.recommendations => (
      'You’re all caught up',
      'There are no recommendations to show right now.',
      Icons.check_circle_outline_rounded,
    ),
    ReadingFeedMode.unavailable when offline => (
      'To Read is unavailable offline',
      'Reconnect to confirm your queue before showing recommendations.',
      Icons.cloud_off_outlined,
    ),
    ReadingFeedMode.unavailable => (
      'To Read is temporarily unavailable',
      'Your queue is protected. Try again when you’re ready.',
      Icons.info_outline_rounded,
    ),
    ReadingFeedMode.guestDiscovery => (
      'No papers yet',
      'Try refreshing the discovery feed.',
      Icons.article_outlined,
    ),
  };
}

class _UnresolvedImportDrafts extends StatelessWidget {
  const _UnresolvedImportDrafts({
    required this.drafts,
    required this.errorMessage,
    required this.onRetry,
    required this.onCancel,
    required this.onReload,
    required this.onClear,
  });

  final List<PaperImportDraft> drafts;
  final String? errorMessage;
  final ValueChanged<PaperImportDraft> onRetry;
  final ValueChanged<PaperImportDraft> onCancel;
  final VoidCallback onReload;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      key: const ValueKey('unresolved-import-drafts'),
      container: true,
      label:
          'Unresolved Add Paper drafts. These device-only drafts keep '
          'Discovery hidden until they are retried or cancelled.',
      child: ExcludeSemantics(
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(PakPerkSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.edit_note_rounded),
                    const SizedBox(width: PakPerkSpacing.xs),
                    Expanded(
                      child: Text(
                        'Unresolved Add Paper',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (drafts.isNotEmpty)
                      TextButton(
                        key: const ValueKey('clear-import-drafts'),
                        onPressed: onClear,
                        child: const Text('Clear all'),
                      ),
                  ],
                ),
                const SizedBox(height: PakPerkSpacing.xs),
                Text(
                  errorMessage ??
                      'These private drafts stay only on this device. '
                          'Discovery remains hidden until you retry or cancel '
                          'each one.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: PakPerkSpacing.sm),
                  Wrap(
                    spacing: PakPerkSpacing.xs,
                    runSpacing: PakPerkSpacing.xs,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: PakPerkSizes.minimumInteractive,
                        ),
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('reload-import-drafts'),
                          onPressed: onReload,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry drafts'),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: PakPerkSizes.minimumInteractive,
                        ),
                        child: OutlinedButton(
                          key: const ValueKey('clear-unreadable-import-drafts'),
                          onPressed: onClear,
                          child: const Text('Clear local drafts'),
                        ),
                      ),
                    ],
                  ),
                ],
                for (final draft in drafts) ...[
                  const SizedBox(height: PakPerkSpacing.sm),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(PakPerkSpacing.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            draft.displayLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: PakPerkSpacing.xxs),
                          Text(
                            draft.status ==
                                    PaperImportDraftStatus.retryableFailure
                                ? 'Ready to retry'
                                : 'Import interrupted',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: PakPerkSpacing.xs),
                          Wrap(
                            spacing: PakPerkSpacing.xs,
                            runSpacing: PakPerkSpacing.xs,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: PakPerkSizes.minimumInteractive,
                                ),
                                child: FilledButton.tonalIcon(
                                  onPressed: () => onRetry(draft),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Retry'),
                                ),
                              ),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: PakPerkSizes.minimumInteractive,
                                ),
                                child: OutlinedButton(
                                  onPressed: () => onCancel(draft),
                                  child: const Text('Cancel draft'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedFloatingActions extends StatelessWidget {
  const _FeedFloatingActions({this.onOpenSearch, this.onAddPaper});

  final VoidCallback? onOpenSearch;
  final VoidCallback? onAddPaper;

  @override
  Widget build(BuildContext context) {
    if (onOpenSearch == null && onAddPaper == null) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (onOpenSearch != null)
            FloatingActionButton(
              key: const ValueKey('feed-search'),
              heroTag: 'feed-search',
              tooltip: 'Search papers',
              onPressed: onOpenSearch,
              child: const Icon(Icons.search_rounded),
            ),
          if (onOpenSearch != null && onAddPaper != null)
            const SizedBox(height: 12),
          if (onAddPaper != null)
            FloatingActionButton.extended(
              key: const ValueKey('feed-add-paper'),
              heroTag: 'feed-add-paper',
              tooltip: 'Add a paper',
              onPressed: onAddPaper,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add paper'),
            ),
        ],
      ),
    );
  }
}
