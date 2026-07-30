import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'horizontal fling changes stage without changing the current paper',
    (tester) async {
      final papers = _papers();
      final repository = _repositoryFor(papers);
      await _pumpFeed(tester, repository);

      final firstReaderKey = feedReaderKey(papers.first);
      await tester.fling(
        find.byKey(ValueKey('feed-paper-$firstReaderKey')),
        const Offset(-520, 0),
        1200,
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      expect(container.read(appRestorationControllerProvider).feedIndex, 0);
      expect(
        container
            .read(appRestorationControllerProvider)
            .readerState(firstReaderKey)
            .stageIndex,
        PaperStage.introduction.index,
      );
      expect(repository.prepareCalls, 1);
    },
  );

  testWidgets(
    'vertical fling changes paper without changing horizontal stage',
    (tester) async {
      final papers = _papers();
      final repository = _repositoryFor(papers);
      await _pumpFeed(tester, repository);

      await tester.fling(
        find.byKey(const ValueKey('stage-abstractView')),
        const Offset(0, -520),
        1200,
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      final restoration = container.read(appRestorationControllerProvider);
      expect(restoration.feedIndex, 1);
      expect(
        restoration.readerState(feedReaderKey(papers[1])).stageIndex,
        PaperStage.abstractView.index,
      );
      expect(repository.prepareCalls, 0);
      expect(find.text(papers[1].title), findsOneWidget);
    },
  );

  testWidgets('reader stays bounded and overflow-free on a large screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final papers = _papers();
    final repository = _repositoryFor(papers);
    await _pumpFeed(tester, repository);

    final reader = find.byKey(
      ValueKey('feed-paper-${feedReaderKey(papers.first)}'),
    );
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    expect(find.text('1 Introduction'), findsOneWidget);
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('stage-connections')));
    await tester.pumpAndSettle();
    expect(find.text('KEY CONNECTIONS'), findsOneWidget);
    expect(tester.getSize(reader).width, 840);
    expect(tester.takeException(), isNull);
  });
}

List<PaperSummary> _papers() => List.generate(3, (index) {
      final number = index + 1;
      final json = samplePaper.toJson()
        ..['paper_id'] =
            '17060376-2000-4000-8000-${number.toString().padLeft(12, '0')}'
        ..['arxiv_id'] = '1706.0376${number}v1'
        ..['title'] = 'Gesture paper $number'
        ..['abs_url'] = 'https://arxiv.org/abs/1706.0376${number}v1'
        ..['pdf_url'] = 'https://arxiv.org/pdf/1706.0376${number}v1';
      return PaperSummary.fromJson(json);
    });

FakePaperDataSource _repositoryFor(List<PaperSummary> papers) =>
    FakePaperDataSource(
      paper: papers.first,
      processing: sampleProcessing,
      introduction: sampleIntroduction,
      connections: sampleConnections,
    )
      ..cachedFeed = FeedPage(items: papers)
      ..networkFeed = FeedPage(items: papers);

Future<void> _pumpFeed(
  WidgetTester tester,
  FakePaperDataSource repository,
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
      child: const PakPerkApp(),
    ),
  );
  await tester.pumpAndSettle();
}
