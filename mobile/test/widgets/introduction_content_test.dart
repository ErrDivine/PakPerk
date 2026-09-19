import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/introduction/introduction_view.dart';
import 'package:pakperk/features/paper_reader/paper_processing_controller.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';

import '../support/fakes.dart';

Future<void> tapInlineMarker(WidgetTester tester, int offset) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byKey(const ValueKey('introduction-paragraph-0')),
      matching: find.byType(RichText),
    ),
  );
  final caret = paragraph.getOffsetForCaret(
    TextPosition(offset: offset),
    Rect.zero,
  );
  await tester.tapAt(paragraph.localToGlobal(caret + const Offset(3, 8)));
}

void main() {
  testWidgets(
    'resolved citation is tappable while unresolved marker stays readable',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const paragraph = IntroductionParagraph(
        ordinal: 0,
        text: 'We use [1] but retain [2].',
        citations: [
          IntroductionCitation(
            start: 7,
            end: 10,
            marker: '[1]',
            references: [
              IntroductionCitationReference(
                paperId: 'paper-2',
                title: 'Resolved paper',
              ),
            ],
          ),
        ],
      );
      IntroductionCitation? opened;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IntroductionParagraphText(
              paragraph: paragraph,
              onOpenCitation: (citation) => opened = citation,
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(
        find.byKey(const ValueKey('introduction-paragraph-0')),
      );
      expect(
        text.textSpan!.toPlainText(includeSemanticsLabels: false),
        'We use [1] but retain [2].',
      );
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans.where((span) => span.text == '[1]'), hasLength(1));
      final link = spans.singleWhere((span) => span.text == '[1]');
      expect(link.recognizer, isA<TapGestureRecognizer>());
      expect(link.semanticsLabel, '[1], citation to Resolved paper');
      await tapInlineMarker(tester, 7);
      expect(opened?.references.single.paperId, 'paper-2');
      semantics.dispose();
    },
  );

  testWidgets('compound citation stays in one clickable inline span', (
    tester,
  ) async {
    const paragraph = IntroductionParagraph(
      ordinal: 0,
      text: 'Résumé cites [51, 52]. While this continues.',
      citations: [
        IntroductionCitation(
          start: 13,
          end: 21,
          marker: '[51, 52]',
          references: [
            IntroductionCitationReference(paperId: 'first', title: 'First'),
            IntroductionCitationReference(paperId: 'second', title: 'Second'),
          ],
        ),
      ],
    );
    IntroductionCitation? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: IntroductionParagraphText(
              paragraph: paragraph,
              onOpenCitation: (citation) => opened = citation,
            ),
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('introduction-paragraph-0')),
    );
    expect(
      text.textSpan!.toPlainText(includeSemanticsLabels: false),
      paragraph.text,
    );
    final spans = (text.textSpan! as TextSpan).children!;
    expect(spans.whereType<WidgetSpan>(), isEmpty);
    final marker = spans.whereType<TextSpan>().singleWhere(
      (span) => span.text == '[51, 52]',
    );
    expect(marker.recognizer, isA<TapGestureRecognizer>());
    await tapInlineMarker(tester, 13);
    expect(opened?.references.map((reference) => reference.paperId), [
      'first',
      'second',
    ]);
  });

  testWidgets('nested Introduction heading renders as a semantic subheading', (
    tester,
  ) async {
    final introduction = PaperIntroduction(
      paperId: samplePaper.paperId,
      generation: 1,
      heading: '1 Introduction',
      paragraphs: const [
        IntroductionParagraph(
          ordinal: 0,
          text: 'Opening paragraph.',
          pageStart: 1,
          pageEnd: 1,
        ),
        IntroductionParagraph(
          ordinal: 1,
          text: 'Motivation remains part of the introduction.',
          heading: '1.1 Motivation',
          pageStart: 2,
          pageEnd: 2,
        ),
      ],
      detectionConfidence: .99,
      originalPdfUrl: samplePaper.pdfUrl,
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: introduction,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PaperReader(
              paper: samplePaper,
              readerKey: 'feed:introduction-headings',
              isActive: true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();

    final heading = find.byKey(const ValueKey('introduction-subheading-1'));
    expect(heading, findsOneWidget);
    expect(find.text('1.1 Motivation'), findsOneWidget);
    expect(tester.getSemantics(heading).flagsCollection.isHeader, isTrue);
  });

  testWidgets('Introduction refreshes once when references become ready', (
    tester,
  ) async {
    final resolving = PaperProcessingState(
      paperId: samplePaper.paperId,
      overallState: 'processing',
      stage: ProcessingStage.resolvingReferences,
      capabilities: const PaperCapabilities(introduction: true, chat: true),
      retryable: false,
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: resolving,
      prepareResult: resolving,
      introduction: sampleIntroduction,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PaperReader(
              paper: samplePaper,
              readerKey: 'feed:introduction-citation-refresh',
              isActive: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(repository.introductionCalls, 1);

    repository.processing = sampleProcessing;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PaperReader)),
    );
    final processing = container.read(
      paperProcessingControllerProvider(samplePaper.versionKey).notifier,
    );
    await processing.refresh();
    await tester.pump();
    expect(repository.introductionCalls, 2);

    await processing.refresh();
    await tester.pump();
    expect(repository.introductionCalls, 2);
  });
}
