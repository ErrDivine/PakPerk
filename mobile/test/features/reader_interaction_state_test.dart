import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/features/document_reader/reader_interaction_state.dart';

void main() {
  test('selection, editor, assistant, object, and Inspect lock navigation', () {
    for (final kind in [
      ReaderInteractionKind.selection,
      ReaderInteractionKind.noteEditor,
      ReaderInteractionKind.assistantComposer,
      ReaderInteractionKind.objectInspector,
      ReaderInteractionKind.inspectMode,
    ]) {
      final controller = ReaderInteractionController();
      addTearDown(controller.dispose);

      controller.setActive(kind, true);
      expect(controller.state.canNavigateStages, isFalse, reason: kind.name);
      expect(
        controller.state.canNavigateVertically,
        isFalse,
        reason: kind.name,
      );
      controller.setActive(kind, false);
      expect(controller.state.canNavigateStages, isTrue, reason: kind.name);
    }
  });

  test('table pan uses slop and directional hysteresis', () {
    final controller = ReaderInteractionController();
    addTearDown(controller.dispose);

    controller.beginTablePan();
    expect(
      controller.updateTablePan(accumulatedDx: 4, accumulatedDy: 3),
      TablePanDisposition.undecided,
    );
    expect(controller.state.navigationLocked, isTrue);
    expect(
      controller.updateTablePan(accumulatedDx: 14, accumulatedDy: 6),
      TablePanDisposition.horizontal,
    );
    expect(controller.state.navigationLocked, isTrue);
    controller.endTablePan();
    expect(controller.state.navigationLocked, isFalse);

    controller.beginTablePan();
    expect(
      controller.updateTablePan(accumulatedDx: 9, accumulatedDy: 12),
      TablePanDisposition.rejected,
    );
    expect(controller.state.tablePanActive, isFalse);
  });

  test('pager gesture is yielded only to selection or table pan', () {
    final controller = ReaderInteractionController();
    addTearDown(controller.dispose);

    for (final kind in [
      ReaderInteractionKind.noteEditor,
      ReaderInteractionKind.assistantComposer,
      ReaderInteractionKind.objectInspector,
      ReaderInteractionKind.inspectMode,
    ]) {
      controller.setActive(kind, true);
      expect(controller.state.canNavigateStages, isFalse, reason: kind.name);
      expect(controller.state.canDragPager, isTrue, reason: kind.name);
      controller.setActive(kind, false);
    }

    controller.setActive(ReaderInteractionKind.selection, true);
    expect(controller.state.canDragPager, isFalse);
    controller.setActive(ReaderInteractionKind.selection, false);
    controller.beginTablePan();
    expect(controller.state.canDragPager, isFalse);
    controller.endTablePan();
    expect(controller.state.canDragPager, isTrue);
  });

  test('clearing transient tools preserves restored Inspect lock', () {
    final controller = ReaderInteractionController();
    addTearDown(controller.dispose);
    controller.setActive(ReaderInteractionKind.inspectMode, true);
    controller.setActive(ReaderInteractionKind.selection, true);

    controller.clearTransientInteractions();

    expect(controller.state.selectionActive, isFalse);
    expect(controller.state.inspectModeActive, isTrue);
    expect(controller.state.navigationLocked, isTrue);
  });
}
