import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/widgets/paper_stage_indicator.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'three-stage reader has no overflow on a small phone at 200% text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: sampleProcessing,
        introduction: sampleIntroduction,
        connections: sampleConnections,
      );
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
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: Scaffold(
                    body: PaperReader(
                      paper: samplePaper,
                      readerKey: 'feed:small-screen',
                      isActive: true,
                      onPreviousPaper: () {},
                      onNextPaper: () {},
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final stage in PaperStage.values) {
        expect(find.byKey(ValueKey('stage-${stage.name}')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('stage-indicator-scroll')),
        findsOneWidget,
      );
      final stageTops = PaperStage.values
          .map(
            (stage) => tester
                .getTopLeft(find.byKey(ValueKey('stage-${stage.name}')))
                .dy,
          )
          .toSet();
      expect(stageTops, hasLength(1));
      expect(
        tester.getSize(find.byType(PaperStageIndicator)).height,
        lessThan(100),
      );

      final introduction = find.byKey(const ValueKey('stage-introduction'));
      await tester.ensureVisible(introduction);
      await tester.pump();
      await tester.tap(introduction);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('1 Introduction'), findsOneWidget);

      final connections = find.byKey(const ValueKey('stage-connections'));
      await tester.ensureVisible(connections);
      await tester.pump();
      await tester.tap(connections);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('KEY CONNECTIONS'), findsOneWidget);
    },
  );
}
