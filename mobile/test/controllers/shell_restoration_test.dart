import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  test('active branch round-trips with the exact Read state', () async {
    final readerKey = feedReaderKey(samplePaper);
    final store = MemoryLocalStore();
    final controller = AppRestorationController(
      store: store,
      initial: AppRestorationState(
        feedIndex: 4,
        routeStack: const [],
        readerStates: {
          readerKey: const ReaderNavigationState(
            stageIndex: 2,
            connectionsOffset: 318.5,
            prepareRequested: true,
          ),
        },
      ),
    );

    controller.setActiveBranch(1);
    await controller.flush();

    final restored = AppRestorationState.fromJson(store.restoration.toJson());
    expect(restored.activeBranchIndex, 1);
    expect(restored.feedIndex, 4);
    expect(restored.readerState(readerKey).stageIndex, 2);
    expect(restored.readerState(readerKey).connectionsOffset, 318.5);
    expect(restored.readerState(readerKey).prepareRequested, isTrue);
    controller.dispose();
  });

  test('unknown restored branch values fall back to Read', () {
    expect(
      AppRestorationState.fromJson(const {
        'active_branch_index': -1,
      }).activeBranchIndex,
      0,
    );
    expect(
      AppRestorationState.fromJson(const {
        'active_branch_index': 99,
      }).activeBranchIndex,
      0,
    );
    expect(
      AppRestorationState.fromJson(const {
        'active_branch_index': 'you',
      }).activeBranchIndex,
      0,
    );
  });

  test('Read reselection pops nested papers without resetting feed state', () {
    final readerKey = feedReaderKey(samplePaper);
    final controller = AppRestorationController(
      store: MemoryLocalStore(),
      initial: AppRestorationState(
        feedIndex: 3,
        routeStack: [
          PaperRouteEntry(routeId: 'paper-route', paper: samplePaper),
        ],
        readerStates: {
          readerKey: const ReaderNavigationState(
            stageIndex: 1,
            introductionOffset: 240,
            prepareRequested: true,
          ),
        },
      ),
    );

    expect(controller.popToFeed(), isTrue);
    expect(controller.state.routeStack, isEmpty);
    expect(controller.state.feedIndex, 3);
    expect(controller.state.readerState(readerKey).stageIndex, 1);
    expect(controller.state.readerState(readerKey).introductionOffset, 240);
    expect(controller.popToFeed(), isFalse);
    controller.dispose();
  });
}
