import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/app.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/chat/chat_sheet.dart';
import 'package:pakperk/features/chat/assistant_v2_sheet.dart';
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
  testWidgets('Introduction question uses Assistant V2 without legacy chat', (
    tester,
  ) async {
    final repository =
        FakePaperDataSource(
            paper: samplePaper,
            processing: sampleProcessing,
            introduction: sampleIntroduction,
            connections: sampleConnections,
          )
          ..cachedFeed = FeedPage(items: [samplePaper])
          ..networkFeed = FeedPage(items: [samplePaper]);
    final adapter = _RouteRecordingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBuildConfigProvider.overrideWithValue(
            AppBuildConfig.fromValues(const {
              'PAKPERK_ASSISTANT_V2_ENABLED': 'true',
            }),
          ),
          pakPerkDioProvider.overrideWithValue(dio),
          paperRepositoryProvider.overrideWithValue(repository),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
        ],
        child: const PakPerkApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stage-introduction')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'What changed?');
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();

    expect(find.byType(AssistantV2Sheet), findsOneWidget);
    expect(repository.chatCalls, 0);
    expect(adapter.path, '/v1/papers/${samplePaper.paperId}/assistant');
    expect(adapter.sessionId, isNotEmpty);
  });
}

final class _RouteRecordingAdapter implements HttpClientAdapter {
  String? path;
  String? sessionId;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.path;
    sessionId = options.headers['X-Session-Id']?.toString();
    return ResponseBody.fromString(
      jsonEncode({
        'thread_id': '22222222-2222-4222-8222-222222222222',
        'response_id': '55555555-5555-4555-8555-555555555555',
        'generation': sampleProcessing.generation,
        'answer': 'Not found in this paper.',
        'status': 'not_found',
        'claims': [],
        'limitations': [],
        'provenance_id': '33333333-3333-4333-8333-333333333333',
        'model_id': 'deepseek-flash',
        'prompt_version': 'assistant-v2',
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
