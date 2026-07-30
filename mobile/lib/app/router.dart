import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/paper.dart';
import '../core/models/reader_state.dart';
import '../core/widgets/responsive_reader_frame.dart';
import '../features/feed/feed_screen.dart';
import '../features/paper_reader/paper_metadata_controller.dart';
import '../features/paper_reader/paper_reader.dart';
import '../features/paper_reader/reader_navigation_controller.dart';

class PakPerkRouter extends ConsumerWidget {
  const PakPerkRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoration = ref.watch(appRestorationControllerProvider);
    final pages = <Page<void>>[
      const MaterialPage<void>(
        key: ValueKey('feed-route'),
        name: '/',
        child: FeedScreen(),
      ),
      for (final entry in restoration.routeStack)
        MaterialPage<void>(
          key: ValueKey('paper-route-${entry.routeId}'),
          name: '/paper/${entry.paper.paperId}',
          child: PaperRouteScreen(entry: entry),
        ),
    ];
    return Navigator(
      restorationScopeId: 'pakperk-navigator',
      pages: pages,
      onDidRemovePage: (page) {
        if (page is! MaterialPage<void>) return;
        final child = page.child;
        if (child is! PaperRouteScreen) return;
        ref
            .read(appRestorationControllerProvider.notifier)
            .popPaper(routeId: child.entry.routeId);
      },
    );
  }
}

class PaperRouteScreen extends ConsumerStatefulWidget {
  const PaperRouteScreen({required this.entry, super.key});

  final PaperRouteEntry entry;

  @override
  ConsumerState<PaperRouteScreen> createState() => _PaperRouteScreenState();
}

class _PaperRouteScreenState extends ConsumerState<PaperRouteScreen> {
  @override
  void initState() {
    super.initState();
    _scheduleMetadataLoad(widget.entry.paper);
  }

  void _scheduleMetadataLoad(PaperSummary snapshot) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.entry.paper.versionKey != snapshot.versionKey) {
        return;
      }
      ref
          .read(paperMetadataControllerProvider(snapshot.versionKey).notifier)
          .ensureLoaded(snapshot);
    });
  }

  @override
  void didUpdateWidget(covariant PaperRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.paper.versionKey != widget.entry.paper.versionKey) {
      _scheduleMetadataLoad(widget.entry.paper);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metadata = ref.watch(
      paperMetadataControllerProvider(widget.entry.paper.versionKey),
    );
    final paper = metadata.paper ?? widget.entry.paper;
    final readerKey = routeReaderKey(widget.entry.routeId, paper);
    final routeStack = ref.watch(appRestorationControllerProvider).routeStack;
    final active = routeStack.isNotEmpty &&
        routeStack.last.routeId == widget.entry.routeId;

    ref.listen<PaperMetadataState>(
      paperMetadataControllerProvider(widget.entry.paper.versionKey),
      (previous, next) {
        final loaded = next.paper;
        if (loaded != null && previous?.paper != loaded) {
          ref
              .read(appRestorationControllerProvider.notifier)
              .updateRoutePaper(widget.entry.routeId, loaded);
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to previous paper',
          onPressed: () => ref
              .read(appRestorationControllerProvider.notifier)
              .popPaper(routeId: widget.entry.routeId),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(paper.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (metadata.refreshing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: ResponsiveReaderFrame(
        key: ValueKey('responsive-reader-$readerKey'),
        child: PaperReader(
          key: ValueKey(readerKey),
          paper: paper,
          readerKey: readerKey,
          isActive: active,
        ),
      ),
    );
  }
}
