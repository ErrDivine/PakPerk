import '../library/library_models.dart';
import '../models/paper.dart';
import '../recommendations/recommendation_interaction_models.dart';

enum ReadingFeedServerMode { toRead, recommendations }

enum ReadingFeedEnforcement { shadow, strict }

enum ReadingFeedRecommendationMode {
  recent('recent'),
  following('following'),
  forYou('for_you'),
  explore('explore');

  const ReadingFeedRecommendationMode(this.wireValue);

  final String wireValue;

  static ReadingFeedRecommendationMode parse(Object? value) {
    for (final candidate in values) {
      if (candidate.wireValue == value) return candidate;
    }
    throw const FormatException('Invalid reading-feed recommendation mode.');
  }
}

enum ReadingFeedItemSource {
  toRead,
  discoveryV1,
  recentV1,
  followingV1,
  forYouV1,
  exploreV1;

  bool get isPersonalizedRecommendation => switch (this) {
    ReadingFeedItemSource.recentV1 ||
    ReadingFeedItemSource.followingV1 ||
    ReadingFeedItemSource.forYouV1 ||
    ReadingFeedItemSource.exploreV1 => true,
    ReadingFeedItemSource.toRead || ReadingFeedItemSource.discoveryV1 => false,
  };

  ReadingFeedRecommendationMode? get recommendationMode => switch (this) {
    ReadingFeedItemSource.recentV1 => ReadingFeedRecommendationMode.recent,
    ReadingFeedItemSource.followingV1 =>
      ReadingFeedRecommendationMode.following,
    ReadingFeedItemSource.forYouV1 => ReadingFeedRecommendationMode.forYou,
    ReadingFeedItemSource.exploreV1 => ReadingFeedRecommendationMode.explore,
    ReadingFeedItemSource.toRead || ReadingFeedItemSource.discoveryV1 => null,
  };
}

enum ReadingFeedMode {
  guestDiscovery,
  checkingQueue,
  finishingQueue,
  toRead,
  recommendations,
  unavailable,
}

enum QueueAuthority {
  unknown,
  localNonEmpty,
  pendingSave,
  serverConfirmedNonEmpty,
  serverConfirmedEmpty,
  stale,
}

final class ReadingFeedDecision {
  static const supportedPolicyVersion = 'queue_first_v1';

  const ReadingFeedDecision({
    required this.policyVersion,
    required this.libraryRevision,
    required this.activeToReadCount,
    required this.queueProvenEmpty,
  });

  final String policyVersion;
  final int libraryRevision;
  final int activeToReadCount;
  final bool queueProvenEmpty;

  factory ReadingFeedDecision.fromJson(Map<String, dynamic> json) {
    final policyVersion = json['policy_version'];
    final revision = json['library_revision'];
    final activeCount = json['active_to_read_count'];
    final provenEmpty = json['queue_proven_empty'];
    if (policyVersion != supportedPolicyVersion ||
        revision is! int ||
        revision < 0 ||
        activeCount is! int ||
        activeCount < 0 ||
        provenEmpty is! bool ||
        provenEmpty != (activeCount == 0)) {
      throw const FormatException('Invalid reading-feed decision.');
    }
    return ReadingFeedDecision(
      policyVersion: policyVersion as String,
      libraryRevision: revision,
      activeToReadCount: activeCount,
      queueProvenEmpty: provenEmpty,
    );
  }

  Map<String, Object?> toJson() => {
    'policy_version': policyVersion,
    'library_revision': libraryRevision,
    'active_to_read_count': activeToReadCount,
    'queue_proven_empty': queueProvenEmpty,
  };
}

final class ReadingFeedQueueItem {
  const ReadingFeedQueueItem({
    required this.savedAt,
    required this.revision,
    this.state = LibraryItemState.inbox,
    this.saveSourceKind,
  });

  final DateTime savedAt;
  final int revision;
  final LibraryItemState state;
  final LibrarySaveSourceKind? saveSourceKind;

