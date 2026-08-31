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

    final controlTops = PaperStage.values
        .map(
          (stage) =>
              tester.getTopLeft(find.byKey(ValueKey('stage-${stage.name}'))).dy,
        )
        .toSet();
    expect(controlTops, hasLength(1));

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

      final selection = tester.widget<AnimatedPositionedDirectional>(
        find.byType(AnimatedPositionedDirectional),
      );
      expect(selection.duration, Duration.zero);
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
    expect(
      find.byKey(const ValueKey('stage-indicator-scroll')),
      findsOneWidget,
    );
    final abstractRect = tester.getRect(
      find.byKey(const ValueKey('stage-abstractView')),
    );
    final introductionRect = tester.getRect(
      find.byKey(const ValueKey('stage-introduction')),
    );
    final connectionsRect = tester.getRect(
      find.byKey(const ValueKey('stage-connections')),
    );
    expect(introductionRect.top, abstractRect.top);
    expect(connectionsRect.top, abstractRect.top);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection capsule follows the live reader page position', (
    tester,
  ) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PaperStageIndicator(
                currentStage: PaperStage.abstractView,
                pageController: controller,
                onSelected: (_) {},
              ),
              Expanded(
                child: PageView(
                  controller: controller,
                  children: const [
                    SizedBox.expand(),
                    SizedBox.expand(),
                    SizedBox.expand(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final capsule = find.byKey(const ValueKey('stage-selection-capsule'));
    final firstLeft = tester.getTopLeft(capsule).dx;
    final segmentWidth = tester
        .getSize(find.byKey(const ValueKey('stage-abstractView')))
        .width;

    controller.jumpTo(controller.position.viewportDimension * .5);
    await tester.pump();

    expect(
      tester.getTopLeft(capsule).dx,
      closeTo(firstLeft + segmentWidth * .5, 1),
    );
  });
}
