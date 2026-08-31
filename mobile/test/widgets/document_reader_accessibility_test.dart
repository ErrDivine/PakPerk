import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/features/document_reader/block_renderer.dart';
import 'package:pakperk/features/document_reader/inline_reference_sheet.dart';
import 'package:pakperk/features/document_reader/selection_toolbar.dart';
import 'package:pakperk/features/document_reader/source_evidence_sheet.dart';

void main() {
  testWidgets(
    'inline references use Unicode scalars, win overlaps, and expose 48pt targets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const blockId = '11111111-1111-4111-8111-111111111111';
      final valid = const DocumentInlineSpan(
        kind: 'bibliography_reference',
        start: 4,
        end: 7,
        targetId: 'references:1',
        label: '[1]',
      );
      final block = DocumentBlock(
        id: blockId,
        paperId: '22222222-2222-4222-8222-222222222222',
        generation: 1,
        stableKey: 'results:paragraph:reference',
        ordinal: 0,
        sectionPath: const ['Results'],
        kind: DocumentBlockKind.paragraph,
        text: 'A😀B [1]',
        contentHash: 'hash-reference',
        inlineSpans: [
          valid,
          DocumentInlineSpan(
            kind: 'figure_reference',
            start: 4,
            end: 99,
            targetId: 'out-of-range',
          ),
          DocumentInlineSpan(
            kind: 'unknown_future_kind',
            start: 0,
            end: 1,
            targetId: 'unknown',
          ),
        ],
      );
      final term = PaperTerm(
        id: '33333333-3333-4333-8333-333333333333',
        displayTerm: '[1]',
        kind: PaperTermKind.term,
        definitionStatus: TermDefinitionStatus.notFound,
        sourceBlockIds: const [],
        occurrences: [
          TermOccurrence(blockId: blockId, startOffset: 4, endOffset: 7),
        ],
        normalizedTerm: '[1]',
      );
      DocumentInlineSpan? openedReference;
      var openedTerms = 0;
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: DocumentBlockRenderer(
                    block: block,
                    terms: [term],
                    highlighted: false,
                    onSelectionChanged: (_) {},
                    onOpenTerm: (_) => openedTerms += 1,
                    onOpenReference: (value) => openedReference = value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final action = find.byKey(
        const ValueKey('inline-reference-results:paragraph:reference-4-7'),
      );
      expect(action, findsOneWidget);
      expect(tester.getSize(action), const Size(48, 48));
      expect(
        find.bySemanticsLabel(RegExp('bibliography reference')),
        findsOneWidget,
      );
      expect(find.textContaining('out-of-range'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(action);
      expect(openedReference, same(valid));
      expect(openedTerms, 0);
      semantics.dispose();
    },
  );

  testWidgets(
    'external reference context is scroll-safe and never launches raw target',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      bool? openOriginal;
      final block = DocumentBlock(
        id: '44444444-4444-4444-8444-444444444444',
        paperId: '55555555-5555-4555-8555-555555555555',
        generation: 1,
        stableKey: 'methods:paragraph:external',
        ordinal: 0,
        sectionPath: const ['Methods'],
        kind: DocumentBlockKind.paragraph,
        text: List.filled(800, '😀 evidence').join(' '),
        contentHash: 'hash-external',
      );
      const reference = DocumentInlineSpan(
        kind: 'external_resource',
        start: 0,
        end: 1,
        targetId: 'https://untrusted.invalid/private-target',
        label: 'Project page',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    openOriginal = await showInlineReferenceContextSheet(
                      context: context,
                      block: block,
                      reference: reference,
                    );
                  },
                  child: const Text('Reference'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Reference'));
      await tester.pumpAndSettle();

      expect(find.text('External resource'), findsOneWidget);
      expect(find.textContaining('untrusted.invalid'), findsNothing);
      expect(find.textContaining('not opened directly'), findsOneWidget);
      final original = find.byKey(const ValueKey('inline-reference-original'));
      await tester.ensureVisible(original);
      expect(tester.getSize(original).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);

      await tester.tap(original);
      await tester.pumpAndSettle();
      expect(openOriginal, isTrue);
    },
  );

  testWidgets(
    'selection feedback is immediate, semantic, and motion-free when reduced',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      String? noted;
      String? highlighted;
      String? questioned;
      String? assistantQuestion;
      String? defined;
      String? evidenced;
      String? reattached;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: PakPerkAccessibilityPreferences(
                  reduceTransparency: true,
                  child: SelectionToolbarShell(
                    onSelectionChanged: (value) => selected = value,
                    onHighlight: (value) => highlighted = value,
                    onAddNote: (value) => noted = value,
                    onAskQuestion: (value) => questioned = value,
                    onAskAssistant: (value) => assistantQuestion = value,
                    onDefine: (value) => defined = value,
                    onSaveEvidence: (value) => evidenced = value,
                    onReattach: (value) => reattached = value,
                    child: const Text('Exact source sentence'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final area = tester.widget<SelectionArea>(find.byType(SelectionArea));
      area.onSelectionChanged!(
        const SelectedContent(plainText: 'Exact source sentence'),
      );
      expect(selected, 'Exact source sentence');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('selection-actions-on')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Selection actions',
        ),
        findsOneWidget,
      );
      for (final label in const [
        'Attach here',
        'Highlight',
        'Add note',
        'Question',
        'Ask assistant',
        'Define term',
        'Evidence',
      ]) {
        expect(
          tester.getSize(find.widgetWithText(OutlinedButton, label)).height,
          greaterThanOrEqualTo(48),
          reason: label,
        );
      }
      expect(
        tester
            .widgetList<AnimatedSwitcher>(find.byType(AnimatedSwitcher))
            .every((widget) => widget.duration == Duration.zero),
        isTrue,
      );
      expect(tester.takeException(), isNull);

      Future<void> tapAction(String label) async {
        final action = find.widgetWithText(OutlinedButton, label);
        await tester.ensureVisible(action);
        await tester.pump();
        await tester.tap(action);
      }

      await tapAction('Add note');
      expect(noted, 'Exact source sentence');
      await tapAction('Highlight');
      await tapAction('Question');
      await tapAction('Ask assistant');
      await tapAction('Define term');
      await tapAction('Evidence');
      await tapAction('Attach here');
      expect(highlighted, 'Exact source sentence');
      expect(questioned, 'Exact source sentence');
      expect(assistantQuestion, 'Exact source sentence');
      expect(defined, 'Exact source sentence');
      expect(evidenced, 'Exact source sentence');
      expect(reattached, 'Exact source sentence');
      expect(find.byType(BackdropFilter), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        selected,
        isNull,
        reason: 'A disposed selection no longer owns the pager gesture.',
      );
    },
  );

  testWidgets('exact-source highlight has a non-color semantic cue', (
    tester,
  ) async {
    const paperId = '00000000-0000-4000-8000-000000000001';
    final block = DocumentBlock(
      id: 'block-1',
      paperId: paperId,
      generation: 1,
      stableKey: 'methods:paragraph:0',
      ordinal: 0,
      sectionPath: const ['Methods'],
      kind: DocumentBlockKind.paragraph,
      text: 'The exact evidence remains readable at large text.',
      contentHash: 'hash-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: DocumentBlockRenderer(
                block: block,
                terms: const [],
                highlighted: true,
                onSelectionChanged: (_) {},
                onOpenTerm: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.selected == true &&
            widget.properties.label?.contains(
                  'exact source block highlighted',
                ) ==
                true,
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).duration,
      Duration.zero,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('prepared headings participate in screen-reader navigation', (
    tester,
  ) async {
    final block = DocumentBlock(
      id: 'block-heading',
      paperId: '00000000-0000-4000-8000-000000000001',
      generation: 1,
      stableKey: 'methods:heading:0',
      ordinal: 0,
      sectionPath: const ['Methods'],
      kind: DocumentBlockKind.heading,
      text: 'Methods',
      contentHash: 'hash-heading',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentBlockRenderer(
            block: block,
            terms: const [],
            highlighted: false,
            onSelectionChanged: (_) {},
            onOpenTerm: (_) {},
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.header == true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'exact-source range uses Unicode scalars and invalid ranges fail closed',
    (tester) async {
      const paperId = '00000000-0000-4000-8000-000000000001';
      final block = DocumentBlock(
        id: 'block-emoji',
        paperId: paperId,
        generation: 1,
        stableKey: 'results:paragraph:0',
        ordinal: 0,
        sectionPath: const ['Results'],
        kind: DocumentBlockKind.paragraph,
        text: 'A😀B exact source',
        contentHash: 'hash-emoji',
      );

      Future<void> pumpRange(int end) => tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: DocumentBlockRenderer(
                  block: block,
                  terms: const [],
                  highlighted: true,
                  highlightStart: 1,
                  highlightEnd: end,
                  onSelectionChanged: (_) {},
                  onOpenTerm: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      await pumpRange(2);
      final highlightedSpans = _leafTextSpans(
        tester.widget<Text>(find.byType(Text)).textSpan!,
      ).where((span) => span.style?.backgroundColor != null).toList();
      expect(highlightedSpans.map((span) => span.text), ['😀']);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.selected == true &&
              widget.properties.label?.contains(
                    'exact source range highlighted, characters 2 through 2',
                  ) ==
                  true,
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        Duration.zero,
      );

      await pumpRange(99);
      final invalidSpans = _leafTextSpans(
        tester.widget<Text>(find.byType(Text)).textSpan!,
      ).where((span) => span.style?.backgroundColor != null);
      expect(invalidSpans, isEmpty);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.selected == true,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source sheet opens immediately while a later page loads', (
    tester,
  ) async {
    final source = Completer<List<DocumentBlock>>();
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selected = await showSourceEvidenceSheet(
                  context: context,
                  title: 'Method evidence',
                  sourceBlockIds: const ['block-later'],
                  blocksById: const {},
                  loadSources: () => source.future,
                );
              },
              child: const Text('Open evidence'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open evidence'));
    await tester.pump();
    expect(find.text('Method evidence'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Loading exact source evidence',
      ),
      findsOneWidget,
    );

    source.complete([
      DocumentBlock(
        id: 'block-later',
        paperId: 'paper-1',
        generation: 1,
        stableKey: 'methods:paragraph:12',
        ordinal: 12,
        sectionPath: const ['Methods'],
        kind: DocumentBlockKind.paragraph,
        text: 'The exact later-page method evidence.',
        contentHash: 'hash-later',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('The exact later-page method evidence.'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ListTile)).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('The exact later-page method evidence.'));
    await tester.pumpAndSettle();
    expect(selected, 'block-later');
    expect(tester.takeException(), isNull);
  });
}

Iterable<TextSpan> _leafTextSpans(InlineSpan root) sync* {
  if (root case TextSpan(:final children)) {
    if (root.text != null) yield root;
    for (final child in children ?? const <InlineSpan>[]) {
      yield* _leafTextSpans(child);
    }
  }
}
