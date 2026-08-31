import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engagement/engagement_models.dart';
import '../../core/models/paper.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

final class NotificationScheduleDraft {
  const NotificationScheduleDraft({
    required this.enabled,
    required this.start,
    required this.end,
    required this.timezone,
  });

  final bool enabled;
  final String? start;
  final String? end;
  final String timezone;
}

final class EngagementScreen extends StatelessWidget {
  const EngagementScreen({
    this.briefOnly = false,
    required this.readingBriefsEnabled,
    required this.subscriptionsEnabled,
    required this.notificationsEnabled,
    required this.brief,
    required this.subscriptions,
    required this.notifications,
    required this.preferences,
    required this.loading,
    required this.busy,
    required this.errorMessage,
    required this.onRetry,
    required this.onCreateBrief,
    required this.onAdvanceBrief,
    required this.onOpenPaper,
    required this.onAddSubscription,
    required this.onSubscriptionFrequencyChanged,
    required this.onMuteSubscription,
    required this.onMuteDiscoveryNotifications,
    required this.onDeleteSubscription,
    required this.onMarkNotificationRead,
    required this.onDismissNotification,
    required this.onMarkAllNotificationsRead,
    required this.onInAppEnabledChanged,
    required this.onGlobalPauseChanged,
    required this.onNotificationTypeFrequencyChanged,
    required this.onDailyBudgetChanged,
    required this.onNotificationScheduleChanged,
    super.key,
  });

  final bool briefOnly;
  final bool readingBriefsEnabled;
  final bool subscriptionsEnabled;
  final bool notificationsEnabled;
  final ReadingBrief? brief;
  final List<Subscription> subscriptions;
  final List<InAppNotification> notifications;
  final NotificationPreferences? preferences;
  final bool loading;
  final bool busy;
  final String? errorMessage;
  final VoidCallback onRetry;
  final VoidCallback onCreateBrief;
  final VoidCallback onAdvanceBrief;
  final ValueChanged<PaperSummary> onOpenPaper;
  final VoidCallback onAddSubscription;
  final void Function(Subscription, SubscriptionFrequency)
  onSubscriptionFrequencyChanged;
  final ValueChanged<Subscription> onMuteSubscription;
  final ValueChanged<InAppNotificationType> onMuteDiscoveryNotifications;
  final ValueChanged<Subscription> onDeleteSubscription;
  final ValueChanged<InAppNotification> onMarkNotificationRead;
  final ValueChanged<InAppNotification> onDismissNotification;
  final VoidCallback onMarkAllNotificationsRead;
  final ValueChanged<bool> onInAppEnabledChanged;
  final ValueChanged<bool> onGlobalPauseChanged;
  final void Function(InAppNotificationType, SubscriptionFrequency)
  onNotificationTypeFrequencyChanged;
  final ValueChanged<int> onDailyBudgetChanged;
  final ValueChanged<NotificationScheduleDraft> onNotificationScheduleChanged;

