import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/reading_feed/reading_feed_api.dart';
import 'package:pakperk/core/reading_feed/reading_feed_models.dart';
import 'package:pakperk/core/reading_feed/reading_feed_page_cache.dart';
import 'package:pakperk/core/reading_feed/reading_feed_policy.dart';
import 'package:pakperk/core/reading_feed/reading_feed_repository.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/feed/feed_controller.dart';
import 'package:pakperk/features/feed/reading_feed_controller.dart';

import '../core/auth/auth_fakes.dart';
import '../support/fakes.dart';

void main() {
  test('provider allows discovery without constructing disabled auth', () {
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWithValue(const FeatureFlags.disabled()),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(publicDiscoveryAllowedProvider), isTrue);
  });

  test('completion acknowledgement clears only its matching sequence', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      libraryFinalCompletionAcknowledgementProvider.notifier,
    );

    controller.publish(
      accountId: 'account-a',
      authEpoch: 1,
      acknowledgedAt: DateTime.utc(2026),
    );
    final first = container.read(
      libraryFinalCompletionAcknowledgementProvider,
    )!;
    controller.publish(
      accountId: 'account-a',
      authEpoch: 1,
      acknowledgedAt: DateTime.utc(2026, 1, 2),
    );
    final second = container.read(
      libraryFinalCompletionAcknowledgementProvider,
    )!;

    controller.end(first.sequence);
    expect(
      container.read(libraryFinalCompletionAcknowledgementProvider),
      same(second),
    );

    controller.end(second.sequence);
    expect(
      container.read(libraryFinalCompletionAcknowledgementProvider),
      isNull,
    );
  });

  test('shadow rollout retains legacy discovery and its prefetch owner', () {
    const base = FeatureFlags(
      accounts: true,
      library: true,
      comments: false,
      openingMotion: false,
      readingFeed: true,
    );

    expect(
      allowsPublicDiscovery(
        flags: base,
        authPhase: AuthSessionPhase.authenticated,
      ),
      isTrue,
    );
    expect(
      allowsPublicDiscovery(
        flags: const FeatureFlags(
          accounts: true,
          library: true,
          comments: false,
          openingMotion: false,
          readingFeed: true,
          toReadFirstEnforcement: true,
        ),
        authPhase: AuthSessionPhase.authenticated,
      ),
      isFalse,
    );
    expect(
      allowsPublicDiscovery(
        flags: const FeatureFlags(
          accounts: true,
          library: true,
          comments: false,
          openingMotion: false,
          readingFeed: true,
          toReadFirstEnforcement: true,
        ),
        authPhase: AuthSessionPhase.authenticated,
        serverEnforcement: ReadingFeedEnforcement.shadow,
      ),
      isTrue,
    );
    expect(
      allowsPublicDiscovery(
        flags: const FeatureFlags(
          accounts: true,
          library: true,
          comments: false,
          openingMotion: false,
          readingFeed: true,
          toReadFirstEnforcement: true,
        ),
        authPhase: AuthSessionPhase.authenticated,
        serverEnforcement: ReadingFeedEnforcement.strict,
      ),
      isFalse,
    );
  });

  test(
    'server rollout policy is accepted only for the current verified scope',
    () {
      const accountA = ReadingFeedAccountScope(
        accountId: _accountA,
        authEpoch: 1,
      );
      const accountB = ReadingFeedAccountScope(
        accountId: _accountB,
        authEpoch: 2,
      );
      final state = ReadingFeedState(
        authEpoch: accountA.authEpoch,
        accountScopeFingerprint: readingFeedScopeFingerprint(accountA),
        serverEnforcement: ReadingFeedEnforcement.shadow,
      );

      expect(
        scopedServerEnforcement(
          state: state,
          sessionScope: accountA,
          verifiedScope: accountA,
        ),
        ReadingFeedEnforcement.shadow,
      );
      expect(
        scopedServerEnforcement(
          state: state,
          sessionScope: accountB,
          verifiedScope: accountB,
        ),
        isNull,
      );
      expect(
        scopedServerEnforcement(
          state: state,
          sessionScope: accountB,
          verifiedScope: accountA,
        ),
        isNull,
      );
    },
  );

  test(
    'provider gates rollout policy across an account and auth-epoch switch',
    () async {
      final auth = _providerAuthController(_accountA);
      expect(await auth.restoreSession(), isTrue);
      final remote = _ReadingFeedRemote();
      final container = _providerContainer(auth: auth, remote: remote);
      final subscription = container.listen<bool>(
        publicDiscoveryAllowedProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });

      expect(container.read(publicDiscoveryAllowedProvider), isFalse);
      expect(remote.requests, hasLength(1));
      remote.complete(
        0,
        _recommendations(enforcement: ReadingFeedEnforcement.shadow),
      );
      await _settleProviders();
      expect(container.read(publicDiscoveryAllowedProvider), isTrue);

      expect(await auth.signIn(), isTrue);
      await auth.bindAccountId(_accountB);
      await _settleProviders();

      expect(auth.state.epoch, 1);
      expect(auth.state.accountId, _accountB);
      expect(container.read(publicDiscoveryAllowedProvider), isFalse);
      expect(remote.requests, hasLength(2));
      expect(
        container.read(readingFeedControllerProvider).serverEnforcement,
        isNull,
      );

      remote.complete(
        1,
        _recommendations(enforcement: ReadingFeedEnforcement.shadow),
      );
      await _settleProviders();
      expect(container.read(publicDiscoveryAllowedProvider), isTrue);
      expect(
        container.read(readingFeedControllerProvider).accountScopeFingerprint,
        readingFeedScopeFingerprint(
          const ReadingFeedAccountScope(accountId: _accountB, authEpoch: 1),
        ),
      );
    },
  );

  test(
    'provider revalidates on unknown-to-shadow and suppresses on strict',
    () async {
      final auth = _providerAuthController(_accountA);
      expect(await auth.restoreSession(), isTrue);
      final remote = _ReadingFeedRemote();
      final container = _providerContainer(auth: auth, remote: remote);
      final allowed = <bool>[];
      var revalidations = 0;
      final subscription = container.listen<bool>(
        publicDiscoveryAllowedProvider,
        (previous, next) {
          allowed.add(next);
          if (shouldRefreshDiscoveryAfterPolicyChange(previous, next)) {
            revalidations += 1;
          }
        },
        fireImmediately: true,
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });

      expect(allowed, [isFalse]);
      expect(remote.requests, hasLength(1));
      remote.complete(
        0,
        _recommendations(enforcement: ReadingFeedEnforcement.shadow),
      );
      await _settleProviders();

      expect(allowed, [isFalse, isTrue]);
      expect(revalidations, 1);
      expect(container.read(publicDiscoveryAllowedProvider), isTrue);

      final refresh = container
          .read(readingFeedControllerProvider.notifier)
          .refresh(force: true);
      expect(remote.requests, hasLength(2));
      remote.complete(
        1,
        _recommendations(enforcement: ReadingFeedEnforcement.strict),
      );
      await refresh;
      await _settleProviders();

      expect(allowed, [isFalse, isTrue, isFalse]);
      expect(revalidations, 1);
      expect(container.read(publicDiscoveryAllowedProvider), isFalse);
      expect(
        container.read(readingFeedControllerProvider).serverEnforcement,
        ReadingFeedEnforcement.strict,
      );
    },
  );

  test(
    'local queue publishes immediately in FIFO order while auth verifies',
    () {
      final controller = _controller(_ReadingFeedRemote(), autoRefresh: false);
      addTearDown(controller.dispose);
      final later = _localItem(_paper(2), day: 2);
      final earlier = _localItem(_paper(1), day: 1);

      controller.updateInput(
        _input(
          authentication: ReadingFeedAuthentication.unknown,
          verified: false,
          localItems: [later, earlier],
        ),
      );

      expect(controller.state.mode, ReadingFeedMode.toRead);
      expect(controller.state.queueAuthority, QueueAuthority.localNonEmpty);
      expect(controller.state.items.map((paper) => paper.paperId), [
        earlier.paper.paperId,
        later.paper.paperId,
      ]);
      expect(controller.state.recommendationsVisible, isFalse);
    },
  );

  test('pending save suppresses a late authoritative-empty response', () async {
    final remote = _ReadingFeedRemote();
    final recording = _RecordingTelemetrySink();
    final controller = _controller(
      remote,
      telemetry: RedactingTelemetrySink(recording),
    );
    addTearDown(controller.dispose);

    controller.updateInput(_input());
    expect(remote.requests, hasLength(1));

    controller.updateInput(
      _input(pending: const LibraryPendingIntentCounts(saves: 1, removes: 0)),
    );
    remote.complete(0, _recommendations());
    await _settle();

    expect(controller.state.mode, ReadingFeedMode.toRead);
    expect(controller.state.queueAuthority, QueueAuthority.pendingSave);
    expect(controller.state.items, isEmpty);
    expect(controller.state.recommendationsVisible, isFalse);
    final rejection = recording.events.singleWhere(
      (event) =>
          event.$1 == PakPerkTelemetryEvent.recommendationPublicationRejected,
    );
    expect(rejection.$2, const {'reason': 'pending_save'});
  });

  test('save intent measures immediate discovery suppression', () async {
    var now = DateTime.utc(2026, 8, 28, 10);
    final remote = _ReadingFeedRemote();
    final recording = _RecordingTelemetrySink();
    final controller = _controller(
      remote,
      autoRefresh: false,
      telemetry: RedactingTelemetrySink(recording),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    controller.updateInput(_input());
    final refresh = controller.refresh();
    remote.complete(0, _recommendations());
    await refresh;
    expect(controller.state.recommendationsVisible, isTrue);

    final startedAt = now;
    now = now.add(const Duration(milliseconds: 250));
    controller.updateInput(
      _input(
        saveIntent: LibrarySaveIntentSignal(
          accountId: _accountA,
          authEpoch: 1,
          sequence: 1,
          startedAt: startedAt,
        ),
      ),
    );

    expect(controller.state.recommendationsVisible, isFalse);
    final suppression = recording.events.singleWhere(
      (event) => event.$1 == PakPerkTelemetryEvent.discoverySuppressionLatency,
    );
    expect(suppression.$2, const {
      'trigger': 'save',
      'latency_bucket': '100ms_1s',
    });
    final cancellation = recording.events.singleWhere(
      (event) =>
          event.$1 ==
          PakPerkTelemetryEvent.recommendationAdvanceCancelledAfterSave,
    );
    expect(cancellation.$2, const {
      'outcome': 'cancelled',
      'local_intent': true,
    });
  });

  test(
    'pending import suppresses a late authoritative-empty response',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);

      controller.updateInput(_input());
      controller.updateInput(_input(pendingImportCount: 1));
      remote.complete(0, _recommendations());
      await _settle();

      expect(controller.state.mode, ReadingFeedMode.toRead);
      expect(controller.state.queueAuthority, QueueAuthority.pendingSave);
      expect(controller.state.items, isEmpty);
    },
  );

  test(
    'import activity to durable draft handoff never republishes recommendations',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);

      controller.updateInput(_input());
      remote.complete(0, _recommendations());
      await _settle();
      expect(controller.state.recommendationsVisible, isTrue);

      // The sheet publishes activity synchronously before its ledger write.
      controller.updateInput(_input(pendingImportCount: 1));
      expect(controller.state.recommendationsVisible, isFalse);

      // Once the queued write completes, the durable draft contributes the
      // same count before activity is ended. The effective authority input is
      // intentionally continuous across that handoff.
      controller.updateInput(_input(pendingImportCount: 1));
      expect(controller.state.mode, ReadingFeedMode.toRead);
      expect(controller.state.queueAuthority, QueueAuthority.pendingSave);
      expect(controller.state.recommendationsVisible, isFalse);
    },
  );

  test('old account and auth-epoch responses are discarded', () async {
    final remote = _ReadingFeedRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);

    controller.updateInput(_input(accountId: _accountA, authEpoch: 2));
    controller.updateInput(_input(accountId: _accountB, authEpoch: 3));
    expect(remote.requests, hasLength(2));

    remote.complete(0, _recommendations());
    await _settle();
    expect(controller.state.items, isEmpty);
    expect(controller.state.recommendationsVisible, isFalse);

    remote.complete(1, _recommendations());
    await _settle();
    expect(controller.state.items.single.paperId, samplePaper.paperId);
    expect(controller.state.recommendationsVisible, isTrue);
    expect(controller.state.authEpoch, 3);
  });

  test(
    'personalized provenance and the requested mode stay scope-bound',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(
        remote,
        recommendationMode: ReadingFeedRecommendationMode.explore,
      );
      addTearDown(controller.dispose);

      controller.updateInput(_input(authEpoch: 4));
      expect(
        remote.requests.single.recommendationMode,
        ReadingFeedRecommendationMode.explore,
      );
      remote.complete(0, _personalizedRecommendations());
      await _settle();

      final state = controller.state;
      expect(state.recommendationBatchId, _batchId);
      expect(state.recommendationItems, hasLength(1));
      expect(state.recommendationItemAt(0)?.paper.paperId, samplePaper.paperId);
      expect(state.authEpoch, 4);
      expect(state.accountGeneration, greaterThan(0));
    },
  );

  test(
    'default recommendation request defers mode to server profile',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);

      controller.updateInput(_input(authEpoch: 4));
      expect(remote.requests.single.recommendationMode, isNull);
      remote.complete(0, _recommendations());
      await _settle();
    },
  );

  test(
    'final remove stays finishing until the server confirms empty',
    () async {
      var now = DateTime.utc(2026, 8, 28, 10);
      final remote = _ReadingFeedRemote();
      final recording = _RecordingTelemetrySink();
      final controller = _controller(
        remote,
        telemetry: RedactingTelemetrySink(recording),
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.updateInput(
        _input(pending: const LibraryPendingIntentCounts(saves: 0, removes: 1)),
      );
      expect(controller.state.mode, ReadingFeedMode.finishingQueue);
      expect(remote.requests, isEmpty);

      controller.updateInput(
        _input(
          finalCompletionAcknowledgement: LibraryFinalCompletionAcknowledgement(
            accountId: _accountA,
            authEpoch: 1,
            sequence: 1,
            acknowledgedAt: now,
          ),
        ),
      );
      expect(controller.state.mode, ReadingFeedMode.checkingQueue);
      expect(remote.requests, hasLength(1));
      now = now.add(const Duration(seconds: 3));
      remote.complete(0, _recommendations());
      await _settle();

      expect(controller.state.mode, ReadingFeedMode.recommendations);
      expect(
        controller.state.queueAuthority,
        QueueAuthority.serverConfirmedEmpty,
      );
      expect(controller.state.recommendationsVisible, isTrue);
      final unlock = recording.events.singleWhere(
        (event) => event.$1 == PakPerkTelemetryEvent.discoveryUnlockLatency,
      );
      expect(unlock.$2, const {
        'trigger': 'final_completion',
        'latency_bucket': '1s_5s',
      });
      final checkingDuration = recording.events.singleWhere(
        (event) => event.$1 == PakPerkTelemetryEvent.finalItemCheckingDuration,
      );
      expect(checkingDuration.$2, const {
        'duration_bucket': '1s_5s',
        'outcome': 'recommendations',
      });
    },
  );

  test('offline empty queue fails closed but retains local papers', () {
    final remote = _ReadingFeedRemote();
    final controller = _controller(remote, autoRefresh: false);
    addTearDown(controller.dispose);

    controller.updateInput(_input(offline: true));
    expect(controller.state.mode, ReadingFeedMode.unavailable);
    expect(controller.state.items, isEmpty);

    controller.updateInput(
      _input(
        authentication: ReadingFeedAuthentication.unknown,
        verified: false,
        offline: true,
        localItems: [_localItem(samplePaper, day: 1)],
      ),
    );
    expect(controller.state.mode, ReadingFeedMode.toRead);
    expect(controller.state.items.single.paperId, samplePaper.paperId);
    expect(controller.state.recommendationsVisible, isFalse);
  });

  test(
    'stale recommendation cursor restarts from a fresh first page',
    () async {
      final remote = _ReadingFeedRemote();
      final recording = _RecordingTelemetrySink();
      final controller = _controller(
        remote,
        telemetry: RedactingTelemetrySink(recording),
      );
      addTearDown(controller.dispose);

      controller.updateInput(_input());
      remote.complete(0, _recommendations(nextCursor: 'opaque-next'));
      await _settle();
      expect(controller.state.recommendationsVisible, isTrue);

      final load = controller.loadMore();
      await _settle();
      remote.completeError(
        1,
        const ApiException(
          code: 'READING_FEED_CURSOR_STALE',
          message: 'Restart the feed.',
          statusCode: 409,
          retryable: true,
        ),
      );
      await load;
      await _settle();

      expect(remote.requests, hasLength(3));
      expect(remote.requests.last.cursor, isNull);
      expect(controller.state.items, isEmpty);
      remote.complete(2, _recommendations());
      await _settle();
      expect(controller.state.recommendationsVisible, isTrue);
      final recovery = recording.events.singleWhere(
        (event) => event.$1 == PakPerkTelemetryEvent.queueStaleCursorRecovery,
      );
      expect(recovery.$2, const {
        'outcome': 'restart_requested',
        'surface': 'recommendations',
        'offline': false,
      });
    },
  );

  test(
    'valid recommendation continuation appends in chronological order',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);

      controller.updateInput(_input());
      remote.complete(
        0,
        _recommendations(papers: [_paper(2)], nextCursor: 'opaque-next'),
      );
      await _settle();

      final load = controller.loadMore();
      await _settle();
      remote.complete(1, _recommendations(papers: [_paper(1)]));
      await load;

      expect(controller.state.items.map((paper) => paper.paperId), [
        _paper(2).paperId,
        _paper(1).paperId,
      ]);
    },
  );

  test(
    'batched recommendation pages append with page-local provenance',
    () async {
      final remote = _ReadingFeedRemote();
      final cache = _RecordingReadingFeedPageCache();
      final controller = _controller(remote, pageCache: cache);
      addTearDown(controller.dispose);
      final firstPagePapers = [
        for (var suffix = 1; suffix <= 20; suffix += 1) _paper(suffix),
      ];

      controller.updateInput(_input());
      remote.complete(
        0,
        _personalizedRecommendations(
          papers: firstPagePapers,
          nextCursor: 'opaque-batch-next',
        ),
      );
      await _settle();
      expect(controller.state.items, hasLength(20));

      final load = controller.loadMore();
      await _settle();
      expect(remote.requests.last.cursor, 'opaque-batch-next');
      remote.complete(
        1,
        _personalizedRecommendations(
          papers: [_paper(21)],
          batchId: _otherBatchId,
        ),
      );
      await load;

      final state = controller.state;
      expect(state.items, hasLength(21));
      expect(state.items.last.paperId, _paper(21).paperId);
      expect(state.recommendationBatchId, isNull);
      expect(state.recommendationProvenanceAt(0)?.batchId, _batchId);
      expect(state.recommendationProvenanceAt(0)?.rerankedPosition, 0);
      expect(state.recommendationProvenanceAt(19)?.batchId, _batchId);
      expect(state.recommendationProvenanceAt(19)?.rerankedPosition, 19);
      expect(state.recommendationProvenanceAt(20)?.batchId, _otherBatchId);
      expect(state.recommendationProvenanceAt(20)?.rerankedPosition, 0);
      expect(state.recommendationBatchIdAt(20), _otherBatchId);
      expect(state.recommendationPositionAt(20), 0);
      expect(cache.savedPages, hasLength(1));
      expect(cache.savedPages.single.batchId, _batchId);
      expect(cache.savedPages.single.items, hasLength(20));
    },
  );

  test(
    'batched continuation metadata mode or revision drift restarts closed',
    () async {
      final incompatiblePages = <ReadingFeedPage>[
        _personalizedRecommendations(
          papers: [_paper(2)],
          batchId: _otherBatchId,
          batchMetadata: const ReadingFeedBatchMetadata(
            profileRevision: 4,
            feedbackRevision: 3,
            algorithmVersion: 'ranker-v2',
            recommendationPolicyVersion: 'policy-v2',
          ),
        ),
        _personalizedRecommendations(
          papers: [_paper(2)],
          batchId: _otherBatchId,
          mode: ReadingFeedRecommendationMode.following,
        ),
        _personalizedRecommendations(
          papers: [_paper(2)],
          batchId: _otherBatchId,
          libraryRevision: 6,
        ),
        _personalizedRecommendations(
          papers: [_paper(2)],
          batchId: _otherBatchId,
          enforcement: ReadingFeedEnforcement.shadow,
        ),
      ];

      for (final continuation in incompatiblePages) {
        final remote = _ReadingFeedRemote();
        final controller = _controller(remote);
        controller.updateInput(_input());
        remote.complete(
          0,
          _personalizedRecommendations(
            papers: [_paper(1)],
            nextCursor: 'opaque-batch-next',
          ),
        );
        await _settle();

        final load = controller.loadMore();
        await _settle();
        remote.complete(1, continuation);
        await load;
        await _settle();

        expect(remote.requests, hasLength(3));
        expect(remote.requests.last.cursor, isNull);
        expect(controller.state.items, isEmpty);
        expect(controller.state.recommendationsVisible, isFalse);
        controller.dispose();
      }
    },
  );

  test('overlap or rollout-policy drift restarts continuation', () async {
    for (final continuation in [
      _recommendations(papers: [_paper(2)]),
      _recommendations(papers: [_paper(3)]),
      _recommendations(
        papers: [_paper(1)],
        enforcement: ReadingFeedEnforcement.strict,
      ),
    ]) {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote);

      controller.updateInput(_input());
      remote.complete(
        0,
        _recommendations(papers: [_paper(2)], nextCursor: 'opaque-next'),
      );
      await _settle();
      final load = controller.loadMore();
      await _settle();
      remote.complete(1, continuation);
      await load;
      await _settle();

      expect(remote.requests, hasLength(3));
      expect(remote.requests.last.cursor, isNull);
      expect(controller.state.items, isEmpty);
      controller.dispose();
    }
  });

  test(
    'shadow rollout records closed decisions without changing authority',
    () async {
      final remote = _ReadingFeedRemote();
      final recording = _RecordingTelemetrySink();
      final controller = _controller(
        remote,
        telemetry: RedactingTelemetrySink(recording),
        shadowMode: true,
      );
      addTearDown(controller.dispose);

      controller.updateInput(_input());
      remote.complete(0, _recommendations());
      await _settle();
      await _settle();

      expect(controller.state.mode, ReadingFeedMode.recommendations);
      expect(controller.state.recommendationsVisible, isTrue);
      expect(recording.events, hasLength(2));
      expect(
        recording.events.map((event) => event.$1),
        everyElement(PakPerkTelemetryEvent.readingFeedShadowDecision),
      );
      expect(recording.events[0].$2, const <String, Object?>{
        'shadow_decision': 'checking_queue',
        'queue_authority': 'unknown',
        'legacy_decision': 'public_discovery',
        'server_policy': 'unknown',
        'queue_policy_agrees': false,
        'offline': false,
      });
      expect(recording.events[1].$2, const <String, Object?>{
        'shadow_decision': 'recommendations',
        'queue_authority': 'server_empty',
        'legacy_decision': 'public_discovery',
        'server_policy': 'shadow',
        'queue_policy_agrees': true,
        'offline': false,
      });

      controller.updateInput(_input());
      await _settle();
      expect(recording.events, hasLength(2));
    },
  );

  test('enforced controller does not emit shadow comparisons', () async {
    final recording = _RecordingTelemetrySink();
    final controller = _controller(
      _ReadingFeedRemote(),
      autoRefresh: false,
      telemetry: RedactingTelemetrySink(recording),
    );
    addTearDown(controller.dispose);

    controller.updateInput(
      _input(localItems: [_localItem(samplePaper, day: 1)]),
    );
    await _settle();

    expect(controller.state.mode, ReadingFeedMode.toRead);
    expect(recording.events, isEmpty);
  });

  test('verified local queue metadata stays aligned with FIFO papers', () {
    final controller = _controller(_ReadingFeedRemote(), autoRefresh: false);
    addTearDown(controller.dispose);
    final later = _localItem(
      _paper(2),
      day: 2,
      state: LibraryItemState.reading,
      privateNote: 'Compare the evaluation setup',
      saveSourceKind: LibrarySaveSourceKind.titleSearch,
    );
    final earlier = _localItem(
      _paper(1),
      day: 1,
      state: LibraryItemState.readNext,
      saveSourceKind: LibrarySaveSourceKind.arxivUrl,
    );

    controller.updateInput(_input(localItems: [later, earlier]));

    expect(controller.state.items, [earlier.paper, later.paper]);
    expect(controller.state.queueItems, hasLength(2));
    expect(controller.state.queueItemAt(0)?.state, LibraryItemState.readNext);
    expect(
      controller.state.queueItemAt(0)?.provenanceLabel,
      'Added from an arXiv link',
    );
    expect(
      controller.state.queueItemAt(1)?.privateNote,
      'Compare the evaluation setup',
    );
  });

  test(
    'explicit recommendation selection refreshes only proven-empty mode',
    () async {
      final remote = _ReadingFeedRemote();
      final controller = _controller(remote, autoRefresh: false);
      addTearDown(controller.dispose);
      controller.updateInput(_input());
      final first = controller.refresh();
      remote.complete(
        0,
        _personalizedRecommendations(
          mode: ReadingFeedRecommendationMode.explore,
        ),
      );
      await first;

      final selected = controller.selectRecommendationMode(
        ReadingFeedRecommendationMode.following,
      );
      expect(remote.requests, hasLength(2));
      expect(
        remote.requests.last.recommendationMode,
        ReadingFeedRecommendationMode.following,
      );
      remote.complete(
        1,
        _personalizedRecommendations(
          mode: ReadingFeedRecommendationMode.following,
        ),
      );
      await selected;
      expect(
        controller.state.recommendationMode,
        ReadingFeedRecommendationMode.following,
      );

      controller.updateInput(
        _input(localItems: [_localItem(_paper(3), day: 3)]),
      );
      await controller.selectRecommendationMode(
        ReadingFeedRecommendationMode.forYou,
      );
      expect(remote.requests, hasLength(2));
      expect(controller.state.mode, ReadingFeedMode.toRead);
    },
  );

  test(
    'turning personalization off invalidates For You and forces Recent',
    () async {
      final remote = _ReadingFeedRemote();
      final recording = _RecordingTelemetrySink();
      final controller = _controller(
        remote,
        autoRefresh: false,
        telemetry: RedactingTelemetrySink(recording),
      );
      addTearDown(controller.dispose);
      controller.updateInput(_input(personalizationEnabled: true));

      final initial = controller.refresh();
      expect(remote.requests.single.recommendationMode, isNull);
      remote.complete(
        0,
        _personalizedRecommendations(
          mode: ReadingFeedRecommendationMode.forYou,
        ),
      );
      await initial;
      expect(controller.state.forYouAvailable, isTrue);
      expect(
        controller.state.recommendationMode,
        ReadingFeedRecommendationMode.forYou,
      );

      final staleForYou = controller.selectRecommendationMode(
        ReadingFeedRecommendationMode.forYou,
      );
      expect(remote.requests, hasLength(2));
      expect(
        remote.requests.last.recommendationMode,
        ReadingFeedRecommendationMode.forYou,
      );

      controller.updateInput(_input(personalizationEnabled: false));
      expect(controller.state.forYouAvailable, isFalse);
      expect(controller.state.items, isEmpty);
      expect(
        controller.state.recommendationMode,
        ReadingFeedRecommendationMode.recent,
      );

      final recent = controller.refresh();
      expect(remote.requests, hasLength(3));
      expect(
        remote.requests.last.recommendationMode,
        ReadingFeedRecommendationMode.recent,
      );
      remote.complete(
        1,
        _personalizedRecommendations(
          mode: ReadingFeedRecommendationMode.forYou,
        ),
      );
      await staleForYou;
      expect(controller.state.items, isEmpty);
      final rejection = recording.events.singleWhere(
        (event) =>
            event.$1 == PakPerkTelemetryEvent.recommendationPublicationRejected,
      );
      expect(rejection.$2, const {'reason': 'personalization_off'});

      remote.complete(
        2,
        _personalizedRecommendations(
          mode: ReadingFeedRecommendationMode.recent,
        ),
      );
      await recent;
      expect(controller.state.items, isNotEmpty);
      expect(
        controller.state.recommendationMode,
        ReadingFeedRecommendationMode.recent,
      );

      await controller.selectRecommendationMode(
        ReadingFeedRecommendationMode.forYou,
      );
      expect(remote.requests, hasLength(3));
      expect(
        controller.state.recommendationMode,
        ReadingFeedRecommendationMode.recent,
      );
    },
  );

  test('unknown personalization rejects a stray For You response', () async {
    final remote = _ReadingFeedRemote();
    final controller = _controller(remote, autoRefresh: false);
    addTearDown(controller.dispose);
    controller.updateInput(_input(personalizationEnabled: null));

    final refresh = controller.refresh();
    expect(
      remote.requests.single.recommendationMode,
      ReadingFeedRecommendationMode.recent,
    );
    remote.complete(
      0,
      _personalizedRecommendations(mode: ReadingFeedRecommendationMode.forYou),
    );
    await refresh;

    expect(controller.state.forYouAvailable, isFalse);
    expect(controller.state.items, isEmpty);
    expect(controller.state.mode, ReadingFeedMode.unavailable);
  });

  test(
    'recommendation authority recheck is 45 seconds and injectable',
    () async {
      expect(
        readingFeedRecommendationRecheckInterval,
        const Duration(seconds: 45),
      );
      final remote = _ReadingFeedRemote();
      final controller = _controller(
        remote,
        autoRefresh: false,
        recommendationRecheckInterval: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      controller.updateInput(_input());
      final first = controller.refresh();
      remote.complete(0, _personalizedRecommendations());
      await first;

      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(remote.requests, hasLength(2));
    },
  );
}

