import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/engagement/engagement_api.dart';
import 'package:pakperk/core/engagement/engagement_models.dart';
import 'package:pakperk/features/search/research_search_models.dart';
import 'package:pakperk/features/search/saved_query_subscription_controller.dart';

void main() {
  test('persisted presentation keeps its ID out of diagnostics', () {
    final query = SavedResearchQueryDraft.savedExplore(
      savedSearchId: _savedSearchId,
      draft: ExploreSearchDraft(query: 'private discovery query'),
    );

    expect(query.savedSearchId, _savedSearchId);
    expect(query.toString(), isNot(contains(_savedSearchId)));
    expect(query.toString(), isNot(contains('private discovery query')));
    expect(
      () => SavedResearchQueryDraft.savedExplore(
        savedSearchId: 'not-a-saved-search',
        draft: ExploreSearchDraft(query: 'valid query'),
      ),
      throwsArgumentError,
    );
  });

  test(
    'saved-search subscription is canonical, bounded, and stable on retry',
    () async {
      final remote = _FakeEngagementRemote();
      final ids = <String>[_operationA, _subscriptionA];
      final controller = SavedQuerySubscriptionController(
        remote: remote,
        accountScope: _scopeA,
        enabled: true,
        createUuid: () => ids.removeAt(0),
      );
      addTearDown(controller.dispose);
      final privateQuery = List.filled(100, '🧬sensitive-topic').join(' ');
      final query = SavedResearchQueryDraft.savedExplore(
        savedSearchId: _savedSearchId,
        draft: ExploreSearchDraft(query: privateQuery),
      );

      final firstAttempt = controller.subscribe(query);
      final first = remote.requests.single;
      expect(first.operationId, _operationA);
      expect(first.id, _subscriptionA);
      expect(first.kind, SubscriptionKind.savedQuery);
      expect(first.key, _savedSearchId);
      expect(first.key, isNot(privateQuery));
      expect(first.savedSearchId, _savedSearchId);
      expect(first.label.length, lessThanOrEqualTo(160));
      expect(first.frequency, SubscriptionFrequency.daily);
      expect(first.authEpoch, 7);
      expect(
        controller.phaseFor(query),
        SavedQuerySubscriptionPhase.subscribing,
      );

      first.completion.completeError(
        const ApiException(
          code: 'UPSTREAM_UNAVAILABLE',
          message: 'private server detail',
          retryable: true,
        ),
      );
      await firstAttempt;
      expect(controller.phaseFor(query), SavedQuerySubscriptionPhase.failed);

      final retry = controller.subscribe(query);
      final second = remote.requests.last;
      expect(second.operationId, first.operationId);
      expect(second.id, first.id);
      second.completion.complete(_subscription(second));
      await retry;
      expect(
        controller.phaseFor(query),
        SavedQuerySubscriptionPhase.subscribed,
      );
      controller.forgetSavedQuery(_savedSearchId);
      expect(controller.phaseFor(query), SavedQuerySubscriptionPhase.idle);
    },
  );

  test(
    'account scope change cancels and clears pending subscription state',
    () async {
      final remote = _FakeEngagementRemote();
      final ids = <String>[
        _operationA,
        _subscriptionA,
        _operationB,
        _subscriptionB,
      ];
      final controller = SavedQuerySubscriptionController(
        remote: remote,
        accountScope: _scopeA,
        enabled: true,
        createUuid: () => ids.removeAt(0),
      );
      addTearDown(controller.dispose);
      final query = SavedResearchQueryDraft.savedExplore(
        savedSearchId: _savedSearchId,
        draft: ExploreSearchDraft(query: 'account scoped query'),
      );

      final oldAttempt = controller.subscribe(query);
      final oldRequest = remote.requests.single;
      controller.updateAccountScope(_scopeB);
      expect(oldRequest.cancellation?.isCancelled, isTrue);
      expect(controller.phaseFor(query), SavedQuerySubscriptionPhase.idle);
      oldRequest.completion.complete(_subscription(oldRequest));
      await oldAttempt;
      expect(controller.phaseFor(query), SavedQuerySubscriptionPhase.idle);

      final newAttempt = controller.subscribe(query);
      final newRequest = remote.requests.last;
      expect(newRequest.operationId, _operationB);
      expect(newRequest.id, _subscriptionB);
      expect(newRequest.authEpoch, 8);
      newRequest.completion.complete(_subscription(newRequest));
      await newAttempt;
      expect(
        controller.phaseFor(query),
        SavedQuerySubscriptionPhase.subscribed,
      );
    },
  );
}

const _savedSearchId = '10000000-0000-4000-8000-000000000001';
const _operationA = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _subscriptionA = '20000000-0000-4000-8000-000000000002';
const _operationB = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _subscriptionB = '30000000-0000-4000-8000-000000000003';

const _scopeA = ResearchSearchAccountScope(
  accountId: 'account-a',
  authEpoch: 7,
  accountGeneration: 1,
);
const _scopeB = ResearchSearchAccountScope(
  accountId: 'account-b',
  authEpoch: 8,
  accountGeneration: 2,
);

Subscription _subscription(_SubscriptionRequest request) => Subscription(
  id: request.id,
  kind: request.kind,
  key: request.key,
  label: request.label,
  savedSearchId: request.savedSearchId,
  frequency: request.frequency,
  lastEvaluatedAt: null,
  revision: 1,
  deleted: false,
  createdAt: DateTime.utc(2026, 8, 19),
  updatedAt: DateTime.utc(2026, 8, 19),
);

final class _FakeEngagementRemote implements EngagementRemoteDataSource {
  final List<_SubscriptionRequest> requests = [];

  @override
  Future<Subscription> createSubscription({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    final request = _SubscriptionRequest(
      operationId: operationId,
      id: id,
      kind: kind,
      key: key,
      label: label,
      savedSearchId: savedSearchId,
      frequency: frequency,
      authEpoch: expectedAuthEpoch,
      cancellation: cancellation,
    );
    requests.add(request);
    return request.completion.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SubscriptionRequest {
  _SubscriptionRequest({
    required this.operationId,
    required this.id,
    required this.kind,
    required this.key,
    required this.label,
    required this.savedSearchId,
    required this.frequency,
    required this.authEpoch,
    required this.cancellation,
  });

  final String operationId;
  final String id;
  final SubscriptionKind kind;
  final String key;
  final String label;
  final String? savedSearchId;
  final SubscriptionFrequency frequency;
  final int authEpoch;
  final RequestCancellation? cancellation;
  final Completer<Subscription> completion = Completer<Subscription>();
}