  factory ReadingFeedQueueItem.fromJson(Map<String, dynamic> json) {
    final savedAt = _requiredUtcDate(json, 'saved_at');
    final revision = json['revision'];
    if (revision is! int || revision <= 0) {
      throw const FormatException('Invalid queue-item revision.');
    }
    final stateValue = json['state'];
    final state = stateValue is String
        ? LibraryItemState.tryFromStorage(stateValue)
        : null;
    if (state == null || !state.isActive) {
      throw const FormatException('Invalid queue-item state.');
    }
    final saveSourceKind = _optionalSaveSourceKind(json['save_source_kind']);
    return ReadingFeedQueueItem(
      savedAt: savedAt,
      revision: revision,
      state: state,
      saveSourceKind: saveSourceKind,
    );
  }

  Map<String, Object?> toJson() => {
    'saved_at': savedAt.toUtc().toIso8601String(),
    'revision': revision,
    'state': state.storageValue,
    'save_source_kind': saveSourceKind?.wireValue,
  };
}

/// Account-scoped queue metadata retained for the Read presentation layer.
///
/// [privateNote] is populated only from the verified local Library projection;
/// it is deliberately not part of the reading-feed wire decoder above.
final class ReadingFeedQueuePresentation {
  const ReadingFeedQueuePresentation({
    required this.paper,
    required this.savedAt,
    required this.state,
    required this.saveSourceKind,
    required this.privateNote,
  });

  final PaperSummary paper;
  final DateTime savedAt;
  final LibraryItemState state;
  final LibrarySaveSourceKind? saveSourceKind;
  final String? privateNote;

  String get provenanceLabel =>
      saveSourceKind?.provenanceLabel ?? 'Saved to To Read';
}

final class ReadingFeedRecommendationMetadata {
  ReadingFeedRecommendationMetadata({
    required this.mode,
    required Iterable<RecommendationExplanationCode> reasonCodes,
    required this.reasonLabel,
    required this.explanationAvailable,
  }) : reasonCodes = List<RecommendationExplanationCode>.unmodifiable(
         reasonCodes,
       );

  final ReadingFeedRecommendationMode mode;
  final List<RecommendationExplanationCode> reasonCodes;
  final String reasonLabel;
  final bool explanationAvailable;

  factory ReadingFeedRecommendationMetadata.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawReasonCodes = json['reason_codes'];
    final explanationAvailable = json['explanation_available'];
    if (rawReasonCodes is! List ||
        rawReasonCodes.isEmpty ||
        rawReasonCodes.length > 16 ||
        explanationAvailable is! bool) {
      throw const FormatException('Invalid recommendation metadata.');
    }
    final reasonCodes = rawReasonCodes
        .map(RecommendationExplanationCode.parse)
        .toList(growable: false);
    if (reasonCodes.toSet().length != reasonCodes.length) {
      throw const FormatException('Duplicate recommendation reason code.');
    }
    return ReadingFeedRecommendationMetadata(
      mode: ReadingFeedRecommendationMode.parse(json['mode']),
      reasonCodes: reasonCodes,
      reasonLabel: _requiredDisplayString(
        json,
        'reason_label',
        maximumLength: 256,
      ),
      explanationAvailable: explanationAvailable,
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.wireValue,
    'reason_codes': reasonCodes
        .map((reason) => reason.wireValue)
        .toList(growable: false),
    'reason_label': reasonLabel,
    'explanation_available': explanationAvailable,
  };
}

/// Server-owned revisions that make a recommendation batch reproducible.
///
/// The tuple is deliberately attached to the batch rather than individual
/// items. Cached content is eligible only when every value still matches the
/// live, server-confirmed empty-queue response exactly.
final class ReadingFeedBatchMetadata {
  const ReadingFeedBatchMetadata({
    required this.profileRevision,
    required this.feedbackRevision,
    required this.algorithmVersion,
    required this.recommendationPolicyVersion,
  });

  final int? profileRevision;
  final int feedbackRevision;
  final String algorithmVersion;
  final String recommendationPolicyVersion;

