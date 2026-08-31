import '../models/paper.dart';
import '../recommendations/recommendation_interaction_models.dart';

enum ReadingBriefMode { queue, discovery }

enum ReadingBriefStatus { current, complete, superseded }

enum EngagementRecommendationMode {
  recent('recent'),
  following('following'),
  forYou('for_you'),
  explore('explore');

  const EngagementRecommendationMode(this.wireValue);

  final String wireValue;

  static EngagementRecommendationMode parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid recommendation mode.');
  }
}

enum ReadingBriefItemSource {
  toRead('to_read'),
  discoveryV1('discovery_v1'),
  recentV1('recent_v1'),
  followingV1('following_v1'),
  forYouV1('for_you_v1'),
  exploreV1('explore_v1');

  const ReadingBriefItemSource(this.wireValue);

  final String wireValue;

  static ReadingBriefItemSource parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid reading-brief source.');
  }
}

final class ReadingBriefItem {
  ReadingBriefItem({
    required this.ordinal,
    required this.paper,
    required this.source,
    required Iterable<RecommendationExplanationCode> reasonCodes,
  }) : reasonCodes = List.unmodifiable(reasonCodes);

  final int ordinal;
  final PaperSummary paper;
  final ReadingBriefItemSource source;
  final List<RecommendationExplanationCode> reasonCodes;

  factory ReadingBriefItem.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'ordinal', 'paper', 'source', 'reason_codes'});
    final ordinal = json['ordinal'];
    final paperJson = _map(json['paper']);
    final paperId = paperJson['paper_id'];
    if (ordinal is! int || ordinal < 0 || ordinal >= 25) {
      throw const FormatException('Invalid reading-brief ordinal.');
    }
    _uuid(paperId);
    return ReadingBriefItem(
      ordinal: ordinal,
      paper: PaperSummary.fromJson(paperJson),
      source: ReadingBriefItemSource.parse(json['source']),
      reasonCodes: _recommendationReasonCodes(json['reason_codes']),
    );
  }
}

final class ReadingBrief {
  ReadingBrief({
    required this.id,
    required this.mode,
    required this.recommendationMode,
    required this.libraryRevision,
    required this.recommendationBatchId,
    required this.localDate,
    required this.position,
    required this.progressRevision,
    required this.status,
    required Iterable<ReadingBriefItem> items,
    required this.createdAt,
    required this.updatedAt,
    required this.completedAt,
  }) : items = List.unmodifiable(items);

  final String id;
  final ReadingBriefMode mode;
  final EngagementRecommendationMode? recommendationMode;
  final int libraryRevision;
  final String? recommendationBatchId;
  final String localDate;
  final int position;
  final int progressRevision;
  final ReadingBriefStatus status;
  final List<ReadingBriefItem> items;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  bool get isFinished => status != ReadingBriefStatus.current;

