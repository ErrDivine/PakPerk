import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
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

    final openRecord = find.text('Open on arXiv');
    await tester.scrollUntilVisible(
      openRecord,
      280,
      scrollable: find.byKey(const PageStorageKey('abstract-scroll')),
    );
    await tester.tap(openRecord);
    await tester.pump();
    expect(links.opened, [Uri.parse('https://arxiv.org/abs/1706.03762v7')]);

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    final openPdf = find.text('Open original PDF on arXiv');
    await tester.scrollUntilVisible(
      openPdf,
      280,
      scrollable: find.byKey(const PageStorageKey('introduction-scroll')),
    );
    await tester.tap(openPdf);
    await tester.pump();
    expect(links.opened.last, Uri.parse('https://arxiv.org/pdf/1706.03762v7'));
  });
}

final class _RecordingLinks implements ExternalLinkOpener {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}
