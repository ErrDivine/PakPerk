import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/research_memory.dart';
import 'package:pakperk/features/memory/memory_controller.dart';
import 'package:pakperk/features/memory/memory_review_screen.dart';

void main() {
  final now = DateTime.utc(2026, 8, 31, 12);
  final item = _item(now);

  testWidgets('review card is usable at 2x text on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        textScaler: const TextScaler.linear(2),
        state: MemoryReviewState(items: [item]),
        now: now,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Due for review'), findsOneWidget);
    expect(find.textContaining('streaks'), findsNothing);
    expect(tester.takeException(), isNull);

    final open = find.byKey(ValueKey('open-memory-source-${item.id}'));
    await tester.scrollUntilVisible(
      open,
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();
    final size = tester.getSize(open);
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));

    final reviewed = find.byKey(ValueKey('review-memory-${item.id}'));
    await tester.ensureVisible(reviewed);
    await tester.tap(reviewed);
    await tester.pumpAndSettle();

    final today = find.byKey(const ValueKey('memory-schedule-today'));
    expect(today, findsOneWidget);
    expect(tester.getSize(today).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion mode reveals the saved note immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        disableAnimations: true,
        state: MemoryReviewState(items: [item]),
        now: now,
      ),
    );

    await tester.tap(find.byKey(ValueKey('reveal-memory-${item.id}')));
    await tester.pump();

    expect(find.text(item.answerText!), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    final reviewed = find.byKey(ValueKey('review-memory-${item.id}'));
    await tester.ensureVisible(reviewed);
    await tester.tap(reviewed);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-schedule-today')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retirement names its Library-safe effect and confirms', (
    tester,
  ) async {
    MemoryItem? retired;
    await tester.pumpWidget(
      _app(
        state: MemoryReviewState(items: [item]),
        now: now,
        onRetire: (value) => retired = value,
      ),
    );

    final retire = find.byKey(ValueKey('retire-memory-${item.id}'));
    await tester.ensureVisible(retire);
    await tester.tap(retire);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Library state will not change'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-retire-memory')));
    await tester.pumpAndSettle();

    expect(retired?.id, item.id);
  });

  testWidgets('question source uses neutral paper copy instead of a UUID', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final question = _item(now, sourceType: MemorySourceType.userQuestion);
      await tester.pumpWidget(
        _app(
          state: MemoryReviewState(items: [question]),
          now: now,
        ),
      );

      expect(find.text('Your saved question'), findsOneWidget);
      expect(find.text('Source paper'), findsOneWidget);
      expect(find.text(question.paperId), findsNothing);
      final sourceSemantics = tester.getSemantics(find.text('Source paper'));
      expect(sourceSemantics.label, contains('Source paper'));
      expect(sourceSemantics.label, isNot(contains(question.paperId)));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('schedule choices return the exact selected preset', (
    tester,
  ) async {
    DateTime? scheduled;
    await tester.pumpWidget(
      _app(
        state: MemoryReviewState(items: [item]),
        now: now,
        onReviewed: (_, nextReviewAt) => scheduled = nextReviewAt,
      ),
    );

    final reviewed = find.byKey(ValueKey('review-memory-${item.id}'));
    await tester.ensureVisible(reviewed);
    await tester.tap(reviewed);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('memory-schedule-today')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('memory-schedule-tomorrow')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('memory-schedule-week')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('memory-schedule-custom')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('memory-schedule-tomorrow')));
    await tester.pumpAndSettle();

    expect(
      scheduled,
      memoryReviewPresetInstant(MemoryReviewSchedulePreset.tomorrow, now),
    );
  });

  testWidgets('custom schedule reports invalid dates before accepting one', (
    tester,
  ) async {
    DateTime? scheduled;
    await tester.pumpWidget(
      _app(
        state: MemoryReviewState(items: [item]),
        now: now,
        onSnooze: (_, nextReviewAt) => scheduled = nextReviewAt,
      ),
    );

    final snooze = find.byKey(ValueKey('snooze-memory-${item.id}'));
    await tester.ensureVisible(snooze);
    await tester.tap(snooze);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('memory-schedule-custom')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('memory-custom-date-input')),
      '2026-02-30',
    );
    final confirm = find.byKey(const ValueKey('memory-custom-date-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pump();

    expect(scheduled, isNull);
    expect(
      find.byKey(const ValueKey('memory-custom-date-error')),
      findsOneWidget,
    );
    expect(find.text('Enter a real calendar date.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('memory-custom-date-input')),
      '2026-09-15',
    );
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(scheduled, DateTime.utc(2026, 9, 15, 9));
  });

  test('custom schedule validation rejects malformed and past values', () {
    expect(validateCustomMemoryReviewDate('09/15/2026', now).isValid, isFalse);
    expect(validateCustomMemoryReviewDate('2026-08-01', now).isValid, isFalse);
    expect(validateCustomMemoryReviewDate('2032-01-01', now).isValid, isFalse);
  });
}

Widget _app({
  required MemoryReviewState state,
  required DateTime now,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
  ValueChanged<MemoryItem>? onRetire,
  MemoryScheduleCallback? onReviewed,
  MemoryScheduleCallback? onSnooze,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(390, 844),
      textScaler: textScaler,
      disableAnimations: disableAnimations,
    ),
    child: MemoryReviewScreen(
      state: state,
      now: now,
      onRefresh: () {},
      onOpenSource: (_) {},
      onReviewed: onReviewed ?? (_, _) {},
      onSnooze: onSnooze ?? (_, _) {},
      onRetire: onRetire ?? (_) {},
    ),
  ),
);

MemoryItem _item(
  DateTime now, {
  MemorySourceType sourceType = MemorySourceType.annotation,
}) => MemoryItem(
  id: '00000000-0000-4000-8000-000000000021',
  paperId: '00000000-0000-4000-8000-000000000011',
  generation: 3,
  sourceType: sourceType,
  sourceId: '00000000-0000-4000-8000-000000000031',
  promptText: 'Why did this result matter?',
  answerText: 'Because the ablation isolates the claimed mechanism.',
  status: MemoryStatus.active,
  nextReviewAt: now,
  reviewCount: 1,
  revision: 2,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 30),
  syncState: ResearchSyncState.clean,
);
