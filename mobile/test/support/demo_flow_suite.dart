import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/chat/chat_controller.dart';
import 'package:pakperk/features/chat/chat_sheet.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import 'fakes.dart';

void registerDemoFlowTests() {
  testWidgets('1. launch, read Abstract, and move to the next paper', (
    tester,
  ) async {
    final nextPaper = _paper(
      id: '18100480-2000-4000-8000-000000000002',
      arxivId: '1810.04805v2',
      title: 'BERT: Pre-training of Deep Bidirectional Transformers',
      abstractText: 'BERT pre-trains bidirectional representations.',
    );
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeed = FeedPage(items: [samplePaper, nextPaper]);

    await _pumpApp(tester, repository);
    expect(find.text(samplePaper.abstractText), findsOneWidget);

    await tester.fling(
      find.byKey(const PageStorageKey('vertical-paper-feed')),
      const Offset(0, -700),
      1200,
    );
    await tester.pumpAndSettle();

    expect(find.text(nextPaper.abstractText), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    expect(container.read(appRestorationControllerProvider).feedIndex, 1);
  });

  testWidgets('2. prepared paper reveals Introduction on a real left swipe', (
    tester,
  ) async {
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
    );
    const readerKey = 'integration:prepared-introduction';
    await _pumpReader(tester, repository, readerKey);

    await _swipeReaderLeft(tester, readerKey);

    expect(find.text(sampleIntroduction.heading), findsOneWidget);
    expect(
      find.text(sampleIntroduction.paragraphs.single.text),
      findsOneWidget,
    );
    expect(repository.prepareCalls, 1);
  });

  testWidgets('3. method question returns an answer with section badges', (
    tester,
  ) async {
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
    );
    const readerKey = 'integration:grounded-chat';
    await _pumpReader(tester, repository, readerKey);
    await _swipeReaderLeft(tester, readerKey);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PaperReader)),
    );
    final chatArgs = ChatControllerArgs(
      paperId: samplePaper.paperId,
      readerKey: readerKey,
    );
    await _pumpUntil(tester, () {
      final chat = container.read(chatControllerProvider(chatArgs));
      return !chat.restoring && chat.generation == sampleProcessing.generation;
    }, description: 'the paper chat generation to become authoritative');

    await tester.tap(find.byType(TextField).first);
    await _pumpUntil(
      tester,
      () => find.byType(PaperChatSheet).evaluate().isNotEmpty,
      description: 'the paper chat sheet to open',
    );
    await tester.pumpAndSettle();
    final sheet = find.byType(PaperChatSheet);
    final composer = find.descendant(
      of: sheet,
      matching: find.byType(TextField),
    );
    const question = 'What method does this paper use?';
    // `WidgetTester.enterText` relies on a synthetic text-input channel that is
    // not deterministic in profile mode. Seed the sheet's real controller;
    // dispatch and rendering still travel through the visible send control.
    final composerController = tester.widget<TextField>(composer).controller!;
    composerController.value = const TextEditingValue(
      text: question,
      selection: TextSelection.collapsed(offset: question.length),
    );
    await tester.pump();
    expect(tester.widget<TextField>(composer).controller?.text, question);
    final sendTooltip = find.descendant(
      of: sheet,
      matching: find.byTooltip('Send question'),
    );
    final sendButton = find.ancestor(
      of: sendTooltip,
      matching: find.byType(IconButton),
    );
    await _pumpUntil(tester, () {
      final buttons = tester.widgetList<IconButton>(sendButton).toList();
      return buttons.length == 1 && buttons.single.onPressed != null;
    }, description: 'the visible chat send button to become enabled');
    await tester.tap(sendButton);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => repository.chatCalls == 1,
      description: 'the visible chat composer to dispatch its request',
    );
    await _pumpUntil(
      tester,
      () => find.text('It uses self-attention.').evaluate().isNotEmpty,
      description: 'the grounded chat answer to appear',
    );

    expect(find.text('It uses self-attention.'), findsOneWidget);
    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('3 Method, pp. 4–5'), findsOneWidget);
  });

  testWidgets('4. connection navigation and Back restore source state', (
    tester,
  ) async {
    final connections = PaperConnections(
      paperId: samplePaper.paperId,
      ready: true,
      keyConnections: const [
        KeyConnection(
          referenceId: 'reference-1',
          paperId: '18100480-2000-4000-8000-000000000002',
          arxivId: '1810.04805v2',
          title: 'A cited paper',
          authors: ['A. Researcher'],
          year: 2018,
          relationType: 'builds_on',
          summary: 'The current method directly builds on this architecture.',
        ),
      ],
      references: const [],
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
      connections: connections,
    );
    final readerKey = feedReaderKey(samplePaper);
    await _pumpApp(tester, repository);
    await tester.tap(find.byKey(const ValueKey('stage-connections')));
    await _pumpUntil(
      tester,
      () => find.text('A cited paper').evaluate().isNotEmpty,
      description: 'the Connections stage to load',
    );

    final connectionTitle = find.text('A cited paper');
    await tester.ensureVisible(connectionTitle);
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(of: connectionTitle, matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PakPerkApp)),
    );
    expect(
      container.read(appRestorationControllerProvider).routeStack,
      hasLength(1),
    );

    await tester.tap(find.byTooltip('Back to previous paper'));
    await tester.pumpAndSettle();

    final restoration = container.read(appRestorationControllerProvider);
    expect(restoration.routeStack, isEmpty);
    expect(restoration.readerState(readerKey).stageIndex, 2);
    expect(find.text('A cited paper'), findsOneWidget);
  });

  testWidgets(
    '5. unprocessed paper shows progressive stages and eventual Introduction',
    (tester) async {
      final queued = _processing(
        ProcessingStage.queued,
        const PaperCapabilities(),
      );
      final parsing = _processing(
        ProcessingStage.parsingPdf,
        const PaperCapabilities(),
      );
      final introductionReady = _processing(
        ProcessingStage.introductionReady,
        const PaperCapabilities(introduction: true),
      );
      final repository = _ProgressiveDataSource(
        prepareResult: queued,
        processingStates: [
          queued,
          parsing,
          introductionReady,
          sampleProcessing,
        ],
      );
      const readerKey = 'integration:lazy-paper';
      await _pumpReader(tester, repository, readerKey);

      await _swipeReaderLeft(tester, readerKey, settle: false);
      expect(repository.prepareCalls, 1);
      expect(
        find.textContaining('Preparing the paper'),
        findsAtLeastNWidgets(1),
      );

      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(
        find.textContaining('Reading the PDF structure'),
        findsAtLeastNWidgets(1),
      );

      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
      expect(
        find.text(sampleIntroduction.paragraphs.single.text),
        findsOneWidget,
      );
      expect(repository.introductionCalls, greaterThanOrEqualTo(1));
      expect(repository.prepareCalls, 1);
    },
  );

  testWidgets('6. GROBID failure leaves the app navigable', (tester) async {
    final parserFailure = _processing(
      ProcessingStage.failedTerminal,
      const PaperCapabilities(),
      overallState: 'failed',
      retryable: false,
      errorCode: 'PARSER_DOCUMENT',
      errorMessage: 'The PDF structure could not be extracted.',
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: parserFailure,
      prepareResult: parserFailure,
    );
    const readerKey = 'integration:grobid-failure';
    await _pumpReader(tester, repository, readerKey);

    await _swipeReaderLeft(tester, readerKey);
    expect(
      find.text('We could not reliably extract this paper’s introduction.'),
      findsOneWidget,
    );

    await _swipeReaderRight(tester, readerKey);
    await tester.pumpAndSettle();
    expect(find.text('ABSTRACT'), findsOneWidget);
  });

  testWidgets('7. LLM failure leaves Introduction and Connections useful', (
    tester,
  ) async {
    final modelFailure = _processing(
      ProcessingStage.failedRetryable,
      const PaperCapabilities(introduction: true, connections: true),
      overallState: 'failed',
      retryable: true,
      errorCode: 'LLM_UNAVAILABLE',
      errorMessage: 'The paper chat service is temporarily unavailable.',
    );
    final repository = FakePaperDataSource(
      paper: samplePaper,
      processing: modelFailure,
      prepareResult: modelFailure,
      introduction: sampleIntroduction,
      connections: PaperConnections(
        paperId: samplePaper.paperId,
        ready: true,
        keyConnections: const [
          KeyConnection(
            referenceId: 'model-failure-reference',
            paperId: '18100480-2000-4000-8000-000000000002',
            arxivId: '1810.04805v2',
            title: 'Useful persisted connection',
            authors: ['A. Researcher'],
            year: 2018,
            relationType: 'builds_on',
            summary:
                'This persisted relationship remains available without chat.',
          ),
        ],
        references: const [],
      ),
    );
    const readerKey = 'integration:llm-failure';
    await _pumpReader(tester, repository, readerKey);

    await _swipeReaderLeft(tester, readerKey);
    expect(
      find.text(sampleIntroduction.paragraphs.single.text),
      findsOneWidget,
    );
    expect(find.text('Paper chat is temporarily unavailable'), findsOneWidget);

    await _swipeReaderLeft(tester, readerKey);
    expect(find.text('KEY CONNECTIONS'), findsOneWidget);
    expect(find.text('Useful persisted connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('8. offline launch still serves the prepared demo feed', (
    tester,
  ) async {
    final repository =
        FakePaperDataSource(
            paper: samplePaper,
            processing: sampleProcessing,
            introduction: sampleIntroduction,
            connections: sampleConnections,
          )
          ..offline = true
          ..contentOrigin = DataOrigin.bundledDemo
          ..networkFeedCompleter = Completer<RepositoryValue<FeedPage>>();

    await _pumpApp(tester, repository);
    expect(find.text(samplePaper.title), findsAtLeastNWidgets(1));
    expect(find.text('OFFLINE · Showing cached paper data'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    expect(find.text('BUNDLED DEMO · Offline sample content'), findsOneWidget);
    expect(repository.networkFeedCompleter!.isCompleted, isFalse);
  });
}

class _ProgressiveDataSource extends FakePaperDataSource {
  _ProgressiveDataSource({
    required super.prepareResult,
    required List<PaperProcessingState> processingStates,
  }) : _processingStates = processingStates;

  final List<PaperProcessingState> _processingStates;
  int _processingIndex = 0;

  @override
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    lastProcessingCancellation = cancellation;
    processingCalls += 1;
    final index = _processingIndex.clamp(0, _processingStates.length - 1);
    final value = _processingStates[index];
    if (_processingIndex < _processingStates.length - 1) {
      _processingIndex += 1;
    }
    return RepositoryValue(
      value: value,
      origin: DataOrigin.network,
      offline: false,
    );
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  FakePaperDataSource repository, {
  AppRestorationState restoration = const AppRestorationState(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialRestorationProvider.overrideWithValue(restoration),
      ],
      child: const PakPerkApp(),
    ),
  );
  await tester.pumpAndSettle();
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
  // Device/profile bindings may schedule the reader's initial async state over
  // more than one frame. Wait until that work is quiescent before interacting.
  await tester.pumpAndSettle();
}

Future<void> _swipeReaderLeft(
  WidgetTester tester,
  String readerKey, {
  bool settle = true,
}) async {
  await _swipeReader(tester, readerKey, direction: -1);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<void> _swipeReaderRight(WidgetTester tester, String readerKey) =>
    _swipeReader(tester, readerKey, direction: 1);

Future<void> _swipeReader(
  WidgetTester tester,
  String readerKey, {
  required double direction,
}) async {
  final reader = find.byKey(ValueKey('paper-reader-$readerKey'));
  final bounds = tester.getRect(reader);
  final start = Offset(
    direction < 0
        ? bounds.left + bounds.width * 0.78
        : bounds.left + bounds.width * 0.22,
    bounds.center.dy,
  );

  // Keep the full gesture inside the viewport. The previous fixed 700-pixel
  // fling left the bounds of phone-sized readers, so it did not exercise the
  // same 1:1 drag path as a real finger on profile/device runtimes.
  await tester.timedDragFrom(
    start,
    Offset(direction * bounds.width * 0.62, 0),
    const Duration(milliseconds: 320),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String description,
}) async {
  const interval = Duration(milliseconds: 50);
  for (var attempt = 0; attempt < 80; attempt += 1) {
    if (predicate()) return;
    await tester.pump(interval);
  }
  fail('Timed out waiting for $description.');
}

PaperProcessingState _processing(
  ProcessingStage stage,
  PaperCapabilities capabilities, {
  String overallState = 'processing',
  bool retryable = false,
  String? errorCode,
  String? errorMessage,
}) => PaperProcessingState(
  paperId: samplePaper.paperId,
  overallState: overallState,
  stage: stage,
  capabilities: capabilities,
  retryable: retryable,
  updatedAt: DateTime.utc(2026, 7, 29),
  lastErrorCode: errorCode,
  lastErrorMessage: errorMessage,
);

PaperSummary _paper({
  required String id,
  required String arxivId,
  required String title,
  required String abstractText,
}) => PaperSummary(
  paperId: id,
  arxivId: arxivId,
  title: title,
  abstractText: abstractText,
  authors: const ['Test Author'],
  primaryCategory: 'cs.CL',
  categories: const ['cs.CL'],
  publishedAt: DateTime.utc(2018),
  updatedAt: DateTime.utc(2019),
  absUrl: 'https://arxiv.org/abs/$arxivId',
  pdfUrl: 'https://arxiv.org/pdf/$arxivId',
);
