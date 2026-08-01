import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';
import '../../core/telemetry/telemetry.dart';
import '../../core/widgets/responsive_reader_frame.dart';
import '../../core/widgets/status_widgets.dart';
import '../../design_system/motion.dart';
import '../paper_reader/paper_reader.dart';
import '../paper_reader/reader_navigation_controller.dart';
import 'feed_controller.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  late final PageController _controller;
  late int _currentIndex;
  int? _pendingCommittedIndex;
  String? _lastCommittedSignature;

  @override
  void initState() {
    super.initState();
    _currentIndex = ref
        .read(appRestorationControllerProvider)
        .feedIndex
        .clamp(0, 1000000);
    _controller = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(feedControllerProvider);
    final routes = ref.watch(appRestorationControllerProvider).routeStack;
    final readBranchActive =
        ref.watch(activeAppBranchProvider) == AppBranch.read;
    if (feed.loadingInitial && feed.items.isEmpty) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: 'Loading the paper feed',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      );
    }
    if (feed.items.isEmpty) {
      return Scaffold(
        body: SafeArea(
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
                    onPressed: () =>
                        ref.read(feedControllerProvider.notifier).loadInitial(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_currentIndex >= feed.items.length) {
      _currentIndex = feed.items.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) _controller.jumpToPage(_currentIndex);
      });
    }
    if (readBranchActive && routes.isEmpty) {
      _scheduleCommittedPage(feed);
    }

    return Scaffold(
      body: Column(
        children: [
          if (feed.origin == DataOrigin.bundledDemo)
            const SafeArea(
              bottom: false,
              minimum: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: BundledDemoNotice(),
            ),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 &&
                    notification.metrics.axis == Axis.vertical) {
                  _settleCommittedPage(feed);
                }
                return false;
              },
              child: PageView.builder(
                key: const PageStorageKey('vertical-paper-feed'),
                controller: _controller,
                scrollDirection: Axis.vertical,
                itemCount: feed.items.length,
                onPageChanged: (index) {
                  final changed = index != _currentIndex;
                  setState(() {
                    _currentIndex = index;
                    if (changed) _pendingCommittedIndex = index;
                  });
                  ref
                      .read(appRestorationControllerProvider.notifier)
                      .setFeedPosition(index, feed.items[index]);
                },
                itemBuilder: (context, index) {
                  final paper = feed.items[index];
                  final readerKey = feedReaderKey(paper);
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
                      onPreviousPaper: index > 0
                          ? () => _goToPaper(index - 1)
                          : null,
                      onNextPaper: index + 1 < feed.items.length
                          ? () => _goToPaper(index + 1)
                          : null,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _goToPaper(int index) {
    if (platformPrefersReducedMotion(context)) {
      _controller.jumpToPage(index);
      return;
    }
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _scheduleCommittedPage(FeedState feed) {
    if (_pendingCommittedIndex != null) return;
    if (_currentIndex < 0 || _currentIndex >= feed.items.length) return;
    final index = _currentIndex;
    final signature = _commitSignature(feed, index);
    if (_lastCommittedSignature == signature) return;
    _lastCommittedSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastCommittedSignature != signature) return;
      ref
          .read(appRestorationControllerProvider.notifier)
          .setFeedPosition(index, feed.items[index]);
      ref.read(feedControllerProvider.notifier).onCommittedPage(index);
    });
  }

  void _settleCommittedPage(FeedState feed) {
    final index = _pendingCommittedIndex;
    _pendingCommittedIndex = null;
    if (index == null || index < 0 || index >= feed.items.length) return;
    if (_commitPage(feed, index)) unawaited(_provideCommitHaptic());
  }

  bool _commitPage(FeedState feed, int index) {
    final signature = _commitSignature(feed, index);
    if (_lastCommittedSignature == signature) return false;
    _lastCommittedSignature = signature;
    _recordCommittedPage(feed, index);
    ref.read(feedControllerProvider.notifier).onCommittedPage(index);
    return true;
  }

  Future<void> _provideCommitHaptic() async {
    if (!mounted || platformPrefersReducedMotion(context)) return;
    try {
      await HapticFeedback.selectionClick();
    } on Object {
      // Haptics are optional platform affordances and never block navigation.
    }
  }

  void _recordCommittedPage(FeedState feed, int index) {
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      PakPerkTelemetryEvent.paperPageCommitted,
      {'source': 'read_feed', 'position_bucket': index.clamp(0, 100)},
    );
  }

  String _commitSignature(FeedState feed, int index) => jsonEncode([
    index,
    feed.category,
    feed.nextCursor,
    for (final paper in feed.items) [paper.paperId, paper.arxivId],
  ]);
}
