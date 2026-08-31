import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/document/passport_api.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/paper_passport.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/paper_reader/abstract_view.dart';
import 'package:pakperk/features/passport/paper_passport_card.dart';
import 'package:pakperk/features/passport/passport_controller.dart';

import '../support/fakes.dart';
import '../support/passport_fixtures.dart';

void main() {
  testWidgets(
    'Abstract makes zero Passport or preparation request when not ready',
    (tester) async {
      final remote = _PassportReadFake();
      var stageRequests = 0;
      await tester.pumpWidget(
        _abstractApp(
          remote: remote,
          ready: false,
          onStageRequested: (_) => stageRequests += 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(remote.requests, isEmpty);
      expect(stageRequests, 0);
      expect(
        find.byKey(const ValueKey('paper-passport-compact-card')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('abstract-passport-loading')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Abstract fetches only an already-ready current Passport generation',
    (tester) async {
      final remote = _PassportReadFake();
      var stageRequests = 0;
      await tester.pumpWidget(
        _abstractApp(
          remote: remote,
          ready: true,
          onStageRequested: (_) => stageRequests += 1,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(remote.requests, [
        (paperId: passportPaperId, versionKey: '2601.00001v7', generation: 7),
      ]);
      expect(stageRequests, 0);
      expect(
        find.byKey(const ValueKey('paper-passport-compact-card')),
        findsOneWidget,
      );
      expect(find.text('View full Passport'), findsOneWidget);
    },
  );

  testWidgets(
    'full Passport remains readable at 2x and exposes evidence and Memory',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PassportField? remembered;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: PaperPassportCard(
                      passport: validPassport(),
                      compact: true,
                      onInspectEvidence: (_) {},
                      onRemember: (field) => remembered = field,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final open = find.byKey(const ValueKey('paper-passport-open-full'));
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
      await tester.tap(open);
      await tester.pumpAndSettle();

      expect(find.text('Generation details'), findsOneWidget);
      final sheet = find.byType(CustomScrollView).last;
      for (
        var index = 0;
        index < 12 && find.text('Pakperk-derived').evaluate().isEmpty;
        index += 1
      ) {
        await tester.drag(sheet, const Offset(0, -360));
        await tester.pump();
      }
      expect(find.text('Pakperk-derived'), findsWidgets);
      expect(find.textContaining('source block'), findsWidgets);
      for (
        var index = 0;
        index < 12 &&
            find
                .byKey(const ValueKey('passport-remember-main_result'))
                .evaluate()
                .isEmpty;
        index += 1
      ) {
        await tester.drag(sheet, const Offset(0, -360));
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('passport-remember-main_result')),
        findsOneWidget,
      );
      final remember = find.byKey(
        const ValueKey('passport-remember-main_result'),
      );
      await tester.ensureVisible(remember);
      expect(tester.getSize(remember).height, greaterThanOrEqualTo(48));
      await tester.tap(remember);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(remembered?.key, 'main_result');
      expect(find.text('Main Result saved to Memory.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _abstractApp({
  required _PassportReadFake remote,
  required bool ready,
  required ValueChanged<PaperStage> onStageRequested,
}) {
  final paper = PaperSummary(
    paperId: passportPaperId,
    arxivId: '2601.00001v7',
    title: samplePaper.title,
    abstractText: samplePaper.abstractText,
    authors: samplePaper.authors,
    primaryCategory: samplePaper.primaryCategory,
    categories: samplePaper.categories,
    publishedAt: samplePaper.publishedAt,
    updatedAt: samplePaper.updatedAt,
    absUrl: 'https://arxiv.org/abs/2601.00001v7',
    pdfUrl: 'https://arxiv.org/pdf/2601.00001v7',
  );
  return ProviderScope(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      featureFlagsProvider.overrideWithValue(
        const FeatureFlags(
          accounts: false,
          library: false,
          comments: false,
          openingMotion: false,
          deepReader: true,
          paperPassport: true,
        ),
      ),
      passportViewerScopeProvider.overrideWithValue('public-test'),
      passportReadRemoteDataSourceProvider.overrideWithValue(remote),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: AbstractView(
          paper: paper,
          scrollController: ScrollController(),
          onStageRequested: onStageRequested,
          passportGeneration: 7,
          paperPassportReady: ready,
        ),
      ),
    ),
  );
}

final class _PassportReadFake implements PassportReadRemoteDataSource {
  final List<({String paperId, String versionKey, int generation})> requests =
      [];

  @override
  Future<PaperPassport> fetchPassport({
    required String paperId,
    required String expectedVersionKey,
    required int expectedGeneration,
    RequestCancellation? cancellation,
  }) async {
    requests.add((
      paperId: paperId,
      versionKey: expectedVersionKey,
      generation: expectedGeneration,
    ));
    return validPassport();
  }
}
