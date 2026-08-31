import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/paper_reader/paper_reader.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'readable Introduction keeps an accessible optional-enrichment notice',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final repository = FakePaperDataSource(
        paper: samplePaper,
        processing: sampleProcessing,
        prepareResult: sampleProcessing,
        introduction: sampleIntroduction,
      );
      const readerKey = 'feed:enrichment-notice';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(
              const FeatureFlags(
                accounts: true,
                library: false,
                comments: false,
                openingMotion: false,
                deepReader: true,
                paperPassport: true,
              ),
            ),
            paperRepositoryProvider.overrideWithValue(repository),
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
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

      const message =
          'Optional reader details are still being prepared. You can keep reading.';
      expect(find.byKey(const ValueKey('reader-enrichment-status')), findsOne);
      expect(find.bySemanticsLabel(message), findsOne);
      expect(tester.takeException(), isNull);
      expect(repository.prepareCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      semantics.dispose();
    },
  );
}