ReadingFeedController _controller(
  _ReadingFeedRemote remote, {
  bool autoRefresh = true,
  TelemetrySink telemetry = const NoopTelemetrySink(),
  bool shadowMode = false,
  ReadingFeedRecommendationMode? recommendationMode,
  ReadingFeedPageCache? pageCache,
  Duration recommendationRecheckInterval =
      readingFeedRecommendationRecheckInterval,
  DateTime Function()? clock,
}) => ReadingFeedController(
  repository: ReadingFeedRepository(remote: remote),
  pageCache: pageCache,
  telemetry: telemetry,
  shadowMode: shadowMode,
  autoRefresh: autoRefresh,
  recommendationMode: recommendationMode,
  recommendationRecheckInterval: recommendationRecheckInterval,
  clock: clock,
);

ReadingFeedControllerInput _input({
  String accountId = _accountA,
  int authEpoch = 1,
  ReadingFeedAuthentication authentication = ReadingFeedAuthentication.verified,
  bool verified = true,
  List<LibraryListItem> localItems = const [],
  LibraryPendingIntentCounts pending = const LibraryPendingIntentCounts.empty(),
  int pendingImportCount = 0,
  bool offline = false,
  bool? personalizationEnabled = true,
  LibrarySaveIntentSignal? saveIntent,
  LibraryFinalCompletionAcknowledgement? finalCompletionAcknowledgement,
}) {
  final scope = ReadingFeedAccountScope(
    accountId: accountId,
    authEpoch: authEpoch,
  );
  return ReadingFeedControllerInput(
    authentication: authentication,
    sessionScope: scope,
    displayScope: scope,
    verifiedScope: verified ? scope : null,
    localItems: localItems,
    pendingIntents: pending,
    pendingImportCount: pendingImportCount,
    checkpoint: const LibrarySyncCheckpoint(initialized: true, lastRevision: 5),
    offline: offline,
    dataReady: true,
    personalizationEnabled: personalizationEnabled,
    saveIntent: saveIntent,
    finalCompletionAcknowledgement: finalCompletionAcknowledgement,
  );
}

