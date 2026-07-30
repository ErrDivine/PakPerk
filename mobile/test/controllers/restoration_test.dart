import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  test('navigation stack and exact reader state serialize and restore', () {
    const reader = ReaderNavigationState(
      stageIndex: 2,
      abstractOffset: 81.5,
      introductionOffset: 912.25,
      connectionsOffset: 244,
      chatSheetOpen: true,
      chatThreadId: 'thread-42',
      prepareRequested: true,
    );
    final original = AppRestorationState(
      feedIndex: 4,
      routeStack: [PaperRouteEntry(routeId: 'route-1', paper: samplePaper)],
      readerStates: const {'feed:source': reader},
    );

    final restored = AppRestorationState.fromJson(original.toJson());
    final value = restored.readerState('feed:source');
    expect(restored.feedIndex, 4);
    expect(restored.routeStack.single.paper.paperId, samplePaper.paperId);
    expect(value.stageIndex, 2);
    expect(value.introductionOffset, 912.25);
    expect(value.chatSheetOpen, isTrue);
    expect(value.chatThreadId, 'thread-42');
    expect(value.prepareRequested, isTrue);
  });

  test('popping a connection keeps origin reader state intact', () async {
    final store = MemoryLocalStore();
    final controller = AppRestorationController(
      store: store,
      initial: const AppRestorationState(),
    );
    controller.updateReader(
      'feed:source',
      (_) => const ReaderNavigationState(
        stageIndex: 2,
        connectionsOffset: 370,
        chatSheetOpen: true,
      ),
    );
    controller.pushPaper(samplePaper);
    expect(controller.state.routeStack, hasLength(1));

    expect(controller.popPaper(), isTrue);
    expect(controller.state.routeStack, isEmpty);
    expect(controller.state.readerState('feed:source').connectionsOffset, 370);
    expect(controller.state.readerState('feed:source').chatSheetOpen, isTrue);
    await controller.flush();
    expect(store.restoration.readerState('feed:source').stageIndex, 2);
    controller.dispose();
  });

  test('route reader state is isolated by arXiv version', () {
    final current = PaperRouteEntry(routeId: 'route-1', paper: samplePaper);
    final newer = PaperRouteEntry(
      routeId: 'route-1',
      paper: PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '1706.03762v8',
      ),
    );

    expect(current.readerKey, 'route:route-1:${samplePaper.arxivId}');
    expect(newer.readerKey, isNot(current.readerKey));
    expect(feedReaderKey(newer.paper), isNot(feedReaderKey(current.paper)));
  });
}
