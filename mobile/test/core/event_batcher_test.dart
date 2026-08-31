import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/discovery_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/interactions/interaction_api.dart';
import 'package:pakperk/core/interactions/interaction_models.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/research_profiles/research_profile_api.dart';
import 'package:pakperk/core/research_profiles/research_profile_models.dart';
import 'package:pakperk/core/sync/event_batcher.dart';

import '../support/fakes.dart';

void main() {
  test('retries are bounded and preserve event identity', () async {
    final remote = _RecordingRemote(
      failures: 2,
      error: const ApiException(
        code: 'RATE_LIMITED',
        message: 'Retry later.',
        retryable: true,
      ),
    );
    final batcher = _batcher(remote);
    batcher.updateConfiguration(
      scope: AccountInteractionScope(accountId: 'account-a', authEpoch: 7),
      behavioralCollectionEnabled: true,
    );

    expect(
      batcher.record(
        eventType: PaperInteractionEventType.impressionQualified,
        paperId: _paperId,
        feedMode: InteractionFeedMode.forYou,
        batchId: _batchId,
        position: 3,
      ),
      isTrue,
    );
    await batcher.flush();

    expect(remote.calls, hasLength(3));
    expect(remote.calls.map((call) => call.events.single.eventId).toSet(), {
      _eventId,
    });
    expect(batcher.pendingCount, 0);
  });

  test('feature-disabled and terminal failures drop safely', () async {
    final remote = _RecordingRemote(
      failures: 5,
      error: const ApiException(
        code: 'FEATURE_DISABLED',
        message: 'Disabled.',
        retryable: false,
      ),
    );
    final batcher = _batcher(remote);
    batcher.updateConfiguration(
      scope: AnonymousInteractionScope(sessionId: _sessionId),
      behavioralCollectionEnabled: true,
    );
    batcher.record(
      eventType: PaperInteractionEventType.impressionQualified,
      paperId: _paperId,
      feedMode: InteractionFeedMode.recent,
      position: 0,
    );
    await batcher.flush();
    expect(remote.calls, hasLength(1));
    expect(batcher.pendingCount, 0);
  });

  test(
    'personalization disable reduces collection to essential events',
    () async {
      final remote = _RecordingRemote();
      final batcher = _batcher(remote);
      final scope = AccountInteractionScope(
        accountId: 'account-a',
        authEpoch: 7,
      );
      batcher.updateConfiguration(
        scope: scope,
        behavioralCollectionEnabled: false,
      );
      expect(
        batcher.record(
          eventType: PaperInteractionEventType.abstractOpened,
          paperId: _paperId,
          feedMode: InteractionFeedMode.toRead,
        ),
        isFalse,
      );
      expect(
        batcher.record(
          eventType: PaperInteractionEventType.saved,
          paperId: _paperId,
          feedMode: InteractionFeedMode.toRead,
        ),
        isTrue,
      );
      await batcher.flush();
      expect(
        remote.calls.single.events.single.eventType,
        PaperInteractionEventType.saved,
      );
    },
  );

  test(
    'account or anonymous scope changes synchronously invalidate pending',
    () {
      final batcher = _batcher(_RecordingRemote());
      batcher.updateConfiguration(
        scope: AccountInteractionScope(accountId: 'account-a', authEpoch: 7),
        behavioralCollectionEnabled: false,
      );
      batcher.record(
        eventType: PaperInteractionEventType.saved,
        paperId: _paperId,
        feedMode: InteractionFeedMode.toRead,
      );
      batcher.updateConfiguration(
        scope: AnonymousInteractionScope(sessionId: _sessionId),
        behavioralCollectionEnabled: true,
      );
      expect(batcher.pendingCount, 0);
    },
  );

  test('invalid generated identity is rejected without throwing', () {
    final batcher = InteractionEventBatcher(
      remote: _RecordingRemote(),
      eventId: () => 'not-a-uuid',
    );
    batcher.updateConfiguration(
      scope: AccountInteractionScope(accountId: 'account-a', authEpoch: 7),
      behavioralCollectionEnabled: false,
    );
    expect(
      batcher.record(
        eventType: PaperInteractionEventType.saved,
        paperId: _paperId,
        feedMode: InteractionFeedMode.toRead,
      ),
      isFalse,
    );
    expect(batcher.pendingCount, 0);
  });

  test(
    'provider requires the independent event flag and guest consent',
    () async {
      final flagOffRemote = _RecordingRemote();
      final flagOff = _providerContainer(
        remote: flagOffRemote,
        eventFlag: false,
        recommendationFlag: true,
      );
      addTearDown(flagOff.dispose);
      expect(
        flagOff
            .read(interactionEventBatcherProvider)
            .record(
              eventType: PaperInteractionEventType.saved,
              paperId: _paperId,
              feedMode: InteractionFeedMode.toRead,
            ),
        isFalse,
      );

      final anonymousRemote = _RecordingRemote();
      final anonymous = _providerContainer(
        remote: anonymousRemote,
        eventFlag: true,
      );
      addTearDown(anonymous.dispose);
      // A stale account preference must not become anonymous consent.
      anonymous
          .read(interactionPersonalizationEnabledProvider.notifier)
          .publish(
            scope: const (accountId: 'account-a', authEpoch: 7),
            enabled: true,
          );
      final batcher = anonymous.read(interactionEventBatcherProvider);
      expect(
        batcher.record(
          eventType: PaperInteractionEventType.impressionQualified,
          paperId: _paperId,
          feedMode: InteractionFeedMode.recent,
          position: 0,
        ),
        isFalse,
      );
      expect(
        batcher.record(
          eventType: PaperInteractionEventType.saved,
          paperId: _paperId,
          feedMode: InteractionFeedMode.toRead,
        ),
        isFalse,
      );
      await batcher.flush();
      expect(flagOffRemote.calls, isEmpty);
      expect(anonymousRemote.calls, isEmpty);
    },
  );

  test(
    'disabled provider does not construct auth or transport dependencies',
    () {
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const FeatureFlags(
              accounts: true,
              library: true,
              comments: false,
              openingMotion: false,
              recommendationEventsEnabled: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container
            .read(interactionEventBatcherProvider)
            .record(
              eventType: PaperInteractionEventType.saved,
              paperId: _paperId,
              feedMode: InteractionFeedMode.toRead,
            ),
        isFalse,
      );
    },
  );

  test(
    'provider startup fails closed until current stored consent resolves true',
    () async {
      final remote = _RecordingRemote();
      final profileResult =
          Completer<ResearchProfileApiResult<ResearchProfile>>();
      final profileRemote = _ProfileRemote(
        (expectedAuthEpoch, _) => profileResult.future,
      );
      const scope = (accountId: 'account-a', authEpoch: 7);
      final container = _providerContainer(
        remote: remote,
        eventFlag: true,
        accountScope: scope,
        profileRemote: profileRemote,
      );
      addTearDown(container.dispose);

      expect(container.read(interactionPersonalizationEnabledProvider), isNull);
      expect(
        container
            .read(interactionEventBatcherProvider)
            .record(
              eventType: PaperInteractionEventType.impressionQualified,
              paperId: _paperId,
              feedMode: InteractionFeedMode.forYou,
              batchId: _batchId,
              position: 0,
            ),
        isFalse,
      );
      expect(profileRemote.requestedEpochs, [7]);

      profileResult.complete(_profileResult(personalizationEnabled: true));
      await pumpEventQueue();
      expect(container.read(interactionPersonalizationEnabledProvider), isTrue);
      final optedIn = container.read(interactionEventBatcherProvider);
      expect(
        optedIn.record(
          eventType: PaperInteractionEventType.impressionQualified,
          paperId: _paperId,
          feedMode: InteractionFeedMode.forYou,
          batchId: _batchId,
          position: 0,
        ),
        isTrue,
      );
      await optedIn.flush();
      expect(remote.calls, hasLength(1));
    },
  );

  test(
    'restart never retains true before the new consent load completes',
    () async {
      const scope = (accountId: 'account-a', authEpoch: 7);
      final firstRemote = _ProfileRemote(
        (_, _) async => _profileResult(personalizationEnabled: true),
      );
      final first = _providerContainer(
        remote: _RecordingRemote(),
        eventFlag: true,
        accountScope: scope,
        profileRemote: firstRemote,
      );
      first.read(interactionPersonalizationEnabledProvider);
      await pumpEventQueue();
      expect(first.read(interactionPersonalizationEnabledProvider), isTrue);
      first.dispose();

      final restartedResult =
          Completer<ResearchProfileApiResult<ResearchProfile>>();
      final restartedRemote = _ProfileRemote((_, _) => restartedResult.future);
      final interactions = _RecordingRemote();
      final restarted = _providerContainer(
        remote: interactions,
        eventFlag: true,
        accountScope: scope,
        profileRemote: restartedRemote,
      );
      addTearDown(restarted.dispose);

      expect(restarted.read(interactionPersonalizationEnabledProvider), isNull);
      expect(
        restarted
            .read(interactionEventBatcherProvider)
            .record(
              eventType: PaperInteractionEventType.abstractOpened,
              paperId: _paperId,
              feedMode: InteractionFeedMode.toRead,
            ),
        isFalse,
      );
      restartedResult.complete(_profileResult(personalizationEnabled: true));
      await pumpEventQueue();
      expect(restarted.read(interactionPersonalizationEnabledProvider), isTrue);
      expect(firstRemote.requestedEpochs, [7]);
      expect(restartedRemote.requestedEpochs, [7]);
      expect(interactions.calls, isEmpty);
    },
  );

  test('account switch cannot inherit or receive stale consent', () async {
    const accountA = (accountId: 'account-a', authEpoch: 7);
    const accountB = (accountId: 'account-b', authEpoch: 8);
    final activeScope = StateProvider<VerifiedDiscoveryAccountScope?>(
      (_) => accountA,
    );
    final accountAResult =
        Completer<ResearchProfileApiResult<ResearchProfile>>();
    final accountBResult =
        Completer<ResearchProfileApiResult<ResearchProfile>>();
    final profileRemote = _ProfileRemote(
      (expectedAuthEpoch, _) => switch (expectedAuthEpoch) {
        7 => accountAResult.future,
        8 => accountBResult.future,
        _ => throw StateError('Unexpected auth epoch.'),
      },
    );
    final interactions = _RecordingRemote();
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWithValue(
          _eventFlags(researchProfilesEnabled: true),
        ),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialAnonymousSessionIdProvider.overrideWithValue(_sessionId),
        verifiedDiscoveryAccountScopeProvider.overrideWith(
          (ref) => ref.watch(activeScope),
        ),
        researchProfileApiProvider.overrideWithValue(profileRemote),
        interactionApiProvider.overrideWithValue(interactions),
      ],
    );
    addTearDown(container.dispose);

    container.read(interactionEventBatcherProvider);
    expect(profileRemote.requestedEpochs, [7]);
    container.read(activeScope.notifier).state = accountB;
    container.read(interactionEventBatcherProvider);
    expect(container.read(interactionPersonalizationEnabledProvider), isNull);
    expect(profileRemote.requestedEpochs, [7, 8]);

    accountAResult.complete(_profileResult(personalizationEnabled: true));
    await pumpEventQueue();
    expect(container.read(interactionPersonalizationEnabledProvider), isNull);
    expect(
      container
          .read(interactionEventBatcherProvider)
          .record(
            eventType: PaperInteractionEventType.impressionQualified,
            paperId: _paperId,
            feedMode: InteractionFeedMode.forYou,
            batchId: _batchId,
            position: 0,
          ),
      isFalse,
    );

    accountBResult.complete(_profileResult(personalizationEnabled: true));
    await pumpEventQueue();
    expect(container.read(interactionPersonalizationEnabledProvider), isTrue);
    final current = container.read(interactionEventBatcherProvider);
    expect(
      current.record(
        eventType: PaperInteractionEventType.impressionQualified,
        paperId: _paperId,
        feedMode: InteractionFeedMode.forYou,
        batchId: _batchId,
        position: 0,
      ),
      isTrue,
    );
    await current.flush();
    expect(
      interactions.calls.single.scope,
      AccountInteractionScope(
        accountId: accountB.accountId,
        authEpoch: accountB.authEpoch,
      ),
    );
  });
}