LibraryListItem _localItem(
  PaperSummary paper, {
  required int day,
  LibraryItemState state = LibraryItemState.inbox,
  String? privateNote,
  LibrarySaveSourceKind saveSourceKind = LibrarySaveSourceKind.other,
}) => LibraryListItem(
  paper: paper,
  savedAt: DateTime.utc(2026, 8, day),
  savedState: const LibrarySavedState(saved: true, syncPending: false),
  state: state,
  privateNote: privateNote,
  saveSourceKind: saveSourceKind,
);

PaperSummary _paper(int suffix) => PaperSummary(
  paperId: '17060376-2000-4000-8000-${suffix.toString().padLeft(12, '0')}',
  arxivId: '2401.${suffix.toString().padLeft(5, '0')}v1',
  title: 'Paper $suffix',
  abstractText: 'Abstract',
  authors: const ['Ada Reader'],
  primaryCategory: 'cs.AI',
  categories: const ['cs.AI'],
  publishedAt: DateTime.utc(2026, 8, suffix),
  updatedAt: DateTime.utc(2026, 8, suffix),
  absUrl: 'https://arxiv.org/abs/2401.00001v1',
  pdfUrl: 'https://arxiv.org/pdf/2401.00001v1',
);

ReadingFeedPage _recommendations({
  String? nextCursor,
  ReadingFeedEnforcement enforcement = ReadingFeedEnforcement.shadow,
  List<PaperSummary>? papers,
}) => ReadingFeedPage(
  enforcement: enforcement,
  mode: ReadingFeedServerMode.recommendations,
  decision: const ReadingFeedDecision(
    policyVersion: ReadingFeedDecision.supportedPolicyVersion,
    libraryRevision: 5,
    activeToReadCount: 0,
    queueProvenEmpty: true,
  ),
  items: [
    for (final paper in papers ?? [samplePaper])
      ReadingFeedItem(
        paper: paper,
        queue: null,
        source: ReadingFeedItemSource.discoveryV1,
      ),
  ],
  nextCursor: nextCursor,
  serverTime: DateTime.utc(2026, 8, 19),
);

