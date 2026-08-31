import 'package:flutter/material.dart';

import '../../core/library/library_history_store.dart';
import '../../core/models/paper.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

final class LibraryHistoryView extends StatelessWidget {
  const LibraryHistoryView({
    required this.enabled,
    required this.entries,
    required this.loading,
    required this.saving,
    required this.errorMessage,
    required this.onEnabledChanged,
    required this.onClear,
    required this.onOpenPaper,
    super.key,
  });

  final bool enabled;
  final List<LibraryHistoryEntry> entries;
  final bool loading;
  final bool saving;
  final String? errorMessage;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onClear;
  final ValueChanged<PaperSummary> onOpenPaper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      key: const ValueKey('library-history-view'),
      container: true,
      label: 'Private paper history',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PakPerkSpacing.md,
          PakPerkSpacing.xs,
          PakPerkSpacing.md,
          PakPerkSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: SwitchListTile.adaptive(
                key: const ValueKey('library-history-enabled'),
                value: enabled,
                onChanged: loading || saving ? null : onEnabledChanged,
                title: const Text('Keep private paper history'),
                subtitle: const Text(
                  'Record papers you explicitly open on this device. Turning this off clears the history. It never changes To Read.',
                ),
              ),
            ),
            if (loading) ...[
              const SizedBox(height: PakPerkSpacing.lg),
              const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Loading private paper history',
                ),
              ),
            ] else if (!enabled) ...[
              const SizedBox(height: PakPerkSpacing.lg),
              const _HistoryEmpty(
                icon: Icons.history_toggle_off_outlined,
                title: 'History is off',
                detail:
                    'Nothing is recorded until you choose to enable private history.',
              ),
            ] else if (entries.isEmpty) ...[
              const SizedBox(height: PakPerkSpacing.lg),
              const _HistoryEmpty(
                icon: Icons.history_rounded,
                title: 'No opened papers yet',
                detail:
                    'Papers appear here only after you explicitly open them.',
              ),
            ] else ...[
              const SizedBox(height: PakPerkSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Recently opened',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: TextButton(
                      key: const ValueKey('library-history-clear'),
                      onPressed: saving ? null : onClear,
                      child: const Text('Clear'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PakPerkSpacing.xs),
              for (final entry in entries) ...[
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    key: ValueKey(
                      'library-history-paper-${entry.paper.paperId}',
                    ),
                    minTileHeight: PakPerkSizes.minimumInteractive,
                    title: Text(entry.paper.title),
                    subtitle: Text(
                      _historyDetail(context, entry),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => onOpenPaper(entry.paper),
                  ),
                ),
                const SizedBox(height: PakPerkSpacing.xs),
              ],
            ],
            if (errorMessage != null) ...[
              const SizedBox(height: PakPerkSpacing.sm),
              Semantics(
                liveRegion: true,
                child: Text(
                  errorMessage!,
                  key: const ValueKey('library-history-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(PakPerkSpacing.lg),
    child: Column(
      children: [
        Icon(icon, size: 44),
        const SizedBox(height: PakPerkSpacing.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Text(detail, textAlign: TextAlign.center),
      ],
    ),
  );
}

String _historyDetail(BuildContext context, LibraryHistoryEntry entry) {
  final opened = MaterialLocalizations.of(
    context,
  ).formatShortDate(entry.openedAt.toLocal());
  final authors = entry.paper.authors.take(2).join(', ');
  return authors.isEmpty ? 'Opened $opened' : '$authors\nOpened $opened';
}