ProviderContainer _providerContainer({
  required _RecordingRemote remote,
  required bool eventFlag,
  bool recommendationFlag = false,
  VerifiedDiscoveryAccountScope? accountScope,
  ResearchProfileRemoteDataSource? profileRemote,
}) => ProviderContainer(
  overrides: [
    featureFlagsProvider.overrideWithValue(
      _eventFlags(
        eventFlag: eventFlag,
        recommendationFlag: recommendationFlag,
        researchProfilesEnabled: profileRemote != null,
      ),
    ),
    localStoreProvider.overrideWithValue(MemoryLocalStore()),
    initialAnonymousSessionIdProvider.overrideWithValue(_sessionId),
    verifiedDiscoveryAccountScopeProvider.overrideWithValue(accountScope),
    if (profileRemote != null)
      researchProfileApiProvider.overrideWithValue(profileRemote),
    interactionApiProvider.overrideWithValue(remote),
  ],
);

FeatureFlags _eventFlags({
  bool eventFlag = true,
  bool recommendationFlag = false,
  bool researchProfilesEnabled = false,
}) => FeatureFlags(
  accounts: true,
  library: true,
  comments: false,
  openingMotion: false,
  readingFeed: true,
  recommendationsEnabled: recommendationFlag,
  recommendationEventsEnabled: eventFlag,
  researchProfilesEnabled: researchProfilesEnabled,
);

