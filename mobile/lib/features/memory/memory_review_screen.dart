import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/research_memory.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import '../../design_system/motion.dart';
import 'memory_controller.dart';

typedef MemoryScheduleCallback =
    void Function(MemoryItem item, DateTime nextReviewAt);

enum MemoryReviewSchedulePreset { laterToday, tomorrow, oneWeek }

final class MemoryReviewDateValidation {
  const MemoryReviewDateValidation._({this.value, this.errorMessage});

  const MemoryReviewDateValidation.valid(DateTime value) : this._(value: value);

  const MemoryReviewDateValidation.invalid(String message)
    : this._(errorMessage: message);

  final DateTime? value;
  final String? errorMessage;

  bool get isValid => value != null;
}

DateTime memoryReviewPresetInstant(
  MemoryReviewSchedulePreset preset,
  DateTime now,
) => switch (preset) {
  MemoryReviewSchedulePreset.laterToday => _laterToday(now),
  MemoryReviewSchedulePreset.tomorrow => _atNine(
    now.add(const Duration(days: 1)),
  ),
  MemoryReviewSchedulePreset.oneWeek => _atNine(
    now.add(const Duration(days: 7)),
  ),
};

MemoryReviewDateValidation validateCustomMemoryReviewDate(
  String input,
  DateTime now,
) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(input.trim());
  if (match == null) {
    return const MemoryReviewDateValidation.invalid(
      'Enter a date as YYYY-MM-DD.',
    );
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final value = now.isUtc
      ? DateTime.utc(year, month, day, 9)
      : DateTime(year, month, day, 9);
  if (value.year != year || value.month != month || value.day != day) {
    return const MemoryReviewDateValidation.invalid(
      'Enter a real calendar date.',
    );
  }
  if (!isValidMemoryReviewInstant(value, now)) {
    return const MemoryReviewDateValidation.invalid(
      'Choose a future date within the next five years.',
    );
  }
  return MemoryReviewDateValidation.valid(value);
}

Future<DateTime?> showMemoryReviewSchedulePicker({
  required BuildContext context,
  required String title,
  required DateTime now,
}) => showModalBottomSheet<DateTime>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  sheetAnimationStyle: platformPrefersReducedMotion(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) => _MemoryScheduleSheet(title: title, now: now),
);

final class MemoryReviewScreen extends StatefulWidget {
  const MemoryReviewScreen({
    required this.state,
    required this.now,
    required this.onRefresh,
    required this.onOpenSource,
    required this.onReviewed,
    required this.onSnooze,
    required this.onRetire,
    this.openingItemId,
    this.openErrorMessage,
    super.key,
  });

  final MemoryReviewState state;
  final DateTime now;
  final VoidCallback onRefresh;
  final ValueChanged<MemoryItem> onOpenSource;
  final MemoryScheduleCallback onReviewed;
  final MemoryScheduleCallback onSnooze;
  final ValueChanged<MemoryItem> onRetire;
  final String? openingItemId;
  final String? openErrorMessage;

  @override
  State<MemoryReviewScreen> createState() => _MemoryReviewScreenState();
}

final class _MemoryReviewScreenState extends State<MemoryReviewScreen> {
  final Set<String> _revealed = {};

