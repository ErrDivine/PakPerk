import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';
import 'package:pakperk/features/reader_modes/reader_mode.dart';

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
      feedPaperId: samplePaper.paperId,
      feedArxivId: samplePaper.arxivId,
      routeStack: [PaperRouteEntry(routeId: 'route-1', paper: samplePaper)],
      readerStates: const {'feed:source': reader},
    );

    final restored = AppRestorationState.fromJson(original.toJson());
    final value = restored.readerState('feed:source');
    expect(restored.feedIndex, 4);
    expect(restored.feedPaperId, samplePaper.paperId);
    expect(restored.feedArxivId, samplePaper.arxivId);
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

  test('popping a connection removes its route-scoped reader state', () {
    final store = MemoryLocalStore();
    final controller = AppRestorationController(
      store: store,
      initial: const AppRestorationState(),
    );
    final routeId = controller.pushPaper(samplePaper);
    final routeKey = routeReaderKey(routeId, samplePaper);
    controller.updateReader(
      routeKey,
      (_) => const ReaderNavigationState(stageIndex: 2),
    );

    expect(controller.state.readerStates, contains(routeKey));
    expect(controller.popPaper(routeId: routeId), isTrue);
    expect(controller.state.readerStates, isNot(contains(routeKey)));
    controller.dispose();
  });

  test('route version updates discard state at the version boundary', () {
    final controller = AppRestorationController(
      store: MemoryLocalStore(),
      initial: const AppRestorationState(),
    );
    final routeId = controller.pushPaper(samplePaper);
    final oldKey = routeReaderKey(routeId, samplePaper);
    controller.updateReader(
      oldKey,
      (_) =>
          const ReaderNavigationState(stageIndex: 1, introductionOffset: 215),
    );
    final newer = PaperSummary.fromJson(
      samplePaper.toJson()..['arxiv_id'] = '1706.03762v8',
    );

    controller.updateRoutePaper(routeId, newer);

    final newKey = routeReaderKey(routeId, newer);
    expect(controller.state.readerStates, isNot(contains(oldKey)));
    expect(controller.state.readerStates, isNot(contains(newKey)));
    expect(controller.state.readerState(newKey).stageIndex, 0);
    expect(controller.state.readerState(newKey).introductionOffset, 0);
    controller.dispose();
  });

  test('restoration history remains bounded and retains the current feed', () {
    final currentPaper = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = 'current-paper'
        ..['arxiv_id'] = '1706.03762v9',
    );
    final currentKey = feedReaderKey(currentPaper);
    final initialReaders = <String, ReaderNavigationState>{
      currentKey: const ReaderNavigationState(stageIndex: 2),
      for (var index = 0; index < maxRestoredReaderStates + 20; index++)
        'feed:old-$index:old-v$index': ReaderNavigationState(
          abstractOffset: index.toDouble(),
        ),
    };

    final controller = AppRestorationController(
      store: MemoryLocalStore(),
      initial: AppRestorationState(
        feedPaperId: currentPaper.paperId,
        feedArxivId: currentPaper.arxivId,
        readerStates: initialReaders,
      ),
    );

    expect(controller.state.readerStates, hasLength(maxRestoredReaderStates));
    expect(controller.state.readerStates, contains(currentKey));
    expect(controller.state.readerState(currentKey).stageIndex, 2);
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

  test(
    'account transition clears A reader state after an older write settles',
    () async {
      final readerKey = feedReaderKey(samplePaper);
      final initial = AppRestorationState(
        feedPaperId: samplePaper.paperId,
        feedArxivId: samplePaper.arxivId,
        routeStack: [
          PaperRouteEntry(routeId: 'safe-public-route', paper: samplePaper),
        ],
        readerStates: {
          readerKey: const ReaderNavigationState(
            stageIndex: 1,
            introductionOffset: 420,
            depthMode: ReaderDepthMode.inspect,
            checkpointBlockId: 'account-a-block',
            checkpointScrollFraction: .67,
          ),
        },
      );
      final store = _FirstWriteGateStore()..restoration = initial;
      final controller = AppRestorationController(
        store: store,
        initial: initial,
      );

      final staleWrite = controller.flush();
      await store.firstWriteStarted.future;
      final transition = controller.clearReaderStatesForAccountTransition();

      expect(controller.state.readerStates, isEmpty);
      expect(controller.state.routeStack.single.routeId, 'safe-public-route');
      controller.updateReader(
        readerKey,
        (_) => const ReaderNavigationState(
          introductionOffset: 999,
          depthMode: ReaderDepthMode.read,
          checkpointBlockId: 'late-account-a-block',
        ),
      );
      expect(
        controller.state.readerStates,
        isEmpty,
        reason: 'outgoing reader callbacks are dropped during cleanup',
      );
      store.releaseFirstWrite.complete();
      await Future.wait([staleWrite, transition]);

      expect(store.restoration.readerStates, isEmpty);
      expect(store.restoration.routeStack.single.routeId, 'safe-public-route');
      expect(
        controller.state.readerState(readerKey),
        isA<ReaderNavigationState>()
            .having((value) => value.introductionOffset, 'offset', 0)
            .having((value) => value.depthMode, 'mode', ReaderDepthMode.skim)
            .having((value) => value.checkpointBlockId, 'block', isNull),
      );
      controller.dispose();
    },
  );
}

final class _FirstWriteGateStore extends MemoryLocalStore {
  final Completer<void> firstWriteStarted = Completer<void>();
  final Completer<void> releaseFirstWrite = Completer<void>();
  var _writes = 0;

  @override
  Future<void> saveRestoration(AppRestorationState value) async {
    _writes += 1;
    if (_writes == 1) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    await super.saveRestoration(value);
  }
}
