import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/engagement/engagement_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/engagement/engagement_screen.dart';

void main() {
  testWidgets('brief resume and progress are explicit and queue bounded', (
    tester,
  ) async {
    final opened = <PaperSummary>[];
    var advanced = 0;
    await _pump(
      tester,
      readingBriefsEnabled: true,
      onOpenPaper: opened.add,
      onAdvanceBrief: () => advanced += 1,
    );

    expect(find.text('To Read remains authoritative'), findsOneWidget);
    expect(find.text('To Read brief'), findsOneWidget);
    final open = find.byKey(const ValueKey('engagement-open-brief-paper'));
    final advance = find.byKey(const ValueKey('engagement-advance-brief'));
    expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(advance).height, greaterThanOrEqualTo(48));
    await tester.tap(open);
    await tester.tap(advance);
    expect(opened, [_paper]);
    expect(advanced, 1);
  });

  testWidgets('notifications render typed copy and never advertise push', (
    tester,
  ) async {
    await _pump(tester, notificationsEnabled: true);
    expect(find.text('New discovery match'), findsOneWidget);
    expect(find.text('raw private payload'), findsNothing);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Push and email remain unavailable in this release.'),
      400,
      scrollable: scrollable,
    );
    expect(
      find.text('Push and email remain unavailable in this release.'),
      findsOneWidget,
    );
    expect(find.textContaining('Enable push'), findsNothing);
  });

  testWidgets('finished brief presents a natural stop without pressure copy', (
    tester,
  ) async {
    await _pump(
      tester,
      readingBriefsEnabled: true,
      briefOnly: true,
      completedBrief: true,
    );

    expect(
      find.byKey(const ValueKey('engagement-brief-natural-stop')),
      findsOneWidget,
    );
    expect(find.text('A good place to stop'), findsOneWidget);
    expect(find.textContaining('nothing else you need to do'), findsOneWidget);
    expect(find.textContaining('streak'), findsNothing);
    expect(find.textContaining('Keep going'), findsNothing);
  });

  testWidgets('subscription and discovery notification expose truthful mute', (
    tester,
  ) async {
    final muted = <Subscription>[];
    final mutedTypes = <InAppNotificationType>[];
    await _pump(
      tester,
      subscriptionsEnabled: true,
      notificationsEnabled: true,
      onMuteSubscription: muted.add,
      onMuteDiscoveryNotifications: mutedTypes.add,
    );

    final subscriptionMute = find.byKey(
      ValueKey('engagement-mute-${_subscription.id}'),
    );
    expect(subscriptionMute, findsOneWidget);
    expect(tester.getSize(subscriptionMute).height, greaterThanOrEqualTo(48));
    await tester.tap(subscriptionMute);

    final scrollable = find.byType(Scrollable).first;
    final notificationMute = find.byKey(
      ValueKey('engagement-mute-notification-${_notification.id}'),
    );
    await tester.scrollUntilVisible(
      notificationMute,
      350,
      scrollable: scrollable,
    );
    await tester.tap(notificationMute);
    expect(muted, [_subscription]);
    expect(mutedTypes, [InAppNotificationType.discoveryMatch]);
  });

  testWidgets('each in-app update type has an accessible frequency control', (
    tester,
  ) async {
    final changes =
        <({InAppNotificationType type, SubscriptionFrequency frequency})>[];
    await _pump(
      tester,
      notificationsEnabled: true,
      onNotificationTypeFrequencyChanged: (type, frequency) =>
          changes.add((type: type, frequency: frequency)),
    );

    final scrollable = find.byType(Scrollable).first;
    for (final type in InAppNotificationType.values) {
      final control = find.byKey(
        ValueKey('engagement-frequency-${type.wireValue}'),
      );
      await tester.scrollUntilVisible(control, 350, scrollable: scrollable);
      expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('engagement-frequency-discovery_match')),
      350,
      scrollable: scrollable,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Paper matches frequency, As they arrive'),
      ),
      findsOneWidget,
    );

    final matchControl = find.byKey(
      const ValueKey('engagement-frequency-discovery_match'),
    );
    final dropdown = tester
        .widget<DropdownButtonFormField<SubscriptionFrequency>>(
          find.descendant(
            of: matchControl,
            matching: find.byType(
              DropdownButtonFormField<SubscriptionFrequency>,
            ),
          ),
        );
    dropdown.onChanged!(SubscriptionFrequency.weekly);
    await tester.pump();
    expect(changes, [
      (
        type: InAppNotificationType.discoveryMatch,
        frequency: SubscriptionFrequency.weekly,
      ),
    ]);
  });

  testWidgets('quiet hours and timezone editor is bounded and reduced-motion', (
    tester,
  ) async {
    NotificationScheduleDraft? saved;
    await _pump(
      tester,
      notificationsEnabled: true,
      media: const MediaQueryData(
        textScaler: TextScaler.linear(1.5),
        disableAnimations: true,
      ),
      onNotificationScheduleChanged: (value) => saved = value,
    );

    final scrollable = find.byType(Scrollable).first;
    final schedule = find.byKey(
      const ValueKey('engagement-notification-schedule'),
    );
    await tester.scrollUntilVisible(schedule, 400, scrollable: scrollable);
    expect(tester.getSize(schedule).height, greaterThanOrEqualTo(48));
    await tester.tap(schedule);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Quiet hours and timezone'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('engagement-quiet-hours-start')),
      '21:30',
    );
    await tester.enterText(
      find.byKey(const ValueKey('engagement-quiet-hours-end')),
      '06:45',
    );
    await tester.enterText(
      find.byKey(const ValueKey('engagement-timezone')),
      'Europe/Paris',
    );
    final save = find.byKey(const ValueKey('engagement-save-schedule'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved?.enabled, isTrue);
    expect(saved?.start, '21:30:00');
    expect(saved?.end, '06:45:00');
    expect(saved?.timezone, 'Europe/Paris');
  });

  testWidgets('narrow Dynamic Type and reduced motion stay scrollable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      readingBriefsEnabled: true,
      subscriptionsEnabled: true,
      notificationsEnabled: true,
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
    );

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('engagement-add-subscription')),
      450,
      scrollable: scrollable,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('engagement-add-subscription')))
          .height,
      greaterThanOrEqualTo(48),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('engagement-in-app-enabled')),
      450,
      scrollable: scrollable,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('engagement-frequency-sync_failure')),
      450,
      scrollable: scrollable,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  bool readingBriefsEnabled = false,
  bool subscriptionsEnabled = false,
  bool notificationsEnabled = false,
  bool briefOnly = false,
  bool completedBrief = false,
  ValueChanged<PaperSummary>? onOpenPaper,
  VoidCallback? onAdvanceBrief,
  ValueChanged<Subscription>? onMuteSubscription,
  ValueChanged<InAppNotificationType>? onMuteDiscoveryNotifications,
  void Function(InAppNotificationType, SubscriptionFrequency)?
  onNotificationTypeFrequencyChanged,
  ValueChanged<NotificationScheduleDraft>? onNotificationScheduleChanged,
  MediaQueryData media = const MediaQueryData(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PakPerkTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: media.textScaler,
            disableAnimations: media.disableAnimations,
          ),
          child: EngagementScreen(
            briefOnly: briefOnly,
            readingBriefsEnabled: readingBriefsEnabled,
            subscriptionsEnabled: subscriptionsEnabled,
            notificationsEnabled: notificationsEnabled,
            brief: readingBriefsEnabled
                ? completedBrief
                      ? _completedBrief
                      : _brief
                : null,
            subscriptions: subscriptionsEnabled ? [_subscription] : const [],
            notifications: notificationsEnabled ? [_notification] : const [],
            preferences: notificationsEnabled ? _preferences : null,
            loading: false,
            busy: false,
            errorMessage: null,
            onRetry: () {},
            onCreateBrief: () {},
            onAdvanceBrief: onAdvanceBrief ?? () {},
            onOpenPaper: onOpenPaper ?? (_) {},
            onAddSubscription: () {},
            onSubscriptionFrequencyChanged: (_, __) {},
            onMuteSubscription: onMuteSubscription ?? (_) {},
            onMuteDiscoveryNotifications:
                onMuteDiscoveryNotifications ?? (_) {},
            onDeleteSubscription: (_) {},
            onMarkNotificationRead: (_) {},
            onDismissNotification: (_) {},
            onMarkAllNotificationsRead: () {},
            onInAppEnabledChanged: (_) {},
            onGlobalPauseChanged: (_) {},
            onNotificationTypeFrequencyChanged:
                onNotificationTypeFrequencyChanged ?? (_, __) {},
            onDailyBudgetChanged: (_) {},
            onNotificationScheduleChanged:
                onNotificationScheduleChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

final _brief = ReadingBrief(
  id: '10000000-0000-4000-8000-000000000001',
  mode: ReadingBriefMode.queue,
  recommendationMode: null,
  libraryRevision: 8,
  recommendationBatchId: null,
  localDate: '2026-08-19',
  position: 0,
  progressRevision: 1,
  status: ReadingBriefStatus.current,
  items: [
    ReadingBriefItem(
      ordinal: 0,
      paper: _paper,
      source: ReadingBriefItemSource.toRead,
      reasonCodes: const [],
    ),
  ],
  createdAt: DateTime.utc(2026, 8, 19, 10),
  updatedAt: DateTime.utc(2026, 8, 19, 10),
  completedAt: null,
);

final _completedBrief = ReadingBrief(
  id: _brief.id,
  mode: ReadingBriefMode.queue,
  recommendationMode: null,
  libraryRevision: _brief.libraryRevision,
  recommendationBatchId: null,
  localDate: _brief.localDate,
  position: 1,
  progressRevision: 2,
  status: ReadingBriefStatus.complete,
  items: _brief.items,
  createdAt: _brief.createdAt,
  updatedAt: DateTime.utc(2026, 8, 19, 11),
  completedAt: DateTime.utc(2026, 8, 19, 11),
);

final _subscription = Subscription(
  id: '20000000-0000-4000-8000-000000000002',
  kind: SubscriptionKind.topic,
  key: 'retrieval',
  label: 'Information retrieval',
  savedSearchId: null,
  frequency: SubscriptionFrequency.daily,
  lastEvaluatedAt: null,
  revision: 1,
  deleted: false,
  createdAt: DateTime.utc(2026, 8, 19, 10),
  updatedAt: DateTime.utc(2026, 8, 19, 10),
);

final _notification = InAppNotification(
  id: '30000000-0000-4000-8000-000000000003',
  type: InAppNotificationType.discoveryMatch,
  scope: InAppNotificationScope.discovery,
  entityType: NotificationEntityType.paper,
  entityId: _paper.paperId,
  deliveryEligibility: NotificationDeliveryEligibility.eligible,
  eligibilityLibraryRevision: 8,
  createdAt: DateTime.utc(2026, 8, 19, 10),
  readAt: null,
  expiresAt: DateTime.utc(2026, 8, 26, 10),
  papers: [_paper],
);

final _preferences = NotificationPreferences(
  typeFrequencies: const NotificationTypeFrequencies(
    discoveryMatch: SubscriptionFrequency.immediate,
    discoveryDigest: SubscriptionFrequency.off,
    userSelectedReminder: SubscriptionFrequency.immediate,
    activePaperVersion: SubscriptionFrequency.weekly,
    syncFailure: SubscriptionFrequency.daily,
  ),
  quietHoursStart: '22:00:00',
  quietHoursEnd: '07:00:00',
  timezone: 'Asia/Shanghai',
  inAppEnabled: true,
  globalPause: false,
  dailyBudget: 5,
  revision: 1,
  updatedAt: DateTime.utc(2026, 8, 19, 10),
);

final _paper = PaperSummary(
  paperId: '40000000-0000-4000-8000-000000000004',
  arxivId: '1706.03762v7',
  title: 'Attention Is All You Need',
  abstractText: 'Transformer architecture.',
  authors: const ['Ashish Vaswani'],
  primaryCategory: 'cs.CL',
  categories: const ['cs.CL', 'cs.LG'],
  publishedAt: DateTime.utc(2017, 6, 12),
  updatedAt: DateTime.utc(2023, 8, 2),
  absUrl: 'https://arxiv.org/abs/1706.03762v7',
  pdfUrl: 'https://arxiv.org/pdf/1706.03762v7.pdf',
);
