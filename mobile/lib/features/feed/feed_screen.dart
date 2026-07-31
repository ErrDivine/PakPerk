import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/reader_state.dart';
import '../../core/widgets/responsive_reader_frame.dart';
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

  @override
  void initState() {
    super.initState();
    _currentIndex =
        ref.read(appRestorationControllerProvider).feedIndex.clamp(0, 1000000);
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

    return Scaffold(
      body: PageView.builder(
        key: const PageStorageKey('vertical-paper-feed'),
        controller: _controller,
        scrollDirection: Axis.vertical,
        itemCount: feed.items.length,
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          ref
              .read(appRestorationControllerProvider.notifier)
              .setFeedIndex(index);
          if (index >= feed.items.length - 3) {
            ref.read(feedControllerProvider.notifier).loadMore();
          }
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
                  readBranchActive && index == _currentIndex && routes.isEmpty,
              onPreviousPaper: index > 0 ? () => _goToPaper(index - 1) : null,
              onNextPaper: index + 1 < feed.items.length
                  ? () => _goToPaper(index + 1)
                  : null,
            ),
          );
        },
      ),
    );
  }

  void _goToPaper(int index) {
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }
}