  factory ReadingBrief.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'id',
      'mode',
      'recommendation_mode',
      'library_revision',
      'recommendation_batch_id',
      'local_date',
      'position',
      'progress_revision',
      'status',
      'items',
      'created_at',
      'updated_at',
      'completed_at',
    });
    final id = _uuid(json['id']);
    final mode = switch (json['mode']) {
      'queue' => ReadingBriefMode.queue,
      'discovery' => ReadingBriefMode.discovery,
      _ => throw const FormatException('Invalid reading-brief mode.'),
    };
    final recommendationMode = json['recommendation_mode'] == null
        ? null
        : EngagementRecommendationMode.parse(json['recommendation_mode']);
    final batchId = json['recommendation_batch_id'] == null
        ? null
        : _uuid(json['recommendation_batch_id']);
    final libraryRevision = json['library_revision'];
    final position = json['position'];
    final progressRevision = json['progress_revision'];
    final rawItems = json['items'];
    if (libraryRevision is! int ||
        libraryRevision < 0 ||
        position is! int ||
        position < 0 ||
        position > 25 ||
        progressRevision is! int ||
        progressRevision < 1 ||
        rawItems is! List ||
        rawItems.isEmpty ||
        rawItems.length > 25) {
      throw const FormatException('Invalid reading-brief bounds.');
    }
    final items = rawItems
        .map((value) => ReadingBriefItem.fromJson(_map(value)))
        .toList(growable: false);
    for (var index = 0; index < items.length; index += 1) {
      if (items[index].ordinal != index) {
        throw const FormatException('Reading-brief ordinals are not stable.');
      }
    }
    if (position > items.length) {
      throw const FormatException('Reading-brief position exceeds its items.');
    }
    final status = switch (json['status']) {
      'current' => ReadingBriefStatus.current,
      'complete' => ReadingBriefStatus.complete,
      'superseded' => ReadingBriefStatus.superseded,
      _ => throw const FormatException('Invalid reading-brief status.'),
    };
    final completedAt = json['completed_at'] == null
        ? null
        : _timestamp(json['completed_at']);
    if ((status == ReadingBriefStatus.complete) != (completedAt != null) ||
        (status == ReadingBriefStatus.complete && position != items.length)) {
      throw const FormatException('Invalid reading-brief completion state.');
    }
    final queueMode = mode == ReadingBriefMode.queue;
    if ((queueMode && (recommendationMode != null || batchId != null)) ||
        (!queueMode && (recommendationMode == null || batchId == null)) ||
        items.any(
          (item) => queueMode
              ? item.source != ReadingBriefItemSource.toRead ||
                    item.reasonCodes.isNotEmpty
              : item.source == ReadingBriefItemSource.toRead,
        )) {
      throw const FormatException('Reading-brief provenance is inconsistent.');
    }
    return ReadingBrief(
      id: id,
      mode: mode,
      recommendationMode: recommendationMode,
      libraryRevision: libraryRevision,
      recommendationBatchId: batchId,
      localDate: _date(json['local_date']),
      position: position,
      progressRevision: progressRevision,
      status: status,
      items: items,
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
      completedAt: completedAt,
    );
  }
}

enum SubscriptionKind {
  topic('topic'),
  category('category'),
  author('author'),
  savedQuery('saved_query');

  const SubscriptionKind(this.wireValue);
  final String wireValue;

  static SubscriptionKind parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid subscription kind.');
  }
}

enum SubscriptionFrequency {
  immediate,
  daily,
  weekly,
  off;

  static SubscriptionFrequency parse(Object? value) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    throw const FormatException('Invalid subscription frequency.');
  }
}

final class Subscription {
  const Subscription({
    required this.id,
    required this.kind,
    required this.key,
    required this.label,
    required this.savedSearchId,
    required this.frequency,
    required this.lastEvaluatedAt,
    required this.revision,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final SubscriptionKind kind;
  final String key;
  final String label;
  final String? savedSearchId;
  final SubscriptionFrequency frequency;
  final DateTime? lastEvaluatedAt;
  final int revision;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Subscription.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'id',
      'kind',
      'key',
      'label',
      'saved_search_id',
      'frequency',
      'last_evaluated_at',
      'revision',
      'deleted',
      'created_at',
      'updated_at',
    });
    final kind = SubscriptionKind.parse(json['kind']);
    final savedSearchId = json['saved_search_id'] == null
        ? null
        : _uuid(json['saved_search_id']);
    final revision = json['revision'];
    final deleted = json['deleted'];
    if (revision is! int || revision < 1 || deleted is! bool) {
      throw const FormatException('Invalid subscription revision.');
    }
    if ((kind == SubscriptionKind.savedQuery) != (savedSearchId != null)) {
      throw const FormatException('Invalid saved-query subscription.');
    }
    return Subscription(
      id: _uuid(json['id']),
      kind: kind,
      key: _bounded(json['key'], 160),
      label: _bounded(json['label'], 160),
      savedSearchId: savedSearchId,
      frequency: SubscriptionFrequency.parse(json['frequency']),
      lastEvaluatedAt: json['last_evaluated_at'] == null
          ? null
          : _timestamp(json['last_evaluated_at']),
      revision: revision,
      deleted: deleted,
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }
}

enum InAppNotificationType {
  discoveryMatch('discovery_match'),
  discoveryDigest('discovery_digest'),
  userSelectedReminder('user_selected_reminder'),
  activePaperVersion('active_paper_version'),
  syncFailure('sync_failure');

  const InAppNotificationType(this.wireValue);
  final String wireValue;

