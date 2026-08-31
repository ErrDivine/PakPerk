import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ReaderInteractionKind {
  selection,
  noteEditor,
  assistantComposer,
  objectInspector,
  inspectMode,
  tablePan,
}

enum TablePanDisposition { idle, undecided, horizontal, rejected }

final class ReaderInteractionState {
  const ReaderInteractionState({
    this.selectionActive = false,
    this.noteEditorActive = false,
    this.assistantComposerActive = false,
    this.objectInspectorActive = false,
    this.inspectModeActive = false,
    this.tablePan = TablePanDisposition.idle,
  });

  final bool selectionActive;
  final bool noteEditorActive;
  final bool assistantComposerActive;
  final bool objectInspectorActive;
  final bool inspectModeActive;
  final TablePanDisposition tablePan;

  bool get tablePanActive =>
      tablePan == TablePanDisposition.undecided ||
      tablePan == TablePanDisposition.horizontal;

  bool get navigationLocked =>
      selectionActive ||
      noteEditorActive ||
      assistantComposerActive ||
      objectInspectorActive ||
      inspectModeActive ||
      tablePanActive;

  /// Only direct-manipulation content gestures remove the pager from the
  /// gesture arena. Modal/editor tools still block explicit navigation
  /// commands through [canNavigateStages] and [canNavigateVertically], but do
  /// not leave pager physics permanently disabled after their gesture ends.
  bool get canDragPager => !selectionActive && !tablePanActive;

  bool get canNavigateStages => !navigationLocked;
  bool get canNavigateVertically => !navigationLocked;

  ReaderInteractionState copyWith({
    bool? selectionActive,
    bool? noteEditorActive,
    bool? assistantComposerActive,
    bool? objectInspectorActive,
    bool? inspectModeActive,
    TablePanDisposition? tablePan,
  }) => ReaderInteractionState(
    selectionActive: selectionActive ?? this.selectionActive,
    noteEditorActive: noteEditorActive ?? this.noteEditorActive,
    assistantComposerActive:
        assistantComposerActive ?? this.assistantComposerActive,
    objectInspectorActive: objectInspectorActive ?? this.objectInspectorActive,
    inspectModeActive: inspectModeActive ?? this.inspectModeActive,
    tablePan: tablePan ?? this.tablePan,
  );
}

final readerInteractionControllerProvider = StateNotifierProvider.autoDispose
    .family<ReaderInteractionController, ReaderInteractionState, String>(
      (_, __) => ReaderInteractionController(),
    );

/// One arbitration point for gestures which compete with reader navigation.
///
/// Table pans remain undecided until movement crosses a small slop threshold,
/// then require horizontal movement to exceed vertical movement by the
/// hysteresis ratio. This prevents a diagonal table gesture from accidentally
/// changing either paper stage or queue item.
final class ReaderInteractionController
    extends StateNotifier<ReaderInteractionState> {
  ReaderInteractionController() : super(const ReaderInteractionState());

  static const double tablePanSlop = 8;
  static const double tablePanHysteresis = 1.25;

  void setActive(ReaderInteractionKind kind, bool active) {
    state = switch (kind) {
      ReaderInteractionKind.selection => state.copyWith(
        selectionActive: active,
      ),
      ReaderInteractionKind.noteEditor => state.copyWith(
        noteEditorActive: active,
      ),
      ReaderInteractionKind.assistantComposer => state.copyWith(
        assistantComposerActive: active,
      ),
      ReaderInteractionKind.objectInspector => state.copyWith(
        objectInspectorActive: active,
      ),
      ReaderInteractionKind.inspectMode => state.copyWith(
        inspectModeActive: active,
      ),
      ReaderInteractionKind.tablePan => state.copyWith(
        tablePan: active
            ? TablePanDisposition.undecided
            : TablePanDisposition.idle,
      ),
    };
  }

  void beginTablePan() {
    state = state.copyWith(tablePan: TablePanDisposition.undecided);
  }

  TablePanDisposition updateTablePan({
    required double accumulatedDx,
    required double accumulatedDy,
  }) {
    if (state.tablePan != TablePanDisposition.undecided) {
      return state.tablePan;
    }
    final dx = accumulatedDx.abs();
    final dy = accumulatedDy.abs();
    if (dx < tablePanSlop && dy < tablePanSlop) return state.tablePan;
    final disposition = dx >= dy * tablePanHysteresis
        ? TablePanDisposition.horizontal
        : TablePanDisposition.rejected;
    state = state.copyWith(tablePan: disposition);
    return disposition;
  }

  void endTablePan() {
    state = state.copyWith(tablePan: TablePanDisposition.idle);
  }

  void clearTransientInteractions() {
    state = ReaderInteractionState(inspectModeActive: state.inspectModeActive);
  }
}
