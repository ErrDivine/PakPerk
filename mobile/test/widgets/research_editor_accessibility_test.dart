import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/features/annotations/annotation_editor.dart';
import 'package:pakperk/features/evidence/evidence_card_editor.dart';

void main() {
  testWidgets(
    'note editor supports 2x text, reduced effects, and 48pt commit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _AccessibleHarness(
          child: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                await showAnnotationEditor(
                  context: context,
                  kind: AnnotationKind.note,
                  selectedText: 'Exact source for the note.',
                );
              },
              child: const Text('Open note editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open note editor'));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Note editor for selected source text',
        ),
        findsOneWidget,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Save Note')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('evidence editor stays readable at 2x without blur dependency', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _AccessibleHarness(
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              await showEvidenceCardEditor(
                context: context,
                selectedText:
                    'A source-backed claim selected by the user for review.',
              );
            },
            child: const Text('Open evidence editor'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open evidence editor'));
    await tester.pumpAndSettle();

    expect(find.text('Save evidence'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester
          .getSize(find.widgetWithText(FilledButton, 'Save evidence card'))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('evidence editor blocks a title above the server scalar bound', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showEvidenceCardEditor(
                context: context,
                selectedText: 'Exact selected source.',
              ),
              child: const Text('Open evidence editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open evidence editor'));
    await tester.pumpAndSettle();

    // Each displayed grapheme contains two Unicode scalars. Flutter's visible
    // character counter alone would permit this, while the server correctly
    // rejects its 502-scalar title.
    final overBound = List.filled(251, 'e\u0301', growable: false).join();
    await tester.enterText(find.byType(TextField).first, overBound);
    await tester.pump();

    expect(find.text('Use 500 Unicode characters or fewer.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save evidence card'),
          )
          .onPressed,
      isNull,
    );
  });
}

class _AccessibleHarness extends StatelessWidget {
  const _AccessibleHarness({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: Scaffold(
          body: PakPerkAccessibilityPreferences(
            reduceTransparency: true,
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );
}