  String get displayTitle => switch (this) {
    InAppNotificationType.discoveryMatch => 'New discovery match',
    InAppNotificationType.discoveryDigest => 'Discovery digest',
    InAppNotificationType.userSelectedReminder => 'Reading reminder',
    InAppNotificationType.activePaperVersion => 'Paper update available',
    InAppNotificationType.syncFailure => 'Sync needs attention',
  };

  static InAppNotificationType parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid notification type.');
  }
}

final class NotificationTypeFrequencies {
  const NotificationTypeFrequencies({
    required this.discoveryMatch,
    required this.discoveryDigest,
    required this.userSelectedReminder,
    required this.activePaperVersion,
    required this.syncFailure,
  }) : assert(
         discoveryMatch == SubscriptionFrequency.off ||
             discoveryDigest == SubscriptionFrequency.off,
         'Individual discovery matches and digests cannot both be enabled.',
       );

  static const defaults = NotificationTypeFrequencies(
    discoveryMatch: SubscriptionFrequency.off,
    discoveryDigest: SubscriptionFrequency.daily,
    userSelectedReminder: SubscriptionFrequency.immediate,
    activePaperVersion: SubscriptionFrequency.off,
    syncFailure: SubscriptionFrequency.immediate,
  );

  final SubscriptionFrequency discoveryMatch;
  final SubscriptionFrequency discoveryDigest;
  final SubscriptionFrequency userSelectedReminder;
  final SubscriptionFrequency activePaperVersion;
  final SubscriptionFrequency syncFailure;

  SubscriptionFrequency operator [](InAppNotificationType type) =>
      switch (type) {
        InAppNotificationType.discoveryMatch => discoveryMatch,
        InAppNotificationType.discoveryDigest => discoveryDigest,
        InAppNotificationType.userSelectedReminder => userSelectedReminder,
        InAppNotificationType.activePaperVersion => activePaperVersion,
        InAppNotificationType.syncFailure => syncFailure,
      };

  SubscriptionFrequency get legacyDiscoveryFrequency =>
      discoveryMatch != SubscriptionFrequency.off
      ? discoveryMatch
      : discoveryDigest;

  bool get legacyActiveUpdatesEnabled =>
      activePaperVersion != SubscriptionFrequency.off;

  bool get hasRepresentableDiscoverySchedule =>
      discoveryMatch == SubscriptionFrequency.off ||
      discoveryDigest == SubscriptionFrequency.off;

  factory NotificationTypeFrequencies.fromLegacy({
    required SubscriptionFrequency discoveryFrequency,
    required bool activeUpdatesEnabled,
  }) => NotificationTypeFrequencies(
    discoveryMatch: discoveryFrequency == SubscriptionFrequency.immediate
        ? SubscriptionFrequency.immediate
        : SubscriptionFrequency.off,
    discoveryDigest:
        discoveryFrequency == SubscriptionFrequency.daily ||
            discoveryFrequency == SubscriptionFrequency.weekly
        ? discoveryFrequency
        : SubscriptionFrequency.off,
    userSelectedReminder: SubscriptionFrequency.immediate,
    activePaperVersion: activeUpdatesEnabled
        ? SubscriptionFrequency.immediate
        : SubscriptionFrequency.off,
    syncFailure: SubscriptionFrequency.immediate,
  );

  factory NotificationTypeFrequencies.fromJson(Map<String, dynamic> json) {
    _exactKeysWithOptional(
      json,
      const {
        'discovery_match',
        'discovery_digest',
        'active_paper_version',
        'sync_failure',
      },
      const {'user_selected_reminder'},
    );
    final discoveryMatch = SubscriptionFrequency.parse(json['discovery_match']);
    final discoveryDigest = SubscriptionFrequency.parse(
      json['discovery_digest'],
    );
    if (discoveryMatch != SubscriptionFrequency.off &&
        discoveryDigest != SubscriptionFrequency.off) {
      throw const FormatException(
        'Discovery matches and digests cannot both be enabled.',
      );
    }
    return NotificationTypeFrequencies(
      discoveryMatch: discoveryMatch,
      discoveryDigest: discoveryDigest,
      userSelectedReminder: json.containsKey('user_selected_reminder')
          ? SubscriptionFrequency.parse(json['user_selected_reminder'])
          : SubscriptionFrequency.immediate,
      activePaperVersion: SubscriptionFrequency.parse(
        json['active_paper_version'],
      ),
      syncFailure: SubscriptionFrequency.parse(json['sync_failure']),
    );
  }

