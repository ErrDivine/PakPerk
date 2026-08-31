import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/discovery_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/discovery_search/discovery_search_api.dart';
import '../../core/discovery_search/discovery_search_models.dart';
import '../../core/providers.dart';
import '../../core/research_profiles/research_profile_api.dart';
import '../../core/research_profiles/research_profile_models.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import 'research_profile_screen.dart';

final class ResearchProfileDestination extends ConsumerStatefulWidget {
  const ResearchProfileDestination({super.key});

  @override
  ConsumerState<ResearchProfileDestination> createState() =>
      _ResearchProfileDestinationState();
}

final class _ResearchProfileDestinationState
    extends ConsumerState<ResearchProfileDestination> {
  late final ResearchProfileRemoteDataSource _remote;
  late final DiscoverySearchRemoteDataSource _searchRemote;
  ProviderSubscription<VerifiedDiscoveryAccountScope?>? _scopeSubscription;
  VerifiedDiscoveryAccountScope? _scope;
  RequestCancellation? _request;
  ResearchProfile? _profile;
  ResearchProfileInterests? _interests;
  final Map<String, String> _operationIds = {};
  var _generation = 0;
  var _loading = false;
  var _busy = false;
  var _scopeModalDepth = 0;
  var _scopeModalCloseScheduled = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _remote = ref.read(researchProfileApiProvider);
    _searchRemote = ref.read(discoverySearchApiProvider);
    _scope = ref.read(verifiedDiscoveryAccountScopeProvider);
    _scopeSubscription = ref.listenManual<VerifiedDiscoveryAccountScope?>(
      verifiedDiscoveryAccountScopeProvider,
      _onScopeChanged,
    );
    if (_scope != null &&
        ref.read(featureFlagsProvider).researchProfilesEnabled) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _scopeSubscription?.close();
    _request?.cancel('The research profile closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.researchProfilesEnabled),
    );
    if (!enabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('Research profile')),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(PakPerkSpacing.lg),
              child: Text(
                'Research profiles are not enabled for this build.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }
    return ResearchProfileScreen(
      profile: _profile,
      interests: _interests,
      loading: _loading,
      busy: _busy,
      errorMessage: _errorMessage,
      onRetry: () => unawaited(_load()),
      onPersonalizationChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(personalizationEnabled: value),
          key: 'personalization:$value',
        ),
      ),
      onPreferredModeChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(preferredDiscoveryMode: value),
          key: 'preferred:${value.name}',
        ),
      ),
      onDiscoveryModeChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(discoveryMode: value),
          key: 'discovery:${value.name}',
        ),
      ),
      onBriefSizeChanged: (value) => unawaited(
        _update(ResearchProfilePatch(briefSize: value), key: 'brief:$value'),
      ),
      onRecencyWeightChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(recencyWeight: value),
          key: 'recency:${value.toStringAsFixed(2)}',
        ),
      ),
      onNoveltyWeightChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(noveltyWeight: value),
          key: 'novelty:${value.toStringAsFixed(2)}',
        ),
      ),
      onDiversityWeightChanged: (value) => unawaited(
        _update(
          ResearchProfilePatch(diversityWeight: value),
          key: 'diversity:${value.toStringAsFixed(2)}',
        ),
      ),
      onEditExplicitCategories: () => unawaited(_editCategories()),
      onAddExplicitTopic: () =>
          unawaited(_addTopic(ResearchTopicPolarity.positive)),
      onAddExplicitNegativeTopic: () =>
          unawaited(_addTopic(ResearchTopicPolarity.negative)),
      onAddExplicitAuthor: () => unawaited(_addAuthor()),
      onDeleteExplicitTopic: (topicId) => unawaited(_deleteTopic(topicId)),
      onDeleteExplicitAuthor: (authorKey) =>
          unawaited(_deleteAuthor(authorKey)),
      onResetInferred: () =>
          unawaited(_confirmReset(ResearchProfileResetScope.inferred)),
      onResetAll: () => unawaited(_confirmReset(ResearchProfileResetScope.all)),
      onExport: () => unawaited(_showExport()),
    );
  }

  void _onScopeChanged(
    VerifiedDiscoveryAccountScope? previous,
    VerifiedDiscoveryAccountScope? next,
  ) {
    if (previous == next) return;
    _scheduleScopeModalClose();
    _generation += 1;
    _request?.cancel('The research profile account scope changed.');
    _request = null;
    _operationIds.clear();
    _scope = next;
    if (mounted) {
      setState(() {
        _profile = null;
        _interests = null;
        _loading = false;
        _busy = false;
        _errorMessage = null;
      });
    }
    if (next != null &&
        ref.read(featureFlagsProvider).researchProfilesEnabled) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final scope = _scope;
    if (scope == null) {
      if (mounted) {
        setState(() {
          _profile = null;
          _interests = null;
          _loading = false;
          _errorMessage = 'Sign in again to view your research profile.';
        });
      }
      return;
    }
    _request?.cancel('A newer profile refresh started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final profile = await _remote.profile(
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      final interests = await _remote.interests(
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (profile.revision != interests.revision) {
        throw const ApiException(
          code: 'PROFILE_REVISION_MISMATCH',
          message: 'Profile revisions disagree.',
          retryable: true,
        );
      }
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _profile = profile.value;
        _interests = interests.value;
        _loading = false;
        _errorMessage = null;
      });
      ref
          .read(interactionPersonalizationEnabledProvider.notifier)
          .publish(scope: scope, enabled: profile.value.personalizationEnabled);
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _loading = false;
        _errorMessage = _safeMessage(error);
      });
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _loading = false;
        _errorMessage = 'Your research profile is temporarily unavailable.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _update(ResearchProfilePatch patch, {required String key}) {
    return _mutate(
      key: key,
      action: (scope, profile, operationId, request) => _remote.update(
        operationId: operationId,
        expectedRevision: profile.profileRevision,
        patch: patch,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
    );
  }

  Future<void> _mutate({
    required String key,
    required Future<ResearchProfileApiResult<ResearchProfile>> Function(
      VerifiedDiscoveryAccountScope scope,
      ResearchProfile profile,
      String operationId,
      RequestCancellation request,
    )
    action,
  }) async {
    final scope = _scope;
    final profile = _profile;
    if (_busy || scope == null || profile == null) return;
    _request?.cancel('A profile mutation started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    final operationId = _operationIds.putIfAbsent(key, () => const Uuid().v7());
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final result = await action(scope, profile, operationId, request);
      if (!_isCurrent(scope, generation)) return;
      _operationIds.remove(key);
      setState(() {
        _profile = result.value;
      });
      ref
          .read(interactionPersonalizationEnabledProvider.notifier)
          .publish(scope: scope, enabled: result.value.personalizationEnabled);
      await _refreshInterests(scope, generation, request);
      if (_isCurrent(scope, generation)) {
        setState(() => _busy = false);
      }
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _busy = false;
        _errorMessage = _safeMessage(error);
      });
      if (error.statusCode == 412) unawaited(_load());
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _busy = false;
        _errorMessage = 'That profile change could not be saved.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _refreshInterests(
    VerifiedDiscoveryAccountScope scope,
    int generation,
    RequestCancellation request,
  ) async {
    final interests = await _remote.interests(
      expectedAuthEpoch: scope.authEpoch,
      cancellation: request,
    );
    if (!_isCurrent(scope, generation)) return;
    final profile = _profile;
    if (profile == null || profile.profileRevision != interests.revision) {
      throw const ApiException(
        code: 'PROFILE_REVISION_MISMATCH',
        message: 'Profile revisions disagree.',
        retryable: true,
      );
    }
    setState(() => _interests = interests.value);
  }

  Future<void> _editCategories() async {
    final scope = _scope;
    if (scope == null) return;
    final current = _interests?.explicit.categories ?? const [];
    final controller = TextEditingController(
      text: current.map((category) => category.category).join(', '),
    );
    final value = await _showScopeDialog<String>(
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Explicit categories'),
        content: SingleChildScrollView(
          child: TextField(
            key: const ValueKey('research-profile-category-input'),
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'arXiv categories',
              helperText:
                  'Separate categories with commas, for example cs.AI, cs.CL.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save choices'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted || _scope != scope) return;
    final categories = value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (categories.length > 32 ||
        categories.any(
          (item) =>
              item.length > 32 || !RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(item),
        )) {
      setState(() {
        _errorMessage =
            'Use at most 32 valid arXiv categories separated by commas.';
      });
      return;
    }
    final weights = {
      for (final category in current) category.category: category.weight,
    };
    await _update(
      ResearchProfilePatch(
        explicitCategories: [
          for (final category in categories)
            ExplicitResearchCategory(
              category: category,
              weight: weights[category] ?? 1,
            ),
        ],
      ),
      key: 'categories:${categories.join(',')}',
    );
  }

  Future<void> _addTopic(ResearchTopicPolarity polarity) async {
    final scope = _scope;
    if (_busy || scope == null || _profile == null) return;
    final controller = TextEditingController();
    final query = await _showScopeDialog<String>(
      builder: (context) => AlertDialog.adaptive(
        title: Text(
          polarity == ResearchTopicPolarity.negative
              ? 'Choose a topic to avoid'
              : 'Find an explicit topic',
        ),
        content: TextField(
          key: const ValueKey('research-profile-topic-query'),
          controller: controller,
          autofocus: true,
          maxLength: 300,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Topic name',
            helperText: polarity == ResearchTopicPolarity.negative
                ? 'This explicitly reduces matching future discovery.'
                : 'Choose a topic from Pakperk’s local vocabulary.',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(
              polarity == ResearchTopicPolarity.negative
                  ? 'Find topic to avoid'
                  : 'Find topics',
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (query == null || !mounted || _scope != scope) return;
    final normalized = query.trim();
    if (normalized.length < 2 || normalized.length > 300) {
      setState(() => _errorMessage = 'Enter at least two topic characters.');
      return;
    }

    _request?.cancel('A topic lookup started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final suggestions = await _searchRemote.suggestions(
        query: normalized,
        cancellation: request,
      );
      if (!_isCurrent(scope, generation)) return;
      setState(() => _busy = false);
      if (suggestions.items.isEmpty) {
        setState(() {
          _errorMessage =
              'No matching local topic is available. Try a broader name.';
        });
        return;
      }
      _request = null;
      final selected = await _chooseTopic(suggestions.items);
      if (selected == null || !mounted || _scope != scope) return;
      await _mutate(
        key: 'topic:${selected.topicId}:${polarity.name}',
        action: (scope, profile, operationId, request) => _remote.upsertTopic(
          topicId: selected.topicId,
          polarity: polarity,
          strength: 1,
          userAlias: null,
          operationId: operationId,
          expectedRevision: profile.profileRevision,
          expectedAuthEpoch: scope.authEpoch,
          cancellation: request,
        ),
      );
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _busy = false;
        _errorMessage = 'Topic suggestions are temporarily unavailable.';
      });
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _busy = false;
        _errorMessage = 'Topic suggestions are temporarily unavailable.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<DiscoveryRelatedTopic?> _chooseTopic(
    List<DiscoveryRelatedTopic> topics,
  ) => _showScopeBottomSheet<DiscoveryRelatedTopic>(
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .65,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PakPerkSpacing.lg,
              0,
              PakPerkSpacing.lg,
              PakPerkSpacing.sm,
            ),
            child: Text(
              'Choose a topic',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: PakPerkSpacing.lg),
            child: Text(
              'Only the topic you select becomes an explicit profile choice.',
            ),
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                PakPerkSpacing.sm,
                0,
                PakPerkSpacing.sm,
                PakPerkSpacing.lg,
              ),
              itemCount: topics.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final topic = topics[index];
                return ListTile(
                  key: ValueKey(
                    'research-profile-topic-option-${topic.topicId}',
                  ),
                  minTileHeight: PakPerkSizes.minimumInteractive,
                  title: Text(topic.label),
                  subtitle: Text(topic.sourceVocabulary),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).pop(topic),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _deleteTopic(String topicId) => _mutate(
    key: 'delete-topic:$topicId',
    action: (scope, profile, operationId, request) => _remote.deleteTopic(
      topicId: topicId,
      operationId: operationId,
      expectedRevision: profile.profileRevision,
      expectedAuthEpoch: scope.authEpoch,
      cancellation: request,
    ),
  );

  Future<void> _addAuthor() async {
    final scope = _scope;
    if (_busy || scope == null || _profile == null) return;
    final keyController = TextEditingController();
    final nameController = TextEditingController();
    final value =
        await _showScopeDialog<({String authorKey, String displayName})>(
          builder: (context) => AlertDialog.adaptive(
            title: const Text('Follow an explicit author'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('research-profile-author-key'),
                    controller: keyController,
                    autofocus: true,
                    maxLength: 200,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Author key',
                      helperText:
                          'Use the stable key shown by the paper source.',
                    ),
                  ),
                  TextField(
                    key: const ValueKey('research-profile-author-name'),
                    controller: nameController,
                    maxLength: 200,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                    onSubmitted: (_) => Navigator.of(context).pop((
                      authorKey: keyController.text,
                      displayName: nameController.text,
                    )),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop((
                  authorKey: keyController.text,
                  displayName: nameController.text,
                )),
                child: const Text('Follow author'),
              ),
            ],
          ),
        );
    keyController.dispose();
    nameController.dispose();
    if (value == null || !mounted || _scope != scope) return;
    final authorKey = value.authorKey.trim();
    final displayName = value.displayName.trim();
    if (authorKey.isEmpty ||
        authorKey.length > 200 ||
        displayName.isEmpty ||
        displayName.length > 200) {
      setState(() {
        _errorMessage = 'Enter a bounded author key and display name.';
      });
      return;
    }
    await _mutate(
      key: 'author:$authorKey:$displayName',
      action: (scope, profile, operationId, request) => _remote.upsertAuthor(
        authorKey: authorKey,
        displayName: displayName,
        operationId: operationId,
        expectedRevision: profile.profileRevision,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
    );
  }

  Future<void> _deleteAuthor(String authorKey) => _mutate(
    key: 'delete-author:$authorKey',
    action: (scope, profile, operationId, request) => _remote.deleteAuthor(
      authorKey: authorKey,
      operationId: operationId,
      expectedRevision: profile.profileRevision,
      expectedAuthEpoch: scope.authEpoch,
      cancellation: request,
    ),
  );

  Future<void> _confirmReset(ResearchProfileResetScope resetScope) async {
    final scope = _scope;
    if (scope == null) return;
    final all = resetScope == ResearchProfileResetScope.all;
    final confirmed = await _showScopeDialog<bool>(
      builder: (context) => AlertDialog.adaptive(
        title: Text(
          all ? 'Reset research profile?' : 'Clear inferred signals?',
        ),
        content: Text(
          all
              ? 'This restores discovery defaults and clears explicit, feedback-derived, and inferred profile signals. Your library and To Read queue are unchanged.'
              : 'This clears only system-inferred profile signals. Explicit choices, feedback, your library, and To Read are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(all ? 'Reset profile' : 'Clear inferred'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _scope != scope) return;
    await _mutate(
      key: 'reset:${resetScope.name}',
      action: (scope, profile, operationId, request) => _remote.reset(
        scope: resetScope,
        operationId: operationId,
        expectedRevision: profile.profileRevision,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
    );
  }

  Future<void> _showExport() async {
    final scope = _scope;
    if (_busy || scope == null) return;
    final request = RequestCancellation();
    _request?.cancel('A profile export started.');
    _request = request;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final export = await _remote.export(
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (!_isCurrent(scope, generation)) return;
      final text = const JsonEncoder.withIndent('  ').convert(export.toJson());
      setState(() => _busy = false);
      if (!mounted) return;
      await _showScopeBottomSheet<void>(
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => FractionallySizedBox(
          heightFactor: .88,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PakPerkSpacing.lg,
                  0,
                  PakPerkSpacing.lg,
                  PakPerkSpacing.sm,
                ),
                child: Text(
                  'Research profile export',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: PakPerkSpacing.lg),
                child: Text(
                  'This bounded snapshot excludes the operation ledger and raw interaction history.',
                ),
              ),
              const SizedBox(height: PakPerkSpacing.sm),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PakPerkSpacing.lg,
                  ),
                  child: SelectableText(text),
                ),
              ),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.all(PakPerkSpacing.lg),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PakPerkSizes.minimumInteractive,
                  ),
                  child: FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy export'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _busy = false;
        _errorMessage = _safeMessage(error);
      });
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _busy = false;
        _errorMessage = 'The profile export is temporarily unavailable.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<T?> _showScopeDialog<T>({required WidgetBuilder builder}) async {
    if (_scope == null) return null;
    _scopeModalDepth += 1;
    try {
      return await showDialog<T>(context: context, builder: builder);
    } finally {
      _scopeModalDepth -= 1;
    }
  }

  Future<T?> _showScopeBottomSheet<T>({
    required WidgetBuilder builder,
    bool isScrollControlled = false,
    bool useSafeArea = false,
    bool showDragHandle = false,
  }) async {
    if (_scope == null) return null;
    _scopeModalDepth += 1;
    try {
      return await showModalBottomSheet<T>(
        context: context,
        isScrollControlled: isScrollControlled,
        useSafeArea: useSafeArea,
        showDragHandle: showDragHandle,
        builder: builder,
      );
    } finally {
      _scopeModalDepth -= 1;
    }
  }

  void _scheduleScopeModalClose() {
    if (_scopeModalDepth == 0 || _scopeModalCloseScheduled || !mounted) return;
    _scopeModalCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scopeModalCloseScheduled = false;
      if (!mounted || _scopeModalDepth == 0) return;
      unawaited(Navigator.of(context, rootNavigator: true).maybePop());
    });
  }

  bool _isCurrent(VerifiedDiscoveryAccountScope scope, int generation) =>
      mounted && _scope == scope && _generation == generation;
}

String _safeMessage(ApiException error) => switch (error.code) {
  'RESEARCH_PROFILE_REVISION_CONFLICT' =>
    'Your profile changed elsewhere. The latest version is being loaded.',
  'RATE_LIMITED' => 'Too many profile changes. Wait a moment and try again.',
  'UNAUTHENTICATED' ||
  'TOKEN_EXPIRED' => 'Sign in again to manage your research profile.',
  _ => 'Your research profile is temporarily unavailable.',
};
