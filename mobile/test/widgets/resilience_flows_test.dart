import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('offline launch publishes cached feed without awaiting network', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper)
      ..offline = true
      ..networkFeedCompleter = Completer<RepositoryValue<FeedPage>>();
    final store = MemoryLocalStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(store),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: const PakPerkApp(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Attention Is All You Need'), findsOneWidget);
    expect(find.text('OFFLINE · Showing cached paper data'), findsOneWidget);
    expect(repository.networkFeedCompleter!.isCompleted, isFalse);
  });

  testWidgets(
    'route refresh starts the newer version with fresh reader state',
    (tester) async {
      const routeId = 'version-refresh-route';
      final newerPaper = PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '1706.03762v8',
      );
      final oldReaderKey = routeReaderKey(routeId, samplePaper);
      final newReaderKey = routeReaderKey(routeId, newerPaper);
      final repository = FakePaperDataSource(
        paper: newerPaper,
        processing: sampleProcessing,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paperRepositoryProvider.overrideWithValue(repository),
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            initialRestorationProvider.overrideWithValue(
              AppRestorationState(
                routeStack: [
                  PaperRouteEntry(routeId: routeId, paper: samplePaper),
                ],
                readerStates: {
                  oldReaderKey: const ReaderNavigationState(
                    stageIndex: 2,
                    connectionsOffset: 280,
                    chatSheetOpen: true,
                    chatThreadId: 'old-version-thread',
                    prepareRequested: true,
                  ),
                },
              ),
            ),
          ],
          child: const PakPerkApp(),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      final restoration = container.read(appRestorationControllerProvider);
      expect(restoration.routeStack.last.paper.arxivId, '1706.03762v8');
      expect(restoration.readerStates, isNot(contains(oldReaderKey)));
      expect(restoration.readerState(oldReaderKey).stageIndex, 0);
      final freshReader = restoration.readerState(newReaderKey);
      expect(freshReader.stageIndex, 0);
      expect(freshReader.connectionsOffset, 0);
      expect(freshReader.prepareRequested, isFalse);
      expect(freshReader.chatSheetOpen, isFalse);
      expect(freshReader.chatThreadId, isNull);
      expect(
        find.byKey(ValueKey('paper-reader-$newReaderKey')),
        findsOneWidget,
      );
    },
  );

  testWidgets('resolved connection and Back preserve origin stage and offset', (
    tester,
  ) async {
    final keyConnections = List.generate(
      5,
      (index) => KeyConnection(
        referenceId: 'reference-$index',
        paperId: samplePaper.paperId,
        arxivId: samplePaper.arxivId,
        title: 'Reference target ${index + 1}',
        authors: const ['A. Researcher'],
        year: 2017,
        relationType: 'builds_on',
        summary:
            'Uses this prior architecture as a carefully documented foundation for the current paper.',
      ),
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
      connections: PaperConnections(
        paperId: samplePaper.paperId,
        ready: true,
        keyConnections: keyConnections,
        references: const [],
      ),
    );
    final store = MemoryLocalStore();
    final readerKey = 'feed:${samplePaper.paperId}:${samplePaper.arxivId}';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(store),
          initialRestorationProvider.overrideWithValue(
            AppRestorationState(
              readerStates: {
                readerKey: const ReaderNavigationState(
                  stageIndex: 2,
                  prepareRequested: true,
                ),
              },
            ),
          ),
        ],
        child: const PakPerkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final connectionsScroll = find.descendant(
      of: find.byKey(const PageStorageKey('connections-scroll')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Reference target 5'),
      140,
      scrollable: connectionsScroll,
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    final originBefore = container
        .read(appRestorationControllerProvider)
        .readerState(readerKey);
    expect(originBefore.stageIndex, 2);
    expect(originBefore.connectionsOffset, greaterThan(0));

    await tester.tap(find.text('Reference target 5'));
    await tester.pumpAndSettle();
    expect(
      container.read(appRestorationControllerProvider).routeStack,
      hasLength(1),
    );

    await tester.tap(find.byTooltip('Back to previous paper'));
    await tester.pumpAndSettle();
    final restored = container
        .read(appRestorationControllerProvider)
        .readerState(readerKey);
    expect(
      container.read(appRestorationControllerProvider).routeStack,
      isEmpty,
    );
    expect(restored.stageIndex, 2);
    expect(
      restored.connectionsOffset,
      moreOrLessEquals(originBefore.connectionsOffset, epsilon: 1),
    );
    expect(find.text('Reference target 5'), findsOneWidget);
  });

  testWidgets('one Back action removes only the top paper from a deep stack', (
    tester,
  ) async {
    final repository = FakePaperDataSource(paper: samplePaper);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: const PakPerkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    final navigation = container.read(
      appRestorationControllerProvider.notifier,
    );
    navigation
      ..pushPaper(samplePaper)
      ..pushPaper(samplePaper)
      ..pushPaper(samplePaper);
    await tester.pumpAndSettle();

    final routeIds = container
        .read(appRestorationControllerProvider)
        .routeStack
        .map((entry) => entry.routeId)
        .toList(growable: false);
    expect(routeIds, hasLength(3));

    await tester.tap(find.byTooltip('Back to previous paper'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(appRestorationControllerProvider)
          .routeStack
          .map((entry) => entry.routeId),
      routeIds.take(2),
    );

    await tester.tap(find.byTooltip('Back to previous paper'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(appRestorationControllerProvider)
          .routeStack
          .map((entry) => entry.routeId),
      routeIds.take(1),
    );
  });

  testWidgets(
    'parser failure keeps Abstract and external PDF navigation usable',
    (tester) async {
      final parserFailure = PaperProcessingState(
        paperId: samplePaper.paperId,
        overallState: 'failed',
        stage: ProcessingStage.failedTerminal,
        capabilities: const PaperCapabilities(),
        retryable: false,
        updatedAt: DateTime.utc(2026, 7, 29),
        lastErrorCode: 'PARSER_DOCUMENT',
        lastErrorMessage: 'The PDF structure could not be extracted.',
      );
      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: parserFailure,
        prepareResult: parserFailure,
      );

      await _pumpReader(tester, repository, 'feed:parser-failure');
      await tester.tap(find.byKey(const ValueKey('stage-introduction')));
      await tester.pumpAndSettle();

      expect(
        find.text('We could not reliably extract this paper’s introduction.'),
        findsOneWidget,
      );
      expect(find.text('Open original PDF on arXiv'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stage-abstractView')));
      await tester.pumpAndSettle();
      expect(find.text('ABSTRACT'), findsOneWidget);
    },
  );

  testWidgets('LLM failure leaves Introduction and Connections usable', (
    tester,
  ) async {
    final modelFailure = PaperProcessingState(
      paperId: samplePaper.paperId,
      overallState: 'failed',
      stage: ProcessingStage.failedRetryable,
      capabilities: const PaperCapabilities(
        introduction: true,
        chat: false,
        connections: true,
      ),
      retryable: true,
      updatedAt: DateTime.utc(2026, 7, 29),
      lastErrorCode: 'LLM_UNAVAILABLE',
      lastErrorMessage: 'The paper chat service is temporarily unavailable.',
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: modelFailure,
      prepareResult: modelFailure,
      introduction: sampleIntroduction,
      connections: sampleConnections,
    );

    await _pumpReader(tester, repository, 'feed:model-failure');
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();

    expect(
      find.text('The Transformer removes recurrence from sequence modeling.'),
      findsOneWidget,
    );
    expect(find.text('Paper chat is temporarily unavailable'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stage-connections')));
    await tester.pumpAndSettle();
    expect(find.text('KEY CONNECTIONS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bundled prepared content is visibly distinguished from live data',
    (tester) async {
      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: sampleProcessing,
        introduction: sampleIntroduction,
        connections: sampleConnections,
      )..contentOrigin = DataOrigin.bundledDemo;

      await _pumpReader(tester, repository, 'feed:bundled-demo');
      await tester.tap(find.byKey(const ValueKey('stage-introduction')));
      await tester.pumpAndSettle();

      expect(
        find.text('BUNDLED DEMO · Offline sample content'),
        findsOneWidget,
      );
      expect(
        find.textContaining('this is not a live parsed result'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('stage-connections')));
      await tester.pumpAndSettle();

      expect(
        find.text('BUNDLED DEMO · Offline sample content'),
        findsOneWidget,
      );
      expect(
        find.textContaining('this is not a live parsed result'),
        findsOneWidget,
      );
    },
  );
}

Future<void> _pumpReader(
  WidgetTester tester,
  FakePaperDataSource repository,
  String readerKey,
) async {
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
            readerKey: readerKey,
            isActive: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