  Map<String, String> toJson() {
    if (!hasRepresentableDiscoverySchedule) {
      throw StateError('Notification frequencies cannot be projected safely.');
    }
    return {
      'discovery_match': discoveryMatch.name,
      'discovery_digest': discoveryDigest.name,
      'user_selected_reminder': userSelectedReminder.name,
      'active_paper_version': activePaperVersion.name,
      'sync_failure': syncFailure.name,
    };
  }

  NotificationTypeFrequencies withFrequency(
    InAppNotificationType type,
    SubscriptionFrequency frequency,
  ) => switch (type) {
    InAppNotificationType.discoveryMatch => NotificationTypeFrequencies(
      discoveryMatch: frequency,
      discoveryDigest: frequency == SubscriptionFrequency.off
          ? discoveryDigest
          : SubscriptionFrequency.off,
      userSelectedReminder: userSelectedReminder,
      activePaperVersion: activePaperVersion,
      syncFailure: syncFailure,
    ),
    InAppNotificationType.discoveryDigest => NotificationTypeFrequencies(
      discoveryMatch: frequency == SubscriptionFrequency.off
          ? discoveryMatch
          : SubscriptionFrequency.off,
      discoveryDigest: frequency,
      userSelectedReminder: userSelectedReminder,
      activePaperVersion: activePaperVersion,
      syncFailure: syncFailure,
    ),
    InAppNotificationType.userSelectedReminder => NotificationTypeFrequencies(
      discoveryMatch: discoveryMatch,
      discoveryDigest: discoveryDigest,
      userSelectedReminder: frequency,
      activePaperVersion: activePaperVersion,
      syncFailure: syncFailure,
    ),
    InAppNotificationType.activePaperVersion => NotificationTypeFrequencies(
      discoveryMatch: discoveryMatch,
      discoveryDigest: discoveryDigest,
      userSelectedReminder: userSelectedReminder,
      activePaperVersion: frequency,
      syncFailure: syncFailure,
    ),
    InAppNotificationType.syncFailure => NotificationTypeFrequencies(
      discoveryMatch: discoveryMatch,
      discoveryDigest: discoveryDigest,
      userSelectedReminder: userSelectedReminder,
      activePaperVersion: activePaperVersion,
      syncFailure: frequency,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationTypeFrequencies &&
      other.discoveryMatch == discoveryMatch &&
      other.discoveryDigest == discoveryDigest &&
      other.userSelectedReminder == userSelectedReminder &&
      other.activePaperVersion == activePaperVersion &&
      other.syncFailure == syncFailure;

  @override
  int get hashCode => Object.hash(
    discoveryMatch,
    discoveryDigest,
    userSelectedReminder,
    activePaperVersion,
    syncFailure,
  );
}

enum InAppNotificationScope {
  queueOwned('queue_owned'),
  discovery('discovery');

  const InAppNotificationScope(this.wireValue);
  final String wireValue;

  static InAppNotificationScope parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid notification scope.');
  }
}

enum NotificationDeliveryEligibility {
  eligible,
  deferredQueueNonempty,
  deferredUnknown,
  expired;

  static NotificationDeliveryEligibility parse(Object? value) {
    return switch (value) {
      'eligible' => NotificationDeliveryEligibility.eligible,
      'deferred_queue_nonempty' =>
        NotificationDeliveryEligibility.deferredQueueNonempty,
      'deferred_unknown' => NotificationDeliveryEligibility.deferredUnknown,
      'expired' => NotificationDeliveryEligibility.expired,
      _ => throw const FormatException('Invalid delivery eligibility.'),
    };
  }
}

enum NotificationEntityType {
  paper('paper'),
  subscription('subscription'),
  digest('digest'),
  sync('sync');

  const NotificationEntityType(this.wireValue);

  final String wireValue;

  static NotificationEntityType parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid notification entity type.');
  }
}

final class InAppNotification {
  InAppNotification({
    required this.id,
    required this.type,
    required this.scope,
    required this.entityType,
    required this.entityId,
    required this.deliveryEligibility,
    required this.eligibilityLibraryRevision,
    required this.createdAt,
    required this.readAt,
    required this.expiresAt,
    required Iterable<PaperSummary> papers,
  }) : papers = List.unmodifiable(papers);

