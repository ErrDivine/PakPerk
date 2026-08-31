import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_api.dart';
import 'package:pakperk/core/recommendations/recommendation_interaction_models.dart';
import 'package:pakperk/features/recommendations/recommendation_interaction_controller.dart';

import '../support/fakes.dart';

void main() {
  test('recommendation context rejects queue items and identity mismatch', () {
    final queueItem = ReadingFeedItem(
      paper: samplePaper,
      queue: ReadingFeedQueueItem(
        savedAt: DateTime.utc(2026, 8, 19),
        revision: 4,
      ),
      source: ReadingFeedItemSource.toRead,
    );

    expect(
      () => RecommendationItemContext.forRecommendation(
        item: queueItem,
        batchId: _batchId,
        paperId: samplePaper.paperId,
        authEpoch: 7,
        accountGeneration: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => RecommendationItemContext.forRecommendation(
        item: _recommendationItem,
        batchId: _batchId,
        paperId: _otherId,
        authEpoch: 7,
        accountGeneration: 1,
      ),
      throwsArgumentError,
    );
  });

  test('capabilities default off and perform no remote work', () async {
    final remote = _FakeRecommendationRemote();
    final controller = RecommendationInteractionController(
      remote: remote,
      context: _context(),
    );
    addTearDown(controller.dispose);

    expect(controller.controlsAvailable, isFalse);
    expect(
      controller.state.explanationPhase,
      RecommendationExplanationPhase.unavailable,
    );
    await controller.loadExplanation();
    await controller.submitFeedback(
      const RecommendationFeedbackSelection.relevant(),
    );
    expect(remote.explanations, isEmpty);
    expect(remote.feedback, isEmpty);
  });

  testWidgets('explanation is ephemeral and cancelled on scope change', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = RecommendationInteractionController(
      remote: remote,
      context: _context(),
      capabilities: const RecommendationInteractionCapabilities.all(),
      operationId: () => _operationId,
    );
    addTearDown(controller.dispose);

    unawaited(controller.loadExplanation());
    expect(remote.explanations, hasLength(1));
    expect(remote.explanations.single.expectedAuthEpoch, 7);
    expect(remote.explanations.single.cancellation?.isCancelled, isFalse);

    controller.updateContext(_context(batchId: _otherId, accountGeneration: 2));
    expect(remote.explanations.single.cancellation?.isCancelled, isTrue);
    expect(controller.state.explanations, isEmpty);
    remote.explanations.single.response.complete(_explanationEnvelope);
    await tester.pump();
    expect(controller.state.explanations, isEmpty);
    expect(
      controller.state.explanationPhase,
      RecommendationExplanationPhase.idle,
    );
  });

  testWidgets('feedback retry reuses the exact operation identity', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = RecommendationInteractionController(
      remote: remote,
      context: _context(),
      capabilities: const RecommendationInteractionCapabilities.all(),
      operationId: () => _operationId,
    );
    addTearDown(controller.dispose);
    const selection = RecommendationFeedbackSelection(
      type: RecommendationFeedbackType.notRelevant,
      reason: RecommendationFeedbackReason.offTopic,
    );

    unawaited(controller.submitFeedback(selection));
    expect(remote.feedback, hasLength(1));
    remote.feedback.single.response.completeError(
      const ApiException(
        code: 'RECOMMENDATION_SERVICE_UNAVAILABLE',
        message: 'raw database detail',
        retryable: true,
      ),
    );
    await tester.pump();
    expect(controller.state.feedbackPhase, RecommendationFeedbackPhase.failed);
    expect(controller.state.feedbackFailure?.message, isNot(contains('raw')));
    expect(controller.state.feedbackOperationId, _operationId);

    unawaited(controller.retryFeedback());
    expect(remote.feedback, hasLength(2));
    expect(remote.feedback.map((request) => request.operationId), {
      _operationId,
    });
    remote.feedback.last.response.complete(
      const RecommendationFeedbackResult(
        feedbackId: _feedbackId,
        replayed: true,
      ),
    );
    await tester.pump();
    expect(
      controller.state.feedbackPhase,
      RecommendationFeedbackPhase.succeeded,
    );
    expect(controller.state.feedbackResult?.replayed, isTrue);
  });

  testWidgets('capability removal cancels feedback and drops late success', (
    tester,
  ) async {
    final remote = _FakeRecommendationRemote();
    final controller = RecommendationInteractionController(
      remote: remote,
      context: _context(),
      capabilities: const RecommendationInteractionCapabilities.all(),
      operationId: () => _operationId,
    );
    addTearDown(controller.dispose);

    unawaited(
      controller.submitFeedback(
        const RecommendationFeedbackSelection.relevant(),
      ),
    );
    final request = remote.feedback.single;
    controller.updateCapabilities(
      const RecommendationInteractionCapabilities.disabled(),
    );
    expect(request.cancellation?.isCancelled, isTrue);
    request.response.complete(
      const RecommendationFeedbackResult(
        feedbackId: _feedbackId,
        replayed: false,
      ),
    );
    await tester.pump();
    expect(controller.controlsAvailable, isFalse);
    expect(controller.state.feedbackResult, isNull);
    expect(
      controller.state.feedbackPhase,
      RecommendationFeedbackPhase.unavailable,
    );
  });

  test('diagnostics redact recommendation and operation identities', () {
    final context = _context();
    final state = RecommendationInteractionState(
      explanationPhase: RecommendationExplanationPhase.idle,
      feedbackPhase: RecommendationFeedbackPhase.sending,
      feedbackOperationId: _operationId,
    );

    expect(context.toString(), isNot(contains(_batchId)));
    expect(context.toString(), isNot(contains(samplePaper.paperId)));
    expect(state.toString(), isNot(contains(_operationId)));
  });
}

RecommendationItemContext _context({
  String batchId = _batchId,
  int accountGeneration = 1,
}) => RecommendationItemContext.forRecommendation(
  item: _recommendationItem,
  batchId: batchId,
  paperId: samplePaper.paperId,
  authEpoch: 7,
  accountGeneration: accountGeneration,
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
    final request = _ExplanationRequest(
      batchId: batchId,
      paperId: paperId,
      expectedAuthEpoch: expectedAuthEpoch,
      cancellation: cancellation,
    );
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
      batchId: batchId,
      paperId: paperId,
      selection: selection,
      operationId: operationId,
      expectedAuthEpoch: expectedAuthEpoch,
      cancellation: cancellation,
    );
    feedback.add(request);
    return request.response.future;
  }
}

final class _ExplanationRequest {
  _ExplanationRequest({
    required this.batchId,
    required this.paperId,
    required this.expectedAuthEpoch,
    required this.cancellation,
  });

  final String batchId;
  final String paperId;
  final int expectedAuthEpoch;
  final RequestCancellation? cancellation;
  final Completer<RecommendationExplanationEnvelope> response =
      Completer<RecommendationExplanationEnvelope>();
}

final class _FeedbackRequest {
  _FeedbackRequest({
    required this.batchId,
    required this.paperId,
    required this.selection,
    required this.operationId,
    required this.expectedAuthEpoch,
    required this.cancellation,
  });

  final String batchId;
  final String paperId;
  final RecommendationFeedbackSelection selection;
  final String operationId;
  final int expectedAuthEpoch;
  final RequestCancellation? cancellation;
  final Completer<RecommendationFeedbackResult> response =
      Completer<RecommendationFeedbackResult>();
}

const _batchId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _feedbackId = '018f47a6-4b56-7f4c-8c7a-e2656e820203';
const _otherId = '018f47a6-4b56-7f4c-8c7a-e2656e820204';