  @override
  Widget build(BuildContext context) {
    final enabled =
        readingBriefsEnabled || subscriptionsEnabled || notificationsEnabled;
    return Scaffold(
      appBar: AppBar(
        title: Text(briefOnly ? 'Reading brief' : 'Reading updates'),
      ),
      body: SafeArea(
        top: false,
        child: !enabled
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(PakPerkSpacing.lg),
                  child: Text(
                    briefOnly
                        ? 'Reading briefs are not enabled for this build.'
                        : 'Reading updates are not enabled for this build.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : loading &&
                  brief == null &&
                  subscriptions.isEmpty &&
                  notifications.isEmpty &&
                  preferences == null
            ? Center(
                child: CircularProgressIndicator(
                  semanticsLabel: briefOnly
                      ? 'Loading reading brief'
                      : 'Loading reading updates',
                ),
              )
            : ListView(
                key: const ValueKey('engagement-scroll-view'),
                padding: const EdgeInsets.fromLTRB(
                  PakPerkSpacing.lg,
                  PakPerkSpacing.sm,
                  PakPerkSpacing.lg,
                  PakPerkSpacing.xxl,
                ),
                children: [
                  const _AuthorityBoundary(),
                  if (errorMessage != null) ...[
                    const SizedBox(height: PakPerkSpacing.sm),
                    Semantics(
                      liveRegion: true,
                      child: Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: ListTile(
                          title: Text(errorMessage!),
                          trailing: TextButton(
                            onPressed: busy ? null : onRetry,
                            child: const Text('Retry'),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (readingBriefsEnabled) ...[
                    const SizedBox(height: PakPerkSpacing.lg),
                    _SectionTitle(
                      title: 'Reading brief',
                      subtitle:
                          'A bounded, resumable view. Progress never changes your library or proves To Read empty.',
                    ),
                    const SizedBox(height: PakPerkSpacing.sm),
                    _BriefCard(
                      brief: brief,
                      enabled: !busy,
                      onCreate: onCreateBrief,
                      onAdvance: onAdvanceBrief,
                      onOpenPaper: onOpenPaper,
                    ),
                  ],
                  if (subscriptionsEnabled) ...[
                    const SizedBox(height: PakPerkSpacing.xl),
                    _SectionTitle(
                      title: 'Subscriptions',
                      subtitle:
                          'Follow explicit topics, categories, or authors. Turning one off does not change To Read.',
                    ),
                    const SizedBox(height: PakPerkSpacing.sm),
                    for (final subscription in subscriptions.where(
                      (value) => !value.deleted,
                    )) ...[
                      _SubscriptionCard(
                        subscription: subscription,
                        enabled: !busy,
                        onFrequencyChanged: (frequency) =>
                            onSubscriptionFrequencyChanged(
                              subscription,
                              frequency,
                            ),
                        onMute: () => onMuteSubscription(subscription),
                        onDelete: () => onDeleteSubscription(subscription),
                      ),
                      const SizedBox(height: PakPerkSpacing.xs),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: PakPerkSizes.minimumInteractive,
                      ),
                      child: OutlinedButton.icon(
                        key: const ValueKey('engagement-add-subscription'),
                        onPressed: busy ? null : onAddSubscription,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add subscription'),
                      ),
                    ),
                  ],
                  if (notificationsEnabled) ...[
                    const SizedBox(height: PakPerkSpacing.xl),
                    _SectionTitle(
                      title: 'In-app notifications',
                      subtitle:
                          'Only bounded server types and paper metadata are shown. Push and email are unavailable.',
                    ),
                    const SizedBox(height: PakPerkSpacing.sm),
                    if (notifications.isEmpty)
                      const Card(
                        child: ListTile(title: Text('No in-app updates')),
                      )
                    else ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: busy ? null : onMarkAllNotificationsRead,
                          child: const Text('Mark all read'),
                        ),
                      ),
                      for (final notification in notifications) ...[
                        _NotificationCard(
                          notification: notification,
                          canMuteDiscoveryNotifications:
                              notification.scope ==
                                  InAppNotificationScope.discovery &&
                              preferences != null &&
                              preferences!.typeFrequencies[notification.type] !=
                                  SubscriptionFrequency.off,
                          enabled: !busy,
                          onOpenPaper: onOpenPaper,
                          onRead: () => onMarkNotificationRead(notification),
                          onDismiss: () => onDismissNotification(notification),
                          onMuteDiscoveryNotifications:
                              onMuteDiscoveryNotifications,
                        ),
                        const SizedBox(height: PakPerkSpacing.xs),
                      ],
                    ],
                    if (preferences != null) ...[
                      const SizedBox(height: PakPerkSpacing.md),
                      _PreferenceCard(
                        preferences: preferences!,
                        enabled: !busy,
                        onInAppEnabledChanged: onInAppEnabledChanged,
                        onGlobalPauseChanged: onGlobalPauseChanged,
                        onNotificationTypeFrequencyChanged:
                            onNotificationTypeFrequencyChanged,
                        onDailyBudgetChanged: onDailyBudgetChanged,
                        onNotificationScheduleChanged:
                            onNotificationScheduleChanged,
                      ),
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}

final class _AuthorityBoundary extends StatelessWidget {
  const _AuthorityBoundary();

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: const ListTile(
      leading: Icon(Icons.shield_outlined),
      title: Text('To Read remains authoritative'),
      subtitle: Text(
        'Briefs and discovery notifications cannot clear, reorder, or bypass your active queue.',
      ),
    ),
  );
}

final class _BriefCard extends StatelessWidget {
  const _BriefCard({
    required this.brief,
    required this.enabled,
    required this.onCreate,
    required this.onAdvance,
    required this.onOpenPaper,
  });

  final ReadingBrief? brief;
  final bool enabled;
  final VoidCallback onCreate;
  final VoidCallback onAdvance;
  final ValueChanged<PaperSummary> onOpenPaper;

  @override
  Widget build(BuildContext context) {
    final value = brief;
    if (value == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(PakPerkSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'The server will use To Read first and only choose discovery after confirmed emptiness.',
              ),
              const SizedBox(height: PakPerkSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: FilledButton.icon(
                  key: const ValueKey('engagement-create-brief'),
                  onPressed: enabled ? onCreate : null,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Create today’s brief'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final current = value.position < value.items.length
        ? value.items[value.position]
        : null;
    final progress = value.items.isEmpty
        ? 0.0
        : value.position / value.items.length;
    final visiblePosition = current == null
        ? value.items.length
        : value.position + 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              value.mode == ReadingBriefMode.queue
                  ? 'To Read brief'
                  : 'Discovery brief',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            Semantics(
              label: 'Brief position $visiblePosition of ${value.items.length}',
              child: LinearProgressIndicator(value: progress.clamp(0, 1)),
            ),
            const SizedBox(height: PakPerkSpacing.sm),
            Text('Paper $visiblePosition of ${value.items.length}'),
            if (current != null) ...[
              const SizedBox(height: PakPerkSpacing.xxs),
              Text(
                'Stop whenever you like. Your place is saved.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: PakPerkSpacing.md),
              Text(current.paper.title),
              const SizedBox(height: PakPerkSpacing.sm),
              Wrap(
                spacing: PakPerkSpacing.xs,
                runSpacing: PakPerkSpacing.xs,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('engagement-open-brief-paper'),
                    onPressed: enabled
                        ? () => onOpenPaper(current.paper)
                        : null,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Resume paper'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('engagement-advance-brief'),
                    onPressed: enabled ? onAdvance : null,
                    icon: Icon(
                      value.position + 1 == value.items.length
                          ? Icons.check_circle_outline_rounded
                          : Icons.arrow_forward_rounded,
                    ),
                    label: Text(
                      value.position + 1 == value.items.length
                          ? 'Finish for today'
                          : 'Continue',
                    ),
                  ),
                ],
              ),
            ] else
              Semantics(
                key: const ValueKey('engagement-brief-natural-stop'),
                container: true,
                liveRegion: true,
                label:
                    'A good place to stop. The brief is finished. Your To Read list is unchanged.',
                child: const ExcludeSemantics(
                  child: Padding(
                    padding: EdgeInsets.only(top: PakPerkSpacing.md),
                    child: Column(
                      children: [
                        Icon(Icons.check_circle_outline_rounded, size: 36),
                        SizedBox(height: PakPerkSpacing.xs),
                        Text(
                          'A good place to stop',
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: PakPerkSpacing.xxs),
                        Text(
                          'This brief is finished. Your To Read list is unchanged, and there is nothing else you need to do.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.subscription,
    required this.enabled,
    required this.onFrequencyChanged,
    required this.onMute,
    required this.onDelete,
  });

  final Subscription subscription;
  final bool enabled;
  final ValueChanged<SubscriptionFrequency> onFrequencyChanged;
  final VoidCallback onMute;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(PakPerkSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            subscription.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(subscription.kind.wireValue.replaceAll('_', ' ')),
          const SizedBox(height: PakPerkSpacing.sm),
          DropdownButtonFormField<SubscriptionFrequency>(
            key: ValueKey('engagement-frequency-${subscription.id}'),
            initialValue: subscription.frequency,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Frequency'),
            items: [
              for (final frequency in SubscriptionFrequency.values)
                DropdownMenuItem(
                  value: frequency,
                  child: Text(_frequencyLabel(frequency)),
                ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) onFrequencyChanged(value);
                  }
                : null,
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          Wrap(
            spacing: PakPerkSpacing.xs,
            runSpacing: PakPerkSpacing.xs,
            children: [
              if (subscription.frequency != SubscriptionFrequency.off)
                TextButton.icon(
                  key: ValueKey('engagement-mute-${subscription.id}'),
                  onPressed: enabled ? onMute : null,
                  icon: const Icon(Icons.notifications_off_outlined),
                  label: const Text('Mute'),
                )
              else
                const Chip(
                  avatar: Icon(Icons.notifications_off_outlined),
                  label: Text('Muted'),
                ),
              TextButton.icon(
                onPressed: enabled ? onDelete : null,
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text('Remove subscription'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

final class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.canMuteDiscoveryNotifications,
    required this.enabled,
    required this.onOpenPaper,
    required this.onRead,
    required this.onDismiss,
    required this.onMuteDiscoveryNotifications,
  });

  final InAppNotification notification;
  final bool canMuteDiscoveryNotifications;
  final bool enabled;
  final ValueChanged<PaperSummary> onOpenPaper;
  final VoidCallback onRead;
  final VoidCallback onDismiss;
  final ValueChanged<InAppNotificationType> onMuteDiscoveryNotifications;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(PakPerkSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            notification.type.displayTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (notification.papers.isNotEmpty) ...[
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(notification.papers.first.title),
          ],
          const SizedBox(height: PakPerkSpacing.sm),
          Wrap(
            spacing: PakPerkSpacing.xs,
            runSpacing: PakPerkSpacing.xs,
            children: [
              if (notification.papers.isNotEmpty)
                OutlinedButton(
                  onPressed: enabled
                      ? () => onOpenPaper(notification.papers.first)
                      : null,
                  child: const Text('Open paper'),
                ),
              if (!notification.isRead)
                TextButton(
                  onPressed: enabled ? onRead : null,
                  child: const Text('Mark read'),
                ),
              TextButton(
                onPressed: enabled ? onDismiss : null,
                child: const Text('Dismiss'),
              ),
              if (canMuteDiscoveryNotifications)
                TextButton.icon(
                  key: ValueKey(
                    'engagement-mute-notification-${notification.id}',
                  ),
                  onPressed: enabled
                      ? () => onMuteDiscoveryNotifications(notification.type)
                      : null,
                  icon: const Icon(Icons.notifications_off_outlined),
                  label: const Text('Mute this update type'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

final class _PreferenceCard extends StatelessWidget {
  const _PreferenceCard({
    required this.preferences,
    required this.enabled,
    required this.onInAppEnabledChanged,
    required this.onGlobalPauseChanged,
    required this.onNotificationTypeFrequencyChanged,
    required this.onDailyBudgetChanged,
    required this.onNotificationScheduleChanged,
  });

  final NotificationPreferences preferences;
  final bool enabled;
  final ValueChanged<bool> onInAppEnabledChanged;
  final ValueChanged<bool> onGlobalPauseChanged;
  final void Function(InAppNotificationType, SubscriptionFrequency)
  onNotificationTypeFrequencyChanged;
  final ValueChanged<int> onDailyBudgetChanged;
  final ValueChanged<NotificationScheduleDraft> onNotificationScheduleChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('engagement-in-app-enabled'),
          title: const Text('In-app notifications'),
          value: preferences.inAppEnabled,
          onChanged: enabled ? onInAppEnabledChanged : null,
        ),
        const Divider(height: 1),
        SwitchListTile.adaptive(
          title: const Text('Pause all in-app updates'),
          value: preferences.globalPause,
          onChanged: enabled ? onGlobalPauseChanged : null,
        ),
        const Divider(height: 1),
        Semantics(
          button: true,
          label: _scheduleSemantics(preferences),
          child: ListTile(
            key: const ValueKey('engagement-notification-schedule'),
            enabled: enabled,
            minVerticalPadding: PakPerkSpacing.sm,
            leading: const Icon(Icons.bedtime_outlined),
            title: const Text('Quiet hours and timezone'),
            subtitle: Text(_scheduleSummary(preferences)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: enabled
                ? () => _showNotificationScheduleEditor(
                    context,
                    preferences,
                    onNotificationScheduleChanged,
                  )
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PakPerkSpacing.md,
            PakPerkSpacing.md,
            PakPerkSpacing.md,
            PakPerkSpacing.xs,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Update frequency',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PakPerkSpacing.md,
            0,
            PakPerkSpacing.md,
            PakPerkSpacing.sm,
          ),
          child: Text(
            'Choose each type separately. Individual matches and discovery '
            'digests are alternatives.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final type in InAppNotificationType.values)
          _NotificationFrequencyField(
            type: type,
            value: preferences.typeFrequencies[type],
            enabled: enabled,
            onChanged: (value) =>
                onNotificationTypeFrequencyChanged(type, value),
          ),
        ListTile(
          title: Text('Daily in-app budget · ${preferences.dailyBudget}'),
          subtitle: Slider.adaptive(
            key: const ValueKey('engagement-daily-budget'),
            value: preferences.dailyBudget.toDouble(),
            min: 1,
            max: 20,
            divisions: 19,
            label: '${preferences.dailyBudget}',
            onChanged: enabled ? (_) {} : null,
            onChangeEnd: enabled
                ? (value) => onDailyBudgetChanged(value.round())
                : null,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            PakPerkSpacing.md,
            0,
            PakPerkSpacing.md,
            PakPerkSpacing.md,
          ),
          child: Text('Push and email remain unavailable in this release.'),
        ),
      ],
    ),
  );
}

final class _NotificationFrequencyField extends StatelessWidget {
  const _NotificationFrequencyField({
    required this.type,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final InAppNotificationType type;
  final SubscriptionFrequency value;
  final bool enabled;
  final ValueChanged<SubscriptionFrequency> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PakPerkSpacing.md,
      PakPerkSpacing.xs,
      PakPerkSpacing.md,
      PakPerkSpacing.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _notificationFrequencyTitle(type),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: PakPerkSpacing.xxs),
        Text(
          _notificationFrequencyHelp(type),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Semantics(
          container: true,
          label:
              '${_notificationFrequencyTitle(type)} frequency, '
              '${_frequencyLabel(value)}',
          child: ConstrainedBox(
            key: ValueKey('engagement-frequency-${type.wireValue}'),
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: DropdownButtonFormField<SubscriptionFrequency>(
              initialValue: value,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Frequency',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: PakPerkSpacing.md,
                  vertical: PakPerkSpacing.sm,
                ),
              ),
              items: [
                for (final frequency in SubscriptionFrequency.values)
                  DropdownMenuItem(
                    value: frequency,
                    child: Text(_frequencyLabel(frequency)),
                  ),
              ],
              onChanged: enabled
                  ? (next) {
                      if (next != null) onChanged(next);
                    }
                  : null,
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _showNotificationScheduleEditor(
  BuildContext context,
  NotificationPreferences preferences,
  ValueChanged<NotificationScheduleDraft> onChanged,
) async {
  final reducedMotion = platformPrefersReducedMotion(context);
  final draft = await showModalBottomSheet<NotificationScheduleDraft>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    barrierLabel: 'Dismiss quiet hours editor',
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (_) => _NotificationScheduleSheet(preferences: preferences),
  );
  if (draft != null && context.mounted) onChanged(draft);
}

final class _NotificationScheduleSheet extends StatefulWidget {
  const _NotificationScheduleSheet({required this.preferences});

  final NotificationPreferences preferences;

  @override
  State<_NotificationScheduleSheet> createState() =>
      _NotificationScheduleSheetState();
}

final class _NotificationScheduleSheetState
    extends State<_NotificationScheduleSheet> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _timezoneController;
  late bool _enabled;
  String? _error;

  @override
  void initState() {
    super.initState();
    final preferences = widget.preferences;
    _enabled =
        preferences.quietHoursStart != null &&
        preferences.quietHoursEnd != null;
    _startController = TextEditingController(
      text: _shortTime(preferences.quietHoursStart) ?? '22:00',
    );
    _endController = TextEditingController(
      text: _shortTime(preferences.quietHoursEnd) ?? '07:00',
    );
    _timezoneController = TextEditingController(text: preferences.timezone);
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _timezoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      label: 'Quiet hours and timezone',
      explicitChildNodes: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          PakPerkSpacing.lg,
          0,
          PakPerkSpacing.lg,
          media.viewInsets.bottom + media.padding.bottom + PakPerkSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Quiet hours',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: PakPerkSpacing.xxs),
              Text(
                'In-app updates wait until quiet hours end. Push and email remain off.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: PakPerkSpacing.sm),
              SwitchListTile.adaptive(
                key: const ValueKey('engagement-quiet-hours-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use quiet hours'),
                value: _enabled,
                onChanged: (value) => setState(() {
                  _enabled = value;
                  _error = null;
                }),
              ),
              const SizedBox(height: PakPerkSpacing.xs),
              TextField(
                key: const ValueKey('engagement-quiet-hours-start'),
                controller: _startController,
                enabled: _enabled,
                keyboardType: TextInputType.datetime,
                textInputAction: TextInputAction.next,
                maxLength: 5,
                inputFormatters: _clockInputFormatters,
                decoration: const InputDecoration(
                  labelText: 'Starts',
                  hintText: '22:00',
                  helperText: '24-hour time, HH:MM',
                ),
              ),
              TextField(
                key: const ValueKey('engagement-quiet-hours-end'),
                controller: _endController,
                enabled: _enabled,
                keyboardType: TextInputType.datetime,
                textInputAction: TextInputAction.next,
                maxLength: 5,
                inputFormatters: _clockInputFormatters,
                decoration: const InputDecoration(
                  labelText: 'Ends',
                  hintText: '07:00',
                  helperText: '24-hour time, HH:MM',
                ),
              ),
              TextField(
                key: const ValueKey('engagement-timezone'),
                controller: _timezoneController,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: 'Timezone',
                  hintText: 'Asia/Shanghai',
                  helperText: 'Use your IANA timezone name.',
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: PakPerkSpacing.xs),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: PakPerkSpacing.md),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: PakPerkSpacing.xs,
                runSpacing: PakPerkSpacing.xs,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: FilledButton(
                      key: const ValueKey('engagement-save-schedule'),
                      onPressed: _submit,
                      child: const Text('Save schedule'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    final timezone = _timezoneController.text.trim();
    final start = _startController.text.trim();
    final end = _endController.text.trim();
    if (timezone.isEmpty ||
        timezone.length > 64 ||
        _controlCharacters.hasMatch(timezone)) {
      setState(() => _error = 'Enter a valid timezone name.');
      return;
    }
    if (_enabled && (!_validClock(start) || !_validClock(end))) {
      setState(() => _error = 'Enter quiet hours as valid 24-hour times.');
      return;
    }
    Navigator.of(context).pop(
      NotificationScheduleDraft(
        enabled: _enabled,
        start: _enabled ? '$start:00' : null,
        end: _enabled ? '$end:00' : null,
        timezone: timezone,
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      const SizedBox(height: PakPerkSpacing.xxs),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

String _scheduleSummary(NotificationPreferences preferences) {
  final start = _shortTime(preferences.quietHoursStart);
  final end = _shortTime(preferences.quietHoursEnd);
  if (start == null || end == null) return 'Off · ${preferences.timezone}';
  return '$start–$end · ${preferences.timezone}';
}

String _scheduleSemantics(NotificationPreferences preferences) =>
    'Edit quiet hours and timezone. ${_scheduleSummary(preferences)}';

String? _shortTime(String? value) =>
    value != null && value.length >= 5 ? value.substring(0, 5) : null;

bool _validClock(String value) {
  if (!_clockPattern.hasMatch(value)) return false;
  final parts = value.split(':').map(int.parse).toList(growable: false);
  return parts[0] <= 23 && parts[1] <= 59;
}

final _clockInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
  LengthLimitingTextInputFormatter(5),
];
final _clockPattern = RegExp(r'^\d{2}:\d{2}$');
final _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

String _frequencyLabel(SubscriptionFrequency value) => switch (value) {
  SubscriptionFrequency.immediate => 'As they arrive',
  SubscriptionFrequency.daily => 'Daily',
  SubscriptionFrequency.weekly => 'Weekly',
  SubscriptionFrequency.off => 'Off',
};

String _notificationFrequencyTitle(InAppNotificationType type) =>
    switch (type) {
      InAppNotificationType.discoveryMatch => 'Paper matches',
      InAppNotificationType.discoveryDigest => 'Discovery digest',
      InAppNotificationType.userSelectedReminder => 'Reading reminders',
      InAppNotificationType.activePaperVersion => 'Paper version updates',
      InAppNotificationType.syncFailure => 'Sync notices',
    };

String _notificationFrequencyHelp(InAppNotificationType type) => switch (type) {
  InAppNotificationType.discoveryMatch =>
    'Individual papers that match your subscriptions.',
  InAppNotificationType.discoveryDigest =>
    'A grouped summary of discovery matches.',
  InAppNotificationType.userSelectedReminder =>
    'Reminders you explicitly set on active Library papers.',
  InAppNotificationType.activePaperVersion =>
    'Changes to papers you are actively reading.',
  InAppNotificationType.syncFailure =>
    'Updates when your library could not finish syncing.',
};