InteractionEventBatcher _batcher(_RecordingRemote remote) =>
    InteractionEventBatcher(
      remote: remote,
      clock: () => DateTime.utc(2026, 8, 28, 8),
      eventId: () => _eventId,
      delay: (_) async {},
    );

final class _RecordingRemote implements InteractionRemoteDataSource {
  _RecordingRemote({this.failures = 0, this.error});

  int failures;
  final ApiException? error;
  final List<({InteractionScope scope, List<PaperInteractionEvent> events})>
  calls = [];

  @override
  Future<InteractionBatchResult> sendBatch({
    required InteractionScope scope,
    required List<PaperInteractionEvent> events,
  }) async {
    calls.add((scope: scope, events: events));
    if (failures > 0) {
      failures -= 1;
      throw error!;
    }
    return InteractionBatchResult(accepted: events.length, duplicates: 0);
  }
}

typedef _ProfileLoader =
    Future<ResearchProfileApiResult<ResearchProfile>> Function(
      int expectedAuthEpoch,
      RequestCancellation? cancellation,
    );

final class _ProfileRemote extends Fake
    implements ResearchProfileRemoteDataSource {
  _ProfileRemote(this._load);

  final _ProfileLoader _load;
  final List<int> requestedEpochs = [];

  @override
  Future<ResearchProfileApiResult<ResearchProfile>> profile({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    requestedEpochs.add(expectedAuthEpoch);
    return _load(expectedAuthEpoch, cancellation);
  }
}

ResearchProfileApiResult<ResearchProfile> _profileResult({
  required bool personalizationEnabled,
}) => ResearchProfileApiResult(
  value: ResearchProfile(
    personalizationEnabled: personalizationEnabled,
    preferredDiscoveryMode: PreferredDiscoveryMode.recent,
    discoveryMode: ResearchDiscoveryMode.balanced,
    briefSize: 20,
    recencyWeight: 0.4,
    noveltyWeight: 0.3,
    diversityWeight: 0.3,
    profileRevision: 1,
    createdAt: DateTime.utc(2026, 8, 28),
    updatedAt: DateTime.utc(2026, 8, 28),
  ),
  revision: 1,
);

const _eventId = '70000000-0000-7000-8000-000000000001';
const _paperId = '40000000-0000-4000-8000-000000000004';
const _batchId = '70000000-0000-7000-8000-000000000007';
const _sessionId = '70000000-0000-7000-8000-000000000009';
