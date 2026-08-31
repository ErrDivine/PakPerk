import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/discovery_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/engagement/engagement_api.dart';
import '../../core/engagement/engagement_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';
import 'engagement_screen.dart';

String notificationPreferencesOperationKey(NotificationPreferences value) {
  final frequencies = value.typeFrequencies;
  return 'preferences:${frequencies.discoveryMatch.name}:'
      '${frequencies.discoveryDigest.name}:'
      '${frequencies.userSelectedReminder.name}:'
      '${frequencies.activePaperVersion.name}:'
      '${frequencies.syncFailure.name}:${value.inAppEnabled}:'
      '${value.globalPause}:${value.dailyBudget}:'
      '${value.quietHoursStart}:${value.quietHoursEnd}:${value.timezone}';
}

final class EngagementDestination extends ConsumerStatefulWidget {
  const EngagementDestination({
    required this.onOpenPaper,
    this.briefOnly = false,
    super.key,
  });

  const EngagementDestination.briefOnly({required this.onOpenPaper, super.key})
    : briefOnly = true;

  final ValueChanged<PaperSummary> onOpenPaper;
  final bool briefOnly;

  @override
  ConsumerState<EngagementDestination> createState() =>
      _EngagementDestinationState();
}

final class _EngagementDestinationState
    extends ConsumerState<EngagementDestination> {
  late final EngagementRemoteDataSource _remote;
  ProviderSubscription<VerifiedDiscoveryAccountScope?>? _scopeSubscription;
  VerifiedDiscoveryAccountScope? _scope;
  RequestCancellation? _request;
  ReadingBrief? _brief;
  List<Subscription> _subscriptions = const [];
  List<InAppNotification> _notifications = const [];
  NotificationPreferences? _preferences;
  final Map<String, String> _operationIds = {};
  final Map<String, String> _entityIds = {};
  var _generation = 0;
  var _loading = false;
  var _busy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _remote = ref.read(engagementApiProvider);
    _scope = ref.read(verifiedDiscoveryAccountScopeProvider);
    _scopeSubscription = ref.listenManual<VerifiedDiscoveryAccountScope?>(
      verifiedDiscoveryAccountScopeProvider,
      _onScopeChanged,
    );
    if (_scope != null && _hasAnyFeature) unawaited(_load());
  }

  bool get _hasAnyFeature {
    final flags = ref.read(featureFlagsProvider);
    return flags.readingBriefsEnabled ||
        (!widget.briefOnly &&
            (flags.subscriptionsEnabled || flags.notificationsEnabled));
  }

  @override
  void dispose() {
    _scopeSubscription?.close();
    _request?.cancel('The reading-updates destination closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(featureFlagsProvider);
    final subscriptionsEnabled =
        !widget.briefOnly && flags.subscriptionsEnabled;
    final notificationsEnabled =
        !widget.briefOnly && flags.notificationsEnabled;
    return EngagementScreen(
      briefOnly: widget.briefOnly,
      readingBriefsEnabled: flags.readingBriefsEnabled,
      subscriptionsEnabled: subscriptionsEnabled,
      notificationsEnabled: notificationsEnabled,
      brief: _brief,
      subscriptions: _subscriptions,
      notifications: _notifications,
      preferences: _preferences,
      loading: _loading,
      busy: _busy || _scope == null,
      errorMessage: _scope == null
          ? 'Sign in again to view reading updates.'
          : _errorMessage,
      onRetry: () => unawaited(_load()),
      onCreateBrief: () => unawaited(_createBrief()),
      onAdvanceBrief: () => unawaited(_advanceBrief()),
      onOpenPaper: widget.onOpenPaper,
      onAddSubscription: () => unawaited(_addSubscription()),
      onSubscriptionFrequencyChanged: (subscription, frequency) =>
          unawaited(_updateSubscription(subscription, frequency)),
      onMuteSubscription: (subscription) => unawaited(
        _updateSubscription(subscription, SubscriptionFrequency.off),
      ),
      onMuteDiscoveryNotifications: (type) => unawaited(
        _updatePreferences(
          (current) => current.copyWith(
            typeFrequencies: current.typeFrequencies.withFrequency(
              type,
              SubscriptionFrequency.off,
            ),
          ),
        ),
      ),
      onDeleteSubscription: (subscription) =>
          unawaited(_deleteSubscription(subscription)),
      onMarkNotificationRead: (notification) =>
          unawaited(_markNotificationRead(notification)),
      onDismissNotification: (notification) =>
          unawaited(_dismissNotification(notification)),
      onMarkAllNotificationsRead: () => unawaited(_markAllRead()),
      onInAppEnabledChanged: (value) => unawaited(
        _updatePreferences((current) => current.copyWith(inAppEnabled: value)),
      ),
      onGlobalPauseChanged: (value) => unawaited(
        _updatePreferences((current) => current.copyWith(globalPause: value)),
      ),
      onNotificationTypeFrequencyChanged: (type, value) => unawaited(
        _updatePreferences(
          (current) => current.copyWith(
            typeFrequencies: current.typeFrequencies.withFrequency(type, value),
          ),
        ),
      ),
      onDailyBudgetChanged: (value) => unawaited(
        _updatePreferences((current) => current.copyWith(dailyBudget: value)),
      ),
      onNotificationScheduleChanged: (schedule) => unawaited(
        _updatePreferences(
          (current) => current.copyWith(
            quietHoursStart: schedule.start,
            quietHoursEnd: schedule.end,
            timezone: schedule.timezone,
            clearQuietHours: !schedule.enabled,
          ),
        ),
      ),
    );
  }

  void _onScopeChanged(
    VerifiedDiscoveryAccountScope? previous,
    VerifiedDiscoveryAccountScope? next,
  ) {
    if (previous == next) return;
    _generation += 1;
    _request?.cancel('The reading-updates account scope changed.');
    _request = null;
    _operationIds.clear();
    _entityIds.clear();
    _scope = next;
    if (mounted) {
      setState(() {
        _brief = null;
        _subscriptions = const [];
        _notifications = const [];
        _preferences = null;
        _loading = false;
        _busy = false;
        _errorMessage = null;
      });
    }
    if (next != null && _hasAnyFeature) unawaited(_load());
  }

  Future<void> _load() async {
    final scope = _scope;
    if (scope == null) {
      if (mounted) {
        setState(() {
          _brief = null;
          _subscriptions = const [];
          _notifications = const [];
          _preferences = null;
          _loading = false;
          _errorMessage = 'Sign in again to view reading updates.';
        });
      }
      return;
    }
    final flags = ref.read(featureFlagsProvider);
    final includeEngagement = !widget.briefOnly;
    _request?.cancel('A newer reading-updates refresh started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final brief = flags.readingBriefsEnabled
          ? await _remote.currentBrief(
              expectedAuthEpoch: scope.authEpoch,
              cancellation: request,
            )
          : null;
      final subscriptions = includeEngagement && flags.subscriptionsEnabled
          ? await _remote.subscriptions(
              expectedAuthEpoch: scope.authEpoch,
              cancellation: request,
            )
          : const <Subscription>[];
      final notifications = includeEngagement && flags.notificationsEnabled
          ? await _remote.notifications(
              expectedAuthEpoch: scope.authEpoch,
              cancellation: request,
            )
          : const <InAppNotification>[];
      final preferences = includeEngagement && flags.notificationsEnabled
          ? await _remote.notificationPreferences(
              expectedAuthEpoch: scope.authEpoch,
              cancellation: request,
            )
          : null;
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _brief = brief;
        _subscriptions = subscriptions;
        _notifications = notifications;
        _preferences = preferences;
        _loading = false;
        _busy = false;
        _errorMessage = null;
      });
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _loading = false;
        _busy = false;
        _errorMessage = _safeMessage(error);
      });
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _loading = false;
        _busy = false;
        _errorMessage = 'Reading updates are temporarily unavailable.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _createBrief() {
    return _runIdempotent<ReadingBrief>(
      key: 'create-brief:profile-default',
      action: (scope, operationId, request) => _remote.createBrief(
        operationId: operationId,
        recommendationMode: null,
        category: null,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
      apply: (value) => _brief = value,
    );
  }

  Future<void> _advanceBrief() {
    final brief = _brief;
    if (brief == null || brief.position >= brief.items.length) {
      return Future.value();
    }
    final next = brief.position + 1;
    return _runIdempotent<ReadingBrief>(
      key: 'brief-progress:${brief.id}:$next',
      action: (scope, operationId, request) => _remote.updateBriefProgress(
        briefId: brief.id,
        operationId: operationId,
        expectedProgressRevision: brief.progressRevision,
        position: next,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
      apply: (value) => _brief = value,
    );
  }

  Future<void> _addSubscription() async {
    if (_busy || _scope == null) return;
    final draft = await showModalBottomSheet<_NewSubscriptionDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const _AddSubscriptionSheet(),
    );
    if (draft == null || !mounted) return;
    final fingerprint =
        '${draft.kind.wireValue}:${draft.key}:${draft.frequency.name}';
    final id = _entityIds.putIfAbsent(fingerprint, () => const Uuid().v7());
    await _runIdempotent<Subscription>(
      key: 'create-subscription:$fingerprint',
      action: (scope, operationId, request) => _remote.createSubscription(
        operationId: operationId,
        id: id,
        kind: draft.kind,
        key: draft.key,
        label: draft.label,
        savedSearchId: null,
        frequency: draft.frequency,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      ),
      apply: (value) {
        _entityIds.remove(fingerprint);
        _subscriptions = _replaceSubscription(_subscriptions, value);
      },
    );
  }

  Future<void> _updateSubscription(
    Subscription subscription,
    SubscriptionFrequency frequency,
  ) => _runIdempotent<Subscription>(
    key: 'subscription:${subscription.id}:${frequency.name}',
    action: (scope, operationId, request) => _remote.updateSubscription(
      operationId: operationId,
      id: subscription.id,
      kind: subscription.kind,
      key: subscription.key,
      label: subscription.label,
      savedSearchId: subscription.savedSearchId,
      frequency: frequency,
      expectedAuthEpoch: scope.authEpoch,
      cancellation: request,
    ),
    apply: (value) {
      _subscriptions = _replaceSubscription(_subscriptions, value);
    },
  );

  Future<void> _deleteSubscription(Subscription subscription) =>
      _runIdempotent<Subscription>(
        key: 'delete-subscription:${subscription.id}',
        action: (scope, operationId, request) => _remote.deleteSubscription(
          operationId: operationId,
          id: subscription.id,
          expectedAuthEpoch: scope.authEpoch,
          cancellation: request,
        ),
        apply: (value) {
          _subscriptions = _replaceSubscription(_subscriptions, value);
        },
      );

  Future<void> _updatePreferences(
    NotificationPreferences Function(NotificationPreferences) update,
  ) {
    final current = _preferences;
    if (current == null) return Future.value();
    final next = update(current);
    final key = notificationPreferencesOperationKey(next);
    return _runIdempotent<NotificationPreferences>(
      key: key,
      action: (scope, operationId, request) =>
          _remote.updateNotificationPreferences(
            operationId: operationId,
            preferences: next,
            expectedAuthEpoch: scope.authEpoch,
            cancellation: request,
          ),
      apply: (value) => _preferences = value,
    );
  }

  Future<void> _markNotificationRead(InAppNotification notification) =>
      _runNotification(
        (scope, request) => _remote.markNotificationRead(
          id: notification.id,
          expectedAuthEpoch: scope.authEpoch,
          cancellation: request,
        ),
      );

  Future<void> _dismissNotification(InAppNotification notification) =>
      _runNotification(
        (scope, request) => _remote.dismissNotification(
          id: notification.id,
          expectedAuthEpoch: scope.authEpoch,
          cancellation: request,
        ),
      );

  Future<void> _markAllRead() => _runNotification(
    (scope, request) => _remote.markAllNotificationsRead(
      expectedAuthEpoch: scope.authEpoch,
      cancellation: request,
    ),
  );

  Future<void> _runNotification(
    Future<int> Function(
      VerifiedDiscoveryAccountScope scope,
      RequestCancellation request,
    )
    action,
  ) async {
    final scope = _scope;
    if (_busy || scope == null) return;
    _request?.cancel('A notification change started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await action(scope, request);
      if (!_isCurrent(scope, generation)) return;
      _request = null;
      await _load();
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
        _errorMessage = 'That notification change could not be saved.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _runIdempotent<T>({
    required String key,
    required Future<T> Function(
      VerifiedDiscoveryAccountScope scope,
      String operationId,
      RequestCancellation request,
    )
    action,
    required void Function(T value) apply,
  }) async {
    final scope = _scope;
    if (_busy || scope == null) return;
    _request?.cancel('A newer reading-updates change started.');
    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    final operationId = _operationIds.putIfAbsent(key, () => const Uuid().v7());
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final value = await action(scope, operationId, request);
      if (!_isCurrent(scope, generation)) return;
      _operationIds.remove(key);
      setState(() {
        apply(value);
        _busy = false;
      });
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation) || error.cancelled) return;
      setState(() {
        _busy = false;
        _errorMessage = _safeMessage(error);
      });
      if (error.code == 'READING_BRIEF_PROGRESS_STALE') {
        _operationIds.remove(key);
        unawaited(_load());
      }
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      setState(() {
        _busy = false;
        _errorMessage = 'That reading-updates change could not be saved.';
      });
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  bool _isCurrent(VerifiedDiscoveryAccountScope scope, int generation) =>
      mounted && _scope == scope && _generation == generation;
}