  @override
  Widget build(BuildContext context) {
    final due = widget.state.dueItems(widget.now);
    final message = widget.openErrorMessage ?? widget.state.errorMessage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Research memory'),
        actions: [
          IconButton(
            key: const ValueKey('memory-review-refresh'),
            tooltip: 'Refresh research memory',
            onPressed: widget.state.loading ? null : widget.onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.state.loading)
              const LinearProgressIndicator(
                key: ValueKey('memory-review-progress'),
              ),
            if (widget.state.offline)
              const _MessageBanner(
                icon: Icons.cloud_off_outlined,
                message:
                    'Offline: cached reviews stay private on this device and changes keep their sync operation.',
              ),
            if (message != null)
              _MessageBanner(
                key: const ValueKey('memory-review-error'),
                icon: Icons.error_outline,
                message: message,
                error: true,
              ),
            if (widget.state.statusMessage case final status?)
              _MessageBanner(
                key: const ValueKey('memory-review-status'),
                icon: Icons.check_circle_outline,
                message: status,
              ),
            Expanded(
              child: due.isEmpty
                  ? _EmptyMemoryReview(loading: widget.state.loading)
                  : ListView.builder(
                      key: const PageStorageKey<String>(
                        'global-memory-review-list',
                      ),
                      padding: const EdgeInsets.fromLTRB(
                        PakPerkSpacing.lg,
                        PakPerkSpacing.md,
                        PakPerkSpacing.lg,
                        PakPerkSpacing.xxl,
                      ),
                      itemCount: due.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return const _ReviewIntroduction();
                        }
                        final item = due[index - 1];
                        return Padding(
                          padding: const EdgeInsets.only(
                            bottom: PakPerkSpacing.md,
                          ),
                          child: _MemoryReviewCard(
                            item: item,
                            now: widget.now,
                            revealed: _revealed.contains(item.id),
                            busy:
                                widget.state.busyItemId == item.id ||
                                widget.openingItemId == item.id,
                            onReveal: () => setState(() {
                              _revealed.add(item.id);
                            }),
                            onOpenSource: () => widget.onOpenSource(item),
                            onReviewed: (nextReviewAt) =>
                                widget.onReviewed(item, nextReviewAt),
                            onSnooze: (nextReviewAt) =>
                                widget.onSnooze(item, nextReviewAt),
                            onRetire: () => _confirmRetire(item),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRetire(MemoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retire this memory item?'),
        content: const Text(
          'It will leave future review. Its source paper and Library state will not change.',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(
                PakPerkSizes.minimumInteractive,
                PakPerkSizes.minimumInteractive,
              ),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep reviewing'),
          ),
          FilledButton(
            key: const ValueKey('confirm-retire-memory'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(
                PakPerkSizes.minimumInteractive,
                PakPerkSizes.minimumInteractive,
              ),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Retire'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onRetire(item);
  }
}

final class _ReviewIntroduction extends StatelessWidget {
  const _ReviewIntroduction();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: PakPerkSpacing.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Due for review',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        const Text(
          'Only notes and evidence you chose to remember appear here. Reviewing never moves a paper in your Library or reading feed.',
        ),
      ],
    ),
  );
}

final class _MemoryReviewCard extends StatelessWidget {
  const _MemoryReviewCard({
    required this.item,
    required this.now,
    required this.revealed,
    required this.busy,
    required this.onReveal,
    required this.onOpenSource,
    required this.onReviewed,
    required this.onSnooze,
    required this.onRetire,
  });

  final MemoryItem item;
  final DateTime now;
  final bool revealed;
  final bool busy;
  final VoidCallback onReveal;
  final VoidCallback onOpenSource;
  final ValueChanged<DateTime> onReviewed;
  final ValueChanged<DateTime> onSnooze;
  final VoidCallback onRetire;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answer = item.answerText;
    return Card(
      key: ValueKey('memory-review-item-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.psychology_alt_outlined),
                const SizedBox(width: PakPerkSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _sourceLabel(item.sourceType),
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: PakPerkSpacing.xxs),
                      Text(
                        item.promptText ?? 'Saved research artifact',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                if (busy)
                  Semantics(
                    liveRegion: true,
                    label: 'Updating memory item',
                    child: const Padding(
                      padding: EdgeInsetsDirectional.only(start: 8),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: PakPerkSpacing.sm),
            Semantics(
              label: 'Source paper',
              excludeSemantics: true,
              child: Text('Source paper', style: theme.textTheme.bodySmall),
            ),
            if (answer != null) ...[
              const SizedBox(height: PakPerkSpacing.sm),
              if (!revealed)
                _ReviewAction(
                  key: ValueKey('reveal-memory-${item.id}'),
                  icon: Icons.visibility_outlined,
                  label: 'Reveal why you saved it',
                  onPressed: busy ? null : onReveal,
                )
              else
                Semantics(
                  liveRegion: true,
                  label: 'Saved note revealed',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(PakPerkSpacing.sm),
                      child: Text(answer),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: PakPerkSpacing.md),
            Wrap(
              spacing: PakPerkSpacing.xs,
              runSpacing: PakPerkSpacing.xs,
              children: [
                _ReviewAction(
                  key: ValueKey('open-memory-source-${item.id}'),
                  icon: Icons.auto_stories_outlined,
                  label: 'Open source paper',
                  onPressed: busy ? null : onOpenSource,
                  filled: true,
                ),
                _ReviewAction(
                  key: ValueKey('review-memory-${item.id}'),
                  icon: Icons.check_circle_outline,
                  label: 'Reviewed',
                  onPressed: busy
                      ? null
                      : () => _chooseSchedule(
                          context,
                          title: 'Schedule next review',
                          onScheduled: onReviewed,
                        ),
                ),
                _ReviewAction(
                  key: ValueKey('snooze-memory-${item.id}'),
                  icon: Icons.snooze,
                  label: 'Snooze',
                  onPressed: busy
                      ? null
                      : () => _chooseSchedule(
                          context,
                          title: 'Snooze until',
                          onScheduled: onSnooze,
                        ),
                ),
                _ReviewAction(
                  key: ValueKey('retire-memory-${item.id}'),
                  icon: Icons.archive_outlined,
                  label: 'Retire',
                  onPressed: busy ? null : onRetire,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseSchedule(
    BuildContext context, {
    required String title,
    required ValueChanged<DateTime> onScheduled,
  }) async {
    final nextReviewAt = await showMemoryReviewSchedulePicker(
      context: context,
      title: title,
      now: now,
    );
    if (nextReviewAt != null) onScheduled(nextReviewAt);
  }
}

final class _MemoryScheduleSheet extends StatefulWidget {
  const _MemoryScheduleSheet({required this.title, required this.now});

  final String title;
  final DateTime now;

  @override
  State<_MemoryScheduleSheet> createState() => _MemoryScheduleSheetState();
}

final class _MemoryScheduleSheetState extends State<_MemoryScheduleSheet> {
  final TextEditingController _customDateController = TextEditingController();
  bool _showCustomDate = false;
  String? _customDateError;

  @override
  void dispose() {
    _customDateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        PakPerkSpacing.lg,
        0,
        PakPerkSpacing.lg,
        PakPerkSpacing.lg + media.viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            const Text(
              'Choose when this item should return. This does not change its source paper or reading queue.',
            ),
            const SizedBox(height: PakPerkSpacing.md),
            _ScheduleChoice(
              key: const ValueKey('memory-schedule-today'),
              label: 'Later today',
              detail: _formatSchedule(context, _presetToday),
              onPressed: () => Navigator.of(context).pop(_presetToday),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            _ScheduleChoice(
              key: const ValueKey('memory-schedule-tomorrow'),
              label: 'Tomorrow',
              detail: _formatSchedule(context, _presetTomorrow),
              onPressed: () => Navigator.of(context).pop(_presetTomorrow),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            _ScheduleChoice(
              key: const ValueKey('memory-schedule-week'),
              label: 'One week',
              detail: _formatSchedule(context, _presetWeek),
              onPressed: () => Navigator.of(context).pop(_presetWeek),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            _ScheduleChoice(
              key: const ValueKey('memory-schedule-custom'),
              label: 'Custom date',
              detail: 'Choose a date at 9:00 AM',
              onPressed: () => setState(() {
                _showCustomDate = true;
                _customDateError = null;
              }),
            ),
            if (_showCustomDate) ...[
              const SizedBox(height: PakPerkSpacing.md),
              TextField(
                key: const ValueKey('memory-custom-date-input'),
                controller: _customDateController,
                autofocus: true,
                keyboardType: TextInputType.datetime,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 10,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Review date',
                  hintText: 'YYYY-MM-DD',
                  helperText: 'Scheduled for 9:00 AM on this device.',
                ),
                onChanged: (_) {
                  if (_customDateError == null) return;
                  setState(() => _customDateError = null);
                },
                onSubmitted: (_) => _submitCustomDate(),
              ),
              if (_customDateError case final error?) ...[
                const SizedBox(height: PakPerkSpacing.xs),
                Semantics(
                  key: const ValueKey('memory-custom-date-error'),
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: PakPerkSpacing.sm),
              FilledButton(
                key: const ValueKey('memory-custom-date-confirm'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(
                    PakPerkSizes.minimumInteractive,
                  ),
                ),
                onPressed: _submitCustomDate,
                child: const Text('Set review date'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  DateTime get _presetToday => memoryReviewPresetInstant(
    MemoryReviewSchedulePreset.laterToday,
    widget.now,
  );

  DateTime get _presetTomorrow => memoryReviewPresetInstant(
    MemoryReviewSchedulePreset.tomorrow,
    widget.now,
  );

  DateTime get _presetWeek =>
      memoryReviewPresetInstant(MemoryReviewSchedulePreset.oneWeek, widget.now);

  void _submitCustomDate() {
    final result = validateCustomMemoryReviewDate(
      _customDateController.text,
      widget.now,
    );
    if (result.value case final value?) {
      Navigator.of(context).pop(value);
      return;
    }
    setState(() => _customDateError = result.errorMessage);
  }
}

final class _ScheduleChoice extends StatelessWidget {
  const _ScheduleChoice({
    required this.label,
    required this.detail,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String detail;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      alignment: AlignmentDirectional.centerStart,
      minimumSize: const Size.fromHeight(PakPerkSizes.minimumInteractive),
      padding: const EdgeInsets.symmetric(
        horizontal: PakPerkSpacing.md,
        vertical: PakPerkSpacing.sm,
      ),
    ),
    onPressed: onPressed,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: PakPerkSpacing.xxs),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

DateTime _laterToday(DateTime now) {
  final preferred = now.add(const Duration(hours: 4));
  if (preferred.year == now.year &&
      preferred.month == now.month &&
      preferred.day == now.day) {
    return preferred;
  }
  return now.isUtc
      ? DateTime.utc(now.year, now.month, now.day, 23, 59, 59, 999, 999)
      : DateTime(now.year, now.month, now.day, 23, 59, 59, 999, 999);
}

DateTime _atNine(DateTime date) => date.isUtc
    ? DateTime.utc(date.year, date.month, date.day, 9)
    : DateTime(date.year, date.month, date.day, 9);

String _formatSchedule(BuildContext context, DateTime value) {
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatMediumDate(value);
  final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value));
  return '$date at $time';
}

final class _ReviewAction extends StatelessWidget {
  const _ReviewAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: PakPerkSizes.minimumInteractive,
      minWidth: PakPerkSizes.minimumInteractive,
    ),
    child: filled
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          ),
  );
}

final class _MessageBanner extends StatelessWidget {
  const _MessageBanner({
    required this.icon,
    required this.message,
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: error ? colors.errorContainer : colors.secondaryContainer,
        padding: const EdgeInsets.all(PakPerkSpacing.sm),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: PakPerkSpacing.sm),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

final class _EmptyMemoryReview extends StatelessWidget {
  const _EmptyMemoryReview({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(PakPerkSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading ? Icons.sync : Icons.check_circle_outline,
            size: PakPerkSizes.minimumInteractive,
          ),
          const SizedBox(height: PakPerkSpacing.md),
          Semantics(
            header: true,
            child: Text(
              loading ? 'Checking research memory' : 'Nothing due right now',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          Text(
            loading
                ? 'Cached items remain visible while the account snapshot is verified.'
                : 'You can return whenever another memory item is due.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

String _sourceLabel(MemorySourceType source) => switch (source) {
  MemorySourceType.annotation => 'Your note or highlight',
  MemorySourceType.evidenceCard => 'Your reviewed evidence',
  MemorySourceType.passportField => 'Your reviewed paper field',
  MemorySourceType.userQuestion => 'Your saved question',
};