  final String id;
  final InAppNotificationType type;
  final InAppNotificationScope scope;
  final NotificationEntityType entityType;
  final String? entityId;
  final NotificationDeliveryEligibility deliveryEligibility;
  final int? eligibilityLibraryRevision;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? expiresAt;
  final List<PaperSummary> papers;

  bool get isRead => readAt != null;

  factory InAppNotification.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'id',
      'notification_type',
      'scope',
      'entity_type',
      'entity_id',
      'payload',
      'delivery_eligibility',
      'eligibility_library_revision',
      'created_at',
      'read_at',
      'expires_at',
      'papers',
    });
    // Payload is deliberately validated as an object and then discarded. It
    // is neither rendered as trusted copy nor persisted as client authority.
    _map(json['payload']);
    final rawPapers = json['papers'];
    final revision = json['eligibility_library_revision'];
    if (rawPapers is! List ||
        rawPapers.length > 25 ||
        (revision != null && (revision is! int || revision < 0))) {
      throw const FormatException('Invalid notification bounds.');
    }
    return InAppNotification(
      id: _uuid(json['id']),
      type: InAppNotificationType.parse(json['notification_type']),
      scope: InAppNotificationScope.parse(json['scope']),
      entityType: NotificationEntityType.parse(json['entity_type']),
      entityId: json['entity_id'] == null ? null : _uuid(json['entity_id']),
      deliveryEligibility: NotificationDeliveryEligibility.parse(
        json['delivery_eligibility'],
      ),
      eligibilityLibraryRevision: revision as int?,
      createdAt: _timestamp(json['created_at']),
      readAt: json['read_at'] == null ? null : _timestamp(json['read_at']),
      expiresAt: json['expires_at'] == null
          ? null
          : _timestamp(json['expires_at']),
      papers: rawPapers.map((value) {
        final paper = _map(value);
        _uuid(paper['paper_id']);
        return PaperSummary.fromJson(paper);
      }),
    );
  }
}

final class NotificationPreferences {
  const NotificationPreferences({
    required this.typeFrequencies,
    required this.quietHoursStart,
    required this.quietHoursEnd,
    required this.timezone,
    required this.inAppEnabled,
    required this.globalPause,
    required this.dailyBudget,
    required this.revision,
    required this.updatedAt,
  });

  final NotificationTypeFrequencies typeFrequencies;
  final String? quietHoursStart;
  final String? quietHoursEnd;
  final String timezone;
  final bool inAppEnabled;
  final bool globalPause;
  final int dailyBudget;
  final int revision;
  final DateTime updatedAt;

  SubscriptionFrequency get discoveryFrequency =>
      typeFrequencies.legacyDiscoveryFrequency;

