import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import '../../l10n/ui.dart';

/// Keep Android's native actions, with the installed dictionary easy to reach.
List<ContextMenuButtonItem> readerSelectionMenuItems(
  List<ContextMenuButtonItem> items, {
  required String translateLabel,
}) {
  final preferred = items.indexWhere((item) {
    final label = item.label?.toLowerCase() ?? '';
    return label.contains('有道') || label.contains('youdao');
  });
  final index = preferred >= 0
      ? preferred
      : items.indexWhere((item) {
          final label = item.label?.toLowerCase() ?? '';
          return label.contains('翻译') || label.contains('translate');
        });
  if (index < 0) return items;
  final action = items[index];
  return [
    ContextMenuButtonItem(label: translateLabel, onPressed: action.onPressed),
    for (var i = 0; i < items.length; i++)
      if (i != index) items[i],
  ];
}

Widget readerSelectionContextMenu(
  BuildContext context,
  SelectableRegionState region,
) => AdaptiveTextSelectionToolbar.buttonItems(
  anchors: region.contextMenuAnchors,
  buttonItems: readerSelectionMenuItems(
    region.contextMenuButtonItems,
    translateLabel: uiString(context, 'Translate'),
  ),
);

/// A paper-scoped selection boundary: select a word, then extend its handles.
class ReaderSelectionArea extends StatefulWidget {
  const ReaderSelectionArea({
    required this.child,
    this.onSelectionChanged,
    super.key,
  });
  final Widget child;
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  @override
  State<ReaderSelectionArea> createState() => _ReaderSelectionAreaState();
}

class _ReaderSelectionAreaState extends State<ReaderSelectionArea> {
  bool _selected = false;

  @override
  void dispose() {
    if (_selected) {
      final callback = widget.onSelectionChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => callback?.call(null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReaderPageSelectionArea(
    onSelectionChanged: (content) {
      _selected = content?.plainText.isNotEmpty == true;
      widget.onSelectionChanged?.call(content);
    },
    child: widget.child,
  );
}

/// Keeps native text selection without taking ordinary swipes from the pager.
class ReaderPageSelectionArea extends SelectionArea {
  const ReaderPageSelectionArea({
    required super.child,
    super.onSelectionChanged,
    super.key,
  }) : super(contextMenuBuilder: readerSelectionContextMenu);

  @override
  SelectionAreaState createState() => _ReaderPageSelectionAreaState();
}

class _ReaderPageSelectionAreaState extends SelectionAreaState {
  @override
  Widget build(BuildContext context) {
    final region = super.build(context);
    if (region is! SelectableRegion ||
        Scrollable.maybeOf(context, axis: Axis.horizontal) == null) {
      return region;
    }
    return _PagerSelectableRegion(
      key: region.key,
      focusNode: region.focusNode,
      selectionControls: region.selectionControls,
      contextMenuBuilder: region.contextMenuBuilder,
      magnifierConfiguration: region.magnifierConfiguration,
      onSelectionChanged: region.onSelectionChanged,
      child: region.child,
    );
  }
}

class _PagerSelectableRegion extends SelectableRegion {
  const _PagerSelectableRegion({
    required super.child,
    required super.selectionControls,
    super.contextMenuBuilder,
    super.focusNode,
    super.key,
    super.magnifierConfiguration,
    super.onSelectionChanged,
  });

  @override
  SelectableRegionState createState() => _PagerSelectableRegionState();
}

class _PagerSelectableRegionState extends SelectableRegionState {
  @override
  Widget build(BuildContext context) {
    // Flutter 3.44's SelectableRegion eagerly claims touch drags outside iOS.
    // Use its non-eager arbitration around a pager and keep all of Flutter's
    // tap, long-press, mouse, toolbar, and selection-handle callbacks.
    final region = super.build(context);
    if (region is! TapRegion) return region;
    final target = region.child;
    if (target is! CompositedTransformTarget) return region;
    final detector = target.child;
    if (detector is! RawGestureDetector) return region;
    final drag = detector.gestures[TapAndHorizontalDragGestureRecognizer];
    if (drag
        is! GestureRecognizerFactory<TapAndHorizontalDragGestureRecognizer>) {
      return region;
    }
    return TapRegion(
      key: region.key,
      behavior: region.behavior,
      enabled: region.enabled,
      groupId: region.groupId,
      onTapInside: region.onTapInside,
      onTapOutside: region.onTapOutside,
      onTapUpInside: region.onTapUpInside,
      onTapUpOutside: region.onTapUpOutside,
      consumeOutsideTaps: region.consumeOutsideTaps,
      debugLabel: region.debugLabel,
      child: CompositedTransformTarget(
        key: target.key,
        link: target.link,
        child: RawGestureDetector(
          key: detector.key,
          behavior: detector.behavior,
          excludeFromSemantics: detector.excludeFromSemantics,
          semantics: detector.semantics,
          gestures: {
            ...detector.gestures,
            TapAndHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  TapAndHorizontalDragGestureRecognizer
                >(drag.constructor, (recognizer) {
                  drag.initializer(recognizer);
                  recognizer.eagerVictoryOnDrag = false;
                }),
          },
          child: detector.child,
        ),
      ),
    );
  }
}