final class _NewSubscriptionDraft {
  const _NewSubscriptionDraft({
    required this.kind,
    required this.key,
    required this.label,
    required this.frequency,
  });

  final SubscriptionKind kind;
  final String key;
  final String label;
  final SubscriptionFrequency frequency;
}

final class _AddSubscriptionSheet extends StatefulWidget {
  const _AddSubscriptionSheet();

  @override
  State<_AddSubscriptionSheet> createState() => _AddSubscriptionSheetState();
}

final class _AddSubscriptionSheetState extends State<_AddSubscriptionSheet> {
  final _keyController = TextEditingController();
  final _labelController = TextEditingController();
  var _kind = SubscriptionKind.topic;
  var _frequency = SubscriptionFrequency.daily;
  String? _error;

  @override
  void dispose() {
    _keyController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      PakPerkSpacing.lg,
      0,
      PakPerkSpacing.lg,
      MediaQuery.viewInsetsOf(context).bottom + PakPerkSpacing.lg,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Add subscription',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          DropdownButtonFormField<SubscriptionKind>(
            initialValue: _kind,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Kind'),
            items: const [
              DropdownMenuItem(
                value: SubscriptionKind.topic,
                child: Text('Topic'),
              ),
              DropdownMenuItem(
                value: SubscriptionKind.category,
                child: Text('Category'),
              ),
              DropdownMenuItem(
                value: SubscriptionKind.author,
                child: Text('Author'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _kind = value);
            },
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          TextField(
            key: const ValueKey('engagement-subscription-key'),
            controller: _keyController,
            autofocus: true,
            maxLength: 160,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Stable key',
              helperText: 'Use the canonical key shown by the paper source.',
            ),
          ),
          TextField(
            key: const ValueKey('engagement-subscription-label'),
            controller: _labelController,
            maxLength: 160,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Display label'),
            onSubmitted: (_) => _submit(),
          ),
          DropdownButtonFormField<SubscriptionFrequency>(
            initialValue: _frequency,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Frequency'),
            items: [
              for (final value in SubscriptionFrequency.values)
                DropdownMenuItem(value: value, child: Text(value.name)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _frequency = value);
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: PakPerkSpacing.sm),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: PakPerkSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: FilledButton(
              onPressed: _submit,
              child: const Text('Add subscription'),
            ),
          ),
        ],
      ),
    ),
  );

  void _submit() {
    final key = _keyController.text.trim();
    final label = _labelController.text.trim();
    if (key.isEmpty ||
        key.length > 160 ||
        label.isEmpty ||
        label.length > 160) {
      setState(() => _error = 'Enter a bounded stable key and display label.');
      return;
    }
    Navigator.of(context).pop(
      _NewSubscriptionDraft(
        kind: _kind,
        key: key,
        label: label,
        frequency: _frequency,
      ),
    );
  }
}

List<Subscription> _replaceSubscription(
  List<Subscription> current,
  Subscription value,
) {
  final next = [
    for (final item in current)
      if (item.id != value.id) item,
    value,
  ];
  next.sort((left, right) => left.label.compareTo(right.label));
  return List.unmodifiable(next);
}

String _safeMessage(ApiException error) => switch (error.code) {
  'READING_BRIEF_PROGRESS_STALE' =>
    'Brief progress changed elsewhere. Refresh and continue.',
  'QUEUE_AUTHORITY_UNAVAILABLE' =>
    'To Read could not be verified. No discovery brief was created.',
  'RATE_LIMITED' => 'Too many updates. Wait a moment and try again.',
  'UNAUTHENTICATED' ||
  'TOKEN_EXPIRED' => 'Sign in again to manage reading updates.',
  _ => 'Reading updates are temporarily unavailable.',
};