  factory ReadingFeedBatchMetadata.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'profile_revision',
      'feedback_revision',
      'algorithm_version',
      'recommendation_policy_version',
    });
    final profileRevision = json['profile_revision'];
    final feedbackRevision = json['feedback_revision'];
    if ((profileRevision != null &&
            (profileRevision is! int || profileRevision < 0)) ||
        feedbackRevision is! int ||
        feedbackRevision < 0) {
      throw const FormatException('Invalid recommendation batch revisions.');
    }
    return ReadingFeedBatchMetadata(
      profileRevision: profileRevision as int?,
      feedbackRevision: feedbackRevision,
      algorithmVersion: _requiredBatchVersion(json, 'algorithm_version'),
      recommendationPolicyVersion: _requiredBatchVersion(
        json,
        'recommendation_policy_version',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'profile_revision': profileRevision,
    'feedback_revision': feedbackRevision,
    'algorithm_version': algorithmVersion,
    'recommendation_policy_version': recommendationPolicyVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is ReadingFeedBatchMetadata &&
      other.profileRevision == profileRevision &&
      other.feedbackRevision == feedbackRevision &&
      other.algorithmVersion == algorithmVersion &&
      other.recommendationPolicyVersion == recommendationPolicyVersion;

  @override
  int get hashCode => Object.hash(
    profileRevision,
    feedbackRevision,
    algorithmVersion,
    recommendationPolicyVersion,
  );
}

/// Item-aligned provenance for a recommendation returned from a persisted
/// server batch.
///
/// A cursor walk can append a later page from a different batch.
/// [rerankedPosition] is local to [batchId], so a new batch restarts at zero
/// and both values must travel together when interactions are emitted.
final class ReadingFeedRecommendationProvenance {
  const ReadingFeedRecommendationProvenance({
    required this.paperId,
    required this.batchId,
    required this.batchMetadata,
    required this.rerankedPosition,
  }) : assert(rerankedPosition >= 0);

  final String paperId;
  final String batchId;
  final ReadingFeedBatchMetadata batchMetadata;
  final int rerankedPosition;
}

/// Read-only progress context bound by the server to this exact feed page.
///
/// This summary is never queue authority and cannot mutate progress. Creation,
/// item selection, and progress remain exclusive to the reading-brief API.
final class ReadingFeedBriefSummary {
  const ReadingFeedBriefSummary({
    required this.id,
    required this.position,
    required this.total,
    required this.complete,
  });

  final String id;
  final int position;
  final int total;
  final bool complete;

  factory ReadingFeedBriefSummary.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'id', 'position', 'total', 'complete'});
    final id = json['id'];
    final position = json['position'];
    final total = json['total'];
    final complete = json['complete'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        position is! int ||
        position < 0 ||
        position > 25 ||
        total is! int ||
        total < 1 ||
        total > 25 ||
        position > total ||
        complete is! bool ||
        (complete && position != total)) {
      throw const FormatException('Invalid reading-feed brief summary.');
    }
    return ReadingFeedBriefSummary(
      id: id,
      position: position,
      total: total,
      complete: complete,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'position': position,
    'total': total,
    'complete': complete,
  };
}

final class ReadingFeedItem {
  const ReadingFeedItem({
    required this.paper,
    required this.queue,
    required this.source,
    this.recommendation,
  });

  final PaperSummary paper;
  final ReadingFeedQueueItem? queue;
  final ReadingFeedItemSource source;
  final ReadingFeedRecommendationMetadata? recommendation;

  factory ReadingFeedItem.fromJson(Map<String, dynamic> json) {
    final rawPaper = json['paper'];
    if (rawPaper is! Map) {
      throw const FormatException('Missing reading-feed paper.');
    }
    final rawQueue = json['queue'];
    final queue = switch (rawQueue) {
      final Map value => ReadingFeedQueueItem.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException('Invalid reading-feed queue item.'),
    };
    final source = switch (json['source']) {
      'to_read' => ReadingFeedItemSource.toRead,
      'discovery_v1' => ReadingFeedItemSource.discoveryV1,
      'recent_v1' => ReadingFeedItemSource.recentV1,
      'following_v1' => ReadingFeedItemSource.followingV1,
      'for_you_v1' => ReadingFeedItemSource.forYouV1,
      'explore_v1' => ReadingFeedItemSource.exploreV1,
      _ => throw const FormatException('Invalid reading-feed source.'),
    };
    final rawRecommendation = json['recommendation'];
    final recommendation = switch (rawRecommendation) {
      final Map value => ReadingFeedRecommendationMetadata.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException('Invalid recommendation metadata.'),
    };
    return ReadingFeedItem(
      paper: PaperSummary.fromJson(Map<String, dynamic>.from(rawPaper)),
      queue: queue,
      source: source,
      recommendation: recommendation,
    );
  }

