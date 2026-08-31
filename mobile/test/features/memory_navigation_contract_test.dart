import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/router.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/document_reader/reader_entry_context.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  test('memory origin round trips without becoming feed authority', () {
    const entry = ReaderEntryContext.memory(originReaderKey: originReaderKey);

    final restored = ReaderEntryContext.fromJson(entry.toJson());

    expect(restored.source, ReaderEntrySource.memory);
    expect(restored.originReaderKey, originReaderKey);
    expect(restored.isExplicitBranch, isTrue);
    expect(restored.belongsToAutomaticFeed, isFalse);
    expect(restored.queueMembership, ReaderQueueMembership.unknown);
    expect(shouldRecordLibraryHistoryForReaderEntry(restored), isFalse);
  });

  test('memory branch preserves origin stage, block, and scroll on return', () {
    final store = MemoryLocalStore();
    const origin = ReaderNavigationState(
      stageIndex: 1,
      introductionOffset: 412,
      checkpointBlockId: 'block-methods-7',
      checkpointScrollFraction: .62,
    );
    final controller = AppRestorationController(
      store: store,
      initial: const AppRestorationState(
        feedIndex: 4,
        feedPaperId: '00000000-0000-4000-8000-000000000099',
        feedArxivId: '2608.00099v1',
        readerStates: {originReaderKey: origin},
      ),
    );
    addTearDown(controller.dispose);

    final routeId = controller.pushPaper(
      samplePaper,
      entryContext: const ReaderEntryContext.memory(
        originReaderKey: originReaderKey,
      ),
    );
    final memoryEntry = controller.state.routeStack.single;

    expect(memoryEntry.routeId, routeId);
    expect(memoryEntry.entryContext.source, ReaderEntrySource.memory);
    expect(memoryEntry.entryContext.originReaderKey, originReaderKey);
    expect(controller.popPaper(routeId: routeId), isTrue);

    final restoredOrigin = controller.state.readerState(originReaderKey);
    expect(restoredOrigin.stageIndex, PaperStage.introduction.index);
    expect(restoredOrigin.introductionOffset, 412);
    expect(restoredOrigin.checkpointBlockId, 'block-methods-7');
    expect(restoredOrigin.checkpointScrollFraction, .62);
    expect(controller.state.feedIndex, 4);
    expect(
      controller.state.feedPaperId,
      '00000000-0000-4000-8000-000000000099',
    );
  });
}

const originReaderKey =
    'feed:00000000-0000-4000-8000-000000000099:2608.00099v1';
