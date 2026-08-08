import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/chat/chat_sheet.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'paper chat is a root route with one keyboard inset and restores reader',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(() {
        tester.view.resetViewInsets();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository =
          FakePaperDataSource(
              paper: samplePaper,
              processing: sampleProcessing,
              introduction: sampleIntroduction,
              connections: sampleConnections,
            )
            ..cachedFeed = FeedPage(items: [samplePaper])
            ..networkFeed = FeedPage(items: [samplePaper]);
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
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stage-introduction')));
      await tester.pumpAndSettle();
      expect(repository.prepareCalls, 1);

      final collapsedComposer = find.byType(TextField).first;
      final navigation = find.byKey(
        const ValueKey<String>('primary-navigation'),
        skipOffstage: false,
      );
      expect(
        tester.getRect(collapsedComposer).bottom,
        lessThanOrEqualTo(tester.getRect(navigation).top),
        reason: 'the collapsed composer belongs to the shell body above nav',
      );
      await tester.tap(collapsedComposer);
      await tester.pumpAndSettle();

      final chatSheet = find.byType(PaperChatSheet);
      expect(chatSheet, findsOneWidget);
      expect(navigation, findsOneWidget);
      expect(
        tester.getRect(chatSheet).overlaps(tester.getRect(navigation)),
        isTrue,
        reason: 'the root chat route must paint above the shell navigation',
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));

      final insetPadding = tester.widget<AnimatedPadding>(
        find.descendant(of: chatSheet, matching: find.byType(AnimatedPadding)),
      );
      expect(
        insetPadding.padding.resolve(TextDirection.ltr).bottom,
        180,
        reason:
            'the root route leaves the keyboard inset for the sheet to '
            'apply exactly once',
      );
      expect(insetPadding.child, isA<SafeArea>());
      final sheetSafeArea = insetPadding.child! as SafeArea;
      expect(sheetSafeArea.top, isFalse);
      expect(sheetSafeArea.bottom, isTrue);
      final modalComposer = find.descendant(
        of: chatSheet,
        matching: find.byType(TextField),
      );
      expect(
        tester.getRect(modalComposer).bottom,
        greaterThan(580),
        reason:
            'the composer should sit just above the 180 px keyboard, not '
            'receive that inset twice',
      );

      await tester.tap(find.byTooltip('Close paper chat'));
      await tester.pumpAndSettle();

      expect(find.byType(PaperChatSheet), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PakPerkApp)),
      );
      final reader = container
          .read(appRestorationControllerProvider)
          .readerState(feedReaderKey(samplePaper));
      expect(reader.stageIndex, PaperStage.introduction.index);
      expect(reader.chatSheetOpen, isFalse);
      expect(repository.prepareCalls, 1);
    },
  );
}