  Map<String, Object?> toJson() => {
    'paper': paper.toJson(),
    'queue': queue?.toJson(),
    'source': switch (source) {
      ReadingFeedItemSource.toRead => 'to_read',
      ReadingFeedItemSource.discoveryV1 => 'discovery_v1',
      ReadingFeedItemSource.recentV1 => 'recent_v1',
      ReadingFeedItemSource.followingV1 => 'following_v1',
      ReadingFeedItemSource.forYouV1 => 'for_you_v1',
      ReadingFeedItemSource.exploreV1 => 'explore_v1',
    },
    'recommendation': recommendation?.toJson(),
  };
}

final class ReadingFeedPage {
  const ReadingFeedPage({
    required this.enforcement,
    required this.mode,
    required this.decision,
    this.batchId,
    this.batchMetadata,
    this.brief,
    required this.items,
    required this.nextCursor,
    required this.serverTime,
  }) : assert(
         (batchId == null) == (batchMetadata == null),
         'Batch metadata must be present exactly when batch ID is present.',
       );

  final ReadingFeedEnforcement enforcement;
  final ReadingFeedServerMode mode;
  final ReadingFeedDecision decision;
  final String? batchId;
  final ReadingFeedBatchMetadata? batchMetadata;
  final ReadingFeedBriefSummary? brief;
  final List<ReadingFeedItem> items;
  final String? nextCursor;
  final DateTime serverTime;