ReadingFeedPage _personalizedRecommendations({
  ReadingFeedRecommendationMode mode = ReadingFeedRecommendationMode.explore,
  List<PaperSummary>? papers,
  String? nextCursor,
  String batchId = _batchId,
  ReadingFeedBatchMetadata batchMetadata = _batchMetadata,
  int libraryRevision = 5,
  ReadingFeedEnforcement enforcement = ReadingFeedEnforcement.strict,
}) => ReadingFeedPage(
  enforcement: enforcement,
  mode: ReadingFeedServerMode.recommendations,
  decision: ReadingFeedDecision(
    policyVersion: ReadingFeedDecision.supportedPolicyVersion,
    libraryRevision: libraryRevision,
    activeToReadCount: 0,
    queueProvenEmpty: true,
  ),
  batchId: batchId,
  batchMetadata: batchMetadata,
  items: [
    for (final paper in papers ?? [samplePaper])
      ReadingFeedItem(
        paper: paper,
        queue: null,
        source: switch (mode) {
          ReadingFeedRecommendationMode.recent =>
            ReadingFeedItemSource.recentV1,
          ReadingFeedRecommendationMode.following =>
            ReadingFeedItemSource.followingV1,
          ReadingFeedRecommendationMode.forYou =>
            ReadingFeedItemSource.forYouV1,
          ReadingFeedRecommendationMode.explore =>
            ReadingFeedItemSource.exploreV1,
        },
        recommendation: ReadingFeedRecommendationMetadata(
          mode: mode,
          reasonCodes: const [],
          reasonLabel: 'A different direction for your reading',
          explanationAvailable: true,
        ),
      ),
  ],
  nextCursor: nextCursor,
  serverTime: DateTime.utc(2026, 8, 19),
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<void> _settleProviders() async {
  await _settle();
  await _settle();
}

AuthSessionController _providerAuthController(String accountId) {
  return AuthSessionController(
    repository: AuthRepository(
      configuration: testOidcConfiguration,
      oidcClient: FakeOidcClient(),
      secureTokenStore: MemorySecureTokenStore(
        storedRecord(accountId: accountId),
      ),
      clock: () => DateTime.utc(2026, 8, 19),
    ),
    clearAccountOwnedData: (_, __) async {},
  );
}

ProviderContainer _providerContainer({
  required AuthSessionController auth,
  required _ReadingFeedRemote remote,
}) {
  return ProviderContainer(
    overrides: [
      featureFlagsProvider.overrideWithValue(_strictReadingFeedFlags),
      authSessionProvider.overrideWith((_) => auth),
      verifiedLibraryScopeProvider.overrideWith((ref) {
        final session = ref.watch(authSessionProvider);
        final accountId = session.accountId;
        if (session.phase != AuthSessionPhase.authenticated ||
            accountId == null) {
          return null;
        }
        return (accountId: accountId, authEpoch: session.epoch);
      }),
      readingFeedAuthorityInputProvider.overrideWith((ref) {
        final session = ref.watch(authSessionProvider);
        final accountId = session.accountId;
        if (session.phase != AuthSessionPhase.authenticated ||
            accountId == null) {
          return ReadingFeedControllerInput(
            authentication: ReadingFeedAuthentication.changing,
            sessionScope: null,
            displayScope: null,
            verifiedScope: null,
            localItems: const [],
            pendingIntents: const LibraryPendingIntentCounts.empty(),
            pendingImportCount: 0,
            checkpoint: const LibrarySyncCheckpoint.unknown(),
            offline: false,
            dataReady: true,
            personalizationEnabled: false,
          );
        }
        return _input(accountId: accountId, authEpoch: session.epoch);
      }),
      readingFeedRepositoryProvider.overrideWithValue(
        ReadingFeedRepository(remote: remote),
      ),
      telemetrySinkProvider.overrideWithValue(const NoopTelemetrySink()),
    ],
  );
}

final class _ReadingFeedRemote implements ReadingFeedRemoteDataSource {
  final requests =
      <
        ({
          int authEpoch,
          String? cursor,
          ReadingFeedRecommendationMode? recommendationMode,
        })
      >[];
  final _responses = <Completer<ReadingFeedPage>>[];

  @override
  Future<ReadingFeedPage> page({
    required int expectedAuthEpoch,
    ReadingFeedRecommendationMode? recommendationMode,
    String? briefId,
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) {
    requests.add((
      authEpoch: expectedAuthEpoch,
      cursor: cursor,
      recommendationMode: recommendationMode,
    ));
    final response = Completer<ReadingFeedPage>();
    _responses.add(response);
    return response.future;
  }

  void complete(int index, ReadingFeedPage page) {
    _responses[index].complete(page);
  }

  void completeError(int index, Object error) {
    _responses[index].completeError(error);
  }
}

final class _RecordingReadingFeedPageCache implements ReadingFeedPageCache {
  final savedPages = <ReadingFeedPage>[];

  @override
  Future<void> clear(String accountId) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<ReadingFeedCachedPage?> loadQueue(
    String accountId, {
    DateTime? now,
  }) async => null;

  @override
  Future<ReadingFeedCachedPage?> loadRecommendations(
    String accountId, {
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  }) async => null;

  @override
  Future<void> save(
    String accountId, {
    required ReadingFeedPage page,
    required ReadingFeedRecommendationMode? requestedMode,
    DateTime? now,
  }) async {
    savedPages.add(page);
  }
}

final class _RecordingTelemetrySink implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map<String, Object?>.from(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

const _accountA = '10000000-0000-4000-8000-000000000001';
const _accountB = '20000000-0000-4000-8000-000000000002';
const _batchId = '70000000-0000-7000-8000-000000000007';
const _otherBatchId = '70000000-0000-7000-8000-000000000008';
const _batchMetadata = ReadingFeedBatchMetadata(
  profileRevision: 4,
  feedbackRevision: 2,
  algorithmVersion: 'ranker-v2',
  recommendationPolicyVersion: 'policy-v2',
);

const _strictReadingFeedFlags = FeatureFlags(
  accounts: true,
  library: true,
  comments: false,
  openingMotion: false,
  readingFeed: true,
  toReadFirstEnforcement: true,
);
