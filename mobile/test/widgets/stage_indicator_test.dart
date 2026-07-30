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
}
