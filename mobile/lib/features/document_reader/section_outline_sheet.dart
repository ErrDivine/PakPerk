import 'package:flutter/material.dart';

import '../../core/models/document_block.dart';
import '../../design_system/motion.dart';

Future<String?> showSectionOutlineSheet({
  required BuildContext context,
  required DocumentOutline outline,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: .72,
      child: Semantics(
        container: true,
        label: 'Document outline',
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              title: Text('Outline'),
            ),
            SliverList.builder(
              itemCount: outline.sections.length,
              itemBuilder: (context, index) {
                final section = outline.sections[index];
                return ListTile(
                  minTileHeight: 48,
                  contentPadding: EdgeInsetsDirectional.only(
                    start: 16 + (section.level - 1) * 12,
                    end: 16,
                  ),
                  title: Text(section.title),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: section.blockIds.isEmpty
                      ? null
                      : () => Navigator.pop(context, section.blockIds.first),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
