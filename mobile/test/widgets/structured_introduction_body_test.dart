import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/widgets/reader_selection_area.dart';
import 'package:pakperk/features/document_reader/reader_interaction_state.dart';
import 'package:pakperk/core/document/arxiv_introduction_source.dart';
import 'package:pakperk/features/introduction/structured_introduction_body.dart';

const base = PaperIntroduction(
  paperId: 'p',
  generation: 1,
  heading: 'Introduction',
  paragraphs: [],
  detectionConfidence: 1,
  originalPdfUrl: 'https://arxiv.org/pdf/1909.04849v1',
);

Future<void> open(
  WidgetTester tester,
  PaperIntroduction content, {
  ProviderContainer? container,
}) async {
  final app = MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 720),
          textScaler: TextScaler.linear(1.7),
        ),
        child: SingleChildScrollView(
          child: ReaderSelectionArea(
            child: StructuredIntroductionBody(
              introduction: content,
              readerKey: 'test',
              onOpenPdf: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    container == null
        ? ProviderScope(child: app)
        : UncontrolledProviderScope(container: container, child: app),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('math remains inside the same text paragraph after wrapped lines', (
    tester,
  ) async {
    final content = PaperIntroduction(
      paperId: 'p',
      generation: 1,
      heading: 'Introduction',
      paragraphs: [],
      detectionConfidence: 1,
      originalPdfUrl: base.originalPdfUrl,
      sourceBlocks: [
        IntroductionSourceBlock(
          kind: 'paragraph',
          text:
              '${'Many words before the symbol. ' * 8}\$Z\$ and more words after it.',
        ),
      ],
    );
    await open(tester, content);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('Many words before') &&
            widget.text.toPlainText().contains('and more words after'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('short inline math stays on the same line as its sentence', (
    tester,
  ) async {
    final content = PaperIntroduction(
      paperId: 'p',
      generation: 1,
      heading: 'Introduction',
      paragraphs: [],
      detectionConfidence: 1,
      originalPdfUrl: base.originalPdfUrl,
      sourceBlocks: const [
        IntroductionSourceBlock(kind: 'paragraph', text: r'A $Z$ B'),
      ],
    );
    await open(tester, content);
    expect(
      tester.getSize(find.byType(StructuredIntroductionBody)).height,
      lessThan(75),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'wide table scrolls without changing reader and restores gestures',
    (tester) async {
      tester.view.reset();
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(
        readerInteractionControllerProvider('test'),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final content = PaperIntroduction(
        paperId: 'p',
        generation: 1,
        heading: 'Introduction',
        paragraphs: [],
        detectionConfidence: 1,
        originalPdfUrl: base.originalPdfUrl,
        sourceBlocks: const [
          IntroductionSourceBlock(
            kind: 'paragraph',
            text: r'A model with $x^2$ preserves inline math and normal words.',
          ),
          IntroductionSourceBlock(
            kind: 'table',
            text: 'Table 1: Results',
            rows: [
              ['Model', 'Score A', 'Score B', 'Score C'],
              ['A', '9', '8', '7'],
            ],
          ),
        ],
      );
      await open(tester, content, container: container);
      final table = find.byType(Table);
      final gesture = await tester.startGesture(
        tester.getCenter(table).translate(-100, 0),
      );
      await tester.pump();
      expect(
        container
            .read(readerInteractionControllerProvider('test'))
            .canDragPager,
        isFalse,
      );
      await gesture.moveBy(const Offset(-180, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        container
            .read(readerInteractionControllerProvider('test'))
            .canDragPager,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  const directory = String.fromEnvironment('PDF_REGRESSION_DIR');
  if (directory.isNotEmpty) {
    for (final id in ['1909.04849', '2611.26586', '2611.26538', '2611.26450']) {
      testWidgets('real Introduction renders without overflow: $id', (
        tester,
      ) async {
        final content = parseArxivIntroduction(
          File('$directory/$id.html').readAsStringSync(),
          Uri.parse('https://arxiv.org/html/${id}v1'),
          base,
        )!;
        await open(tester, content);
        expect(find.byType(StructuredIntroductionBody), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
