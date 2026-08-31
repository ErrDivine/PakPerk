enum PaperInteractionEventType {
  impressionQualified('impression_qualified'),
  abstractOpened('abstract_opened'),
  introductionCommitted('introduction_committed'),
  connectionsOpened('connections_opened'),
  saved('saved'),
  unsaved('unsaved'),
  markedRelevant('marked_relevant'),
  markedNotRelevant('marked_not_relevant'),
  dismissed('dismissed'),
  openedOriginal('opened_original'),
  openedConnection('opened_connection'),
  libraryStateChanged('library_state_changed');

  const PaperInteractionEventType(this.wireValue);

  final String wireValue;

  bool get isBehavioral => switch (this) {
    PaperInteractionEventType.saved ||
    PaperInteractionEventType.unsaved ||
    PaperInteractionEventType.libraryStateChanged => false,
    _ => true,
  };

  bool get requiresRecommendationBatch => switch (this) {
    PaperInteractionEventType.impressionQualified ||
    PaperInteractionEventType.markedRelevant ||
    PaperInteractionEventType.markedNotRelevant ||
    PaperInteractionEventType.dismissed => true,
    _ => false,
  };

  static PaperInteractionEventType parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid paper-interaction event type.');
  }
}

enum InteractionFeedMode {
  toRead('to_read'),
  recent('recent'),
  following('following'),
  forYou('for_you'),
  explore('explore');

  const InteractionFeedMode(this.wireValue);

  final String wireValue;

  bool get isRecommendation => this != InteractionFeedMode.toRead;

  static InteractionFeedMode parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid interaction feed mode.');
  }
}

sealed class InteractionScope {
  const InteractionScope();

  String get identity;
}

final class AccountInteractionScope extends InteractionScope {
  AccountInteractionScope({required this.accountId, required this.authEpoch}) {
    if (accountId.isEmpty ||
        accountId.length > 128 ||
        accountId.runes.any((rune) => rune < 0x20) ||
        authEpoch < 0) {
      throw ArgumentError('Invalid account interaction scope.');
    }
  }

  final String accountId;
  final int authEpoch;

  @override
  String get identity => 'account:$accountId:$authEpoch';

  @override
  bool operator ==(Object other) =>
      other is AccountInteractionScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch;

  @override
  int get hashCode => Object.hash(accountId, authEpoch);
}

final class AnonymousInteractionScope extends InteractionScope {
  AnonymousInteractionScope({required this.sessionId}) {
    _validateUuid(sessionId, 'sessionId');
  }

  final String sessionId;

  @override
  String get identity => 'anonymous:$sessionId';

  @override
  bool operator ==(Object other) =>
      other is AnonymousInteractionScope && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

final class PaperInteractionContext {
  const PaperInteractionContext({
    required this.feedMode,
    required this.batchId,
    required this.position,
  });

  final InteractionFeedMode? feedMode;
  final String? batchId;
  final int? position;
}

final class PaperInteractionEvent {
  PaperInteractionEvent({
    required this.eventId,
    required this.eventType,
    required this.paperId,
    required this.feedMode,
    required this.batchId,
    required this.position,
    required this.occurredAt,
  }) {
    _validateUuid(eventId, 'eventId');
    _validateUuid(paperId, 'paperId');
    if (batchId != null) _validateUuid(batchId!, 'batchId');
    if (!occurredAt.isUtc ||
        (position != null && (position! < 0 || position! > 10000))) {
      throw ArgumentError('Invalid paper-interaction event metadata.');
    }
  }

  final String eventId;
  final PaperInteractionEventType eventType;
  final String paperId;
  final InteractionFeedMode? feedMode;
  final String? batchId;
  final int? position;
  final DateTime occurredAt;

  Map<String, Object?> toJson() => {
    'event_id': eventId,
    'event_type': eventType.wireValue,
    'paper_id': paperId,
    'feed_mode': feedMode?.wireValue,
    'batch_id': batchId,
    'position': position,
    'occurred_at': occurredAt.toIso8601String(),
  };
}

final class InteractionBatchResult {
  const InteractionBatchResult({
    required this.accepted,
    required this.duplicates,
  });

  final int accepted;
  final int duplicates;

  factory InteractionBatchResult.fromJson(
    Map<String, dynamic> json, {
    required int submitted,
  }) {
    _exactKeys(json, const {'accepted', 'duplicates'});
    final accepted = json['accepted'];
    final duplicates = json['duplicates'];
    if (accepted is! int ||
        accepted < 0 ||
        duplicates is! int ||
        duplicates < 0 ||
        accepted + duplicates != submitted) {
      throw const FormatException('Invalid interaction-batch result.');
    }
    return InteractionBatchResult(accepted: accepted, duplicates: duplicates);
  }
}

void validateInteractionBatch(
  InteractionScope scope,
  List<PaperInteractionEvent> events,
) {
  if (events.isEmpty || events.length > 50) {
    throw ArgumentError.value(events.length, 'events', 'Must contain 1..50.');
  }
  if (events.map((event) => event.eventId).toSet().length != events.length) {
    throw ArgumentError('Interaction event identities must be unique.');
  }
  for (final event in events) {
    switch (scope) {
      case AccountInteractionScope():
        if (event.batchId != null &&
            !(event.feedMode?.isRecommendation ?? false)) {
          throw ArgumentError('A batch requires a recommendation feed mode.');
        }
        if (event.batchId == null &&
            event.feedMode != null &&
            event.feedMode != InteractionFeedMode.toRead) {
          throw ArgumentError('Account recommendation mode requires a batch.');
        }
        if (event.eventType.requiresRecommendationBatch &&
            event.batchId == null) {
          throw ArgumentError(
            'The interaction requires a recommendation batch.',
          );
        }
      case AnonymousInteractionScope():
        if (event.batchId != null ||
            (event.feedMode != null &&
                event.feedMode != InteractionFeedMode.recent &&
                event.feedMode != InteractionFeedMode.explore) ||
            (event.eventType.requiresRecommendationBatch &&
                event.eventType !=
                    PaperInteractionEventType.impressionQualified)) {
          throw ArgumentError('Invalid anonymous public interaction.');
        }
    }
  }
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.difference(expected).isNotEmpty ||
      expected.difference(actual).isNotEmpty) {
    throw const FormatException('Unexpected interaction response fields.');
  }
}

void _validateUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Must be a canonical UUID.');
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