  factory ReadingFeedPage.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('batch_metadata')) {
      throw const FormatException('Missing reading-feed batch metadata.');
    }
    final enforcement = switch (json['enforcement']) {
      'shadow' => ReadingFeedEnforcement.shadow,
      'strict' => ReadingFeedEnforcement.strict,
      _ => throw const FormatException('Invalid reading-feed enforcement.'),
    };
    final mode = switch (json['mode']) {
      'to_read' => ReadingFeedServerMode.toRead,
      'recommendations' => ReadingFeedServerMode.recommendations,
      _ => throw const FormatException('Invalid reading-feed mode.'),
    };
    if (!json.containsKey('brief')) {
      throw const FormatException('Missing reading-feed brief binding.');
    }
    final rawDecision = json['decision'];
    final rawItems = json['items'];
    if (rawDecision is! Map || rawItems is! List || rawItems.length > 50) {
      throw const FormatException('Invalid reading-feed envelope.');
    }
    final decision = ReadingFeedDecision.fromJson(
      Map<String, dynamic>.from(rawDecision),
    );
    final items = rawItems
        .map(
          (item) => item is Map
              ? ReadingFeedItem.fromJson(Map<String, dynamic>.from(item))
              : throw const FormatException('Invalid reading-feed item.'),
        )
        .toList(growable: false);
    final nextCursor = _optionalBoundedString(json, 'next_cursor', 512);
    final batchId = _optionalUuid(json, 'batch_id');
    final batchMetadata = switch (json['batch_metadata']) {
      final Map value => ReadingFeedBatchMetadata.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException(
        'Invalid recommendation batch metadata.',
      ),
    };
    if ((batchId == null) != (batchMetadata == null)) {
      throw const FormatException(
        'Recommendation batch identity and metadata must be paired.',
      );
    }
    final brief = switch (json['brief']) {
      final Map value => ReadingFeedBriefSummary.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException('Invalid reading-feed brief binding.'),
    };
    final serverTime = _requiredUtcDate(json, 'server_time');

    final uniquePapers = <String>{};
    DateTime? previousSavedAt;
    DateTime? previousPublishedAt;
    String? previousPaperId;
    ReadingFeedRecommendationMode? pageRecommendationMode;
    for (final item in items) {
      if (!uniquePapers.add(item.paper.paperId)) {
        throw const FormatException('Duplicate reading-feed paper.');
      }
      switch (mode) {
        case ReadingFeedServerMode.toRead:
          final queue = item.queue;
          if (decision.activeToReadCount == 0 ||
              decision.queueProvenEmpty ||
              batchId != null ||
              queue == null ||
              item.source != ReadingFeedItemSource.toRead ||
              item.recommendation != null ||
              queue.revision > decision.libraryRevision) {
            throw const FormatException('Invalid To Read feed page.');
          }
          if (previousSavedAt != null &&
              (queue.savedAt.isBefore(previousSavedAt) ||
                  (queue.savedAt.isAtSameMomentAs(previousSavedAt) &&
                      item.paper.paperId.compareTo(previousPaperId!) <= 0))) {
            throw const FormatException('To Read feed is not FIFO ordered.');
          }
          previousSavedAt = queue.savedAt;
          previousPaperId = item.paper.paperId;
        case ReadingFeedServerMode.recommendations:
          if (!decision.queueProvenEmpty ||
              decision.activeToReadCount != 0 ||
              item.queue != null) {
            throw const FormatException('Invalid recommendation feed page.');
          }
          final recommendation = item.recommendation;
          if (batchId == null) {
            if (item.source != ReadingFeedItemSource.discoveryV1 ||
                recommendation != null) {
              throw const FormatException(
                'Legacy recommendations cannot claim batch provenance.',
              );
            }
            if (previousPublishedAt != null &&
                !_isDescendingPaperOrder(
                  previousPublishedAt: previousPublishedAt,
                  previousPaperId: previousPaperId!,
                  nextPublishedAt: item.paper.publishedAt,
                  nextPaperId: item.paper.paperId,
                )) {
              throw const FormatException(
                'Recommendation feed is not chronologically ordered.',
              );
            }
            previousPublishedAt = item.paper.publishedAt;
            previousPaperId = item.paper.paperId;
          } else {
            final sourceMode = item.source.recommendationMode;
            if (!item.source.isPersonalizedRecommendation ||
                recommendation == null ||
                recommendation.mode != sourceMode ||
                (pageRecommendationMode != null &&
                    recommendation.mode != pageRecommendationMode)) {
              throw const FormatException(
                'Personalized recommendation provenance does not match.',
              );
            }
            pageRecommendationMode ??= recommendation.mode;
          }
      }
    }
    if (mode == ReadingFeedServerMode.toRead &&
            decision.activeToReadCount == 0 ||
        mode == ReadingFeedServerMode.recommendations &&
            !decision.queueProvenEmpty) {
      throw const FormatException('Reading-feed mode contradicts decision.');
    }
    if (mode == ReadingFeedServerMode.toRead && batchId != null) {
      throw const FormatException('Invalid reading-feed batch envelope.');
    }
    return ReadingFeedPage(
      enforcement: enforcement,
      mode: mode,
      decision: decision,
      batchId: batchId,
      batchMetadata: batchMetadata,
      brief: brief,
      items: items,
      nextCursor: nextCursor,
      serverTime: serverTime,
    );
  }

  List<PaperSummary> get papers =>
      items.map((item) => item.paper).toList(growable: false);

  Map<String, Object?> toJson() => {
    'enforcement': switch (enforcement) {
      ReadingFeedEnforcement.shadow => 'shadow',
      ReadingFeedEnforcement.strict => 'strict',
    },
    'mode': switch (mode) {
      ReadingFeedServerMode.toRead => 'to_read',
      ReadingFeedServerMode.recommendations => 'recommendations',
    },
    'decision': decision.toJson(),
    'batch_id': batchId,
    'batch_metadata': batchMetadata?.toJson(),
    'brief': brief?.toJson(),
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'next_cursor': nextCursor,
    'server_time': serverTime.toUtc().toIso8601String(),
  };
}

bool _isDescendingPaperOrder({
  required DateTime previousPublishedAt,
  required String previousPaperId,
  required DateTime nextPublishedAt,
  required String nextPaperId,
}) {
  return nextPublishedAt.isBefore(previousPublishedAt) ||
      (nextPublishedAt.isAtSameMomentAs(previousPublishedAt) &&
          nextPaperId.compareTo(previousPaperId) < 0);
}

final class ReadingFeedState {
  const ReadingFeedState({
    this.mode = ReadingFeedMode.checkingQueue,
    this.queueAuthority = QueueAuthority.unknown,
    this.items = const [],
    this.queueItems = const [],
    this.recommendationItems = const [],
    this.recommendationProvenance = const [],
    this.recommendationBatchId,
    this.recommendationMode,
    this.forYouAvailable = false,
    this.libraryRevision,
    this.activeToReadCount,
    this.nextCursor,
    this.loadingInitial = true,
    this.loadingMore = false,
    this.offline = false,
    this.recoverableError,
    this.authEpoch = 0,
    this.accountGeneration = 0,
    this.accountScopeFingerprint,
    this.serverEnforcement,
  });

