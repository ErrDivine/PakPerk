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
}
