import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/provenance.dart';
import 'package:pakperk/features/document_reader/reader_progression.dart';
import 'package:pakperk/features/reader_modes/reader_mode.dart';

void main() {
  test(
    'section progress uses the complete outline across paginated blocks',
    () {
      final outline = DocumentOutline(
        paperId: '11111111-1111-4111-8111-111111111111',
        generation: 3,
        provenance: const ProvenanceSummary(status: 'ready'),
        sections: [
          _section(0, 'Introduction'),
          _section(1, 'Methods'),
          _section(2, 'Results'),
        ],
      );
      final titles = documentSectionProgressTitles(
        outline: outline,
        loadedBlocks: [_block(0, section: 'Introduction')],
      );

      expect(titles, ['Introduction', 'Methods', 'Results']);
      expect(sectionProgressIndex(titles, 'methods'), 1);
      expect(sectionProgressIndex(titles, 'unknown'), 0);
    },
  );

  test('Skim is bounded and never participates in automatic pagination', () {
    final blocks = List.generate(
      10,
      (index) => _block(index, section: index < 5 ? 'Methods' : 'Results'),
    );

    expect(
      visibleDocumentBlocksForMode(blocks, ReaderDepthMode.skim),
      hasLength(skimDocumentBlockLimit),
    );
    expect(
      visibleDocumentBlocksForMode(blocks, ReaderDepthMode.read),
      hasLength(10),
    );
    expect(
      shouldLoadNextDocumentPage(
        mode: ReaderDepthMode.skim,
        active: true,
        loadingMore: false,
        nextCursor: 'next',
        extentAfter: 0,
      ),
      isFalse,
    );
    expect(
      shouldRecordTrueDocumentEnd(
        mode: ReaderDepthMode.skim,
        active: true,
        nextCursor: null,
        extentAfter: 0,
      ),
      isFalse,
    );
    expect(
      shouldLoadNextDocumentPage(
        mode: ReaderDepthMode.read,
        active: true,
        loadingMore: false,
        nextCursor: 'next',
        extentAfter: 320,
      ),
      isTrue,
    );
    expect(
      shouldLoadNextDocumentPage(
        mode: ReaderDepthMode.read,
        active: false,
        loadingMore: false,
        nextCursor: 'next',
        extentAfter: 0,
      ),
      isFalse,
    );
    expect(
      shouldLoadNextDocumentPage(
        mode: ReaderDepthMode.read,
        active: true,
        loadingMore: true,
        nextCursor: 'next',
        extentAfter: 0,
      ),
      isFalse,
    );
    expect(isTopLevelSectionBoundary(blocks[4], blocks[5]), isTrue);
    expect(isTopLevelSectionBoundary(blocks[5], blocks[6]), isFalse);
  });

  test('assistant questions use the API scalar and null-character bound', () {
    expect(normalizedAssistantQuestion('  Why?  '), 'Why?');
    expect(normalizedAssistantQuestion('   '), isNull);
    expect(normalizedAssistantQuestion('why\u0000'), isNull);
    expect(normalizedAssistantQuestion(List.filled(501, 'a').join()), isNull);
    expect(
      normalizedAssistantQuestion(List.filled(500, '😀').join()),
      isNotNull,
    );
  });

  testWidgets(
    'persistent composer is 48pt-safe and retains a failed handoff draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var acceptsHandoff = false;
      var submissions = 0;
      final composition = <bool>[];
      final semantics = tester.ensureSemantics();

      Widget buildComposer() => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              ReadAssistantComposer(
                enabled: true,
                onCompositionChanged: composition.add,
                onSubmit: (question) async {
                  submissions += 1;
                  expect(question, 'What is the method?');
                  return acceptsHandoff;
                },
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(buildComposer());
      await tester.enterText(
        find.byKey(const ValueKey('read-assistant-question')),
        'What is the method?',
      );
      await tester.pump();

      final submit = find.byKey(const ValueKey('read-assistant-submit'));
      expect(tester.getSize(submit), const Size(48, 48));
      expect(
        find.bySemanticsLabel(RegExp('Persistent Read Assistant composer')),
        findsOneWidget,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(composition, contains(isTrue));
      expect(tester.takeException(), isNull);

      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(submissions, 1);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('read-assistant-question')),
            )
            .controller!
            .text,
        'What is the method?',
      );

      acceptsHandoff = true;
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(submissions, 2);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('read-assistant-question')),
            )
            .controller!
            .text,
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      expect(composition.last, isFalse);
      semantics.dispose();
    },
  );

  testWidgets('stopping point wraps 48pt actions at 320px and 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReaderStoppingPoint(
              semanticLabel: 'End of Methods. Next section: Results',
              title: 'End of Methods',
              message:
                  'Next: Results. Nothing was marked Reviewed or changed in your Library.',
              actions: [
                ReaderStoppingAction(
                  label: 'Continue',
                  icon: Icons.arrow_downward,
                  emphasized: true,
                  onPressed: () {},
                ),
                ReaderStoppingAction(
                  label: 'Save checkpoint',
                  icon: Icons.bookmark_add_outlined,
                  onPressed: () {},
                ),
                ReaderStoppingAction(
                  label: 'Open Library',
                  icon: Icons.local_library_outlined,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.bySemanticsLabel('End of Methods. Next section: Results'),
      findsOneWidget,
    );
    for (final label in ['Continue', 'Save checkpoint', 'Open Library']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is FilledButton || widget is OutlinedButton,
        ),
      );
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    }
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('section progress names the section at 320px and 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: ReaderSectionProgress(
              sections: ['Introduction', 'Methods', 'Results'],
              currentSection: 'Methods',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Section 2 of 3'), findsOneWidget);
    expect(find.text('Methods'), findsOneWidget);
    expect(find.text('Next: Results'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Reading section 2 of 3: Methods'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}

DocumentSection _section(int index, String title) => DocumentSection(
  id: '22222222-2222-4222-8222-${index.toString().padLeft(12, '0')}',
  stableKey: 'section:$index',
  title: title,
  level: 1,
  ordinal: index,
  blockIds: const [],
);

DocumentBlock _block(int index, {required String section}) => DocumentBlock(
  id: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
  paperId: '11111111-1111-4111-8111-111111111111',
  generation: 3,
  stableKey: '$section:paragraph:$index',
  ordinal: index,
  sectionPath: [section],
  kind: DocumentBlockKind.paragraph,
  text: 'Block $index',
  contentHash: 'hash-$index',
);