  final ReadingFeedMode mode;
  final QueueAuthority queueAuthority;
  final List<PaperSummary> items;
  final List<ReadingFeedQueuePresentation> queueItems;
  final List<ReadingFeedItem> recommendationItems;
  final List<ReadingFeedRecommendationProvenance?> recommendationProvenance;

  /// The batch shared by every visible recommendation, when homogeneous.
  /// Cursor walks spanning multiple server batches use per-item provenance.
  final String? recommendationBatchId;
  final ReadingFeedRecommendationMode? recommendationMode;
  final bool forYouAvailable;
  final int? libraryRevision;
  final int? activeToReadCount;
  final String? nextCursor;
  final bool loadingInitial;
  final bool loadingMore;
  final bool offline;
  final Object? recoverableError;
  final int authEpoch;
  final int accountGeneration;
  final String? accountScopeFingerprint;
  final ReadingFeedEnforcement? serverEnforcement;

  bool get recommendationsVisible =>
      mode == ReadingFeedMode.recommendations &&
      queueAuthority == QueueAuthority.serverConfirmedEmpty;

  ReadingFeedQueuePresentation? queueItemAt(int index) {
    if ((mode != ReadingFeedMode.toRead &&
            mode != ReadingFeedMode.checkingQueue &&
            mode != ReadingFeedMode.unavailable) ||
        index < 0 ||
        index >= items.length ||
        queueItems.length != items.length) {
      return null;
    }
    final item = queueItems[index];
    return item.paper.paperId == items[index].paperId ? item : null;
  }

  ReadingFeedItem? recommendationItemAt(int index) {
    if (!recommendationsVisible ||
        index < 0 ||
        index >= items.length ||
        recommendationItems.length != items.length) {
      return null;
    }
    final item = recommendationItems[index];
    return item.paper.paperId == items[index].paperId ? item : null;
  }

  ReadingFeedRecommendationProvenance? recommendationProvenanceAt(int index) {
    if (recommendationItemAt(index) == null ||
        recommendationProvenance.isEmpty) {
      return null;
    }
    if (recommendationProvenance.length != items.length) return null;
    final provenance = recommendationProvenance[index];
    return provenance?.paperId == items[index].paperId ? provenance : null;
  }

  String? recommendationBatchIdAt(int index) =>
      recommendationProvenanceAt(index)?.batchId ??
      (recommendationItemAt(index) == null ? null : recommendationBatchId);

  int? recommendationPositionAt(int index) =>
      recommendationProvenanceAt(index)?.rerankedPosition ??
      (recommendationItemAt(index) == null ? null : index);
}

DateTime _requiredUtcDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 64) {
    throw FormatException('Invalid $key.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !value.endsWith('Z')) {
    throw FormatException('Invalid $key.');
  }
  return parsed.toUtc();
}

String? _optionalBoundedString(
  Map<String, dynamic> json,
  String key,
  int maximumLength,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

LibrarySaveSourceKind? _optionalSaveSourceKind(Object? value) =>
    switch (value) {
      null => null,
      'discovery' => LibrarySaveSourceKind.discovery,
      'lookup' => LibrarySaveSourceKind.lookup,
      'title_search' => LibrarySaveSourceKind.titleSearch,
      'arxiv_url' => LibrarySaveSourceKind.arxivUrl,
      'arxiv_id' => LibrarySaveSourceKind.arxivId,
      'connection' => LibrarySaveSourceKind.connection,
      'other' => LibrarySaveSourceKind.other,
      // A future source is unknown, not the explicit `other` provenance.
      _ => null,
    };

String _requiredDisplayString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.trim() != value ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any(
        (rune) =>
            (rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
            rune == 0x7f,
      )) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String _requiredBatchVersion(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !_batchVersion.hasMatch(value)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String? _optionalUuid(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || !_uuid.hasMatch(value)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected reading-feed fields.');
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _batchVersion = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
