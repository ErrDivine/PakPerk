import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/models/semantic_span.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/document_reader/block_renderer.dart';
import 'package:pakperk/features/document_reader/document_screen.dart';
import 'package:pakperk/features/semantic/definition_sheet.dart';
import 'package:pakperk/features/semantic/facet_controller.dart';
import 'package:pakperk/features/semantic/faceted_text.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'density control restores per reader with 48 point targets at 2x type',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            initialRestorationProvider.overrideWithValue(
              const AppRestorationState(
                readerStates: {
                  'paper-a': ReaderNavigationState(
                    semanticDensity: SemanticDensity.detailed,
                  ),
                },
              ),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: const Scaffold(
                  body: SingleChildScrollView(
                    child: _DensityHarness(readerKey: 'paper-a'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final value in ['off', 'key', 'detailed']) {
        final finder = find.byKey(ValueKey('semantic-density-$value'));
        expect(finder, findsOneWidget);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
      }
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Detailed semantic cues' &&
              widget.properties.selected == true,
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
            .every((widget) => widget.duration == Duration.zero),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('semantic-density-off')));
      await tester.pump();
      expect(find.text('selected: off'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'facet cues use labels and invalid scalar ranges stay invisible',
    (tester) async {
      final valid = _span(
        id: _spanId,
        facet: SemanticFacet.method,
        end: 6,
        ordinal: 0,
      );
      final invalid = _span(
        id: _otherSpanId,
        facet: SemanticFacet.evidence,
        end: 999,
        ordinal: 1,
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
                body: SingleChildScrollView(
                  child: DocumentBlockRenderer(
                    block: _block,
                    terms: const [],
                    semanticSpans: [valid, invalid],
                    semanticDensity: SemanticDensity.key,
                    highlighted: false,
                    onSelectionChanged: (_) {},
                    onOpenTerm: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(ValueKey('semantic-facet-cue-${valid.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('semantic-facet-cue-${invalid.id}')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Method facet, supported',
        ),
        findsOneWidget,
      );
      expect(find.text('Method'), findsOneWidget);
      expect(find.text('Evidence'), findsNothing);
      final sourceText = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan != null,
        ),
      );
      expect(
        sourceText.textSpan!.toPlainText(
          includeSemanticsLabels: false,
          includePlaceholders: false,
        ),
        _block.text,
        reason: 'facet cues must not enter the selectable exact source text',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'symbol definitions disclose local meaning and exact source at 2x type',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(body: _DefinitionHarness(term: _symbolTerm)),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open definition'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('does not assume equivalence elsewhere'),
        findsOneWidget,
      );
      expect(find.text('Nearest current-paper context'), findsOneWidget);

      final source = find.widgetWithText(OutlinedButton, 'Open exact source');
      await tester.ensureVisible(source);
      await tester.pump();
      expect(tester.getSize(source).height, greaterThanOrEqualTo(48));
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.text('source: $_blockId'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('selection definition matching is exact, local, and unambiguous', () {
    expect(
      findUnambiguousPreparedTerm(
        selectedText: '  ALPHA  ',
        blockId: _blockId,
        terms: [_symbolTerm],
      ),
      same(_symbolTerm),
    );
    expect(
      findUnambiguousPreparedTerm(
        selectedText: 'Alpha',
        blockId: _otherBlockId,
        terms: [_symbolTerm],
      ),
      isNull,
    );
    expect(
      findUnambiguousPreparedTerm(
        selectedText: 'Alpha',
        blockId: _blockId,
        terms: [_symbolTerm, _ambiguousTerm],
      ),
      isNull,
    );
  });
}

class _DensityHarness extends ConsumerWidget {
  const _DensityHarness({required this.readerKey});

  final String readerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(semanticFacetDensityProvider(readerKey));
    return Column(
      children: [
        SemanticDensitySelector(
          selected: selected,
          onSelected: ref
              .read(semanticFacetControllerProvider(readerKey))
              .select,
        ),
        Text('selected: ${selected.wireValue}'),
      ],
    );
  }
}

class _DefinitionHarness extends StatefulWidget {
  const _DefinitionHarness({required this.term});

  final PaperTerm term;

  @override
  State<_DefinitionHarness> createState() => _DefinitionHarnessState();
}

class _DefinitionHarnessState extends State<_DefinitionHarness> {
  String? source;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FilledButton(
        onPressed: () async {
          final value = await showDefinitionSheet(
            context: context,
            term: widget.term,
            contextBlockId: _blockId,
          );
          if (mounted) setState(() => source = value);
        },
        child: const Text('Open definition'),
      ),
      Text('source: ${source ?? 'none'}'),
    ],
  );
}

SemanticSpan _span({
  required String id,
  required SemanticFacet facet,
  required int end,
  required int ordinal,
}) => SemanticSpan(
  id: id,
  blockId: _blockId,
  ordinal: ordinal,
  startOffset: 0,
  endOffset: end,
  facet: facet,
  minimumDensity: SemanticDensity.key,
  sourceKind: SemanticSpanSourceKind.deterministic,
  confidenceBasisPoints: 8000,
  supportStatus: SemanticSupportStatus.supported,
  provenanceId: _provenanceId,
  createdAt: DateTime.utc(2026, 8, 31),
);

final _block = DocumentBlock(
  id: _blockId,
  paperId: _paperId,
  generation: 7,
  stableKey: 'methods:paragraph:0',
  ordinal: 0,
  sectionPath: const ['Methods'],
  kind: DocumentBlockKind.paragraph,
  text: 'Method text 😀 remains selectable.',
  contentHash: 'hash',
);

final _symbolTerm = PaperTerm(
  id: _termId,
  displayTerm: 'Alpha',
  kind: PaperTermKind.symbol,
  definitionStatus: TermDefinitionStatus.available,
  sourceBlockIds: const [],
  occurrences: [
    TermOccurrence(blockId: _blockId, startOffset: 0, endOffset: 5),
  ],
  normalizedTerm: 'alpha',
  definitions: [
    TermDefinition(
      id: _definitionId,
      sourceType: TermDefinitionSource.currentPaper,
      sourceBlockIds: const [_blockId],
      definition: 'Alpha denotes the section-local coefficient.',
      confidenceStatus: TermDefinitionConfidence.supported,
    ),
    TermDefinition(
      id: _generatedDefinitionId,
      sourceType: TermDefinitionSource.generated,
      sourceBlockIds: const [],
      definition: 'A labeled generated explanation.',
      confidenceStatus: TermDefinitionConfidence.inferred,
      modelId: 'model',
      promptVersion: 'v1',
    ),
  ],
);

final _ambiguousTerm = PaperTerm(
  id: _otherTermId,
  displayTerm: 'Alpha',
  kind: PaperTermKind.term,
  definitionStatus: TermDefinitionStatus.available,
  sourceBlockIds: const [],
  occurrences: [
    TermOccurrence(
      blockId: _blockId,
      startOffset: 0,
      endOffset: 5,
      occurrenceOrdinal: 1,
    ),
  ],
  normalizedTerm: 'alpha',
  definitions: [
    TermDefinition(
      id: _otherDefinitionId,
      sourceType: TermDefinitionSource.currentPaper,
      sourceBlockIds: const [_blockId],
      definition: 'A second prepared meaning.',
      confidenceStatus: TermDefinitionConfidence.supported,
    ),
  ],
);

const _paperId = '11111111-1111-4111-8111-111111111111';
const _blockId = '22222222-2222-4222-8222-222222222222';
const _otherBlockId = '33333333-3333-4333-8333-333333333333';
const _spanId = '44444444-4444-4444-8444-444444444444';
const _otherSpanId = '55555555-5555-4555-8555-555555555555';
const _provenanceId = '66666666-6666-4666-8666-666666666666';
const _termId = '77777777-7777-4777-8777-777777777777';
const _otherTermId = '88888888-8888-4888-8888-888888888888';
const _definitionId = '99999999-9999-4999-8999-999999999999';
const _otherDefinitionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _generatedDefinitionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
