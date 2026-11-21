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
  Widget build(BuildContext context) => SelectionArea(
    contextMenuBuilder: readerSelectionContextMenu,
    onSelectionChanged: (content) {
      _selected = content?.plainText.isNotEmpty == true;
      widget.onSelectionChanged?.call(content);
    },
    child: widget.child,
  );
}
