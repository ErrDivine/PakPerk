import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/account/current_account_controller.dart';
import '../core/discovery_search/discovery_search_api.dart';
import '../core/discovery_search/search_privacy_store.dart';
import '../core/engagement/engagement_api.dart';
import '../core/interactions/interaction_api.dart';
import '../core/interactions/interaction_models.dart';
import '../core/providers.dart';
import '../core/api/request_cancellation.dart';
import '../core/research_profiles/research_profile_api.dart';
import '../core/sync/event_batcher.dart';
import 'account_providers.dart';

typedef VerifiedDiscoveryAccountScope = ({String accountId, int authEpoch});

final verifiedDiscoveryAccountScopeProvider =
    Provider<VerifiedDiscoveryAccountScope?>((ref) {
      if (!ref.watch(featureFlagsProvider).accounts) return null;
      final session = ref.watch(authSessionProvider);
      final account = ref.watch(currentAccountProvider);
      final profile = account.profile;
      if (!session.mayHaveRecoverableCredentials ||
          account.phase != CurrentAccountPhase.ready ||
          account.verifiedAuthEpoch != session.epoch ||
          profile == null ||
          !profile.isActive ||
          profile.id != session.accountId) {
        return null;
      }
      return (accountId: profile.id, authEpoch: session.epoch);
    });

final discoverySearchApiProvider = Provider<DiscoverySearchRemoteDataSource>(
  (ref) => DiscoverySearchApi(ref.watch(pakPerkDioProvider)),
);

final searchPrivacyStoreProvider = Provider<SearchPrivacyStore>(
  (_) => SharedPreferencesSearchPrivacyStore(),
);

final researchProfileApiProvider = Provider<ResearchProfileRemoteDataSource>(
  (ref) => ResearchProfileApi(ref.watch(pakPerkDioProvider)),
);

final engagementApiProvider = Provider<EngagementRemoteDataSource>(
  (ref) => EngagementApi(ref.watch(pakPerkDioProvider)),
);

/// Account/auth-epoch scoped consent loaded independently of the profile UI.
///
/// `null` is deliberately distinct from `false`: both fail closed for event
/// collection, while only a current successful server response may publish
/// `true`. Rebuilding this provider for a new verified scope disposes and
/// cancels the prior scope before the new request begins.
final interactionPersonalizationEnabledProvider =
    StateNotifierProvider<InteractionPersonalizationConsentController, bool?>((
      ref,
    ) {
      final scope = ref.watch(verifiedDiscoveryAccountScopeProvider);
      final profilesEnabled = ref.watch(
        featureFlagsProvider.select((flags) => flags.researchProfilesEnabled),
      );
      return InteractionPersonalizationConsentController(
        remote: scope != null && profilesEnabled
            ? ref.watch(researchProfileApiProvider)
            : null,
        scope: scope,
      );
    });

final class InteractionPersonalizationConsentController
    extends StateNotifier<bool?> {
  InteractionPersonalizationConsentController({
    required ResearchProfileRemoteDataSource? remote,
    required VerifiedDiscoveryAccountScope? scope,
  }) : _remote = remote,
       _scope = scope,
       super(null) {
    if (_remote != null && _scope != null) unawaited(_load());
  }

  final ResearchProfileRemoteDataSource? _remote;
  final VerifiedDiscoveryAccountScope? _scope;
  RequestCancellation? _request;
  int _generation = 0;

  Future<void> _load() async {
    final remote = _remote;
    final scope = _scope;
    if (!mounted || remote == null || scope == null) return;
    final generation = ++_generation;
    final request = RequestCancellation();
    _request = request;
    try {
      final result = await remote.profile(
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (!mounted || generation != _generation || request.isCancelled) return;
      state = result.value.personalizationEnabled;
    } on Object {
      // Unknown, cancelled, malformed, and transport failures all remain
      // fail-closed. A later provider rebuild or explicit profile refresh can
      // establish a new current value.
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  /// Publishes a profile response already verified by another current flow.
  /// A response for a stale account/auth epoch is ignored.
  void publish({
    required VerifiedDiscoveryAccountScope scope,
    required bool enabled,
  }) {
    if (!mounted || scope != _scope) return;
    _generation += 1;
    _request?.cancel('A newer current profile response resolved consent.');
    _request = null;
    state = enabled;
  }

  @override
  void dispose() {
    _generation += 1;
    _request?.cancel('The personalization consent scope changed.');
    _request = null;
    super.dispose();
  }
}

final interactionApiProvider = Provider<InteractionRemoteDataSource>(
  (ref) => InteractionApi(ref.watch(pakPerkDioProvider)),
);

final interactionEventBatcherProvider = Provider<InteractionEventBatcher>((
  ref,
) {
  final enabled = ref.watch(
    featureFlagsProvider.select((flags) => flags.recommendationEventsEnabled),
  );
  if (!enabled) {
    // Keep every event hook safe to call while the independent collection
    // switch is off. In particular, do not construct account/auth/network
    // providers for Library-only and signed-out builds.
    final batcher = InteractionEventBatcher(
      remote: const _DisabledInteractionRemoteDataSource(),
    );
    batcher.updateConfiguration(
      scope: null,
      behavioralCollectionEnabled: false,
    );
    ref.onDispose(batcher.dispose);
    return batcher;
  }
  final batcher = InteractionEventBatcher(
    remote: ref.watch(interactionApiProvider),
  );
  final account = ref.watch(verifiedDiscoveryAccountScopeProvider);
  final personalization = ref.watch(interactionPersonalizationEnabledProvider);
  final scope = account == null
      ? AnonymousInteractionScope(
          sessionId: ref.watch(anonymousSessionIdProvider),
        )
      : AccountInteractionScope(
          accountId: account.accountId,
          authEpoch: account.authEpoch,
        );
  batcher.updateConfiguration(
    scope: scope,
    // There is no guest analytics consent in this release, so anonymous
    // behavioral collection stays off. Account behavioral events require the
    // explicit, current server profile preference.
    behavioralCollectionEnabled:
        scope is AccountInteractionScope && personalization == true,
  );
  ref.onDispose(batcher.dispose);
  return batcher;
});

final class _DisabledInteractionRemoteDataSource
    implements InteractionRemoteDataSource {
  const _DisabledInteractionRemoteDataSource();

  @override
  Future<InteractionBatchResult> sendBatch({
    required InteractionScope scope,
    required List<PaperInteractionEvent> events,
  }) => Future.error(
    StateError('Disabled interaction collection cannot send events.'),
  );
}
