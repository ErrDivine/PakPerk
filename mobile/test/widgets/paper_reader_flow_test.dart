import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/paper_reader/paper_action_bar.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('committed Introduction navigation prepares exactly once', (
    tester,
  ) async {
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
    );
    final store = MemoryLocalStore();
    const readerKey = 'feed:test-paper';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(store),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PaperReader(
              paper: samplePaper,
              readerKey: readerKey,
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
    expect(repository.prepareCalls, 1);
    expect(find.text('1 Introduction'), findsOneWidget);
    final preparationLifecycle = repository.lastPrepareCancellation;
    expect(preparationLifecycle, isNotNull);
    expect(preparationLifecycle!.isCancelled, isFalse);

    await tester.tap(find.byKey(const ValueKey('stage-abstractView')));
    await tester.pumpAndSettle();
    expect(preparationLifecycle.isCancelled, isTrue);
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(repository.prepareCalls, 1);
  });

  testWidgets(
    'restored committed intent reissues prepare only when status is not requested',
    (tester) async {
      final notRequested = PaperProcessingState(
        paperId: samplePaper.paperId,
        overallState: 'not_requested',
        stage: ProcessingStage.notRequested,
        capabilities: const PaperCapabilities(),
        retryable: false,
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: notRequested,
        prepareResult: sampleProcessing,
        introduction: sampleIntroduction,
      );
      final store = MemoryLocalStore();
      const readerKey = 'feed:restored-paper';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paperRepositoryProvider.overrideWithValue(repository),
            localStoreProvider.overrideWithValue(store),
            initialRestorationProvider.overrideWithValue(
              const AppRestorationState(
                readerStates: {
                  readerKey: ReaderNavigationState(
                    stageIndex: 1,
                    prepareRequested: true,
                  ),
                },
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PaperReader(
                paper: samplePaper,
                readerKey: readerKey,
                isActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(repository.processingCalls, 1);
      expect(repository.prepareCalls, 1);
    },
  );

  testWidgets(
    'one synchronized save control persists across every paper stage',
    (tester) async {
      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: sampleProcessing,
        introduction: sampleIntroduction,
        connections: sampleConnections,
      );
      const readerKey = 'feed:library-paper';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(
              const FeatureFlags(
                accounts: true,
                library: true,
                comments: false,
                openingMotion: false,
              ),
            ),
            paperSavedStateProvider.overrideWith(
              (ref, paperId) => Stream.value(
                const LibrarySavedState(saved: true, syncPending: false),
              ),
            ),
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
                readerKey: readerKey,
                isActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stage-introduction')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stage-connections')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);
    },
  );

  testWidgets(
    'compact paper actions keep full labels and keyboard order at 320 px and 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final links = _RecordingLinks();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(
              const FeatureFlags(
                accounts: true,
                library: true,
                comments: true,
                openingMotion: false,
              ),
            ),
            paperSavedStateProvider.overrideWith(
              (ref, paperId) => Stream.value(
                const LibrarySavedState(saved: false, syncPending: false),
              ),
            ),
            externalLinkOpenerProvider.overrideWithValue(links),
          ],
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: PaperActionBar(paper: samplePaper),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Comments'), findsOneWidget);
      expect(find.text('arXiv'), findsOneWidget);
      for (final key in const [
        ValueKey('paper-save-label'),
        ValueKey('paper-comments-label'),
        ValueKey('paper-arxiv-label'),
      ]) {
        final label = tester.widget<Text>(find.byKey(key));
        expect(label.maxLines, isNull);
        expect(label.overflow, isNull);
      }

      expect(find.bySemanticsLabel('Save to To Read'), findsOneWidget);
      expect(find.bySemanticsLabel('Open paper discussions'), findsOneWidget);
      expect(find.bySemanticsLabel('Open on arXiv'), findsOneWidget);

      final controls = const [
        ValueKey('paper-save-control'),
        ValueKey('paper-comments-control'),
        ValueKey('paper-arxiv-control'),
      ];
      final centers = <Offset>[];
      for (final key in controls) {
        final control = find.byKey(key);
        expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(control).width, greaterThanOrEqualTo(48));
        centers.add(tester.getCenter(control));
      }
      expect(centers[0].dx, lessThan(centers[1].dx));
      expect(centers[1].dx, lessThan(centers[2].dx));

      for (final key in controls) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_focusedInkWellKey(), key);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(links.opened, [samplePaper.canonicalAbsUri]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_focusedInkWellKey(), const ValueKey('paper-comments-control'));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_focusedInkWellKey(), const ValueKey('paper-comments-control'));
      expect(links.opened, [samplePaper.canonicalAbsUri]);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('reduced motion commits an explicit stage jump immediately', (
    tester,
  ) async {
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
    );
    const readerKey = 'feed:reduced-motion-paper';

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
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: PaperReader(
                paper: samplePaper,
                readerKey: readerKey,
                isActive: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PaperReader)),
    );
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pump();

    expect(
      container.read(readerNavigationStateProvider(readerKey)).stageIndex,
      PaperStage.introduction.index,
    );
  });

  testWidgets('arXiv actions ignore untrusted model URLs', (tester) async {
    final paper = PaperSummary(
      paperId: samplePaper.paperId,
      arxivId: samplePaper.arxivId,
      title: samplePaper.title,
      abstractText: samplePaper.abstractText,
      authors: samplePaper.authors,
      primaryCategory: samplePaper.primaryCategory,
      categories: samplePaper.categories,
      publishedAt: samplePaper.publishedAt,
      updatedAt: samplePaper.updatedAt,
      absUrl: 'javascript:alert(1)',
      pdfUrl: 'https://arxiv.org/pdf/9999.99999v1',
      capabilities: samplePaper.capabilities,
    );
    final repository = FakePaperDataSource(
      paper: paper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
    );
    final links = _RecordingLinks();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          externalLinkOpenerProvider.overrideWithValue(links),
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PaperReader(
              paper: paper,
              readerKey: 'feed:trusted-arxiv-links',
              isActive: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('paper-arxiv-control')), findsOneWidget);
    expect(find.bySemanticsLabel('Open on arXiv'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paper-arxiv-control')));
    await tester.pump();
    expect(links.opened, [Uri.parse('https://arxiv.org/abs/1706.03762v7')]);

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    final openPdf = find.text('Open original PDF on arXiv');
    await tester.scrollUntilVisible(
      openPdf,
      280,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey('introduction-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(openPdf);
    await tester.pump();
    expect(links.opened.last, Uri.parse('https://arxiv.org/pdf/1706.03762v7'));
  });
}

Key? _focusedInkWellKey() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<InkWell>()
    ?.key;

final class _RecordingLinks implements ExternalLinkOpener {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}
