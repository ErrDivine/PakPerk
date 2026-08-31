import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/models/assistant_v2.dart';
import 'package:pakperk/core/models/paper_passport.dart';
import 'package:pakperk/core/models/provenance.dart';
import 'package:pakperk/features/chat/assistant_v2_sheet.dart';
import 'package:pakperk/features/passport/paper_passport_card.dart';

void main() {
  testWidgets(
    'generation change cancels the request, clears stale answer, and keeps draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _DelayedAssistantAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final generationIsCurrent = StateProvider<bool>((ref) => true);
      final container = ProviderContainer(
        overrides: [
          pakPerkDioProvider.overrideWithValue(dio),
          verifiedLibraryScopeProvider.overrideWithValue(const (
            accountId: 'account-1',
            authEpoch: 9,
          )),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: AssistantV2Sheet(
                  paperId: _paperId,
                  readerKey: 'generation-reader',
                  paperTitle: 'Generation fenced paper',
                  generation: 7,
                  scope: const AssistantRequestScope.paper(),
                  generationIsCurrent: ref.watch(generationIsCurrent),
                  enabled: true,
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Keep this draft.');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Ask'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
      for (
        var attempt = 0;
        attempt < 20 && adapter.requestCount == 0;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(adapter.requestCount, 1);

      container.read(generationIsCurrent.notifier).state = false;
      await tester.pump();
      await tester.pump();

      expect(adapter.cancelObserved, isTrue);
      expect(
        find.text(
          'The prepared paper changed. Close and reopen Assistant for the current source.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('The evidence supports part of the explanation.'),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep this draft.',
      );

      adapter.releaseIfNeeded();
      await tester.pumpAndSettle();
      expect(
        find.text('The evidence supports part of the explanation.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit initial question submits once and the composer stays pinned',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _AssistantAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      Widget buildSheet() => ProviderScope(
        overrides: [
          pakPerkDioProvider.overrideWithValue(dio),
          verifiedLibraryScopeProvider.overrideWithValue(const (
            accountId: 'account-1',
            authEpoch: 9,
          )),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: AssistantV2Sheet(
              paperId: _paperId,
              readerKey: 'reader-pinned',
              paperTitle: 'Pinned composer paper',
              generation: 7,
              scope: const AssistantRequestScope.paper(),
              initialQuestion: '  Explain this once.  ',
              submitInitialQuestion: true,
              enabled: true,
              onClose: () {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(buildSheet());
      await tester.pumpAndSettle();

      expect(adapter.requestCount, 1);
      final body = jsonDecode(adapter.lastRequestBody) as Map<String, dynamic>;
      expect(body['question'], 'Explain this once.');
      final composer = find.byKey(const ValueKey('assistant-pinned-composer'));
      expect(composer, findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Ask')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(568));

      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await tester.pump();
      expect(composer, findsOneWidget);
      expect(adapter.requestCount, 1);

      await tester.pumpWidget(buildSheet());
      await tester.pumpAndSettle();
      expect(adapter.requestCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'evidence correctness report stays touch-safe at 2x text and targets the exact citation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _AssistantAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pakPerkDioProvider.overrideWithValue(dio),
            verifiedLibraryScopeProvider.overrideWithValue(const (
              accountId: 'account-1',
              authEpoch: 9,
            )),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const Scaffold(
              body: AssistantV2Sheet(
                paperId: _paperId,
                readerKey: 'feedback-reader',
                paperTitle: 'Evidence report paper',
                generation: 7,
                scope: AssistantRequestScope.paper(),
                initialQuestion: 'What supports this?',
                submitInitialQuestion: true,
                enabled: true,
                onClose: _doNothing,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final report = find.byKey(const ValueKey('assistant-feedback-open'));
      await tester.dragUntilVisible(
        report,
        find.byType(ListView),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(report).height, greaterThanOrEqualTo(48));
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
      expect(find.byIcon(Icons.thumb_down_outlined), findsNothing);
      await tester.tap(report);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('Evidence correctness report')),
        findsOneWidget,
      );
      final detail = find.byKey(const ValueKey('assistant-feedback-detail'));
      await tester.dragUntilVisible(
        detail,
        find.byType(ListView),
        const Offset(0, -220),
      );
      await tester.enterText(
        detail,
        'The cited range describes another result.',
      );
      final submit = find.byKey(const ValueKey('assistant-feedback-submit'));
      await tester.dragUntilVisible(
        submit,
        find.byType(ListView),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(submit).height, greaterThanOrEqualTo(48));
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(adapter.feedbackRequestCount, 1);
      expect(
        adapter.lastRequestPath,
        '/v1/papers/$_paperId/assistant/feedback',
      );
      final body = jsonDecode(adapter.lastFeedbackBody) as Map<String, dynamic>;
      expect(body['paper_id'], _paperId);
      expect(body['generation'], 7);
      expect(body['thread_id'], '22222222-2222-4222-8222-222222222222');
      expect(body['response_id'], '55555555-5555-4555-8555-555555555555');
      expect(body['provenance_id'], '33333333-3333-4333-8333-333333333333');
      expect(body['feedback_type'], 'incorrect_citation');
      expect(body['claim_index'], 0);
      expect(body['evidence_block_id'], _blockId);
      expect(body['detail'], 'The cited range describes another result.');
      final operationId = body['operation_id'] as String;
      expect(operationId.length, 36);
      expect(operationId[14], '7');
      final status = find.byKey(
        const ValueKey('assistant-feedback-status'),
        skipOffstage: false,
      );
      expect(status, findsOneWidget);
      await tester.ensureVisible(status);
      await tester.pumpAndSettle();
      expect(find.text('Evidence issue saved.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('generation change cancels an in-flight evidence report', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _DelayedFeedbackAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final generationIsCurrent = StateProvider<bool>((ref) => true);
    final container = ProviderContainer(
      overrides: [
        pakPerkDioProvider.overrideWithValue(dio),
        verifiedLibraryScopeProvider.overrideWithValue(const (
          accountId: 'account-1',
          authEpoch: 9,
        )),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: AssistantV2Sheet(
                paperId: _paperId,
                readerKey: 'feedback-generation-reader',
                paperTitle: 'Generation-fenced feedback',
                generation: 7,
                scope: const AssistantRequestScope.paper(),
                generationIsCurrent: ref.watch(generationIsCurrent),
                initialQuestion: 'What supports this?',
                submitInitialQuestion: true,
                enabled: true,
                onClose: _doNothing,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final report = find.byKey(const ValueKey('assistant-feedback-open'));
    await tester.dragUntilVisible(
      report,
      find.byType(ListView),
      const Offset(0, -260),
    );
    await tester.tap(report);
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('assistant-feedback-submit'));
    await tester.scrollUntilVisible(
      submit,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.getCenter(submit).dy, lessThan(568));
    await tester.tap(submit);
    for (
      var attempt = 0;
      attempt < 20 && adapter.feedbackRequestCount == 0;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(adapter.feedbackRequestCount, 1);

    container.read(generationIsCurrent.notifier).state = false;
    await tester.pump();
    await tester.pump();

    expect(adapter.feedbackCancelObserved, isTrue);
    expect(
      find.text(
        'The prepared paper changed. Close and reopen Assistant for the current source.',
      ),
      findsOneWidget,
    );
    expect(find.text('Evidence issue saved.'), findsNothing);
    expect(
      find.byKey(const ValueKey('assistant-evidence-feedback-form')),
      findsNothing,
    );

    adapter.releaseFeedbackIfNeeded();
    await tester.pumpAndSettle();
    expect(find.text('Evidence issue saved.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account epoch change cancels evidence feedback and retains only the question draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _DelayedFeedbackAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [
          pakPerkDioProvider.overrideWithValue(dio),
          verifiedLibraryScopeProvider.overrideWith(
            (ref) => ref.watch(_activeAssistantScopeProvider),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: AssistantV2Sheet(
                paperId: _paperId,
                readerKey: 'feedback-account-reader',
                paperTitle: 'Account-fenced feedback',
                generation: 7,
                scope: AssistantRequestScope.paper(),
                initialQuestion: 'Keep this account-local draft.',
                submitInitialQuestion: true,
                enabled: true,
                onClose: _doNothing,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final report = find.byKey(const ValueKey('assistant-feedback-open'));
      await tester.dragUntilVisible(
        report,
        find.byType(ListView),
        const Offset(0, -260),
      );
      await tester.tap(report);
      await tester.pumpAndSettle();
      final submit = find.byKey(const ValueKey('assistant-feedback-submit'));
      await tester.scrollUntilVisible(
        submit,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(submit);
      for (
        var attempt = 0;
        attempt < 20 && adapter.feedbackRequestCount == 0;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(adapter.feedbackRequestCount, 1);

      container.read(_activeAssistantScopeProvider.notifier).state = const (
        accountId: 'account-2',
        authEpoch: 10,
      );
      await tester.pump();
      await tester.pump();

      expect(adapter.feedbackCancelObserved, isTrue);
      expect(
        find.text('The active account changed. Close and reopen Assistant.'),
        findsOneWidget,
      );
      expect(
        find.text('The evidence supports part of the explanation.'),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep this account-local draft.',
      );
      expect(
        find.byKey(const ValueKey('assistant-evidence-feedback-form')),
        findsNothing,
      );

      adapter.releaseFeedbackIfNeeded();
      await tester.pumpAndSettle();
      expect(find.text('Evidence issue saved.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed evidence feedback retry reuses its operation id', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final adapter = _RetryFeedbackAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pakPerkDioProvider.overrideWithValue(dio),
          verifiedLibraryScopeProvider.overrideWithValue(const (
            accountId: 'account-1',
            authEpoch: 9,
          )),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AssistantV2Sheet(
              paperId: _paperId,
              readerKey: 'feedback-retry-reader',
              paperTitle: 'Idempotent feedback retry',
              generation: 7,
              scope: AssistantRequestScope.paper(),
              initialQuestion: 'What supports this?',
              submitInitialQuestion: true,
              enabled: true,
              onClose: _doNothing,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final report = find.byKey(const ValueKey('assistant-feedback-open'));
    await tester.dragUntilVisible(
      report,
      find.byType(ListView),
      const Offset(0, -260),
    );
    await tester.tap(report);
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('assistant-feedback-submit'));
    await tester.scrollUntilVisible(
      submit,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(adapter.feedbackRequestCount, 1);
    final retry = find.byKey(
      const ValueKey('assistant-feedback-retry'),
      skipOffstage: false,
    );
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(adapter.feedbackRequestCount, 2);
    expect(adapter.operationIds, hasLength(2));
    expect(adapter.operationIds[1], adapter.operationIds[0]);
    final status = find.byKey(
      const ValueKey('assistant-feedback-status'),
      skipOffstage: false,
    );
    await tester.ensureVisible(status);
    await tester.pumpAndSettle();
    expect(find.text('Evidence issue saved.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scope, style, trust labels, coverage, and exact target stay accessible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();

      final adapter = _AssistantAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [
          pakPerkDioProvider.overrideWithValue(dio),
          verifiedLibraryScopeProvider.overrideWith(
            (ref) => ref.watch(_activeAssistantScopeProvider),
          ),
        ],
      );
      addTearDown(container.dispose);
      final targetProvider = assistantEvidenceTargetProvider('reader-1');
      final targetSubscription = container.listen<AssistantEvidenceTarget?>(
        targetProvider,
        (_, __) {},
      );
      addTearDown(targetSubscription.close);
      var closed = false;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: AssistantV2Sheet(
                    paperId: _paperId,
                    readerKey: 'reader-1',
                    paperTitle: 'A long accessible paper title',
                    generation: 7,
                    scope: AssistantRequestScope.selection(
                      blockId: _blockId,
                      start: 2,
                      end: 9,
                    ),
                    enabled: true,
                    onClose: () => closed = true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('Active assistant evidence scope')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Assistant answer style')),
        findsOneWidget,
      );
      expect(find.text('Selected text · characters 3–9'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('assistant-style-concise')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey(
                  'assistant-scope-selection-11111111-1111-4111-8111-111111111111:2:9',
                ),
              ),
            )
            .height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(const ValueKey('assistant-style-concise')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beginner').last);
      await tester.pumpAndSettle();
      expect(find.text('Selected text · characters 3–9'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Explain this evidence.');
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      final ask = find.widgetWithText(FilledButton, 'Ask');
      await tester.tap(ask);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 1600));
      await tester.pumpAndSettle();

      final body = jsonDecode(adapter.lastRequestBody) as Map<String, dynamic>;
      expect(body['answer_style'], 'beginner');
      expect(body['scope'], {
        'kind': 'selection',
        'section_kinds': <Object?>[],
        'object_ids': <Object?>[],
        'selection': {'block_id': _blockId, 'start': 2, 'end': 9},
      });

      await tester.dragUntilVisible(
        find.byKey(const ValueKey('assistant-claim-text-0')),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('assistant-not-found-answer')),
        findsNothing,
        reason:
            'partial answers must render through claims without duplication',
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('assistant-claim-text-0')),
            )
            .data,
        'The paper directly reports the measured result.',
      );
      await tester.dragUntilVisible(
        find.text('Direct'),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Claim support: Direct')),
        findsOneWidget,
      );
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('assistant-claim-text-1')),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('assistant-claim-text-1')),
            )
            .data,
        'The broader interpretation is inferred.',
      );
      await tester.dragUntilVisible(
        find.text('Inferred'),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(find.text('Inferred'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Claim support: Inferred')),
        findsOneWidget,
      );
      await tester.dragUntilVisible(
        find.text(
          'Only claim-backed portions of the requested answer are shown.',
        ),
        find.byType(ListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Only claim-backed portions of the requested answer are shown.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Answer coverage notice')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      final source = find.widgetWithText(
        TextButton,
        'Open exact source · page 3',
      );
      await tester.dragUntilVisible(
        source,
        find.byType(ListView),
        const Offset(0, 240),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(source).height, greaterThanOrEqualTo(48));
      await tester.tap(source);
      await tester.pump();

      expect(container.read(targetProvider), (
        blockId: _blockId,
        start: 2,
        end: 9,
        pageStart: 3,
      ));
      expect(closed, isTrue);
      container.read(_activeAssistantScopeProvider.notifier).state = const (
        accountId: 'account-2',
        authEpoch: 10,
      );
      await tester.pump();
      expect(
        find.text('The evidence supports part of the explanation.'),
        findsNothing,
      );
      expect(
        find.text('The active account changed. Close and reopen Assistant.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('Passport and every server section scope are available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(
      overrides: [verifiedLibraryScopeProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: AssistantV2Sheet(
              paperId: _paperId,
              readerKey: 'reader-2',
              paperTitle: 'Paper',
              generation: 7,
              scope: AssistantRequestScope.passportField('main_result'),
              enabled: false,
              onClose: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Passport · Main Result'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('assistant-scope-passport_field-main_result')),
    );
    await tester.pumpAndSettle();
    for (final kind in AssistantSectionKind.values) {
      expect(find.text('${kind.displayLabel} section'), findsWidgets);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Passport fields expose a 48pt Assistant scope action at 2x text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PassportField? askedField;
      final field = PassportField(
        key: 'main_result',
        status: PassportFieldStatus.supported,
        value: 'The reported result.',
        sourceBlockIds: const [_blockId],
      );
      final passport = PaperPassport(
        paperId: _paperId,
        generation: 7,
        status: PassportStatus.ready,
        versionLabel: 'v2',
        fields: [field],
        provenance: const ProvenanceSummary(status: 'ready'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: PaperPassportCard(
                  passport: passport,
                  compact: false,
                  onInspectEvidence: (_) {},
                  onAskAssistant: (value) => askedField = value,
                ),
              ),
            ),
          ),
        ),
      );

      final ask = find.byTooltip('Ask about Main Result');
      expect(ask, findsOneWidget);
      expect(tester.getSize(ask).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(ask).width, greaterThanOrEqualTo(48));
      await tester.tap(ask);
      expect(askedField, same(field));
      expect(tester.takeException(), isNull);
    },
  );
}

const _paperId = '99999999-9999-4999-8999-999999999999';
const _blockId = '11111111-1111-4111-8111-111111111111';
void _doNothing() {}
final _activeAssistantScopeProvider = StateProvider<ActiveLibraryScope?>(
  (ref) => const (accountId: 'account-1', authEpoch: 9),
);

class _AssistantAdapter implements HttpClientAdapter {
  String lastRequestBody = '';
  String lastRequestPath = '';
  String lastFeedbackBody = '';
  int requestCount = 0;
  int feedbackRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    lastRequestPath = options.path;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    lastRequestBody = utf8.decode(bytes);
    if (options.path.endsWith('/assistant/feedback')) {
      feedbackRequestCount += 1;
      lastFeedbackBody = lastRequestBody;
      return ResponseBody.fromString(
        jsonEncode({
          'feedback_id': '77777777-7777-4777-8777-777777777777',
          'status': 'stored',
        }),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'thread_id': '22222222-2222-4222-8222-222222222222',
        'response_id': '55555555-5555-4555-8555-555555555555',
        'generation': 7,
        'answer':
            'The paper directly reports the measured result.\n\nThe broader interpretation is inferred.',
        'status': 'partial',
        'claims': [
          {
            'text': 'The paper directly reports the measured result.',
            'support': 'direct',
            'evidence': [
              {
                'block_id': _blockId,
                'start': 2,
                'end': 9,
                'page_start': 3,
                'section': 'Methods',
              },
            ],
          },
          {
            'text': 'The broader interpretation is inferred.',
            'support': 'inferred',
            'evidence': [
              {
                'block_id': _blockId,
                'start': 10,
                'end': 15,
                'page_start': 4,
                'section': 'Methods',
              },
            ],
          },
        ],
        'limitations': [
          'Only claim-backed portions of the requested answer are shown.',
        ],
        'provenance_id': '33333333-3333-4333-8333-333333333333',
        'model_id': 'model-v2',
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

final class _DelayedFeedbackAdapter extends _AssistantAdapter {
  final Completer<void> _feedbackRelease = Completer<void>();
  bool feedbackCancelObserved = false;

  void releaseFeedbackIfNeeded() {
    if (!_feedbackRelease.isCompleted) _feedbackRelease.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.endsWith('/assistant/feedback')) {
      return super.fetch(options, requestStream, cancelFuture);
    }
    requestCount += 1;
    feedbackRequestCount += 1;
    lastRequestPath = options.path;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    lastRequestBody = utf8.decode(bytes);
    lastFeedbackBody = lastRequestBody;
    cancelFuture?.then((_) {
      feedbackCancelObserved = true;
      releaseFeedbackIfNeeded();
    });
    await _feedbackRelease.future;
    if (feedbackCancelObserved) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'feedback_id': '77777777-7777-4777-8777-777777777777',
        'status': 'stored',
      }),
      201,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

final class _RetryFeedbackAdapter extends _AssistantAdapter {
  final List<String> operationIds = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.endsWith('/assistant/feedback')) {
      return super.fetch(options, requestStream, cancelFuture);
    }
    requestCount += 1;
    feedbackRequestCount += 1;
    lastRequestPath = options.path;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    lastRequestBody = utf8.decode(bytes);
    lastFeedbackBody = lastRequestBody;
    final body = jsonDecode(lastRequestBody) as Map<String, dynamic>;
    operationIds.add(body['operation_id'] as String);
    if (feedbackRequestCount == 1) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'ASSISTANT_FEEDBACK_UNAVAILABLE',
            'message': 'Try again.',
            'retryable': true,
          },
        }),
        503,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'feedback_id': '77777777-7777-4777-8777-777777777777',
        'status': 'replayed',
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

final class _DelayedAssistantAdapter extends _AssistantAdapter {
  final Completer<void> _release = Completer<void>();
  bool cancelObserved = false;

  void releaseIfNeeded() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount += 1;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    lastRequestBody = utf8.decode(bytes);
    cancelFuture?.then((_) {
      cancelObserved = true;
      releaseIfNeeded();
    });
    await _release.future;
    if (cancelObserved) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }
    return super.fetch(options, null, null);
  }
}
