import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/document/visual_asset_repository.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/features/document_reader/reader_interaction_state.dart';
import 'package:pakperk/features/visual_objects/document_object_navigator.dart';
import 'package:smart_latex/smart_latex.dart';

void main() {
  testWidgets(
    'figure sheet never renders an untrusted URL and exposes source actions',
    (tester) async {
      final interaction = ReaderInteractionController();
      addTearDown(interaction.dispose);
      String? referenceBlock;
      var sources = 0;
      var original = 0;
      var saved = 0;
      var asked = 0;
      final figure = DocumentFigure(
        id: _objectId,
        label: 'Figure 1',
        caption: 'A caption-only extraction.',
        page: 4,
        sourceBlockIds: const [_blockId],
        referencedBy: [_reference],
        status: DocumentObjectStatus.partial,
        limitation: 'Image derivative unavailable.',
        assetAvailable: false,
        assetUrl: 'https://assets.example.test/wrong-image.png',
      );

      await _pumpLauncher(
        tester,
        object: figure,
        interaction: interaction,
        onInspectSources: () => sources++,
        onInspectReference: (value) => referenceBlock = value,
        onOpenOriginal: () => original++,
        onSaveEvidence: () => saved++,
        onAskObject: () => asked++,
      );

      expect(interaction.state.objectInspectorActive, isTrue);
      expect(find.byType(Image), findsNothing);
      expect(
        find.textContaining('No trustworthy image derivative'),
        findsOneWidget,
      );
      expect(find.text('Referenced by'), findsOneWidget);
      expect(find.text(_referenceContext), findsOneWidget);

      await tester.tap(find.text(_referenceContext));
      expect(referenceBlock, _blockId);
      await _invokeAction(tester, 'Sources');
      await _invokeAction(tester, 'PDF · page 4');
      await _invokeAction(tester, 'Save evidence');
      await _invokeAction(tester, 'Ask about this');
      expect((sources, original, saved, asked), (1, 1, 1, 1));

      for (final label in const [
        'Sources',
        'PDF · page 4',
        'Save evidence',
        'Ask about this',
      ]) {
        final button = find.widgetWithText(OutlinedButton, label);
        expect(
          tester.getSize(button).height,
          greaterThanOrEqualTo(48),
          reason: label,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Close object'));
      await tester.pumpAndSettle();
      expect(interaction.state.objectInspectorActive, isFalse);
    },
  );

  testWidgets('requestable unprobed derivative loads and releases its lease', (
    tester,
  ) async {
    final interaction = ReaderInteractionController();
    addTearDown(interaction.dispose);
    final completion = Completer<VisualAssetLease>();
    var releases = 0;
    final bytes = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    final payload = VisualAssetPayload(
      bytes: bytes,
      contentType: 'image/png',
      checksum: sha256.convert(bytes).toString(),
    );
    final figure = DocumentFigure(
      id: _objectId,
      label: 'Figure 1',
      caption: 'Verified figure.',
      page: 4,
      sourceBlockIds: const [_blockId],
      status: DocumentObjectStatus.ready,
      limitation: null,
      assetAvailable: false,
      assetRequestable: true,
      assetUrl:
          '/v1/papers/paper/figures/$_objectId/asset?generation=4&revision=$_assetRevision',
      assetRevision: _assetRevision,
    );

    await _pumpLauncher(
      tester,
      object: figure,
      interaction: interaction,
      onInspectSources: () {},
      onInspectReference: (_) {},
      onOpenOriginal: () {},
      loadFigureAsset: (_) => completion.future,
      settle: false,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completion.complete(VisualAssetLease(payload, () => releases++));
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.imageProvider, isA<MemoryImage>());
    expect(resized.width, 1);
    expect(resized.height, 1);

    await tester.tap(find.byTooltip('Close object'));
    await tester.pumpAndSettle();
    expect(releases, 1);
  });

  testWidgets('large tables render one bounded row page at a time', (
    tester,
  ) async {
    final interaction = ReaderInteractionController();
    addTearDown(interaction.dispose);
    final rows = List.generate(
      26,
      (index) => [
        DocumentTableCell(
          text: 'row-${index + 1}',
          header: index == 0,
          rowSpan: 1,
          columnSpan: 1,
        ),
      ],
    );
    final table = DocumentTable(
      id: _objectId,
      label: 'Table 1',
      caption: 'Paged exact values.',
      page: 7,
      sourceBlockIds: const [_blockId],
      status: DocumentObjectStatus.ready,
      limitation: null,
      columns: const ['Value'],
      rows: rows.map((row) => [row.single.text]),
      structureRows: rows,
    );

    await _pumpLauncher(
      tester,
      object: table,
      interaction: interaction,
      onInspectSources: () {},
      onInspectReference: (_) {},
      onOpenOriginal: () {},
    );

    expect(find.text('row-1'), findsOneWidget);
    expect(find.text('row-26'), findsNothing);
    final next = find.byTooltip('Next table rows');
    expect(tester.getSize(next).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pump();
    expect(find.text('row-1'), findsNothing);
    expect(find.text('row-26'), findsOneWidget);
  });

  testWidgets(
    'table sheet announces headers and spans and provides exact plain text',
    (tester) async {
      final interaction = ReaderInteractionController();
      addTearDown(interaction.dispose);
      final table = DocumentTable(
        id: _objectId,
        label: 'Table 1',
        caption: 'Exact scores.',
        page: 7,
        sourceBlockIds: const [_blockId],
        referencedBy: [_reference],
        status: DocumentObjectStatus.ready,
        limitation: null,
        columns: const ['Model', 'Score'],
        rows: const [
          ['A', '9'],
        ],
        structureRows: const [
          [
            DocumentTableCell(
              text: 'Model and score',
              header: true,
              rowSpan: 1,
              columnSpan: 2,
            ),
          ],
          [
            DocumentTableCell(
              text: 'A',
              header: false,
              rowSpan: 1,
              columnSpan: 1,
            ),
            DocumentTableCell(
              text: '9',
              header: false,
              rowSpan: 1,
              columnSpan: 1,
            ),
          ],
        ],
        plainText: 'Model\tScore\nA\t9\nNote: exact reported values.',
      );

      await _pumpLauncher(
        tester,
        object: table,
        interaction: interaction,
        onInspectSources: () {},
        onInspectReference: (_) {},
        onOpenOriginal: () {},
      );

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label?.contains(
                    'Header, row 1, column 1, spans 2 columns',
                  ) ==
                  true,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Plain text'));
      await tester.pump();
      expect(
        find.textContaining('Note: exact reported values.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'equation renders accessibly and keeps selectable source and zoom',
    (tester) async {
      final interaction = ReaderInteractionController();
      addTearDown(interaction.dispose);
      final equation = DocumentEquation(
        id: _objectId,
        label: 'Equation 1',
        caption: null,
        page: 8,
        sourceBlockIds: const [_blockId],
        status: DocumentObjectStatus.ready,
        limitation: null,
        latex: r'x = \frac{a}{b}',
        plainText: 'x equals a divided by b',
      );

      await _pumpLauncher(
        tester,
        object: equation,
        interaction: interaction,
        onInspectSources: () {},
        onInspectReference: (_) {},
        onOpenOriginal: () {},
      );

      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        find.byKey(const ValueKey('equation-rendered-math')),
        findsOneWidget,
      );
      expect(
        tester.widget<SmartMath>(find.byType(SmartMath)).sanitize,
        isFalse,
      );
      expect(find.bySemanticsLabel('x equals a divided by b'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      final increase = find.byTooltip('Increase equation size');
      expect(tester.getSize(increase).height, greaterThanOrEqualTo(48));
      await tester.tap(increase);
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      expect(find.text('Copy LaTeX'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MathML-only equation renders and retains the exact source at large text',
    (tester) async {
      final interaction = ReaderInteractionController();
      addTearDown(interaction.dispose);
      const mathMl =
          '<math alttext="x equals a over b"><mrow><mi>x</mi><mo>=</mo>'
          '<mfrac><mi>a</mi><mi>b</mi></mfrac></mrow></math>';
      final equation = DocumentEquation(
        id: _objectId,
        label: 'Equation 2',
        caption: null,
        page: 9,
        sourceBlockIds: const [_blockId],
        status: DocumentObjectStatus.ready,
        limitation: null,
        mathMl: mathMl,
      );

      await _pumpLauncher(
        tester,
        object: equation,
        interaction: interaction,
        onInspectSources: () {},
        onInspectReference: (_) {},
        onOpenOriginal: () {},
        surfaceSize: const Size(320, 568),
      );

      expect(
        find.byKey(const ValueKey('equation-rendered-math')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('x equals a over b'), findsOneWidget);
      expect(find.text(mathMl), findsOneWidget);
      expect(find.text('Copy MathML'), findsOneWidget);
      final copy = find.widgetWithText(TextButton, 'Copy MathML');
      expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.widget<TextButton>(copy).onPressed!();
      await tester.pump();
      expect(copiedText, mathMl);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('LaTeX wins when both equation representations are present', (
    tester,
  ) async {
    final interaction = ReaderInteractionController();
    addTearDown(interaction.dispose);
    final equation = DocumentEquation(
      id: _objectId,
      label: 'Equation 3',
      caption: null,
      page: 10,
      sourceBlockIds: const [_blockId],
      status: DocumentObjectStatus.ready,
      limitation: null,
      latex: r'x^2',
      mathMl: '<math><script>must not render</script></math>',
      plainText: 'x squared',
    );

    await _pumpLauncher(
      tester,
      object: equation,
      interaction: interaction,
      onInspectSources: () {},
      onInspectReference: (_) {},
      onOpenOriginal: () {},
    );

    expect(
      find.byKey(const ValueKey('equation-rendered-math')),
      findsOneWidget,
    );
    expect(find.text(r'x^2'), findsOneWidget);
    expect(find.text('Copy LaTeX'), findsOneWidget);
    expect(find.text('Copy MathML'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported MathML fails closed to exact selectable source', (
    tester,
  ) async {
    final interaction = ReaderInteractionController();
    addTearDown(interaction.dispose);
    const source = '<math><script>must not execute</script></math>';
    final equation = DocumentEquation(
      id: _objectId,
      label: 'Equation 4',
      caption: null,
      page: 11,
      sourceBlockIds: const [_blockId],
      status: DocumentObjectStatus.partial,
      limitation: 'Structured equation rendering unavailable.',
      mathMl: source,
      plainText: 'Exact unrendered equation source',
    );

    await _pumpLauncher(
      tester,
      object: equation,
      interaction: interaction,
      onInspectSources: () {},
      onInspectReference: (_) {},
      onOpenOriginal: () {},
      surfaceSize: const Size(320, 568),
    );

    expect(find.byKey(const ValueKey('equation-rendered-math')), findsNothing);
    expect(find.text(source), findsOneWidget);
    expect(find.text('Copy MathML'), findsOneWidget);
    expect(find.textContaining('must not execute'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long visual captions scroll at 320px and 200% text', (
    tester,
  ) async {
    final interaction = ReaderInteractionController();
    addTearDown(interaction.dispose);
    final figure = DocumentFigure(
      id: _objectId,
      label: 'Figure with a long caption',
      caption: List.filled(600, 'Bounded caption evidence.').join(' '),
      page: 4,
      sourceBlockIds: const [_blockId],
      status: DocumentObjectStatus.partial,
      limitation: 'Image derivative unavailable.',
      assetAvailable: false,
    );

    await _pumpLauncher(
      tester,
      object: figure,
      interaction: interaction,
      onInspectSources: () {},
      onInspectReference: (_) {},
      onOpenOriginal: () {},
      surfaceSize: const Size(320, 568),
    );

    expect(
      find.byKey(const ValueKey('document-object-sheet-scroll')),
      findsOneWidget,
    );
    expect(find.byTooltip('Close object'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required DocumentEvidenceObject object,
  required ReaderInteractionController interaction,
  required VoidCallback onInspectSources,
  required ValueChanged<String> onInspectReference,
  required VoidCallback onOpenOriginal,
  VoidCallback? onSaveEvidence,
  VoidCallback? onAskObject,
  Future<VisualAssetLease> Function(RequestCancellation cancellation)?
  loadFigureAsset,
  bool settle = true,
  Size surfaceSize = const Size(430, 932),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: PakPerkAccessibilityPreferences(
            reduceTransparency: true,
            child: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showDocumentObjectSheet(
                    context: context,
                    object: object,
                    interaction: interaction,
                    onInspectSources: onInspectSources,
                    onInspectReference: onInspectReference,
                    onOpenOriginal: onOpenOriginal,
                    onSaveEvidence: onSaveEvidence,
                    onAskObject: onAskObject,
                    loadFigureAsset: loadFigureAsset,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
}

Future<void> _invokeAction(WidgetTester tester, String label) async {
  final button = tester.widget<OutlinedButton>(
    find.widgetWithText(OutlinedButton, label),
  );
  button.onPressed!();
  await tester.pump();
}

const _objectId = '11111111-1111-4111-8111-111111111111';
const _assetRevision =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _blockId = '22222222-2222-4222-8222-222222222222';
const _referenceContext = 'Results in Figure 1 support the conclusion.';
final _reference = DocumentObjectReference(
  blockId: _blockId,
  startOffset: 11,
  endOffset: 19,
  marker: 'Figure 1',
  context: _referenceContext,
  sectionPath: const ['Results'],
  pageNumber: 5,
);