  bool get activeUpdatesEnabled => typeFrequencies.legacyActiveUpdatesEnabled;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    _exactKeysWithOptional(
      json,
      const {
        'discovery_frequency',
        'quiet_hours_start',
        'quiet_hours_end',
        'timezone',
        'in_app_enabled',
        'push_enabled',
        'email_enabled',
        'global_pause',
        'active_updates_enabled',
        'daily_budget',
        'revision',
        'updated_at',
      },
      const {'type_frequencies'},
    );
    final inApp = json['in_app_enabled'];
    final paused = json['global_pause'];
    final activeUpdates = json['active_updates_enabled'];
    final budget = json['daily_budget'];
    final revision = json['revision'];
    if (inApp is! bool ||
        paused is! bool ||
        activeUpdates is! bool ||
        json['push_enabled'] != false ||
        json['email_enabled'] != false ||
        budget is! int ||
        budget < 1 ||
        budget > 20 ||
        revision is! int ||
        revision < 1) {
      throw const FormatException('Invalid notification preferences.');
    }
    final discoveryFrequency = SubscriptionFrequency.parse(
      json['discovery_frequency'],
    );
    final typeFrequencies = json.containsKey('type_frequencies')
        ? NotificationTypeFrequencies.fromJson(_map(json['type_frequencies']))
        : NotificationTypeFrequencies.fromLegacy(
            discoveryFrequency: discoveryFrequency,
            activeUpdatesEnabled: activeUpdates,
          );
    if (typeFrequencies.legacyDiscoveryFrequency != discoveryFrequency ||
        typeFrequencies.legacyActiveUpdatesEnabled != activeUpdates) {
      throw const FormatException(
        'Canonical and legacy notification preferences are inconsistent.',
      );
    }
    return NotificationPreferences(
      typeFrequencies: typeFrequencies,
      quietHoursStart: _optionalTime(json['quiet_hours_start']),
      quietHoursEnd: _optionalTime(json['quiet_hours_end']),
      timezone: _bounded(json['timezone'], 64),
      inAppEnabled: inApp,
      globalPause: paused,
      dailyBudget: budget,
      revision: revision,
      updatedAt: _timestamp(json['updated_at']),
    );
  }

  Map<String, Object?> updateJson(String operationId) => {
    'operation_id': _uuid(operationId),
    'type_frequencies': typeFrequencies.toJson(),
    'discovery_frequency': typeFrequencies.legacyDiscoveryFrequency.name,
    'quiet_hours_start': quietHoursStart,
    'quiet_hours_end': quietHoursEnd,
    'timezone': timezone,
    'in_app_enabled': inAppEnabled,
    'push_enabled': false,
    'email_enabled': false,
    'global_pause': globalPause,
    'active_updates_enabled': typeFrequencies.legacyActiveUpdatesEnabled,
    'daily_budget': dailyBudget,
  };

  NotificationPreferences copyWith({
    NotificationTypeFrequencies? typeFrequencies,
    String? quietHoursStart,
    String? quietHoursEnd,
    String? timezone,
    bool clearQuietHours = false,
    bool? inAppEnabled,
    bool? globalPause,
    int? dailyBudget,
  }) => NotificationPreferences(
    typeFrequencies: typeFrequencies ?? this.typeFrequencies,
    quietHoursStart: clearQuietHours
        ? null
        : quietHoursStart ?? this.quietHoursStart,
    quietHoursEnd: clearQuietHours ? null : quietHoursEnd ?? this.quietHoursEnd,
    timezone: timezone ?? this.timezone,
    inAppEnabled: inAppEnabled ?? this.inAppEnabled,
    globalPause: globalPause ?? this.globalPause,
    dailyBudget: dailyBudget ?? this.dailyBudget,
    revision: revision,
    updatedAt: updatedAt,
  );
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected response fields.');
  }
}

void _exactKeysWithOptional(
  Map<String, dynamic> json,
  Set<String> required,
  Set<String> optional,
) {
  final actual = json.keys.toSet();
  if (actual.difference({...required, ...optional}).isNotEmpty ||
      required.difference(actual).isNotEmpty) {
    throw const FormatException('Unexpected response fields.');
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

String _bounded(Object? value, int maximumLength) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maximumLength ||
      value.trim() != value) {
    throw const FormatException('Invalid bounded text.');
  }
  return value;
}

List<RecommendationExplanationCode> _recommendationReasonCodes(Object? value) {
  if (value is! List || value.length > 16) {
    throw const FormatException('Invalid recommendation reason codes.');
  }
  final result = value
      .map(RecommendationExplanationCode.parse)
      .toList(growable: false);
  if (result.toSet().length != result.length) {
    throw const FormatException('Duplicate recommendation reason code.');
  }
  return result;
}

String _uuid(Object? value) {
  if (value is! String || !_uuidPattern.hasMatch(value)) {
    throw const FormatException('Invalid UUID.');
  }
  return value;
}

DateTime _timestamp(Object? value) {
  if (value is! String) throw const FormatException('Invalid timestamp.');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('Invalid timestamp.');
  return parsed.toUtc();
}

String _date(Object? value) {
  if (value is! String || !_datePattern.hasMatch(value)) {
    throw const FormatException('Invalid local date.');
  }
  final parsed = DateTime.tryParse('${value}T00:00:00Z');
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    throw const FormatException('Invalid local date.');
  }
  return value;
}

String? _optionalTime(Object? value) {
  if (value == null) return null;
  if (value is! String || !_timePattern.hasMatch(value)) {
    throw const FormatException('Invalid quiet-hours time.');
  }
  final parts = value.split(':').map(int.parse).toList(growable: false);
  if (parts[0] > 23 || parts[1] > 59 || parts[2] > 59) {
    throw const FormatException('Invalid quiet-hours time.');
  }
  return value;
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}$');
