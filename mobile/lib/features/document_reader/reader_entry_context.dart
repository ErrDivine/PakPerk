enum ReaderEntrySource {
  queue,
  recommendation,
  library,
  search,
  connection,
  memory,
  publicDiscovery,
  external;

  String get wireValue => switch (this) {
    ReaderEntrySource.queue => 'queue',
    ReaderEntrySource.recommendation => 'recommendation',
    ReaderEntrySource.library => 'library',
    ReaderEntrySource.search => 'search',
    ReaderEntrySource.connection => 'connection',
    ReaderEntrySource.memory => 'memory',
    ReaderEntrySource.publicDiscovery => 'public_discovery',
    ReaderEntrySource.external => 'external',
  };

  static ReaderEntrySource fromWire(Object? value) => switch (value) {
    'queue' => ReaderEntrySource.queue,
    'recommendation' => ReaderEntrySource.recommendation,
    'library' => ReaderEntrySource.library,
    'search' => ReaderEntrySource.search,
    'connection' => ReaderEntrySource.connection,
    'memory' => ReaderEntrySource.memory,
    'public_discovery' => ReaderEntrySource.publicDiscovery,
    _ => ReaderEntrySource.external,
  };
}

enum ReaderQueueMembership {
  inToRead,
  outsideToRead,
  unknown;

  String get wireValue => switch (this) {
    ReaderQueueMembership.inToRead => 'in_to_read',
    ReaderQueueMembership.outsideToRead => 'outside_to_read',
    ReaderQueueMembership.unknown => 'unknown',
  };

  static ReaderQueueMembership fromWire(Object? value) => switch (value) {
    'in_to_read' => ReaderQueueMembership.inToRead,
    'outside_to_read' => ReaderQueueMembership.outsideToRead,
    _ => ReaderQueueMembership.unknown,
  };
}

/// Restorable provenance for opening one paper reader.
///
/// This object describes navigation only. It deliberately carries no Library
/// state mutation and no account identifier. Numeric auth/account generations
/// are stale-response fences, never authority on their own.
final class ReaderEntryContext {
  const ReaderEntryContext({
    required this.source,
    required this.queueMembership,
    this.originReaderKey,
    this.expectedAuthEpoch,
    this.accountGeneration,
    this.libraryRevision,
    this.recommendationBatchId,
  }) : assert(expectedAuthEpoch == null || expectedAuthEpoch >= 0),
       assert(accountGeneration == null || accountGeneration >= 0),
       assert(libraryRevision == null || libraryRevision >= 0);

  const ReaderEntryContext.external()
    : this(
        source: ReaderEntrySource.external,
        queueMembership: ReaderQueueMembership.unknown,
      );

  const ReaderEntryContext.library()
    : this(
        source: ReaderEntrySource.library,
        queueMembership: ReaderQueueMembership.inToRead,
      );

  const ReaderEntryContext.search()
    : this(
        source: ReaderEntrySource.search,
        queueMembership: ReaderQueueMembership.outsideToRead,
      );

  const ReaderEntryContext.memory({String? originReaderKey})
    : this(
        source: ReaderEntrySource.memory,
        // Memory review can resurface an active, Reviewed, or Archived paper.
        // The memory endpoint is not Library authority, so it must not guess.
        queueMembership: ReaderQueueMembership.unknown,
        originReaderKey: originReaderKey,
      );

  const ReaderEntryContext.publicDiscovery()
    : this(
        source: ReaderEntrySource.publicDiscovery,
        queueMembership: ReaderQueueMembership.outsideToRead,
      );

  const ReaderEntryContext.connection({String? originReaderKey})
    : this(
        source: ReaderEntrySource.connection,
        queueMembership: ReaderQueueMembership.outsideToRead,
        originReaderKey: originReaderKey,
      );

  const ReaderEntryContext.queue({
    required int expectedAuthEpoch,
    required int accountGeneration,
    int? libraryRevision,
  }) : this(
         source: ReaderEntrySource.queue,
         queueMembership: ReaderQueueMembership.inToRead,
         expectedAuthEpoch: expectedAuthEpoch,
         accountGeneration: accountGeneration,
         libraryRevision: libraryRevision,
       );

  const ReaderEntryContext.recommendation({
    required int expectedAuthEpoch,
    required int accountGeneration,
    required String recommendationBatchId,
    int? libraryRevision,
  }) : this(
         source: ReaderEntrySource.recommendation,
         queueMembership: ReaderQueueMembership.outsideToRead,
         expectedAuthEpoch: expectedAuthEpoch,
         accountGeneration: accountGeneration,
         libraryRevision: libraryRevision,
         recommendationBatchId: recommendationBatchId,
       );

  final ReaderEntrySource source;
  final ReaderQueueMembership queueMembership;
  final String? originReaderKey;
  final int? expectedAuthEpoch;
  final int? accountGeneration;
  final int? libraryRevision;
  final String? recommendationBatchId;

  bool get belongsToAutomaticFeed =>
      source == ReaderEntrySource.queue ||
      source == ReaderEntrySource.recommendation ||
      source == ReaderEntrySource.publicDiscovery;

  bool get isExplicitBranch => !belongsToAutomaticFeed;

  bool matchesScope({required int authEpoch, required int generation}) {
    return (expectedAuthEpoch == null || expectedAuthEpoch == authEpoch) &&
        (accountGeneration == null || accountGeneration == generation);
  }

  ReaderEntryContext copyWith({
    ReaderQueueMembership? queueMembership,
    int? libraryRevision,
  }) => ReaderEntryContext(
    source: source,
    queueMembership: queueMembership ?? this.queueMembership,
    originReaderKey: originReaderKey,
    expectedAuthEpoch: expectedAuthEpoch,
    accountGeneration: accountGeneration,
    libraryRevision: libraryRevision ?? this.libraryRevision,
    recommendationBatchId: recommendationBatchId,
  );

  factory ReaderEntryContext.fromJson(Map<String, dynamic> json) {
    int? nonNegativeInt(String key) {
      final value = (json[key] as num?)?.toInt();
      return value != null && value >= 0 ? value : null;
    }

    final origin = json['origin_reader_key']?.toString().trim();
    final batch = json['recommendation_batch_id']?.toString().trim();
    return ReaderEntryContext(
      source: ReaderEntrySource.fromWire(json['source']),
      queueMembership: ReaderQueueMembership.fromWire(json['queue_membership']),
      originReaderKey: origin?.isNotEmpty == true ? origin : null,
      expectedAuthEpoch: nonNegativeInt('expected_auth_epoch'),
      accountGeneration: nonNegativeInt('account_generation'),
      libraryRevision: nonNegativeInt('library_revision'),
      recommendationBatchId: batch?.isNotEmpty == true ? batch : null,
    );
  }

  Map<String, Object?> toJson() => {
    'source': source.wireValue,
    'queue_membership': queueMembership.wireValue,
    if (originReaderKey != null) 'origin_reader_key': originReaderKey,
    if (expectedAuthEpoch != null) 'expected_auth_epoch': expectedAuthEpoch,
    if (accountGeneration != null) 'account_generation': accountGeneration,
    if (libraryRevision != null) 'library_revision': libraryRevision,
    if (recommendationBatchId != null)
      'recommendation_batch_id': recommendationBatchId,
  };
}
