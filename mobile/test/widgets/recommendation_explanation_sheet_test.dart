import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_api.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_models.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/recommendations/recommendation_explanation_sheet.dart';
import 'package:pakperk/features/recommendations/recommendation_interaction_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'control stays absent without capability or recommendation context',
    (tester) async {
      final remote = _FakeRecommendationRemote();
      final disabled = RecommendationInteractionController(
        remote: remote,
        context: _context(),
      );
      final missingContext = RecommendationInteractionController(
        remote: remote,
        capabilities: const RecommendationInteractionCapabilities.all(),
      );
      addTearDown(disabled.dispose);
      addTearDown(missingContext.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: PakPerkTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                RecommendationInteractionButton(
                  controller: disabled,
                  paperTitle: samplePaper.title,
                ),
                RecommendationInteractionButton(
                  controller: missingContext,
                  paperTitle: samplePaper.title,
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('recommendation-details-action')),
        findsNothing,
      );
      disabled.updateCapabilities(
        const RecommendationInteractionCapabilities.all(),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recommendation-details-action')),
        findsOneWidget,
      );
      disabled.updateContext(null);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recommendation-details-action')),
        findsNothing,
      );
      expect(remote.explanations, isEmpty);
      expect(remote.feedback, isEmpty);
    },
  );

  testWidgets('sheet explains and collects explicit typed feedback', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    RecommendationFeedbackSelection? submittedSelection;
    RecommendationFeedbackResult? submittedResult;
    await _pumpButton(
      tester,
      controller: controller,
      onFeedbackSubmitted: (selection, result) {
        submittedSelection = selection;
        submittedResult = result;
      },
    );

    final entry = find.byKey(const ValueKey('recommendation-details-action'));
    expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(remote.explanations, hasLength(1));
    expect(
      _semanticsWithLabel('Recommendation details modal sheet'),
      findsOneWidget,
    );
    expect(_semanticsWithLabel('Drag handle'), findsOneWidget);
    final close = find.byKey(const ValueKey('recommendation-sheet-close'));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(48));

    remote.explanations.single.response.complete(_explanationEnvelope);
    await tester.pump();
    expect(find.text('Matches a followed topic'), findsOneWidget);
    expect(
      find.text('It matches your followed topic efficient ML.'),
      findsOneWidget,
    );
    expect(find.text('A topic you follow'), findsOneWidget);
    final followedTopicCard = find.byKey(
      const ValueKey('recommendation-explanation-followed_topic'),
    );
    expect(
      find.descendant(
        of: followedTopicCard,
        matching: find.text('Yes — recorded behavior affected ranking'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: followedTopicCard,
        matching: find.text('Relevance — matches a recorded signal'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Yes — recorded behavior affected ranking'),
      findsNWidgets(2),
    );
    expect(
      find.text('Diversity — avoids a repetitive result set'),
      findsOneWidget,
    );
    expect(find.text('A recorded paper in your library'), findsOneWidget);
    expect(
      _semanticsWithLabel('Candidate source: A topic you follow'),
      findsOneWidget,
    );
    expect(
      find.textContaining('not proof that your reading queue is empty'),
      findsOneWidget,
    );

    final notForMe = find.byKey(
      const ValueKey('recommendation-feedback-not-relevant'),
    );
    await _scrollTo(tester, notForMe);
    await tester.tap(notForMe);
    await tester.pump();
    final reason = find.byKey(
      const ValueKey('recommendation-feedback-reason-off_topic'),
    );
    await _scrollTo(tester, reason);
    expect(tester.getSize(reason).height, greaterThanOrEqualTo(44));
    await tester.tap(reason);
    await tester.pump();
    final send = find.byKey(
      const ValueKey('recommendation-feedback-submit-negative'),
    );
    await _scrollTo(tester, send);
    expect(tester.getSize(send).height, greaterThanOrEqualTo(48));
    await tester.tap(send);
    await tester.pump();

    expect(remote.feedback, hasLength(1));
    expect(
      remote.feedback.single.selection,
      const RecommendationFeedbackSelection(
        type: RecommendationFeedbackType.notRelevant,
        reason: RecommendationFeedbackReason.offTopic,
      ),
    );
    expect(remote.feedback.single.operationId, _operationId);
    remote.feedback.single.response.complete(
      const RecommendationFeedbackResult(
        feedbackId: _feedbackId,
        replayed: false,
      ),
    );
    await tester.pump();

    expect(find.text('Feedback sent'), findsWidgets);
    expect(submittedSelection, remote.feedback.single.selection);
    expect(submittedResult?.feedbackId, _feedbackId);
    expect(find.textContaining('not queue state'), findsOneWidget);
  });

  testWidgets('adjustment and privacy actions close before navigating', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    var adjustments = 0;
    var privacyOpens = 0;
    await _pumpButton(
      tester,
      controller: controller,
      onAdjustPersonalization: () => adjustments += 1,
      onOpenPrivacy: () => privacyOpens += 1,
    );

    await tester.tap(
      find.byKey(const ValueKey('recommendation-details-action')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    remote.explanations.single.response.complete(_explanationEnvelope);
    await tester.pump();

    final adjust = find.byKey(
      const ValueKey('recommendation-adjust-personalization'),
    );
    await _scrollTo(tester, adjust);
    expect(tester.getSize(adjust).height, greaterThanOrEqualTo(48));
    await tester.tap(adjust);
    await tester.pumpAndSettle();
    expect(adjustments, 1);
    expect(
      find.byKey(const ValueKey('recommendation-sheet-scroll-view')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('recommendation-details-action')),
    );
    await tester.pumpAndSettle();
    final privacy = find.byKey(const ValueKey('recommendation-open-privacy'));
    await _scrollTo(tester, privacy);
    expect(tester.getSize(privacy).height, greaterThanOrEqualTo(48));
    await tester.tap(privacy);
    await tester.pumpAndSettle();
    expect(privacyOpens, 1);
  });

  testWidgets('retryable explanation failure exposes an immediate retry', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpButton(tester, controller: controller);

    await tester.tap(
      find.byKey(const ValueKey('recommendation-details-action')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    remote.explanations.single.response.completeError(
      const ApiException(
        code: 'RECOMMENDATION_SERVICE_UNAVAILABLE',
        message: 'raw database detail',
        retryable: true,
      ),
    );
    await tester.pump();

    expect(find.text('Couldn’t load this explanation'), findsOneWidget);
    expect(find.text('raw database detail'), findsNothing);
    final retry = find.byKey(
      const ValueKey('recommendation-interaction-retry'),
    );
    await _scrollTo(tester, retry);
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    await tester.pump();
    expect(remote.explanations, hasLength(2));
  });

  testWidgets('narrow Dynamic Type and reduced motion remain usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final remote = _FakeRecommendationRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpButton(
      tester,
      controller: controller,
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('recommendation-details-action')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    remote.explanations.single.response.complete(_explanationEnvelope);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<AnimatedPadding>(
            find.byKey(const ValueKey('recommendation-sheet-keyboard-padding')),
          )
          .duration,
      Duration.zero,
    );

    final notForMe = find.byKey(
      const ValueKey('recommendation-feedback-not-relevant'),
    );
    await _scrollTo(tester, notForMe);
    await tester.tap(notForMe);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedSwitcher && widget.duration == Duration.zero,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpButton(
  WidgetTester tester, {
  required RecommendationInteractionController controller,
  RecommendationFeedbackSubmittedCallback? onFeedbackSubmitted,
  VoidCallback? onAdjustPersonalization,
  VoidCallback? onOpenPrivacy,
  MediaQueryData media = const MediaQueryData(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PakPerkTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: media.textScaler,
            disableAnimations: media.disableAnimations,
            accessibleNavigation: media.accessibleNavigation,
          ),
          child: Scaffold(
            body: Center(
              child: RecommendationInteractionButton(
                controller: controller,
                paperTitle: samplePaper.title,
                onFeedbackSubmitted: onFeedbackSubmitted,
                onAdjustPersonalization: onAdjustPersonalization,
                onOpenPrivacy: onOpenPrivacy,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _semanticsWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('recommendation-sheet-scroll-view')),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(target, 280, scrollable: scrollable);
  await tester.pump();
}

RecommendationInteractionController _controller(
  _FakeRecommendationRemote remote,
) => RecommendationInteractionController(
  remote: remote,
  context: _context(),
  capabilities: const RecommendationInteractionCapabilities.all(),
  operationId: () => _operationId,
);

RecommendationItemContext _context() =>
    RecommendationItemContext.forRecommendation(
      item: _recommendationItem,
      batchId: _batchId,
      paperId: samplePaper.paperId,
      authEpoch: 7,
      accountGeneration: 1,
    );

final _recommendationItem = ReadingFeedItem(
  paper: samplePaper,
  queue: null,
  source: ReadingFeedItemSource.followingV1,
  recommendation: ReadingFeedRecommendationMetadata(
    mode: ReadingFeedRecommendationMode.following,
    reasonCodes: const [RecommendationExplanationCode.followedTopic],
    reasonLabel: 'Matches a followed topic',
    explanationAvailable: true,
  ),
);

final _explanationEnvelope = RecommendationExplanationEnvelope(
  batchId: _batchId,
  paperId: samplePaper.paperId,
  explanations: const [
    RecommendationExplanation(
      code: RecommendationExplanationCode.followedTopic,
      title: 'Matches a followed topic',
      detail: 'It matches your followed topic efficient ML.',
      source: RecommendationSource.topicFollow,
      behaviorUsed: true,
      seedPaperId: null,
    ),
    RecommendationExplanation(
      code: RecommendationExplanationCode.reviewedPaperSimilarity,
      title: 'Similar to a reviewed paper',
      detail: 'It is close to a paper you marked Reviewed.',
      source: RecommendationSource.semantic,
      behaviorUsed: true,
      seedPaperId: _seedPaperId,
    ),
    RecommendationExplanation(
      code: RecommendationExplanationCode.diversitySlot,
      title: 'Adds variety',
      detail: 'It keeps this result set from repeating one topic.',
      source: RecommendationSource.exploration,
      behaviorUsed: false,
      seedPaperId: null,
    ),
  ],
);

final class _FakeRecommendationRemote
    implements RecommendationInteractionRemoteDataSource {
  final List<_ExplanationRequest> explanations = [];
  final List<_FeedbackRequest> feedback = [];

  @override
  Future<RecommendationExplanationEnvelope> explanation({
    required String batchId,
    required String paperId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    final request = _ExplanationRequest(cancellation: cancellation);
    explanations.add(request);
    return request.response.future;
  }

  @override
  Future<RecommendationFeedbackResult> submitFeedback({
    required String batchId,
    required String paperId,
    required RecommendationFeedbackSelection selection,
    required String operationId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    final request = _FeedbackRequest(
      selection: selection,
      operationId: operationId,
      cancellation: cancellation,
    );
    feedback.add(request);
    return request.response.future;
  }
}

final class _ExplanationRequest {
  _ExplanationRequest({required this.cancellation});

  final RequestCancellation? cancellation;
  final Completer<RecommendationExplanationEnvelope> response =
      Completer<RecommendationExplanationEnvelope>();
}

final class _FeedbackRequest {
  _FeedbackRequest({
    required this.selection,
    required this.operationId,
    required this.cancellation,
  });

  final RecommendationFeedbackSelection selection;
  final String operationId;
  final RequestCancellation? cancellation;
  final Completer<RecommendationFeedbackResult> response =
      Completer<RecommendationFeedbackResult>();
}

const _batchId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _feedbackId = '018f47a6-4b56-7f4c-8c7a-e2656e820203';
const _seedPaperId = '018f47a6-4b56-7f4c-8c7a-e2656e820204';
