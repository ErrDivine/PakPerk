import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/widgets/paper_stage_indicator.dart';

void main() {
  testWidgets('stage indicator labels and taps every horizontal view', (
    tester,
  ) async {
    PaperStage? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaperStageIndicator(
            currentStage: PaperStage.abstractView,
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    expect(find.text('Abstract'), findsOneWidget);
    expect(find.text('Introduction'), findsOneWidget);
    expect(find.text('Connections'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stage-connections')));
    expect(selected, PaperStage.connections);
  });

  testWidgets('stage indicator removes its transition for reduced motion', (
    tester,
  ) async {
    for (final media in const [
      MediaQueryData(disableAnimations: true),
      MediaQueryData(accessibleNavigation: true),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: media,
            child: Scaffold(
              body: PaperStageIndicator(
                currentStage: PaperStage.introduction,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );

      final dots = tester.widgetList<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(dots, isNotEmpty);
      expect(dots.every((dot) => dot.duration == Duration.zero), isTrue);
    }
  });

  testWidgets('stage labels remain physically scaled at 200 percent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<double> pumpAt(TextScaler scaler) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: Scaffold(
              body: PaperStageIndicator(
                currentStage: PaperStage.abstractView,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.text('Introduction')).height;
    }

    final normalHeight = await pumpAt(TextScaler.noScaling);
    final scaledHeight = await pumpAt(const TextScaler.linear(2));

    expect(find.byType(FittedBox), findsNothing);
    expect(scaledHeight, greaterThanOrEqualTo(normalHeight * 1.8));
    final abstractRect = tester.getRect(
      find.byKey(const ValueKey('stage-abstractView')),
    );
    final introductionRect = tester.getRect(
      find.byKey(const ValueKey('stage-introduction')),
    );
    final connectionsRect = tester.getRect(
      find.byKey(const ValueKey('stage-connections')),
    );
    expect(introductionRect.top, greaterThanOrEqualTo(abstractRect.bottom));
    expect(connectionsRect.top, greaterThanOrEqualTo(introductionRect.bottom));
    expect(tester.takeException(), isNull);
  });
}
