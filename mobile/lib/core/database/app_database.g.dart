// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $CachedPapersTable extends CachedPapers
    with TableInfo<$CachedPapersTable, CachedPaperRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedPapersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _arxivBaseIdMeta = const VerificationMeta(
    'arxivBaseId',
  );
  @override
  late final GeneratedColumn<String> arxivBaseId = GeneratedColumn<String>(
    'arxiv_base_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _arxivVersionMeta = const VerificationMeta(
    'arxivVersion',
  );
  @override
  late final GeneratedColumn<int> arxivVersion = GeneratedColumn<int>(
    'arxiv_version',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _metadataJsonMeta = const VerificationMeta(
    'metadataJson',
  );
  @override
  late final GeneratedColumn<String> metadataJson = GeneratedColumn<String>(
    'metadata_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _publishedAtMeta = const VerificationMeta(
    'publishedAt',
  );
  @override
  late final GeneratedColumn<DateTime> publishedAt = GeneratedColumn<DateTime>(
    'published_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAccessedAtMeta = const VerificationMeta(
    'lastAccessedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastAccessedAt =
      GeneratedColumn<DateTime>(
        'last_accessed_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pinnedByLibraryMeta = const VerificationMeta(
    'pinnedByLibrary',
  );
  @override
  late final GeneratedColumn<bool> pinnedByLibrary = GeneratedColumn<bool>(
    'pinned_by_library',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned_by_library" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    paperId,
    arxivBaseId,
    arxivVersion,
    metadataJson,
    publishedAt,
    updatedAt,
    lastAccessedAt,
    expiresAt,
    pinnedByLibrary,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_papers';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedPaperRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('arxiv_base_id')) {
      context.handle(
        _arxivBaseIdMeta,
        arxivBaseId.isAcceptableOrUnknown(
          data['arxiv_base_id']!,
          _arxivBaseIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_arxivBaseIdMeta);
    }
    if (data.containsKey('arxiv_version')) {
      context.handle(
        _arxivVersionMeta,
        arxivVersion.isAcceptableOrUnknown(
          data['arxiv_version']!,
          _arxivVersionMeta,
        ),
      );
    }
    if (data.containsKey('metadata_json')) {
      context.handle(
        _metadataJsonMeta,
        metadataJson.isAcceptableOrUnknown(
          data['metadata_json']!,
          _metadataJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataJsonMeta);
    }
    if (data.containsKey('published_at')) {
      context.handle(
        _publishedAtMeta,
        publishedAt.isAcceptableOrUnknown(
          data['published_at']!,
          _publishedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_publishedAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('last_accessed_at')) {
      context.handle(
        _lastAccessedAtMeta,
        lastAccessedAt.isAcceptableOrUnknown(
          data['last_accessed_at']!,
          _lastAccessedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastAccessedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    if (data.containsKey('pinned_by_library')) {
      context.handle(
        _pinnedByLibraryMeta,
        pinnedByLibrary.isAcceptableOrUnknown(
          data['pinned_by_library']!,
          _pinnedByLibraryMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {paperId};
  @override
  CachedPaperRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedPaperRow(
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      arxivBaseId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}arxiv_base_id'],
      )!,
      arxivVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}arxiv_version'],
      ),
      metadataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_json'],
      )!,
      publishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}published_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      lastAccessedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_accessed_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
      pinnedByLibrary: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned_by_library'],
      )!,
    );
  }

  @override
  $CachedPapersTable createAlias(String alias) {
    return $CachedPapersTable(attachedDatabase, alias);
  }
}

class CachedPaperRow extends DataClass implements Insertable<CachedPaperRow> {
  final String paperId;
  final String arxivBaseId;
  final int? arxivVersion;
  final String metadataJson;
  final DateTime publishedAt;
  final DateTime updatedAt;
  final DateTime lastAccessedAt;
  final DateTime expiresAt;
  final bool pinnedByLibrary;
  const CachedPaperRow({
    required this.paperId,
    required this.arxivBaseId,
    this.arxivVersion,
    required this.metadataJson,
    required this.publishedAt,
    required this.updatedAt,
    required this.lastAccessedAt,
    required this.expiresAt,
    required this.pinnedByLibrary,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['paper_id'] = Variable<String>(paperId);
    map['arxiv_base_id'] = Variable<String>(arxivBaseId);
    if (!nullToAbsent || arxivVersion != null) {
      map['arxiv_version'] = Variable<int>(arxivVersion);
    }
    map['metadata_json'] = Variable<String>(metadataJson);
    map['published_at'] = Variable<DateTime>(publishedAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    map['pinned_by_library'] = Variable<bool>(pinnedByLibrary);
    return map;
  }

  CachedPapersCompanion toCompanion(bool nullToAbsent) {
    return CachedPapersCompanion(
      paperId: Value(paperId),
      arxivBaseId: Value(arxivBaseId),
      arxivVersion: arxivVersion == null && nullToAbsent
          ? const Value.absent()
          : Value(arxivVersion),
      metadataJson: Value(metadataJson),
      publishedAt: Value(publishedAt),
      updatedAt: Value(updatedAt),
      lastAccessedAt: Value(lastAccessedAt),
      expiresAt: Value(expiresAt),
      pinnedByLibrary: Value(pinnedByLibrary),
    );
  }

  factory CachedPaperRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedPaperRow(
      paperId: serializer.fromJson<String>(json['paperId']),
      arxivBaseId: serializer.fromJson<String>(json['arxivBaseId']),
      arxivVersion: serializer.fromJson<int?>(json['arxivVersion']),
      metadataJson: serializer.fromJson<String>(json['metadataJson']),
      publishedAt: serializer.fromJson<DateTime>(json['publishedAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      lastAccessedAt: serializer.fromJson<DateTime>(json['lastAccessedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
      pinnedByLibrary: serializer.fromJson<bool>(json['pinnedByLibrary']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'paperId': serializer.toJson<String>(paperId),
      'arxivBaseId': serializer.toJson<String>(arxivBaseId),
      'arxivVersion': serializer.toJson<int?>(arxivVersion),
      'metadataJson': serializer.toJson<String>(metadataJson),
      'publishedAt': serializer.toJson<DateTime>(publishedAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'lastAccessedAt': serializer.toJson<DateTime>(lastAccessedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
      'pinnedByLibrary': serializer.toJson<bool>(pinnedByLibrary),
    };
  }

  CachedPaperRow copyWith({
    String? paperId,
    String? arxivBaseId,
    Value<int?> arxivVersion = const Value.absent(),
    String? metadataJson,
    DateTime? publishedAt,
    DateTime? updatedAt,
    DateTime? lastAccessedAt,
    DateTime? expiresAt,
    bool? pinnedByLibrary,
  }) => CachedPaperRow(
    paperId: paperId ?? this.paperId,
    arxivBaseId: arxivBaseId ?? this.arxivBaseId,
    arxivVersion: arxivVersion.present ? arxivVersion.value : this.arxivVersion,
    metadataJson: metadataJson ?? this.metadataJson,
    publishedAt: publishedAt ?? this.publishedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    pinnedByLibrary: pinnedByLibrary ?? this.pinnedByLibrary,
  );
  CachedPaperRow copyWithCompanion(CachedPapersCompanion data) {
    return CachedPaperRow(
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      arxivBaseId: data.arxivBaseId.present
          ? data.arxivBaseId.value
          : this.arxivBaseId,
      arxivVersion: data.arxivVersion.present
          ? data.arxivVersion.value
          : this.arxivVersion,
      metadataJson: data.metadataJson.present
          ? data.metadataJson.value
          : this.metadataJson,
      publishedAt: data.publishedAt.present
          ? data.publishedAt.value
          : this.publishedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      lastAccessedAt: data.lastAccessedAt.present
          ? data.lastAccessedAt.value
          : this.lastAccessedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      pinnedByLibrary: data.pinnedByLibrary.present
          ? data.pinnedByLibrary.value
          : this.pinnedByLibrary,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedPaperRow(')
          ..write('paperId: $paperId, ')
          ..write('arxivBaseId: $arxivBaseId, ')
          ..write('arxivVersion: $arxivVersion, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('publishedAt: $publishedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('pinnedByLibrary: $pinnedByLibrary')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    paperId,
    arxivBaseId,
    arxivVersion,
    metadataJson,
    publishedAt,
    updatedAt,
    lastAccessedAt,
    expiresAt,
    pinnedByLibrary,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedPaperRow &&
          other.paperId == this.paperId &&
          other.arxivBaseId == this.arxivBaseId &&
          other.arxivVersion == this.arxivVersion &&
          other.metadataJson == this.metadataJson &&
          other.publishedAt == this.publishedAt &&
          other.updatedAt == this.updatedAt &&
          other.lastAccessedAt == this.lastAccessedAt &&
          other.expiresAt == this.expiresAt &&
          other.pinnedByLibrary == this.pinnedByLibrary);
}

class CachedPapersCompanion extends UpdateCompanion<CachedPaperRow> {
  final Value<String> paperId;
  final Value<String> arxivBaseId;
  final Value<int?> arxivVersion;
  final Value<String> metadataJson;
  final Value<DateTime> publishedAt;
  final Value<DateTime> updatedAt;
  final Value<DateTime> lastAccessedAt;
  final Value<DateTime> expiresAt;
  final Value<bool> pinnedByLibrary;
  final Value<int> rowid;
  const CachedPapersCompanion({
    this.paperId = const Value.absent(),
    this.arxivBaseId = const Value.absent(),
    this.arxivVersion = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.publishedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastAccessedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.pinnedByLibrary = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedPapersCompanion.insert({
    required String paperId,
    required String arxivBaseId,
    this.arxivVersion = const Value.absent(),
    required String metadataJson,
    required DateTime publishedAt,
    required DateTime updatedAt,
    required DateTime lastAccessedAt,
    required DateTime expiresAt,
    this.pinnedByLibrary = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : paperId = Value(paperId),
       arxivBaseId = Value(arxivBaseId),
       metadataJson = Value(metadataJson),
       publishedAt = Value(publishedAt),
       updatedAt = Value(updatedAt),
       lastAccessedAt = Value(lastAccessedAt),
       expiresAt = Value(expiresAt);
  static Insertable<CachedPaperRow> custom({
    Expression<String>? paperId,
    Expression<String>? arxivBaseId,
    Expression<int>? arxivVersion,
    Expression<String>? metadataJson,
    Expression<DateTime>? publishedAt,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? lastAccessedAt,
    Expression<DateTime>? expiresAt,
    Expression<bool>? pinnedByLibrary,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (paperId != null) 'paper_id': paperId,
      if (arxivBaseId != null) 'arxiv_base_id': arxivBaseId,
      if (arxivVersion != null) 'arxiv_version': arxivVersion,
      if (metadataJson != null) 'metadata_json': metadataJson,
      if (publishedAt != null) 'published_at': publishedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (lastAccessedAt != null) 'last_accessed_at': lastAccessedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (pinnedByLibrary != null) 'pinned_by_library': pinnedByLibrary,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedPapersCompanion copyWith({
    Value<String>? paperId,
    Value<String>? arxivBaseId,
    Value<int?>? arxivVersion,
    Value<String>? metadataJson,
    Value<DateTime>? publishedAt,
    Value<DateTime>? updatedAt,
    Value<DateTime>? lastAccessedAt,
    Value<DateTime>? expiresAt,
    Value<bool>? pinnedByLibrary,
    Value<int>? rowid,
  }) {
    return CachedPapersCompanion(
      paperId: paperId ?? this.paperId,
      arxivBaseId: arxivBaseId ?? this.arxivBaseId,
      arxivVersion: arxivVersion ?? this.arxivVersion,
      metadataJson: metadataJson ?? this.metadataJson,
      publishedAt: publishedAt ?? this.publishedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      pinnedByLibrary: pinnedByLibrary ?? this.pinnedByLibrary,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (arxivBaseId.present) {
      map['arxiv_base_id'] = Variable<String>(arxivBaseId.value);
    }
    if (arxivVersion.present) {
      map['arxiv_version'] = Variable<int>(arxivVersion.value);
    }
    if (metadataJson.present) {
      map['metadata_json'] = Variable<String>(metadataJson.value);
    }
    if (publishedAt.present) {
      map['published_at'] = Variable<DateTime>(publishedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (lastAccessedAt.present) {
      map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (pinnedByLibrary.present) {
      map['pinned_by_library'] = Variable<bool>(pinnedByLibrary.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedPapersCompanion(')
          ..write('paperId: $paperId, ')
          ..write('arxivBaseId: $arxivBaseId, ')
          ..write('arxivVersion: $arxivVersion, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('publishedAt: $publishedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('pinnedByLibrary: $pinnedByLibrary, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FeedQueriesTable extends FeedQueries
    with TableInfo<$FeedQueriesTable, FeedQueryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FeedQueriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _queryKeyMeta = const VerificationMeta(
    'queryKey',
  );
  @override
  late final GeneratedColumn<String> queryKey = GeneratedColumn<String>(
    'query_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextCursorMeta = const VerificationMeta(
    'nextCursor',
  );
  @override
  late final GeneratedColumn<String> nextCursor = GeneratedColumn<String>(
    'next_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _refreshedAtMeta = const VerificationMeta(
    'refreshedAt',
  );
  @override
  late final GeneratedColumn<DateTime> refreshedAt = GeneratedColumn<DateTime>(
    'refreshed_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _exhaustedMeta = const VerificationMeta(
    'exhausted',
  );
  @override
  late final GeneratedColumn<bool> exhausted = GeneratedColumn<bool>(
    'exhausted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exhausted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _entryCountMeta = const VerificationMeta(
    'entryCount',
  );
  @override
  late final GeneratedColumn<int> entryCount = GeneratedColumn<int>(
    'entry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    queryKey,
    category,
    nextCursor,
    refreshedAt,
    exhausted,
    etag,
    entryCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'feed_queries';
  @override
  VerificationContext validateIntegrity(
    Insertable<FeedQueryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('query_key')) {
      context.handle(
        _queryKeyMeta,
        queryKey.isAcceptableOrUnknown(data['query_key']!, _queryKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_queryKeyMeta);
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('next_cursor')) {
      context.handle(
        _nextCursorMeta,
        nextCursor.isAcceptableOrUnknown(data['next_cursor']!, _nextCursorMeta),
      );
    }
    if (data.containsKey('refreshed_at')) {
      context.handle(
        _refreshedAtMeta,
        refreshedAt.isAcceptableOrUnknown(
          data['refreshed_at']!,
          _refreshedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_refreshedAtMeta);
    }
    if (data.containsKey('exhausted')) {
      context.handle(
        _exhaustedMeta,
        exhausted.isAcceptableOrUnknown(data['exhausted']!, _exhaustedMeta),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('entry_count')) {
      context.handle(
        _entryCountMeta,
        entryCount.isAcceptableOrUnknown(data['entry_count']!, _entryCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {queryKey};
  @override
  FeedQueryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FeedQueryRow(
      queryKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}query_key'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      ),
      nextCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}next_cursor'],
      ),
      refreshedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}refreshed_at'],
      )!,
      exhausted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exhausted'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      entryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}entry_count'],
      )!,
    );
  }

  @override
  $FeedQueriesTable createAlias(String alias) {
    return $FeedQueriesTable(attachedDatabase, alias);
  }
}

class FeedQueryRow extends DataClass implements Insertable<FeedQueryRow> {
  final String queryKey;
  final String? category;
  final String? nextCursor;
  final DateTime refreshedAt;
  final bool exhausted;
  final String? etag;
  final int entryCount;
  const FeedQueryRow({
    required this.queryKey,
    this.category,
    this.nextCursor,
    required this.refreshedAt,
    required this.exhausted,
    this.etag,
    required this.entryCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['query_key'] = Variable<String>(queryKey);
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || nextCursor != null) {
      map['next_cursor'] = Variable<String>(nextCursor);
    }
    map['refreshed_at'] = Variable<DateTime>(refreshedAt);
    map['exhausted'] = Variable<bool>(exhausted);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    map['entry_count'] = Variable<int>(entryCount);
    return map;
  }

  FeedQueriesCompanion toCompanion(bool nullToAbsent) {
    return FeedQueriesCompanion(
      queryKey: Value(queryKey),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      nextCursor: nextCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(nextCursor),
      refreshedAt: Value(refreshedAt),
      exhausted: Value(exhausted),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      entryCount: Value(entryCount),
    );
  }

  factory FeedQueryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FeedQueryRow(
      queryKey: serializer.fromJson<String>(json['queryKey']),
      category: serializer.fromJson<String?>(json['category']),
      nextCursor: serializer.fromJson<String?>(json['nextCursor']),
      refreshedAt: serializer.fromJson<DateTime>(json['refreshedAt']),
      exhausted: serializer.fromJson<bool>(json['exhausted']),
      etag: serializer.fromJson<String?>(json['etag']),
      entryCount: serializer.fromJson<int>(json['entryCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'queryKey': serializer.toJson<String>(queryKey),
      'category': serializer.toJson<String?>(category),
      'nextCursor': serializer.toJson<String?>(nextCursor),
      'refreshedAt': serializer.toJson<DateTime>(refreshedAt),
      'exhausted': serializer.toJson<bool>(exhausted),
      'etag': serializer.toJson<String?>(etag),
      'entryCount': serializer.toJson<int>(entryCount),
    };
  }

  FeedQueryRow copyWith({
    String? queryKey,
    Value<String?> category = const Value.absent(),
    Value<String?> nextCursor = const Value.absent(),
    DateTime? refreshedAt,
    bool? exhausted,
    Value<String?> etag = const Value.absent(),
    int? entryCount,
  }) => FeedQueryRow(
    queryKey: queryKey ?? this.queryKey,
    category: category.present ? category.value : this.category,
    nextCursor: nextCursor.present ? nextCursor.value : this.nextCursor,
    refreshedAt: refreshedAt ?? this.refreshedAt,
    exhausted: exhausted ?? this.exhausted,
    etag: etag.present ? etag.value : this.etag,
    entryCount: entryCount ?? this.entryCount,
  );
  FeedQueryRow copyWithCompanion(FeedQueriesCompanion data) {
    return FeedQueryRow(
      queryKey: data.queryKey.present ? data.queryKey.value : this.queryKey,
      category: data.category.present ? data.category.value : this.category,
      nextCursor: data.nextCursor.present
          ? data.nextCursor.value
          : this.nextCursor,
      refreshedAt: data.refreshedAt.present
          ? data.refreshedAt.value
          : this.refreshedAt,
      exhausted: data.exhausted.present ? data.exhausted.value : this.exhausted,
      etag: data.etag.present ? data.etag.value : this.etag,
      entryCount: data.entryCount.present
          ? data.entryCount.value
          : this.entryCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FeedQueryRow(')
          ..write('queryKey: $queryKey, ')
          ..write('category: $category, ')
          ..write('nextCursor: $nextCursor, ')
          ..write('refreshedAt: $refreshedAt, ')
          ..write('exhausted: $exhausted, ')
          ..write('etag: $etag, ')
          ..write('entryCount: $entryCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    queryKey,
    category,
    nextCursor,
    refreshedAt,
    exhausted,
    etag,
    entryCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FeedQueryRow &&
          other.queryKey == this.queryKey &&
          other.category == this.category &&
          other.nextCursor == this.nextCursor &&
          other.refreshedAt == this.refreshedAt &&
          other.exhausted == this.exhausted &&
          other.etag == this.etag &&
          other.entryCount == this.entryCount);
}

class FeedQueriesCompanion extends UpdateCompanion<FeedQueryRow> {
  final Value<String> queryKey;
  final Value<String?> category;
  final Value<String?> nextCursor;
  final Value<DateTime> refreshedAt;
  final Value<bool> exhausted;
  final Value<String?> etag;
  final Value<int> entryCount;
  final Value<int> rowid;
  const FeedQueriesCompanion({
    this.queryKey = const Value.absent(),
    this.category = const Value.absent(),
    this.nextCursor = const Value.absent(),
    this.refreshedAt = const Value.absent(),
    this.exhausted = const Value.absent(),
    this.etag = const Value.absent(),
    this.entryCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FeedQueriesCompanion.insert({
    required String queryKey,
    this.category = const Value.absent(),
    this.nextCursor = const Value.absent(),
    required DateTime refreshedAt,
    this.exhausted = const Value.absent(),
    this.etag = const Value.absent(),
    this.entryCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : queryKey = Value(queryKey),
       refreshedAt = Value(refreshedAt);
  static Insertable<FeedQueryRow> custom({
    Expression<String>? queryKey,
    Expression<String>? category,
    Expression<String>? nextCursor,
    Expression<DateTime>? refreshedAt,
    Expression<bool>? exhausted,
    Expression<String>? etag,
    Expression<int>? entryCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (queryKey != null) 'query_key': queryKey,
      if (category != null) 'category': category,
      if (nextCursor != null) 'next_cursor': nextCursor,
      if (refreshedAt != null) 'refreshed_at': refreshedAt,
      if (exhausted != null) 'exhausted': exhausted,
      if (etag != null) 'etag': etag,
      if (entryCount != null) 'entry_count': entryCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FeedQueriesCompanion copyWith({
    Value<String>? queryKey,
    Value<String?>? category,
    Value<String?>? nextCursor,
    Value<DateTime>? refreshedAt,
    Value<bool>? exhausted,
    Value<String?>? etag,
    Value<int>? entryCount,
    Value<int>? rowid,
  }) {
    return FeedQueriesCompanion(
      queryKey: queryKey ?? this.queryKey,
      category: category ?? this.category,
      nextCursor: nextCursor ?? this.nextCursor,
      refreshedAt: refreshedAt ?? this.refreshedAt,
      exhausted: exhausted ?? this.exhausted,
      etag: etag ?? this.etag,
      entryCount: entryCount ?? this.entryCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (queryKey.present) {
      map['query_key'] = Variable<String>(queryKey.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (nextCursor.present) {
      map['next_cursor'] = Variable<String>(nextCursor.value);
    }
    if (refreshedAt.present) {
      map['refreshed_at'] = Variable<DateTime>(refreshedAt.value);
    }
    if (exhausted.present) {
      map['exhausted'] = Variable<bool>(exhausted.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (entryCount.present) {
      map['entry_count'] = Variable<int>(entryCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FeedQueriesCompanion(')
          ..write('queryKey: $queryKey, ')
          ..write('category: $category, ')
          ..write('nextCursor: $nextCursor, ')
          ..write('refreshedAt: $refreshedAt, ')
          ..write('exhausted: $exhausted, ')
          ..write('etag: $etag, ')
          ..write('entryCount: $entryCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FeedEntriesTable extends FeedEntries
    with TableInfo<$FeedEntriesTable, FeedEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FeedEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _queryKeyMeta = const VerificationMeta(
    'queryKey',
  );
  @override
  late final GeneratedColumn<String> queryKey = GeneratedColumn<String>(
    'query_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES feed_queries (query_key) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _insertedAtMeta = const VerificationMeta(
    'insertedAt',
  );
  @override
  late final GeneratedColumn<DateTime> insertedAt = GeneratedColumn<DateTime>(
    'inserted_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    queryKey,
    position,
    paperId,
    insertedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'feed_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<FeedEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('query_key')) {
      context.handle(
        _queryKeyMeta,
        queryKey.isAcceptableOrUnknown(data['query_key']!, _queryKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_queryKeyMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('inserted_at')) {
      context.handle(
        _insertedAtMeta,
        insertedAt.isAcceptableOrUnknown(data['inserted_at']!, _insertedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_insertedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {queryKey, paperId};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {queryKey, position},
  ];
  @override
  FeedEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FeedEntryRow(
      queryKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}query_key'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      insertedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}inserted_at'],
      )!,
    );
  }

  @override
  $FeedEntriesTable createAlias(String alias) {
    return $FeedEntriesTable(attachedDatabase, alias);
  }
}

class FeedEntryRow extends DataClass implements Insertable<FeedEntryRow> {
  final String queryKey;
  final int position;
  final String paperId;
  final DateTime insertedAt;
  const FeedEntryRow({
    required this.queryKey,
    required this.position,
    required this.paperId,
    required this.insertedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['query_key'] = Variable<String>(queryKey);
    map['position'] = Variable<int>(position);
    map['paper_id'] = Variable<String>(paperId);
    map['inserted_at'] = Variable<DateTime>(insertedAt);
    return map;
  }

  FeedEntriesCompanion toCompanion(bool nullToAbsent) {
    return FeedEntriesCompanion(
      queryKey: Value(queryKey),
      position: Value(position),
      paperId: Value(paperId),
      insertedAt: Value(insertedAt),
    );
  }

  factory FeedEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FeedEntryRow(
      queryKey: serializer.fromJson<String>(json['queryKey']),
      position: serializer.fromJson<int>(json['position']),
      paperId: serializer.fromJson<String>(json['paperId']),
      insertedAt: serializer.fromJson<DateTime>(json['insertedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'queryKey': serializer.toJson<String>(queryKey),
      'position': serializer.toJson<int>(position),
      'paperId': serializer.toJson<String>(paperId),
      'insertedAt': serializer.toJson<DateTime>(insertedAt),
    };
  }

  FeedEntryRow copyWith({
    String? queryKey,
    int? position,
    String? paperId,
    DateTime? insertedAt,
  }) => FeedEntryRow(
    queryKey: queryKey ?? this.queryKey,
    position: position ?? this.position,
    paperId: paperId ?? this.paperId,
    insertedAt: insertedAt ?? this.insertedAt,
  );
  FeedEntryRow copyWithCompanion(FeedEntriesCompanion data) {
    return FeedEntryRow(
      queryKey: data.queryKey.present ? data.queryKey.value : this.queryKey,
      position: data.position.present ? data.position.value : this.position,
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      insertedAt: data.insertedAt.present
          ? data.insertedAt.value
          : this.insertedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FeedEntryRow(')
          ..write('queryKey: $queryKey, ')
          ..write('position: $position, ')
          ..write('paperId: $paperId, ')
          ..write('insertedAt: $insertedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(queryKey, position, paperId, insertedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FeedEntryRow &&
          other.queryKey == this.queryKey &&
          other.position == this.position &&
          other.paperId == this.paperId &&
          other.insertedAt == this.insertedAt);
}

class FeedEntriesCompanion extends UpdateCompanion<FeedEntryRow> {
  final Value<String> queryKey;
  final Value<int> position;
  final Value<String> paperId;
  final Value<DateTime> insertedAt;
  final Value<int> rowid;
  const FeedEntriesCompanion({
    this.queryKey = const Value.absent(),
    this.position = const Value.absent(),
    this.paperId = const Value.absent(),
    this.insertedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FeedEntriesCompanion.insert({
    required String queryKey,
    required int position,
    required String paperId,
    required DateTime insertedAt,
    this.rowid = const Value.absent(),
  }) : queryKey = Value(queryKey),
       position = Value(position),
       paperId = Value(paperId),
       insertedAt = Value(insertedAt);
  static Insertable<FeedEntryRow> custom({
    Expression<String>? queryKey,
    Expression<int>? position,
    Expression<String>? paperId,
    Expression<DateTime>? insertedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (queryKey != null) 'query_key': queryKey,
      if (position != null) 'position': position,
      if (paperId != null) 'paper_id': paperId,
      if (insertedAt != null) 'inserted_at': insertedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FeedEntriesCompanion copyWith({
    Value<String>? queryKey,
    Value<int>? position,
    Value<String>? paperId,
    Value<DateTime>? insertedAt,
    Value<int>? rowid,
  }) {
    return FeedEntriesCompanion(
      queryKey: queryKey ?? this.queryKey,
      position: position ?? this.position,
      paperId: paperId ?? this.paperId,
      insertedAt: insertedAt ?? this.insertedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (queryKey.present) {
      map['query_key'] = Variable<String>(queryKey.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (insertedAt.present) {
      map['inserted_at'] = Variable<DateTime>(insertedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FeedEntriesCompanion(')
          ..write('queryKey: $queryKey, ')
          ..write('position: $position, ')
          ..write('paperId: $paperId, ')
          ..write('insertedAt: $insertedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedProcessingTable extends CachedProcessing
    with TableInfo<$CachedProcessingTable, CachedProcessingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedProcessingTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _versionKeyMeta = const VerificationMeta(
    'versionKey',
  );
  @override
  late final GeneratedColumn<String> versionKey = GeneratedColumn<String>(
    'version_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_processing';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedProcessingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('version_key')) {
      context.handle(
        _versionKeyMeta,
        versionKey.isAcceptableOrUnknown(data['version_key']!, _versionKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_versionKeyMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {paperId};
  @override
  CachedProcessingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedProcessingRow(
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      versionKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_key'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      ),
    );
  }

  @override
  $CachedProcessingTable createAlias(String alias) {
    return $CachedProcessingTable(attachedDatabase, alias);
  }
}

class CachedProcessingRow extends DataClass
    implements Insertable<CachedProcessingRow> {
  final String paperId;
  final String versionKey;
  final int generation;
  final String payloadJson;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  const CachedProcessingRow({
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.payloadJson,
    required this.updatedAt,
    this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['paper_id'] = Variable<String>(paperId);
    map['version_key'] = Variable<String>(versionKey);
    map['generation'] = Variable<int>(generation);
    map['payload_json'] = Variable<String>(payloadJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<DateTime>(expiresAt);
    }
    return map;
  }

  CachedProcessingCompanion toCompanion(bool nullToAbsent) {
    return CachedProcessingCompanion(
      paperId: Value(paperId),
      versionKey: Value(versionKey),
      generation: Value(generation),
      payloadJson: Value(payloadJson),
      updatedAt: Value(updatedAt),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
    );
  }

  factory CachedProcessingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedProcessingRow(
      paperId: serializer.fromJson<String>(json['paperId']),
      versionKey: serializer.fromJson<String>(json['versionKey']),
      generation: serializer.fromJson<int>(json['generation']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      expiresAt: serializer.fromJson<DateTime?>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'paperId': serializer.toJson<String>(paperId),
      'versionKey': serializer.toJson<String>(versionKey),
      'generation': serializer.toJson<int>(generation),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'expiresAt': serializer.toJson<DateTime?>(expiresAt),
    };
  }

  CachedProcessingRow copyWith({
    String? paperId,
    String? versionKey,
    int? generation,
    String? payloadJson,
    DateTime? updatedAt,
    Value<DateTime?> expiresAt = const Value.absent(),
  }) => CachedProcessingRow(
    paperId: paperId ?? this.paperId,
    versionKey: versionKey ?? this.versionKey,
    generation: generation ?? this.generation,
    payloadJson: payloadJson ?? this.payloadJson,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
  );
  CachedProcessingRow copyWithCompanion(CachedProcessingCompanion data) {
    return CachedProcessingRow(
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      versionKey: data.versionKey.present
          ? data.versionKey.value
          : this.versionKey,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedProcessingRow(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedProcessingRow &&
          other.paperId == this.paperId &&
          other.versionKey == this.versionKey &&
          other.generation == this.generation &&
          other.payloadJson == this.payloadJson &&
          other.updatedAt == this.updatedAt &&
          other.expiresAt == this.expiresAt);
}

class CachedProcessingCompanion extends UpdateCompanion<CachedProcessingRow> {
  final Value<String> paperId;
  final Value<String> versionKey;
  final Value<int> generation;
  final Value<String> payloadJson;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> expiresAt;
  final Value<int> rowid;
  const CachedProcessingCompanion({
    this.paperId = const Value.absent(),
    this.versionKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedProcessingCompanion.insert({
    required String paperId,
    required String versionKey,
    this.generation = const Value.absent(),
    required String payloadJson,
    required DateTime updatedAt,
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : paperId = Value(paperId),
       versionKey = Value(versionKey),
       payloadJson = Value(payloadJson),
       updatedAt = Value(updatedAt);
  static Insertable<CachedProcessingRow> custom({
    Expression<String>? paperId,
    Expression<String>? versionKey,
    Expression<int>? generation,
    Expression<String>? payloadJson,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (paperId != null) 'paper_id': paperId,
      if (versionKey != null) 'version_key': versionKey,
      if (generation != null) 'generation': generation,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedProcessingCompanion copyWith({
    Value<String>? paperId,
    Value<String>? versionKey,
    Value<int>? generation,
    Value<String>? payloadJson,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? expiresAt,
    Value<int>? rowid,
  }) {
    return CachedProcessingCompanion(
      paperId: paperId ?? this.paperId,
      versionKey: versionKey ?? this.versionKey,
      generation: generation ?? this.generation,
      payloadJson: payloadJson ?? this.payloadJson,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (versionKey.present) {
      map['version_key'] = Variable<String>(versionKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedProcessingCompanion(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedIntroductionsTable extends CachedIntroductions
    with TableInfo<$CachedIntroductionsTable, CachedIntroductionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedIntroductionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _versionKeyMeta = const VerificationMeta(
    'versionKey',
  );
  @override
  late final GeneratedColumn<String> versionKey = GeneratedColumn<String>(
    'version_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_introductions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedIntroductionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('version_key')) {
      context.handle(
        _versionKeyMeta,
        versionKey.isAcceptableOrUnknown(data['version_key']!, _versionKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_versionKeyMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    } else if (isInserting) {
      context.missing(_generationMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {paperId};
  @override
  CachedIntroductionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedIntroductionRow(
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      versionKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_key'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      ),
    );
  }

  @override
  $CachedIntroductionsTable createAlias(String alias) {
    return $CachedIntroductionsTable(attachedDatabase, alias);
  }
}

class CachedIntroductionRow extends DataClass
    implements Insertable<CachedIntroductionRow> {
  final String paperId;
  final String versionKey;
  final int generation;
  final String payloadJson;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  const CachedIntroductionRow({
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.payloadJson,
    required this.updatedAt,
    this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['paper_id'] = Variable<String>(paperId);
    map['version_key'] = Variable<String>(versionKey);
    map['generation'] = Variable<int>(generation);
    map['payload_json'] = Variable<String>(payloadJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<DateTime>(expiresAt);
    }
    return map;
  }

  CachedIntroductionsCompanion toCompanion(bool nullToAbsent) {
    return CachedIntroductionsCompanion(
      paperId: Value(paperId),
      versionKey: Value(versionKey),
      generation: Value(generation),
      payloadJson: Value(payloadJson),
      updatedAt: Value(updatedAt),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
    );
  }

  factory CachedIntroductionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedIntroductionRow(
      paperId: serializer.fromJson<String>(json['paperId']),
      versionKey: serializer.fromJson<String>(json['versionKey']),
      generation: serializer.fromJson<int>(json['generation']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      expiresAt: serializer.fromJson<DateTime?>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'paperId': serializer.toJson<String>(paperId),
      'versionKey': serializer.toJson<String>(versionKey),
      'generation': serializer.toJson<int>(generation),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'expiresAt': serializer.toJson<DateTime?>(expiresAt),
    };
  }

  CachedIntroductionRow copyWith({
    String? paperId,
    String? versionKey,
    int? generation,
    String? payloadJson,
    DateTime? updatedAt,
    Value<DateTime?> expiresAt = const Value.absent(),
  }) => CachedIntroductionRow(
    paperId: paperId ?? this.paperId,
    versionKey: versionKey ?? this.versionKey,
    generation: generation ?? this.generation,
    payloadJson: payloadJson ?? this.payloadJson,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
  );
  CachedIntroductionRow copyWithCompanion(CachedIntroductionsCompanion data) {
    return CachedIntroductionRow(
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      versionKey: data.versionKey.present
          ? data.versionKey.value
          : this.versionKey,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedIntroductionRow(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedIntroductionRow &&
          other.paperId == this.paperId &&
          other.versionKey == this.versionKey &&
          other.generation == this.generation &&
          other.payloadJson == this.payloadJson &&
          other.updatedAt == this.updatedAt &&
          other.expiresAt == this.expiresAt);
}

class CachedIntroductionsCompanion
    extends UpdateCompanion<CachedIntroductionRow> {
  final Value<String> paperId;
  final Value<String> versionKey;
  final Value<int> generation;
  final Value<String> payloadJson;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> expiresAt;
  final Value<int> rowid;
  const CachedIntroductionsCompanion({
    this.paperId = const Value.absent(),
    this.versionKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedIntroductionsCompanion.insert({
    required String paperId,
    required String versionKey,
    required int generation,
    required String payloadJson,
    required DateTime updatedAt,
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : paperId = Value(paperId),
       versionKey = Value(versionKey),
       generation = Value(generation),
       payloadJson = Value(payloadJson),
       updatedAt = Value(updatedAt);
  static Insertable<CachedIntroductionRow> custom({
    Expression<String>? paperId,
    Expression<String>? versionKey,
    Expression<int>? generation,
    Expression<String>? payloadJson,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (paperId != null) 'paper_id': paperId,
      if (versionKey != null) 'version_key': versionKey,
      if (generation != null) 'generation': generation,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedIntroductionsCompanion copyWith({
    Value<String>? paperId,
    Value<String>? versionKey,
    Value<int>? generation,
    Value<String>? payloadJson,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? expiresAt,
    Value<int>? rowid,
  }) {
    return CachedIntroductionsCompanion(
      paperId: paperId ?? this.paperId,
      versionKey: versionKey ?? this.versionKey,
      generation: generation ?? this.generation,
      payloadJson: payloadJson ?? this.payloadJson,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (versionKey.present) {
      map['version_key'] = Variable<String>(versionKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedIntroductionsCompanion(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedConnectionsTable extends CachedConnections
    with TableInfo<$CachedConnectionsTable, CachedConnectionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedConnectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _versionKeyMeta = const VerificationMeta(
    'versionKey',
  );
  @override
  late final GeneratedColumn<String> versionKey = GeneratedColumn<String>(
    'version_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_connections';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedConnectionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('version_key')) {
      context.handle(
        _versionKeyMeta,
        versionKey.isAcceptableOrUnknown(data['version_key']!, _versionKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_versionKeyMeta);
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {paperId};
  @override
  CachedConnectionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedConnectionRow(
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      versionKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_key'],
      )!,
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      ),
    );
  }

  @override
  $CachedConnectionsTable createAlias(String alias) {
    return $CachedConnectionsTable(attachedDatabase, alias);
  }
}

class CachedConnectionRow extends DataClass
    implements Insertable<CachedConnectionRow> {
  final String paperId;
  final String versionKey;
  final int generation;
  final String payloadJson;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  const CachedConnectionRow({
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.payloadJson,
    required this.updatedAt,
    this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['paper_id'] = Variable<String>(paperId);
    map['version_key'] = Variable<String>(versionKey);
    map['generation'] = Variable<int>(generation);
    map['payload_json'] = Variable<String>(payloadJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<DateTime>(expiresAt);
    }
    return map;
  }

  CachedConnectionsCompanion toCompanion(bool nullToAbsent) {
    return CachedConnectionsCompanion(
      paperId: Value(paperId),
      versionKey: Value(versionKey),
      generation: Value(generation),
      payloadJson: Value(payloadJson),
      updatedAt: Value(updatedAt),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
    );
  }

  factory CachedConnectionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedConnectionRow(
      paperId: serializer.fromJson<String>(json['paperId']),
      versionKey: serializer.fromJson<String>(json['versionKey']),
      generation: serializer.fromJson<int>(json['generation']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      expiresAt: serializer.fromJson<DateTime?>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'paperId': serializer.toJson<String>(paperId),
      'versionKey': serializer.toJson<String>(versionKey),
      'generation': serializer.toJson<int>(generation),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'expiresAt': serializer.toJson<DateTime?>(expiresAt),
    };
  }

  CachedConnectionRow copyWith({
    String? paperId,
    String? versionKey,
    int? generation,
    String? payloadJson,
    DateTime? updatedAt,
    Value<DateTime?> expiresAt = const Value.absent(),
  }) => CachedConnectionRow(
    paperId: paperId ?? this.paperId,
    versionKey: versionKey ?? this.versionKey,
    generation: generation ?? this.generation,
    payloadJson: payloadJson ?? this.payloadJson,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
  );
  CachedConnectionRow copyWithCompanion(CachedConnectionsCompanion data) {
    return CachedConnectionRow(
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      versionKey: data.versionKey.present
          ? data.versionKey.value
          : this.versionKey,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedConnectionRow(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedConnectionRow &&
          other.paperId == this.paperId &&
          other.versionKey == this.versionKey &&
          other.generation == this.generation &&
          other.payloadJson == this.payloadJson &&
          other.updatedAt == this.updatedAt &&
          other.expiresAt == this.expiresAt);
}

class CachedConnectionsCompanion extends UpdateCompanion<CachedConnectionRow> {
  final Value<String> paperId;
  final Value<String> versionKey;
  final Value<int> generation;
  final Value<String> payloadJson;
  final Value<DateTime> updatedAt;
  final Value<DateTime?> expiresAt;
  final Value<int> rowid;
  const CachedConnectionsCompanion({
    this.paperId = const Value.absent(),
    this.versionKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedConnectionsCompanion.insert({
    required String paperId,
    required String versionKey,
    this.generation = const Value.absent(),
    required String payloadJson,
    required DateTime updatedAt,
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : paperId = Value(paperId),
       versionKey = Value(versionKey),
       payloadJson = Value(payloadJson),
       updatedAt = Value(updatedAt);
  static Insertable<CachedConnectionRow> custom({
    Expression<String>? paperId,
    Expression<String>? versionKey,
    Expression<int>? generation,
    Expression<String>? payloadJson,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (paperId != null) 'paper_id': paperId,
      if (versionKey != null) 'version_key': versionKey,
      if (generation != null) 'generation': generation,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedConnectionsCompanion copyWith({
    Value<String>? paperId,
    Value<String>? versionKey,
    Value<int>? generation,
    Value<String>? payloadJson,
    Value<DateTime>? updatedAt,
    Value<DateTime?>? expiresAt,
    Value<int>? rowid,
  }) {
    return CachedConnectionsCompanion(
      paperId: paperId ?? this.paperId,
      versionKey: versionKey ?? this.versionKey,
      generation: generation ?? this.generation,
      payloadJson: payloadJson ?? this.payloadJson,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (versionKey.present) {
      map['version_key'] = Variable<String>(versionKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedConnectionsCompanion(')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedCommentPagesTable extends CachedCommentPages
    with TableInfo<$CachedCommentPagesTable, CachedCommentPageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedCommentPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _pageKeyMeta = const VerificationMeta(
    'pageKey',
  );
  @override
  late final GeneratedColumn<String> pageKey = GeneratedColumn<String>(
    'page_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _viewerAccountIdMeta = const VerificationMeta(
    'viewerAccountId',
  );
  @override
  late final GeneratedColumn<String> viewerAccountId = GeneratedColumn<String>(
    'viewer_account_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fetchedAtMeta = const VerificationMeta(
    'fetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
    'fetched_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    pageKey,
    paperId,
    viewerAccountId,
    cursor,
    payloadJson,
    fetchedAt,
    expiresAt,
    etag,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_comment_pages';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedCommentPageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('page_key')) {
      context.handle(
        _pageKeyMeta,
        pageKey.isAcceptableOrUnknown(data['page_key']!, _pageKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_pageKeyMeta);
    }
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('viewer_account_id')) {
      context.handle(
        _viewerAccountIdMeta,
        viewerAccountId.isAcceptableOrUnknown(
          data['viewer_account_id']!,
          _viewerAccountIdMeta,
        ),
      );
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(
        _fetchedAtMeta,
        fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {pageKey};
  @override
  CachedCommentPageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedCommentPageRow(
      pageKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_key'],
      )!,
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      viewerAccountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}viewer_account_id'],
      ),
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      fetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}fetched_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
    );
  }

  @override
  $CachedCommentPagesTable createAlias(String alias) {
    return $CachedCommentPagesTable(attachedDatabase, alias);
  }
}

class CachedCommentPageRow extends DataClass
    implements Insertable<CachedCommentPageRow> {
  final String pageKey;
  final String paperId;
  final String? viewerAccountId;
  final String? cursor;
  final String payloadJson;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  final String? etag;
  const CachedCommentPageRow({
    required this.pageKey,
    required this.paperId,
    this.viewerAccountId,
    this.cursor,
    required this.payloadJson,
    required this.fetchedAt,
    required this.expiresAt,
    this.etag,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['page_key'] = Variable<String>(pageKey);
    map['paper_id'] = Variable<String>(paperId);
    if (!nullToAbsent || viewerAccountId != null) {
      map['viewer_account_id'] = Variable<String>(viewerAccountId);
    }
    if (!nullToAbsent || cursor != null) {
      map['cursor'] = Variable<String>(cursor);
    }
    map['payload_json'] = Variable<String>(payloadJson);
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    return map;
  }

  CachedCommentPagesCompanion toCompanion(bool nullToAbsent) {
    return CachedCommentPagesCompanion(
      pageKey: Value(pageKey),
      paperId: Value(paperId),
      viewerAccountId: viewerAccountId == null && nullToAbsent
          ? const Value.absent()
          : Value(viewerAccountId),
      cursor: cursor == null && nullToAbsent
          ? const Value.absent()
          : Value(cursor),
      payloadJson: Value(payloadJson),
      fetchedAt: Value(fetchedAt),
      expiresAt: Value(expiresAt),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
    );
  }

  factory CachedCommentPageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedCommentPageRow(
      pageKey: serializer.fromJson<String>(json['pageKey']),
      paperId: serializer.fromJson<String>(json['paperId']),
      viewerAccountId: serializer.fromJson<String?>(json['viewerAccountId']),
      cursor: serializer.fromJson<String?>(json['cursor']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
      etag: serializer.fromJson<String?>(json['etag']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'pageKey': serializer.toJson<String>(pageKey),
      'paperId': serializer.toJson<String>(paperId),
      'viewerAccountId': serializer.toJson<String?>(viewerAccountId),
      'cursor': serializer.toJson<String?>(cursor),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
      'etag': serializer.toJson<String?>(etag),
    };
  }

  CachedCommentPageRow copyWith({
    String? pageKey,
    String? paperId,
    Value<String?> viewerAccountId = const Value.absent(),
    Value<String?> cursor = const Value.absent(),
    String? payloadJson,
    DateTime? fetchedAt,
    DateTime? expiresAt,
    Value<String?> etag = const Value.absent(),
  }) => CachedCommentPageRow(
    pageKey: pageKey ?? this.pageKey,
    paperId: paperId ?? this.paperId,
    viewerAccountId: viewerAccountId.present
        ? viewerAccountId.value
        : this.viewerAccountId,
    cursor: cursor.present ? cursor.value : this.cursor,
    payloadJson: payloadJson ?? this.payloadJson,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    etag: etag.present ? etag.value : this.etag,
  );
  CachedCommentPageRow copyWithCompanion(CachedCommentPagesCompanion data) {
    return CachedCommentPageRow(
      pageKey: data.pageKey.present ? data.pageKey.value : this.pageKey,
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      viewerAccountId: data.viewerAccountId.present
          ? data.viewerAccountId.value
          : this.viewerAccountId,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      etag: data.etag.present ? data.etag.value : this.etag,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedCommentPageRow(')
          ..write('pageKey: $pageKey, ')
          ..write('paperId: $paperId, ')
          ..write('viewerAccountId: $viewerAccountId, ')
          ..write('cursor: $cursor, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('etag: $etag')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    pageKey,
    paperId,
    viewerAccountId,
    cursor,
    payloadJson,
    fetchedAt,
    expiresAt,
    etag,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedCommentPageRow &&
          other.pageKey == this.pageKey &&
          other.paperId == this.paperId &&
          other.viewerAccountId == this.viewerAccountId &&
          other.cursor == this.cursor &&
          other.payloadJson == this.payloadJson &&
          other.fetchedAt == this.fetchedAt &&
          other.expiresAt == this.expiresAt &&
          other.etag == this.etag);
}

class CachedCommentPagesCompanion
    extends UpdateCompanion<CachedCommentPageRow> {
  final Value<String> pageKey;
  final Value<String> paperId;
  final Value<String?> viewerAccountId;
  final Value<String?> cursor;
  final Value<String> payloadJson;
  final Value<DateTime> fetchedAt;
  final Value<DateTime> expiresAt;
  final Value<String?> etag;
  final Value<int> rowid;
  const CachedCommentPagesCompanion({
    this.pageKey = const Value.absent(),
    this.paperId = const Value.absent(),
    this.viewerAccountId = const Value.absent(),
    this.cursor = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.etag = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedCommentPagesCompanion.insert({
    required String pageKey,
    required String paperId,
    this.viewerAccountId = const Value.absent(),
    this.cursor = const Value.absent(),
    required String payloadJson,
    required DateTime fetchedAt,
    required DateTime expiresAt,
    this.etag = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : pageKey = Value(pageKey),
       paperId = Value(paperId),
       payloadJson = Value(payloadJson),
       fetchedAt = Value(fetchedAt),
       expiresAt = Value(expiresAt);
  static Insertable<CachedCommentPageRow> custom({
    Expression<String>? pageKey,
    Expression<String>? paperId,
    Expression<String>? viewerAccountId,
    Expression<String>? cursor,
    Expression<String>? payloadJson,
    Expression<DateTime>? fetchedAt,
    Expression<DateTime>? expiresAt,
    Expression<String>? etag,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (pageKey != null) 'page_key': pageKey,
      if (paperId != null) 'paper_id': paperId,
      if (viewerAccountId != null) 'viewer_account_id': viewerAccountId,
      if (cursor != null) 'cursor': cursor,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (etag != null) 'etag': etag,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedCommentPagesCompanion copyWith({
    Value<String>? pageKey,
    Value<String>? paperId,
    Value<String?>? viewerAccountId,
    Value<String?>? cursor,
    Value<String>? payloadJson,
    Value<DateTime>? fetchedAt,
    Value<DateTime>? expiresAt,
    Value<String?>? etag,
    Value<int>? rowid,
  }) {
    return CachedCommentPagesCompanion(
      pageKey: pageKey ?? this.pageKey,
      paperId: paperId ?? this.paperId,
      viewerAccountId: viewerAccountId ?? this.viewerAccountId,
      cursor: cursor ?? this.cursor,
      payloadJson: payloadJson ?? this.payloadJson,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      etag: etag ?? this.etag,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (pageKey.present) {
      map['page_key'] = Variable<String>(pageKey.value);
    }
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (viewerAccountId.present) {
      map['viewer_account_id'] = Variable<String>(viewerAccountId.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedCommentPagesCompanion(')
          ..write('pageKey: $pageKey, ')
          ..write('paperId: $paperId, ')
          ..write('viewerAccountId: $viewerAccountId, ')
          ..write('cursor: $cursor, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('etag: $etag, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedChatsTable extends CachedChats
    with TableInfo<$CachedChatsTable, CachedChatRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _readerKeyMeta = const VerificationMeta(
    'readerKey',
  );
  @override
  late final GeneratedColumn<String> readerKey = GeneratedColumn<String>(
    'reader_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _versionKeyMeta = const VerificationMeta(
    'versionKey',
  );
  @override
  late final GeneratedColumn<String> versionKey = GeneratedColumn<String>(
    'version_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _generationMeta = const VerificationMeta(
    'generation',
  );
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
    'generation',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sessionId,
    readerKey,
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_chats';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedChatRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('reader_key')) {
      context.handle(
        _readerKeyMeta,
        readerKey.isAcceptableOrUnknown(data['reader_key']!, _readerKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_readerKeyMeta);
    }
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    }
    if (data.containsKey('version_key')) {
      context.handle(
        _versionKeyMeta,
        versionKey.isAcceptableOrUnknown(data['version_key']!, _versionKeyMeta),
      );
    }
    if (data.containsKey('generation')) {
      context.handle(
        _generationMeta,
        generation.isAcceptableOrUnknown(data['generation']!, _generationMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sessionId, readerKey};
  @override
  CachedChatRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedChatRow(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      readerKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reader_key'],
      )!,
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      ),
      versionKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_key'],
      ),
      generation: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generation'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
    );
  }

  @override
  $CachedChatsTable createAlias(String alias) {
    return $CachedChatsTable(attachedDatabase, alias);
  }
}

class CachedChatRow extends DataClass implements Insertable<CachedChatRow> {
  final String sessionId;
  final String readerKey;
  final String? paperId;
  final String? versionKey;
  final int generation;
  final String payloadJson;
  final DateTime updatedAt;
  final DateTime expiresAt;
  const CachedChatRow({
    required this.sessionId,
    required this.readerKey,
    this.paperId,
    this.versionKey,
    required this.generation,
    required this.payloadJson,
    required this.updatedAt,
    required this.expiresAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<String>(sessionId);
    map['reader_key'] = Variable<String>(readerKey);
    if (!nullToAbsent || paperId != null) {
      map['paper_id'] = Variable<String>(paperId);
    }
    if (!nullToAbsent || versionKey != null) {
      map['version_key'] = Variable<String>(versionKey);
    }
    map['generation'] = Variable<int>(generation);
    map['payload_json'] = Variable<String>(payloadJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    return map;
  }

  CachedChatsCompanion toCompanion(bool nullToAbsent) {
    return CachedChatsCompanion(
      sessionId: Value(sessionId),
      readerKey: Value(readerKey),
      paperId: paperId == null && nullToAbsent
          ? const Value.absent()
          : Value(paperId),
      versionKey: versionKey == null && nullToAbsent
          ? const Value.absent()
          : Value(versionKey),
      generation: Value(generation),
      payloadJson: Value(payloadJson),
      updatedAt: Value(updatedAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory CachedChatRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedChatRow(
      sessionId: serializer.fromJson<String>(json['sessionId']),
      readerKey: serializer.fromJson<String>(json['readerKey']),
      paperId: serializer.fromJson<String?>(json['paperId']),
      versionKey: serializer.fromJson<String?>(json['versionKey']),
      generation: serializer.fromJson<int>(json['generation']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<String>(sessionId),
      'readerKey': serializer.toJson<String>(readerKey),
      'paperId': serializer.toJson<String?>(paperId),
      'versionKey': serializer.toJson<String?>(versionKey),
      'generation': serializer.toJson<int>(generation),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
    };
  }

  CachedChatRow copyWith({
    String? sessionId,
    String? readerKey,
    Value<String?> paperId = const Value.absent(),
    Value<String?> versionKey = const Value.absent(),
    int? generation,
    String? payloadJson,
    DateTime? updatedAt,
    DateTime? expiresAt,
  }) => CachedChatRow(
    sessionId: sessionId ?? this.sessionId,
    readerKey: readerKey ?? this.readerKey,
    paperId: paperId.present ? paperId.value : this.paperId,
    versionKey: versionKey.present ? versionKey.value : this.versionKey,
    generation: generation ?? this.generation,
    payloadJson: payloadJson ?? this.payloadJson,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt ?? this.expiresAt,
  );
  CachedChatRow copyWithCompanion(CachedChatsCompanion data) {
    return CachedChatRow(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      readerKey: data.readerKey.present ? data.readerKey.value : this.readerKey,
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      versionKey: data.versionKey.present
          ? data.versionKey.value
          : this.versionKey,
      generation: data.generation.present
          ? data.generation.value
          : this.generation,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedChatRow(')
          ..write('sessionId: $sessionId, ')
          ..write('readerKey: $readerKey, ')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    readerKey,
    paperId,
    versionKey,
    generation,
    payloadJson,
    updatedAt,
    expiresAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedChatRow &&
          other.sessionId == this.sessionId &&
          other.readerKey == this.readerKey &&
          other.paperId == this.paperId &&
          other.versionKey == this.versionKey &&
          other.generation == this.generation &&
          other.payloadJson == this.payloadJson &&
          other.updatedAt == this.updatedAt &&
          other.expiresAt == this.expiresAt);
}

class CachedChatsCompanion extends UpdateCompanion<CachedChatRow> {
  final Value<String> sessionId;
  final Value<String> readerKey;
  final Value<String?> paperId;
  final Value<String?> versionKey;
  final Value<int> generation;
  final Value<String> payloadJson;
  final Value<DateTime> updatedAt;
  final Value<DateTime> expiresAt;
  final Value<int> rowid;
  const CachedChatsCompanion({
    this.sessionId = const Value.absent(),
    this.readerKey = const Value.absent(),
    this.paperId = const Value.absent(),
    this.versionKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedChatsCompanion.insert({
    required String sessionId,
    required String readerKey,
    this.paperId = const Value.absent(),
    this.versionKey = const Value.absent(),
    this.generation = const Value.absent(),
    required String payloadJson,
    required DateTime updatedAt,
    required DateTime expiresAt,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       readerKey = Value(readerKey),
       payloadJson = Value(payloadJson),
       updatedAt = Value(updatedAt),
       expiresAt = Value(expiresAt);
  static Insertable<CachedChatRow> custom({
    Expression<String>? sessionId,
    Expression<String>? readerKey,
    Expression<String>? paperId,
    Expression<String>? versionKey,
    Expression<int>? generation,
    Expression<String>? payloadJson,
    Expression<DateTime>? updatedAt,
    Expression<DateTime>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (readerKey != null) 'reader_key': readerKey,
      if (paperId != null) 'paper_id': paperId,
      if (versionKey != null) 'version_key': versionKey,
      if (generation != null) 'generation': generation,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedChatsCompanion copyWith({
    Value<String>? sessionId,
    Value<String>? readerKey,
    Value<String?>? paperId,
    Value<String?>? versionKey,
    Value<int>? generation,
    Value<String>? payloadJson,
    Value<DateTime>? updatedAt,
    Value<DateTime>? expiresAt,
    Value<int>? rowid,
  }) {
    return CachedChatsCompanion(
      sessionId: sessionId ?? this.sessionId,
      readerKey: readerKey ?? this.readerKey,
      paperId: paperId ?? this.paperId,
      versionKey: versionKey ?? this.versionKey,
      generation: generation ?? this.generation,
      payloadJson: payloadJson ?? this.payloadJson,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (readerKey.present) {
      map['reader_key'] = Variable<String>(readerKey.value);
    }
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (versionKey.present) {
      map['version_key'] = Variable<String>(versionKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedChatsCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('readerKey: $readerKey, ')
          ..write('paperId: $paperId, ')
          ..write('versionKey: $versionKey, ')
          ..write('generation: $generation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryItemsTable extends LibraryItems
    with TableInfo<$LibraryItemsTable, LibraryItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _listStateMeta = const VerificationMeta(
    'listState',
  );
  @override
  late final GeneratedColumn<String> listState = GeneratedColumn<String>(
    'list_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('to_read'),
  );
  static const VerificationMeta _clientUpdatedAtMeta = const VerificationMeta(
    'clientUpdatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> clientUpdatedAt =
      GeneratedColumn<DateTime>(
        'client_updated_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _serverUpdatedAtMeta = const VerificationMeta(
    'serverUpdatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> serverUpdatedAt =
      GeneratedColumn<DateTime>(
        'server_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _savedAtMeta = const VerificationMeta(
    'savedAt',
  );
  @override
  late final GeneratedColumn<DateTime> savedAt = GeneratedColumn<DateTime>(
    'saved_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _removedAtMeta = const VerificationMeta(
    'removedAt',
  );
  @override
  late final GeneratedColumn<DateTime> removedAt = GeneratedColumn<DateTime>(
    'removed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  @override
  late final GeneratedColumn<int> revision = GeneratedColumn<int>(
    'revision',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastOperationIdMeta = const VerificationMeta(
    'lastOperationId',
  );
  @override
  late final GeneratedColumn<String> lastOperationId = GeneratedColumn<String>(
    'last_operation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _canonicalDeletedMeta = const VerificationMeta(
    'canonicalDeleted',
  );
  @override
  late final GeneratedColumn<bool> canonicalDeleted = GeneratedColumn<bool>(
    'canonical_deleted',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("canonical_deleted" IN (0, 1))',
    ),
  );
  static const VerificationMeta _canonicalSavedAtMeta = const VerificationMeta(
    'canonicalSavedAt',
  );
  @override
  late final GeneratedColumn<DateTime> canonicalSavedAt =
      GeneratedColumn<DateTime>(
        'canonical_saved_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _canonicalRemovedAtMeta =
      const VerificationMeta('canonicalRemovedAt');
  @override
  late final GeneratedColumn<DateTime> canonicalRemovedAt =
      GeneratedColumn<DateTime>(
        'canonical_removed_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    paperId,
    listState,
    clientUpdatedAt,
    serverUpdatedAt,
    deleted,
    savedAt,
    removedAt,
    revision,
    lastOperationId,
    canonicalDeleted,
    canonicalSavedAt,
    canonicalRemovedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('list_state')) {
      context.handle(
        _listStateMeta,
        listState.isAcceptableOrUnknown(data['list_state']!, _listStateMeta),
      );
    }
    if (data.containsKey('client_updated_at')) {
      context.handle(
        _clientUpdatedAtMeta,
        clientUpdatedAt.isAcceptableOrUnknown(
          data['client_updated_at']!,
          _clientUpdatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_clientUpdatedAtMeta);
    }
    if (data.containsKey('server_updated_at')) {
      context.handle(
        _serverUpdatedAtMeta,
        serverUpdatedAt.isAcceptableOrUnknown(
          data['server_updated_at']!,
          _serverUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    if (data.containsKey('saved_at')) {
      context.handle(
        _savedAtMeta,
        savedAt.isAcceptableOrUnknown(data['saved_at']!, _savedAtMeta),
      );
    }
    if (data.containsKey('removed_at')) {
      context.handle(
        _removedAtMeta,
        removedAt.isAcceptableOrUnknown(data['removed_at']!, _removedAtMeta),
      );
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    }
    if (data.containsKey('last_operation_id')) {
      context.handle(
        _lastOperationIdMeta,
        lastOperationId.isAcceptableOrUnknown(
          data['last_operation_id']!,
          _lastOperationIdMeta,
        ),
      );
    }
    if (data.containsKey('canonical_deleted')) {
      context.handle(
        _canonicalDeletedMeta,
        canonicalDeleted.isAcceptableOrUnknown(
          data['canonical_deleted']!,
          _canonicalDeletedMeta,
        ),
      );
    }
    if (data.containsKey('canonical_saved_at')) {
      context.handle(
        _canonicalSavedAtMeta,
        canonicalSavedAt.isAcceptableOrUnknown(
          data['canonical_saved_at']!,
          _canonicalSavedAtMeta,
        ),
      );
    }
    if (data.containsKey('canonical_removed_at')) {
      context.handle(
        _canonicalRemovedAtMeta,
        canonicalRemovedAt.isAcceptableOrUnknown(
          data['canonical_removed_at']!,
          _canonicalRemovedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, paperId};
  @override
  LibraryItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryItemRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      listState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_state'],
      )!,
      clientUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}client_updated_at'],
      )!,
      serverUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}server_updated_at'],
      ),
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      savedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}saved_at'],
      ),
      removedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}removed_at'],
      ),
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}revision'],
      ),
      lastOperationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_operation_id'],
      ),
      canonicalDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}canonical_deleted'],
      ),
      canonicalSavedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}canonical_saved_at'],
      ),
      canonicalRemovedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}canonical_removed_at'],
      ),
    );
  }

  @override
  $LibraryItemsTable createAlias(String alias) {
    return $LibraryItemsTable(attachedDatabase, alias);
  }
}

class LibraryItemRow extends DataClass implements Insertable<LibraryItemRow> {
  final String accountId;
  final String paperId;
  final String listState;
  final DateTime clientUpdatedAt;
  final DateTime? serverUpdatedAt;
  final bool deleted;
  final DateTime? savedAt;
  final DateTime? removedAt;
  final int? revision;
  final String? lastOperationId;
  final bool? canonicalDeleted;
  final DateTime? canonicalSavedAt;
  final DateTime? canonicalRemovedAt;
  const LibraryItemRow({
    required this.accountId,
    required this.paperId,
    required this.listState,
    required this.clientUpdatedAt,
    this.serverUpdatedAt,
    required this.deleted,
    this.savedAt,
    this.removedAt,
    this.revision,
    this.lastOperationId,
    this.canonicalDeleted,
    this.canonicalSavedAt,
    this.canonicalRemovedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['paper_id'] = Variable<String>(paperId);
    map['list_state'] = Variable<String>(listState);
    map['client_updated_at'] = Variable<DateTime>(clientUpdatedAt);
    if (!nullToAbsent || serverUpdatedAt != null) {
      map['server_updated_at'] = Variable<DateTime>(serverUpdatedAt);
    }
    map['deleted'] = Variable<bool>(deleted);
    if (!nullToAbsent || savedAt != null) {
      map['saved_at'] = Variable<DateTime>(savedAt);
    }
    if (!nullToAbsent || removedAt != null) {
      map['removed_at'] = Variable<DateTime>(removedAt);
    }
    if (!nullToAbsent || revision != null) {
      map['revision'] = Variable<int>(revision);
    }
    if (!nullToAbsent || lastOperationId != null) {
      map['last_operation_id'] = Variable<String>(lastOperationId);
    }
    if (!nullToAbsent || canonicalDeleted != null) {
      map['canonical_deleted'] = Variable<bool>(canonicalDeleted);
    }
    if (!nullToAbsent || canonicalSavedAt != null) {
      map['canonical_saved_at'] = Variable<DateTime>(canonicalSavedAt);
    }
    if (!nullToAbsent || canonicalRemovedAt != null) {
      map['canonical_removed_at'] = Variable<DateTime>(canonicalRemovedAt);
    }
    return map;
  }

  LibraryItemsCompanion toCompanion(bool nullToAbsent) {
    return LibraryItemsCompanion(
      accountId: Value(accountId),
      paperId: Value(paperId),
      listState: Value(listState),
      clientUpdatedAt: Value(clientUpdatedAt),
      serverUpdatedAt: serverUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(serverUpdatedAt),
      deleted: Value(deleted),
      savedAt: savedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(savedAt),
      removedAt: removedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(removedAt),
      revision: revision == null && nullToAbsent
          ? const Value.absent()
          : Value(revision),
      lastOperationId: lastOperationId == null && nullToAbsent
          ? const Value.absent()
          : Value(lastOperationId),
      canonicalDeleted: canonicalDeleted == null && nullToAbsent
          ? const Value.absent()
          : Value(canonicalDeleted),
      canonicalSavedAt: canonicalSavedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(canonicalSavedAt),
      canonicalRemovedAt: canonicalRemovedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(canonicalRemovedAt),
    );
  }

  factory LibraryItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryItemRow(
      accountId: serializer.fromJson<String>(json['accountId']),
      paperId: serializer.fromJson<String>(json['paperId']),
      listState: serializer.fromJson<String>(json['listState']),
      clientUpdatedAt: serializer.fromJson<DateTime>(json['clientUpdatedAt']),
      serverUpdatedAt: serializer.fromJson<DateTime?>(json['serverUpdatedAt']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      savedAt: serializer.fromJson<DateTime?>(json['savedAt']),
      removedAt: serializer.fromJson<DateTime?>(json['removedAt']),
      revision: serializer.fromJson<int?>(json['revision']),
      lastOperationId: serializer.fromJson<String?>(json['lastOperationId']),
      canonicalDeleted: serializer.fromJson<bool?>(json['canonicalDeleted']),
      canonicalSavedAt: serializer.fromJson<DateTime?>(
        json['canonicalSavedAt'],
      ),
      canonicalRemovedAt: serializer.fromJson<DateTime?>(
        json['canonicalRemovedAt'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'paperId': serializer.toJson<String>(paperId),
      'listState': serializer.toJson<String>(listState),
      'clientUpdatedAt': serializer.toJson<DateTime>(clientUpdatedAt),
      'serverUpdatedAt': serializer.toJson<DateTime?>(serverUpdatedAt),
      'deleted': serializer.toJson<bool>(deleted),
      'savedAt': serializer.toJson<DateTime?>(savedAt),
      'removedAt': serializer.toJson<DateTime?>(removedAt),
      'revision': serializer.toJson<int?>(revision),
      'lastOperationId': serializer.toJson<String?>(lastOperationId),
      'canonicalDeleted': serializer.toJson<bool?>(canonicalDeleted),
      'canonicalSavedAt': serializer.toJson<DateTime?>(canonicalSavedAt),
      'canonicalRemovedAt': serializer.toJson<DateTime?>(canonicalRemovedAt),
    };
  }

  LibraryItemRow copyWith({
    String? accountId,
    String? paperId,
    String? listState,
    DateTime? clientUpdatedAt,
    Value<DateTime?> serverUpdatedAt = const Value.absent(),
    bool? deleted,
    Value<DateTime?> savedAt = const Value.absent(),
    Value<DateTime?> removedAt = const Value.absent(),
    Value<int?> revision = const Value.absent(),
    Value<String?> lastOperationId = const Value.absent(),
    Value<bool?> canonicalDeleted = const Value.absent(),
    Value<DateTime?> canonicalSavedAt = const Value.absent(),
    Value<DateTime?> canonicalRemovedAt = const Value.absent(),
  }) => LibraryItemRow(
    accountId: accountId ?? this.accountId,
    paperId: paperId ?? this.paperId,
    listState: listState ?? this.listState,
    clientUpdatedAt: clientUpdatedAt ?? this.clientUpdatedAt,
    serverUpdatedAt: serverUpdatedAt.present
        ? serverUpdatedAt.value
        : this.serverUpdatedAt,
    deleted: deleted ?? this.deleted,
    savedAt: savedAt.present ? savedAt.value : this.savedAt,
    removedAt: removedAt.present ? removedAt.value : this.removedAt,
    revision: revision.present ? revision.value : this.revision,
    lastOperationId: lastOperationId.present
        ? lastOperationId.value
        : this.lastOperationId,
    canonicalDeleted: canonicalDeleted.present
        ? canonicalDeleted.value
        : this.canonicalDeleted,
    canonicalSavedAt: canonicalSavedAt.present
        ? canonicalSavedAt.value
        : this.canonicalSavedAt,
    canonicalRemovedAt: canonicalRemovedAt.present
        ? canonicalRemovedAt.value
        : this.canonicalRemovedAt,
  );
  LibraryItemRow copyWithCompanion(LibraryItemsCompanion data) {
    return LibraryItemRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      listState: data.listState.present ? data.listState.value : this.listState,
      clientUpdatedAt: data.clientUpdatedAt.present
          ? data.clientUpdatedAt.value
          : this.clientUpdatedAt,
      serverUpdatedAt: data.serverUpdatedAt.present
          ? data.serverUpdatedAt.value
          : this.serverUpdatedAt,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      savedAt: data.savedAt.present ? data.savedAt.value : this.savedAt,
      removedAt: data.removedAt.present ? data.removedAt.value : this.removedAt,
      revision: data.revision.present ? data.revision.value : this.revision,
      lastOperationId: data.lastOperationId.present
          ? data.lastOperationId.value
          : this.lastOperationId,
      canonicalDeleted: data.canonicalDeleted.present
          ? data.canonicalDeleted.value
          : this.canonicalDeleted,
      canonicalSavedAt: data.canonicalSavedAt.present
          ? data.canonicalSavedAt.value
          : this.canonicalSavedAt,
      canonicalRemovedAt: data.canonicalRemovedAt.present
          ? data.canonicalRemovedAt.value
          : this.canonicalRemovedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemRow(')
          ..write('accountId: $accountId, ')
          ..write('paperId: $paperId, ')
          ..write('listState: $listState, ')
          ..write('clientUpdatedAt: $clientUpdatedAt, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('deleted: $deleted, ')
          ..write('savedAt: $savedAt, ')
          ..write('removedAt: $removedAt, ')
          ..write('revision: $revision, ')
          ..write('lastOperationId: $lastOperationId, ')
          ..write('canonicalDeleted: $canonicalDeleted, ')
          ..write('canonicalSavedAt: $canonicalSavedAt, ')
          ..write('canonicalRemovedAt: $canonicalRemovedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    paperId,
    listState,
    clientUpdatedAt,
    serverUpdatedAt,
    deleted,
    savedAt,
    removedAt,
    revision,
    lastOperationId,
    canonicalDeleted,
    canonicalSavedAt,
    canonicalRemovedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryItemRow &&
          other.accountId == this.accountId &&
          other.paperId == this.paperId &&
          other.listState == this.listState &&
          other.clientUpdatedAt == this.clientUpdatedAt &&
          other.serverUpdatedAt == this.serverUpdatedAt &&
          other.deleted == this.deleted &&
          other.savedAt == this.savedAt &&
          other.removedAt == this.removedAt &&
          other.revision == this.revision &&
          other.lastOperationId == this.lastOperationId &&
          other.canonicalDeleted == this.canonicalDeleted &&
          other.canonicalSavedAt == this.canonicalSavedAt &&
          other.canonicalRemovedAt == this.canonicalRemovedAt);
}

class LibraryItemsCompanion extends UpdateCompanion<LibraryItemRow> {
  final Value<String> accountId;
  final Value<String> paperId;
  final Value<String> listState;
  final Value<DateTime> clientUpdatedAt;
  final Value<DateTime?> serverUpdatedAt;
  final Value<bool> deleted;
  final Value<DateTime?> savedAt;
  final Value<DateTime?> removedAt;
  final Value<int?> revision;
  final Value<String?> lastOperationId;
  final Value<bool?> canonicalDeleted;
  final Value<DateTime?> canonicalSavedAt;
  final Value<DateTime?> canonicalRemovedAt;
  final Value<int> rowid;
  const LibraryItemsCompanion({
    this.accountId = const Value.absent(),
    this.paperId = const Value.absent(),
    this.listState = const Value.absent(),
    this.clientUpdatedAt = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.removedAt = const Value.absent(),
    this.revision = const Value.absent(),
    this.lastOperationId = const Value.absent(),
    this.canonicalDeleted = const Value.absent(),
    this.canonicalSavedAt = const Value.absent(),
    this.canonicalRemovedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryItemsCompanion.insert({
    required String accountId,
    required String paperId,
    this.listState = const Value.absent(),
    required DateTime clientUpdatedAt,
    this.serverUpdatedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.removedAt = const Value.absent(),
    this.revision = const Value.absent(),
    this.lastOperationId = const Value.absent(),
    this.canonicalDeleted = const Value.absent(),
    this.canonicalSavedAt = const Value.absent(),
    this.canonicalRemovedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       paperId = Value(paperId),
       clientUpdatedAt = Value(clientUpdatedAt);
  static Insertable<LibraryItemRow> custom({
    Expression<String>? accountId,
    Expression<String>? paperId,
    Expression<String>? listState,
    Expression<DateTime>? clientUpdatedAt,
    Expression<DateTime>? serverUpdatedAt,
    Expression<bool>? deleted,
    Expression<DateTime>? savedAt,
    Expression<DateTime>? removedAt,
    Expression<int>? revision,
    Expression<String>? lastOperationId,
    Expression<bool>? canonicalDeleted,
    Expression<DateTime>? canonicalSavedAt,
    Expression<DateTime>? canonicalRemovedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (paperId != null) 'paper_id': paperId,
      if (listState != null) 'list_state': listState,
      if (clientUpdatedAt != null) 'client_updated_at': clientUpdatedAt,
      if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
      if (deleted != null) 'deleted': deleted,
      if (savedAt != null) 'saved_at': savedAt,
      if (removedAt != null) 'removed_at': removedAt,
      if (revision != null) 'revision': revision,
      if (lastOperationId != null) 'last_operation_id': lastOperationId,
      if (canonicalDeleted != null) 'canonical_deleted': canonicalDeleted,
      if (canonicalSavedAt != null) 'canonical_saved_at': canonicalSavedAt,
      if (canonicalRemovedAt != null)
        'canonical_removed_at': canonicalRemovedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryItemsCompanion copyWith({
    Value<String>? accountId,
    Value<String>? paperId,
    Value<String>? listState,
    Value<DateTime>? clientUpdatedAt,
    Value<DateTime?>? serverUpdatedAt,
    Value<bool>? deleted,
    Value<DateTime?>? savedAt,
    Value<DateTime?>? removedAt,
    Value<int?>? revision,
    Value<String?>? lastOperationId,
    Value<bool?>? canonicalDeleted,
    Value<DateTime?>? canonicalSavedAt,
    Value<DateTime?>? canonicalRemovedAt,
    Value<int>? rowid,
  }) {
    return LibraryItemsCompanion(
      accountId: accountId ?? this.accountId,
      paperId: paperId ?? this.paperId,
      listState: listState ?? this.listState,
      clientUpdatedAt: clientUpdatedAt ?? this.clientUpdatedAt,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      deleted: deleted ?? this.deleted,
      savedAt: savedAt ?? this.savedAt,
      removedAt: removedAt ?? this.removedAt,
      revision: revision ?? this.revision,
      lastOperationId: lastOperationId ?? this.lastOperationId,
      canonicalDeleted: canonicalDeleted ?? this.canonicalDeleted,
      canonicalSavedAt: canonicalSavedAt ?? this.canonicalSavedAt,
      canonicalRemovedAt: canonicalRemovedAt ?? this.canonicalRemovedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (listState.present) {
      map['list_state'] = Variable<String>(listState.value);
    }
    if (clientUpdatedAt.present) {
      map['client_updated_at'] = Variable<DateTime>(clientUpdatedAt.value);
    }
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<DateTime>(serverUpdatedAt.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (savedAt.present) {
      map['saved_at'] = Variable<DateTime>(savedAt.value);
    }
    if (removedAt.present) {
      map['removed_at'] = Variable<DateTime>(removedAt.value);
    }
    if (revision.present) {
      map['revision'] = Variable<int>(revision.value);
    }
    if (lastOperationId.present) {
      map['last_operation_id'] = Variable<String>(lastOperationId.value);
    }
    if (canonicalDeleted.present) {
      map['canonical_deleted'] = Variable<bool>(canonicalDeleted.value);
    }
    if (canonicalSavedAt.present) {
      map['canonical_saved_at'] = Variable<DateTime>(canonicalSavedAt.value);
    }
    if (canonicalRemovedAt.present) {
      map['canonical_removed_at'] = Variable<DateTime>(
        canonicalRemovedAt.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemsCompanion(')
          ..write('accountId: $accountId, ')
          ..write('paperId: $paperId, ')
          ..write('listState: $listState, ')
          ..write('clientUpdatedAt: $clientUpdatedAt, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('deleted: $deleted, ')
          ..write('savedAt: $savedAt, ')
          ..write('removedAt: $removedAt, ')
          ..write('revision: $revision, ')
          ..write('lastOperationId: $lastOperationId, ')
          ..write('canonicalDeleted: $canonicalDeleted, ')
          ..write('canonicalSavedAt: $canonicalSavedAt, ')
          ..write('canonicalRemovedAt: $canonicalRemovedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CommentDraftsTable extends CommentDrafts
    with TableInfo<$CommentDraftsTable, CommentDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CommentDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _draftIdMeta = const VerificationMeta(
    'draftId',
  );
  @override
  late final GeneratedColumn<String> draftId = GeneratedColumn<String>(
    'draft_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _paperIdMeta = const VerificationMeta(
    'paperId',
  );
  @override
  late final GeneratedColumn<String> paperId = GeneratedColumn<String>(
    'paper_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES cached_papers (paper_id) ON DELETE RESTRICT',
    ),
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientRequestIdMeta = const VerificationMeta(
    'clientRequestId',
  );
  @override
  late final GeneratedColumn<String> clientRequestId = GeneratedColumn<String>(
    'client_request_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastAttemptedBodyMeta = const VerificationMeta(
    'lastAttemptedBody',
  );
  @override
  late final GeneratedColumn<String> lastAttemptedBody =
      GeneratedColumn<String>(
        'last_attempted_body',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    draftId,
    accountId,
    paperId,
    body,
    clientRequestId,
    lastAttemptedBody,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'comment_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<CommentDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('draft_id')) {
      context.handle(
        _draftIdMeta,
        draftId.isAcceptableOrUnknown(data['draft_id']!, _draftIdMeta),
      );
    } else if (isInserting) {
      context.missing(_draftIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('paper_id')) {
      context.handle(
        _paperIdMeta,
        paperId.isAcceptableOrUnknown(data['paper_id']!, _paperIdMeta),
      );
    } else if (isInserting) {
      context.missing(_paperIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('client_request_id')) {
      context.handle(
        _clientRequestIdMeta,
        clientRequestId.isAcceptableOrUnknown(
          data['client_request_id']!,
          _clientRequestIdMeta,
        ),
      );
    }
    if (data.containsKey('last_attempted_body')) {
      context.handle(
        _lastAttemptedBodyMeta,
        lastAttemptedBody.isAcceptableOrUnknown(
          data['last_attempted_body']!,
          _lastAttemptedBodyMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {draftId};
  @override
  CommentDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CommentDraftRow(
      draftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      ),
      paperId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paper_id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      clientRequestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_request_id'],
      ),
      lastAttemptedBody: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_attempted_body'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $CommentDraftsTable createAlias(String alias) {
    return $CommentDraftsTable(attachedDatabase, alias);
  }
}

class CommentDraftRow extends DataClass implements Insertable<CommentDraftRow> {
  final String draftId;
  final String? accountId;
  final String paperId;
  final String body;
  final String? clientRequestId;
  final String? lastAttemptedBody;
  final DateTime createdAt;
  final DateTime updatedAt;
  const CommentDraftRow({
    required this.draftId,
    this.accountId,
    required this.paperId,
    required this.body,
    this.clientRequestId,
    this.lastAttemptedBody,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['draft_id'] = Variable<String>(draftId);
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<String>(accountId);
    }
    map['paper_id'] = Variable<String>(paperId);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || clientRequestId != null) {
      map['client_request_id'] = Variable<String>(clientRequestId);
    }
    if (!nullToAbsent || lastAttemptedBody != null) {
      map['last_attempted_body'] = Variable<String>(lastAttemptedBody);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  CommentDraftsCompanion toCompanion(bool nullToAbsent) {
    return CommentDraftsCompanion(
      draftId: Value(draftId),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      paperId: Value(paperId),
      body: Value(body),
      clientRequestId: clientRequestId == null && nullToAbsent
          ? const Value.absent()
          : Value(clientRequestId),
      lastAttemptedBody: lastAttemptedBody == null && nullToAbsent
          ? const Value.absent()
          : Value(lastAttemptedBody),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CommentDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CommentDraftRow(
      draftId: serializer.fromJson<String>(json['draftId']),
      accountId: serializer.fromJson<String?>(json['accountId']),
      paperId: serializer.fromJson<String>(json['paperId']),
      body: serializer.fromJson<String>(json['body']),
      clientRequestId: serializer.fromJson<String?>(json['clientRequestId']),
      lastAttemptedBody: serializer.fromJson<String?>(
        json['lastAttemptedBody'],
      ),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'draftId': serializer.toJson<String>(draftId),
      'accountId': serializer.toJson<String?>(accountId),
      'paperId': serializer.toJson<String>(paperId),
      'body': serializer.toJson<String>(body),
      'clientRequestId': serializer.toJson<String?>(clientRequestId),
      'lastAttemptedBody': serializer.toJson<String?>(lastAttemptedBody),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CommentDraftRow copyWith({
    String? draftId,
    Value<String?> accountId = const Value.absent(),
    String? paperId,
    String? body,
    Value<String?> clientRequestId = const Value.absent(),
    Value<String?> lastAttemptedBody = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => CommentDraftRow(
    draftId: draftId ?? this.draftId,
    accountId: accountId.present ? accountId.value : this.accountId,
    paperId: paperId ?? this.paperId,
    body: body ?? this.body,
    clientRequestId: clientRequestId.present
        ? clientRequestId.value
        : this.clientRequestId,
    lastAttemptedBody: lastAttemptedBody.present
        ? lastAttemptedBody.value
        : this.lastAttemptedBody,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CommentDraftRow copyWithCompanion(CommentDraftsCompanion data) {
    return CommentDraftRow(
      draftId: data.draftId.present ? data.draftId.value : this.draftId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      paperId: data.paperId.present ? data.paperId.value : this.paperId,
      body: data.body.present ? data.body.value : this.body,
      clientRequestId: data.clientRequestId.present
          ? data.clientRequestId.value
          : this.clientRequestId,
      lastAttemptedBody: data.lastAttemptedBody.present
          ? data.lastAttemptedBody.value
          : this.lastAttemptedBody,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CommentDraftRow(')
          ..write('draftId: $draftId, ')
          ..write('accountId: $accountId, ')
          ..write('paperId: $paperId, ')
          ..write('body: $body, ')
          ..write('clientRequestId: $clientRequestId, ')
          ..write('lastAttemptedBody: $lastAttemptedBody, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    draftId,
    accountId,
    paperId,
    body,
    clientRequestId,
    lastAttemptedBody,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CommentDraftRow &&
          other.draftId == this.draftId &&
          other.accountId == this.accountId &&
          other.paperId == this.paperId &&
          other.body == this.body &&
          other.clientRequestId == this.clientRequestId &&
          other.lastAttemptedBody == this.lastAttemptedBody &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CommentDraftsCompanion extends UpdateCompanion<CommentDraftRow> {
  final Value<String> draftId;
  final Value<String?> accountId;
  final Value<String> paperId;
  final Value<String> body;
  final Value<String?> clientRequestId;
  final Value<String?> lastAttemptedBody;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const CommentDraftsCompanion({
    this.draftId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.paperId = const Value.absent(),
    this.body = const Value.absent(),
    this.clientRequestId = const Value.absent(),
    this.lastAttemptedBody = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CommentDraftsCompanion.insert({
    required String draftId,
    this.accountId = const Value.absent(),
    required String paperId,
    required String body,
    this.clientRequestId = const Value.absent(),
    this.lastAttemptedBody = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : draftId = Value(draftId),
       paperId = Value(paperId),
       body = Value(body),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CommentDraftRow> custom({
    Expression<String>? draftId,
    Expression<String>? accountId,
    Expression<String>? paperId,
    Expression<String>? body,
    Expression<String>? clientRequestId,
    Expression<String>? lastAttemptedBody,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (draftId != null) 'draft_id': draftId,
      if (accountId != null) 'account_id': accountId,
      if (paperId != null) 'paper_id': paperId,
      if (body != null) 'body': body,
      if (clientRequestId != null) 'client_request_id': clientRequestId,
      if (lastAttemptedBody != null) 'last_attempted_body': lastAttemptedBody,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CommentDraftsCompanion copyWith({
    Value<String>? draftId,
    Value<String?>? accountId,
    Value<String>? paperId,
    Value<String>? body,
    Value<String?>? clientRequestId,
    Value<String?>? lastAttemptedBody,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return CommentDraftsCompanion(
      draftId: draftId ?? this.draftId,
      accountId: accountId ?? this.accountId,
      paperId: paperId ?? this.paperId,
      body: body ?? this.body,
      clientRequestId: clientRequestId ?? this.clientRequestId,
      lastAttemptedBody: lastAttemptedBody ?? this.lastAttemptedBody,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (draftId.present) {
      map['draft_id'] = Variable<String>(draftId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (paperId.present) {
      map['paper_id'] = Variable<String>(paperId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (clientRequestId.present) {
      map['client_request_id'] = Variable<String>(clientRequestId.value);
    }
    if (lastAttemptedBody.present) {
      map['last_attempted_body'] = Variable<String>(lastAttemptedBody.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CommentDraftsCompanion(')
          ..write('draftId: $draftId, ')
          ..write('accountId: $accountId, ')
          ..write('paperId: $paperId, ')
          ..write('body: $body, ')
          ..write('clientRequestId: $clientRequestId, ')
          ..write('lastAttemptedBody: $lastAttemptedBody, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BlockedUsersTable extends BlockedUsers
    with TableInfo<$BlockedUsersTable, BlockedUserRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BlockedUsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _blockedUserIdMeta = const VerificationMeta(
    'blockedUserId',
  );
  @override
  late final GeneratedColumn<String> blockedUserId = GeneratedColumn<String>(
    'blocked_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _handleMeta = const VerificationMeta('handle');
  @override
  late final GeneratedColumn<String> handle = GeneratedColumn<String>(
    'handle',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverConfirmedMeta = const VerificationMeta(
    'serverConfirmed',
  );
  @override
  late final GeneratedColumn<bool> serverConfirmed = GeneratedColumn<bool>(
    'server_confirmed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("server_confirmed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    blockedUserId,
    handle,
    displayName,
    createdAt,
    serverConfirmed,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'blocked_users';
  @override
  VerificationContext validateIntegrity(
    Insertable<BlockedUserRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('blocked_user_id')) {
      context.handle(
        _blockedUserIdMeta,
        blockedUserId.isAcceptableOrUnknown(
          data['blocked_user_id']!,
          _blockedUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_blockedUserIdMeta);
    }
    if (data.containsKey('handle')) {
      context.handle(
        _handleMeta,
        handle.isAcceptableOrUnknown(data['handle']!, _handleMeta),
      );
    } else if (isInserting) {
      context.missing(_handleMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('server_confirmed')) {
      context.handle(
        _serverConfirmedMeta,
        serverConfirmed.isAcceptableOrUnknown(
          data['server_confirmed']!,
          _serverConfirmedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, blockedUserId};
  @override
  BlockedUserRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BlockedUserRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      blockedUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blocked_user_id'],
      )!,
      handle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}handle'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      serverConfirmed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}server_confirmed'],
      )!,
    );
  }

  @override
  $BlockedUsersTable createAlias(String alias) {
    return $BlockedUsersTable(attachedDatabase, alias);
  }
}

class BlockedUserRow extends DataClass implements Insertable<BlockedUserRow> {
  final String accountId;
  final String blockedUserId;
  final String handle;
  final String? displayName;
  final DateTime createdAt;
  final bool serverConfirmed;
  const BlockedUserRow({
    required this.accountId,
    required this.blockedUserId,
    required this.handle,
    this.displayName,
    required this.createdAt,
    required this.serverConfirmed,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['blocked_user_id'] = Variable<String>(blockedUserId);
    map['handle'] = Variable<String>(handle);
    if (!nullToAbsent || displayName != null) {
      map['display_name'] = Variable<String>(displayName);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['server_confirmed'] = Variable<bool>(serverConfirmed);
    return map;
  }

  BlockedUsersCompanion toCompanion(bool nullToAbsent) {
    return BlockedUsersCompanion(
      accountId: Value(accountId),
      blockedUserId: Value(blockedUserId),
      handle: Value(handle),
      displayName: displayName == null && nullToAbsent
          ? const Value.absent()
          : Value(displayName),
      createdAt: Value(createdAt),
      serverConfirmed: Value(serverConfirmed),
    );
  }

  factory BlockedUserRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BlockedUserRow(
      accountId: serializer.fromJson<String>(json['accountId']),
      blockedUserId: serializer.fromJson<String>(json['blockedUserId']),
      handle: serializer.fromJson<String>(json['handle']),
      displayName: serializer.fromJson<String?>(json['displayName']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      serverConfirmed: serializer.fromJson<bool>(json['serverConfirmed']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'blockedUserId': serializer.toJson<String>(blockedUserId),
      'handle': serializer.toJson<String>(handle),
      'displayName': serializer.toJson<String?>(displayName),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'serverConfirmed': serializer.toJson<bool>(serverConfirmed),
    };
  }

  BlockedUserRow copyWith({
    String? accountId,
    String? blockedUserId,
    String? handle,
    Value<String?> displayName = const Value.absent(),
    DateTime? createdAt,
    bool? serverConfirmed,
  }) => BlockedUserRow(
    accountId: accountId ?? this.accountId,
    blockedUserId: blockedUserId ?? this.blockedUserId,
    handle: handle ?? this.handle,
    displayName: displayName.present ? displayName.value : this.displayName,
    createdAt: createdAt ?? this.createdAt,
    serverConfirmed: serverConfirmed ?? this.serverConfirmed,
  );
  BlockedUserRow copyWithCompanion(BlockedUsersCompanion data) {
    return BlockedUserRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      blockedUserId: data.blockedUserId.present
          ? data.blockedUserId.value
          : this.blockedUserId,
      handle: data.handle.present ? data.handle.value : this.handle,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      serverConfirmed: data.serverConfirmed.present
          ? data.serverConfirmed.value
          : this.serverConfirmed,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BlockedUserRow(')
          ..write('accountId: $accountId, ')
          ..write('blockedUserId: $blockedUserId, ')
          ..write('handle: $handle, ')
          ..write('displayName: $displayName, ')
          ..write('createdAt: $createdAt, ')
          ..write('serverConfirmed: $serverConfirmed')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountId,
    blockedUserId,
    handle,
    displayName,
    createdAt,
    serverConfirmed,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlockedUserRow &&
          other.accountId == this.accountId &&
          other.blockedUserId == this.blockedUserId &&
          other.handle == this.handle &&
          other.displayName == this.displayName &&
          other.createdAt == this.createdAt &&
          other.serverConfirmed == this.serverConfirmed);
}

class BlockedUsersCompanion extends UpdateCompanion<BlockedUserRow> {
  final Value<String> accountId;
  final Value<String> blockedUserId;
  final Value<String> handle;
  final Value<String?> displayName;
  final Value<DateTime> createdAt;
  final Value<bool> serverConfirmed;
  final Value<int> rowid;
  const BlockedUsersCompanion({
    this.accountId = const Value.absent(),
    this.blockedUserId = const Value.absent(),
    this.handle = const Value.absent(),
    this.displayName = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.serverConfirmed = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BlockedUsersCompanion.insert({
    required String accountId,
    required String blockedUserId,
    required String handle,
    this.displayName = const Value.absent(),
    required DateTime createdAt,
    this.serverConfirmed = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       blockedUserId = Value(blockedUserId),
       handle = Value(handle),
       createdAt = Value(createdAt);
  static Insertable<BlockedUserRow> custom({
    Expression<String>? accountId,
    Expression<String>? blockedUserId,
    Expression<String>? handle,
    Expression<String>? displayName,
    Expression<DateTime>? createdAt,
    Expression<bool>? serverConfirmed,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (blockedUserId != null) 'blocked_user_id': blockedUserId,
      if (handle != null) 'handle': handle,
      if (displayName != null) 'display_name': displayName,
      if (createdAt != null) 'created_at': createdAt,
      if (serverConfirmed != null) 'server_confirmed': serverConfirmed,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BlockedUsersCompanion copyWith({
    Value<String>? accountId,
    Value<String>? blockedUserId,
    Value<String>? handle,
    Value<String?>? displayName,
    Value<DateTime>? createdAt,
    Value<bool>? serverConfirmed,
    Value<int>? rowid,
  }) {
    return BlockedUsersCompanion(
      accountId: accountId ?? this.accountId,
      blockedUserId: blockedUserId ?? this.blockedUserId,
      handle: handle ?? this.handle,
      displayName: displayName ?? this.displayName,
      createdAt: createdAt ?? this.createdAt,
      serverConfirmed: serverConfirmed ?? this.serverConfirmed,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (blockedUserId.present) {
      map['blocked_user_id'] = Variable<String>(blockedUserId.value);
    }
    if (handle.present) {
      map['handle'] = Variable<String>(handle.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (serverConfirmed.present) {
      map['server_confirmed'] = Variable<bool>(serverConfirmed.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BlockedUsersCompanion(')
          ..write('accountId: $accountId, ')
          ..write('blockedUserId: $blockedUserId, ')
          ..write('handle: $handle, ')
          ..write('displayName: $displayName, ')
          ..write('createdAt: $createdAt, ')
          ..write('serverConfirmed: $serverConfirmed, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncOutboxTable extends SyncOutbox
    with TableInfo<$SyncOutboxTable, SyncOutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncOutboxTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _entityKindMeta = const VerificationMeta(
    'entityKind',
  );
  @override
  late final GeneratedColumn<String> entityKind = GeneratedColumn<String>(
    'entity_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationMeta = const VerificationMeta(
    'operation',
  );
  @override
  late final GeneratedColumn<String> operation = GeneratedColumn<String>(
    'operation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastErrorCodeMeta = const VerificationMeta(
    'lastErrorCode',
  );
  @override
  late final GeneratedColumn<String> lastErrorCode = GeneratedColumn<String>(
    'last_error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('queued'),
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    operationId,
    accountId,
    entityKind,
    entityId,
    operation,
    payloadJson,
    createdAt,
    attemptCount,
    nextAttemptAt,
    lastErrorCode,
    state,
    startedAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_outbox';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncOutboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    }
    if (data.containsKey('entity_kind')) {
      context.handle(
        _entityKindMeta,
        entityKind.isAcceptableOrUnknown(data['entity_kind']!, _entityKindMeta),
      );
    } else if (isInserting) {
      context.missing(_entityKindMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('operation')) {
      context.handle(
        _operationMeta,
        operation.isAcceptableOrUnknown(data['operation']!, _operationMeta),
      );
    } else if (isInserting) {
      context.missing(_operationMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error_code')) {
      context.handle(
        _lastErrorCodeMeta,
        lastErrorCode.isAcceptableOrUnknown(
          data['last_error_code']!,
          _lastErrorCodeMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {operationId};
  @override
  SyncOutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncOutboxRow(
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      ),
      entityKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_kind'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      operation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      ),
      lastErrorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_code'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
    );
  }

  @override
  $SyncOutboxTable createAlias(String alias) {
    return $SyncOutboxTable(attachedDatabase, alias);
  }
}

class SyncOutboxRow extends DataClass implements Insertable<SyncOutboxRow> {
  final String operationId;
  final String? accountId;
  final String entityKind;
  final String entityId;
  final String operation;
  final String payloadJson;
  final DateTime createdAt;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode;
  final String state;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  const SyncOutboxRow({
    required this.operationId,
    this.accountId,
    required this.entityKind,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.createdAt,
    required this.attemptCount,
    this.nextAttemptAt,
    this.lastErrorCode,
    required this.state,
    this.startedAt,
    this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['operation_id'] = Variable<String>(operationId);
    if (!nullToAbsent || accountId != null) {
      map['account_id'] = Variable<String>(accountId);
    }
    map['entity_kind'] = Variable<String>(entityKind);
    map['entity_id'] = Variable<String>(entityId);
    map['operation'] = Variable<String>(operation);
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    }
    if (!nullToAbsent || lastErrorCode != null) {
      map['last_error_code'] = Variable<String>(lastErrorCode);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || startedAt != null) {
      map['started_at'] = Variable<DateTime>(startedAt);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  SyncOutboxCompanion toCompanion(bool nullToAbsent) {
    return SyncOutboxCompanion(
      operationId: Value(operationId),
      accountId: accountId == null && nullToAbsent
          ? const Value.absent()
          : Value(accountId),
      entityKind: Value(entityKind),
      entityId: Value(entityId),
      operation: Value(operation),
      payloadJson: Value(payloadJson),
      createdAt: Value(createdAt),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      lastErrorCode: lastErrorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorCode),
      state: Value(state),
      startedAt: startedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(startedAt),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory SyncOutboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncOutboxRow(
      operationId: serializer.fromJson<String>(json['operationId']),
      accountId: serializer.fromJson<String?>(json['accountId']),
      entityKind: serializer.fromJson<String>(json['entityKind']),
      entityId: serializer.fromJson<String>(json['entityId']),
      operation: serializer.fromJson<String>(json['operation']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<DateTime?>(json['nextAttemptAt']),
      lastErrorCode: serializer.fromJson<String?>(json['lastErrorCode']),
      state: serializer.fromJson<String>(json['state']),
      startedAt: serializer.fromJson<DateTime?>(json['startedAt']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'operationId': serializer.toJson<String>(operationId),
      'accountId': serializer.toJson<String?>(accountId),
      'entityKind': serializer.toJson<String>(entityKind),
      'entityId': serializer.toJson<String>(entityId),
      'operation': serializer.toJson<String>(operation),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<DateTime?>(nextAttemptAt),
      'lastErrorCode': serializer.toJson<String?>(lastErrorCode),
      'state': serializer.toJson<String>(state),
      'startedAt': serializer.toJson<DateTime?>(startedAt),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  SyncOutboxRow copyWith({
    String? operationId,
    Value<String?> accountId = const Value.absent(),
    String? entityKind,
    String? entityId,
    String? operation,
    String? payloadJson,
    DateTime? createdAt,
    int? attemptCount,
    Value<DateTime?> nextAttemptAt = const Value.absent(),
    Value<String?> lastErrorCode = const Value.absent(),
    String? state,
    Value<DateTime?> startedAt = const Value.absent(),
    Value<DateTime?> updatedAt = const Value.absent(),
  }) => SyncOutboxRow(
    operationId: operationId ?? this.operationId,
    accountId: accountId.present ? accountId.value : this.accountId,
    entityKind: entityKind ?? this.entityKind,
    entityId: entityId ?? this.entityId,
    operation: operation ?? this.operation,
    payloadJson: payloadJson ?? this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    lastErrorCode: lastErrorCode.present
        ? lastErrorCode.value
        : this.lastErrorCode,
    state: state ?? this.state,
    startedAt: startedAt.present ? startedAt.value : this.startedAt,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
  );
  SyncOutboxRow copyWithCompanion(SyncOutboxCompanion data) {
    return SyncOutboxRow(
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      entityKind: data.entityKind.present
          ? data.entityKind.value
          : this.entityKind,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      operation: data.operation.present ? data.operation.value : this.operation,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastErrorCode: data.lastErrorCode.present
          ? data.lastErrorCode.value
          : this.lastErrorCode,
      state: data.state.present ? data.state.value : this.state,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncOutboxRow(')
          ..write('operationId: $operationId, ')
          ..write('accountId: $accountId, ')
          ..write('entityKind: $entityKind, ')
          ..write('entityId: $entityId, ')
          ..write('operation: $operation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('state: $state, ')
          ..write('startedAt: $startedAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    operationId,
    accountId,
    entityKind,
    entityId,
    operation,
    payloadJson,
    createdAt,
    attemptCount,
    nextAttemptAt,
    lastErrorCode,
    state,
    startedAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncOutboxRow &&
          other.operationId == this.operationId &&
          other.accountId == this.accountId &&
          other.entityKind == this.entityKind &&
          other.entityId == this.entityId &&
          other.operation == this.operation &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastErrorCode == this.lastErrorCode &&
          other.state == this.state &&
          other.startedAt == this.startedAt &&
          other.updatedAt == this.updatedAt);
}

class SyncOutboxCompanion extends UpdateCompanion<SyncOutboxRow> {
  final Value<String> operationId;
  final Value<String?> accountId;
  final Value<String> entityKind;
  final Value<String> entityId;
  final Value<String> operation;
  final Value<String> payloadJson;
  final Value<DateTime> createdAt;
  final Value<int> attemptCount;
  final Value<DateTime?> nextAttemptAt;
  final Value<String?> lastErrorCode;
  final Value<String> state;
  final Value<DateTime?> startedAt;
  final Value<DateTime?> updatedAt;
  final Value<int> rowid;
  const SyncOutboxCompanion({
    this.operationId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.entityKind = const Value.absent(),
    this.entityId = const Value.absent(),
    this.operation = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.state = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncOutboxCompanion.insert({
    required String operationId,
    this.accountId = const Value.absent(),
    required String entityKind,
    required String entityId,
    required String operation,
    required String payloadJson,
    required DateTime createdAt,
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.state = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : operationId = Value(operationId),
       entityKind = Value(entityKind),
       entityId = Value(entityId),
       operation = Value(operation),
       payloadJson = Value(payloadJson),
       createdAt = Value(createdAt);
  static Insertable<SyncOutboxRow> custom({
    Expression<String>? operationId,
    Expression<String>? accountId,
    Expression<String>? entityKind,
    Expression<String>? entityId,
    Expression<String>? operation,
    Expression<String>? payloadJson,
    Expression<DateTime>? createdAt,
    Expression<int>? attemptCount,
    Expression<DateTime>? nextAttemptAt,
    Expression<String>? lastErrorCode,
    Expression<String>? state,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (operationId != null) 'operation_id': operationId,
      if (accountId != null) 'account_id': accountId,
      if (entityKind != null) 'entity_kind': entityKind,
      if (entityId != null) 'entity_id': entityId,
      if (operation != null) 'operation': operation,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
      if (state != null) 'state': state,
      if (startedAt != null) 'started_at': startedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncOutboxCompanion copyWith({
    Value<String>? operationId,
    Value<String?>? accountId,
    Value<String>? entityKind,
    Value<String>? entityId,
    Value<String>? operation,
    Value<String>? payloadJson,
    Value<DateTime>? createdAt,
    Value<int>? attemptCount,
    Value<DateTime?>? nextAttemptAt,
    Value<String?>? lastErrorCode,
    Value<String>? state,
    Value<DateTime?>? startedAt,
    Value<DateTime?>? updatedAt,
    Value<int>? rowid,
  }) {
    return SyncOutboxCompanion(
      operationId: operationId ?? this.operationId,
      accountId: accountId ?? this.accountId,
      entityKind: entityKind ?? this.entityKind,
      entityId: entityId ?? this.entityId,
      operation: operation ?? this.operation,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      state: state ?? this.state,
      startedAt: startedAt ?? this.startedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (entityKind.present) {
      map['entity_kind'] = Variable<String>(entityKind.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (operation.present) {
      map['operation'] = Variable<String>(operation.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (lastErrorCode.present) {
      map['last_error_code'] = Variable<String>(lastErrorCode.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncOutboxCompanion(')
          ..write('operationId: $operationId, ')
          ..write('accountId: $accountId, ')
          ..write('entityKind: $entityKind, ')
          ..write('entityId: $entityId, ')
          ..write('operation: $operation, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('state: $state, ')
          ..write('startedAt: $startedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibrarySyncStatesTable extends LibrarySyncStates
    with TableInfo<$LibrarySyncStatesTable, LibrarySyncStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibrarySyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastRevisionMeta = const VerificationMeta(
    'lastRevision',
  );
  @override
  late final GeneratedColumn<int> lastRevision = GeneratedColumn<int>(
    'last_revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _initializedMeta = const VerificationMeta(
    'initialized',
  );
  @override
  late final GeneratedColumn<bool> initialized = GeneratedColumn<bool>(
    'initialized',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("initialized" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _lastFullSyncAtMeta = const VerificationMeta(
    'lastFullSyncAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastFullSyncAt =
      GeneratedColumn<DateTime>(
        'last_full_sync_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    accountId,
    lastRevision,
    initialized,
    lastFullSyncAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_sync_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibrarySyncStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('last_revision')) {
      context.handle(
        _lastRevisionMeta,
        lastRevision.isAcceptableOrUnknown(
          data['last_revision']!,
          _lastRevisionMeta,
        ),
      );
    }
    if (data.containsKey('initialized')) {
      context.handle(
        _initializedMeta,
        initialized.isAcceptableOrUnknown(
          data['initialized']!,
          _initializedMeta,
        ),
      );
    }
    if (data.containsKey('last_full_sync_at')) {
      context.handle(
        _lastFullSyncAtMeta,
        lastFullSyncAt.isAcceptableOrUnknown(
          data['last_full_sync_at']!,
          _lastFullSyncAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId};
  @override
  LibrarySyncStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibrarySyncStateRow(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      lastRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_revision'],
      )!,
      initialized: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}initialized'],
      )!,
      lastFullSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_full_sync_at'],
      ),
    );
  }

  @override
  $LibrarySyncStatesTable createAlias(String alias) {
    return $LibrarySyncStatesTable(attachedDatabase, alias);
  }
}

class LibrarySyncStateRow extends DataClass
    implements Insertable<LibrarySyncStateRow> {
  final String accountId;
  final int lastRevision;
  final bool initialized;
  final DateTime? lastFullSyncAt;
  const LibrarySyncStateRow({
    required this.accountId,
    required this.lastRevision,
    required this.initialized,
    this.lastFullSyncAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['last_revision'] = Variable<int>(lastRevision);
    map['initialized'] = Variable<bool>(initialized);
    if (!nullToAbsent || lastFullSyncAt != null) {
      map['last_full_sync_at'] = Variable<DateTime>(lastFullSyncAt);
    }
    return map;
  }

  LibrarySyncStatesCompanion toCompanion(bool nullToAbsent) {
    return LibrarySyncStatesCompanion(
      accountId: Value(accountId),
      lastRevision: Value(lastRevision),
      initialized: Value(initialized),
      lastFullSyncAt: lastFullSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastFullSyncAt),
    );
  }

  factory LibrarySyncStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibrarySyncStateRow(
      accountId: serializer.fromJson<String>(json['accountId']),
      lastRevision: serializer.fromJson<int>(json['lastRevision']),
      initialized: serializer.fromJson<bool>(json['initialized']),
      lastFullSyncAt: serializer.fromJson<DateTime?>(json['lastFullSyncAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'lastRevision': serializer.toJson<int>(lastRevision),
      'initialized': serializer.toJson<bool>(initialized),
      'lastFullSyncAt': serializer.toJson<DateTime?>(lastFullSyncAt),
    };
  }

  LibrarySyncStateRow copyWith({
    String? accountId,
    int? lastRevision,
    bool? initialized,
    Value<DateTime?> lastFullSyncAt = const Value.absent(),
  }) => LibrarySyncStateRow(
    accountId: accountId ?? this.accountId,
    lastRevision: lastRevision ?? this.lastRevision,
    initialized: initialized ?? this.initialized,
    lastFullSyncAt: lastFullSyncAt.present
        ? lastFullSyncAt.value
        : this.lastFullSyncAt,
  );
  LibrarySyncStateRow copyWithCompanion(LibrarySyncStatesCompanion data) {
    return LibrarySyncStateRow(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      lastRevision: data.lastRevision.present
          ? data.lastRevision.value
          : this.lastRevision,
      initialized: data.initialized.present
          ? data.initialized.value
          : this.initialized,
      lastFullSyncAt: data.lastFullSyncAt.present
          ? data.lastFullSyncAt.value
          : this.lastFullSyncAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibrarySyncStateRow(')
          ..write('accountId: $accountId, ')
          ..write('lastRevision: $lastRevision, ')
          ..write('initialized: $initialized, ')
          ..write('lastFullSyncAt: $lastFullSyncAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(accountId, lastRevision, initialized, lastFullSyncAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibrarySyncStateRow &&
          other.accountId == this.accountId &&
          other.lastRevision == this.lastRevision &&
          other.initialized == this.initialized &&
          other.lastFullSyncAt == this.lastFullSyncAt);
}

class LibrarySyncStatesCompanion extends UpdateCompanion<LibrarySyncStateRow> {
  final Value<String> accountId;
  final Value<int> lastRevision;
  final Value<bool> initialized;
  final Value<DateTime?> lastFullSyncAt;
  final Value<int> rowid;
  const LibrarySyncStatesCompanion({
    this.accountId = const Value.absent(),
    this.lastRevision = const Value.absent(),
    this.initialized = const Value.absent(),
    this.lastFullSyncAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibrarySyncStatesCompanion.insert({
    required String accountId,
    this.lastRevision = const Value.absent(),
    this.initialized = const Value.absent(),
    this.lastFullSyncAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId);
  static Insertable<LibrarySyncStateRow> custom({
    Expression<String>? accountId,
    Expression<int>? lastRevision,
    Expression<bool>? initialized,
    Expression<DateTime>? lastFullSyncAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (lastRevision != null) 'last_revision': lastRevision,
      if (initialized != null) 'initialized': initialized,
      if (lastFullSyncAt != null) 'last_full_sync_at': lastFullSyncAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibrarySyncStatesCompanion copyWith({
    Value<String>? accountId,
    Value<int>? lastRevision,
    Value<bool>? initialized,
    Value<DateTime?>? lastFullSyncAt,
    Value<int>? rowid,
  }) {
    return LibrarySyncStatesCompanion(
      accountId: accountId ?? this.accountId,
      lastRevision: lastRevision ?? this.lastRevision,
      initialized: initialized ?? this.initialized,
      lastFullSyncAt: lastFullSyncAt ?? this.lastFullSyncAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (lastRevision.present) {
      map['last_revision'] = Variable<int>(lastRevision.value);
    }
    if (initialized.present) {
      map['initialized'] = Variable<bool>(initialized.value);
    }
    if (lastFullSyncAt.present) {
      map['last_full_sync_at'] = Variable<DateTime>(lastFullSyncAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibrarySyncStatesCompanion(')
          ..write('accountId: $accountId, ')
          ..write('lastRevision: $lastRevision, ')
          ..write('initialized: $initialized, ')
          ..write('lastFullSyncAt: $lastFullSyncAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CacheMetadataTable extends CacheMetadata
    with TableInfo<$CacheMetadataTable, CacheMetadataRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CacheMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueJsonMeta = const VerificationMeta(
    'valueJson',
  );
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
    'value_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, valueJson, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cache_metadata';
  @override
  VerificationContext validateIntegrity(
    Insertable<CacheMetadataRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(
        _valueJsonMeta,
        valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  CacheMetadataRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CacheMetadataRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      valueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value_json'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $CacheMetadataTable createAlias(String alias) {
    return $CacheMetadataTable(attachedDatabase, alias);
  }
}

class CacheMetadataRow extends DataClass
    implements Insertable<CacheMetadataRow> {
  final String key;
  final String valueJson;
  final DateTime updatedAt;
  const CacheMetadataRow({
    required this.key,
    required this.valueJson,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value_json'] = Variable<String>(valueJson);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  CacheMetadataCompanion toCompanion(bool nullToAbsent) {
    return CacheMetadataCompanion(
      key: Value(key),
      valueJson: Value(valueJson),
      updatedAt: Value(updatedAt),
    );
  }

  factory CacheMetadataRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CacheMetadataRow(
      key: serializer.fromJson<String>(json['key']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'valueJson': serializer.toJson<String>(valueJson),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CacheMetadataRow copyWith({
    String? key,
    String? valueJson,
    DateTime? updatedAt,
  }) => CacheMetadataRow(
    key: key ?? this.key,
    valueJson: valueJson ?? this.valueJson,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CacheMetadataRow copyWithCompanion(CacheMetadataCompanion data) {
    return CacheMetadataRow(
      key: data.key.present ? data.key.value : this.key,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CacheMetadataRow(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, valueJson, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CacheMetadataRow &&
          other.key == this.key &&
          other.valueJson == this.valueJson &&
          other.updatedAt == this.updatedAt);
}

class CacheMetadataCompanion extends UpdateCompanion<CacheMetadataRow> {
  final Value<String> key;
  final Value<String> valueJson;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const CacheMetadataCompanion({
    this.key = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CacheMetadataCompanion.insert({
    required String key,
    required String valueJson,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       valueJson = Value(valueJson),
       updatedAt = Value(updatedAt);
  static Insertable<CacheMetadataRow> custom({
    Expression<String>? key,
    Expression<String>? valueJson,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (valueJson != null) 'value_json': valueJson,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CacheMetadataCompanion copyWith({
    Value<String>? key,
    Value<String>? valueJson,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return CacheMetadataCompanion(
      key: key ?? this.key,
      valueJson: valueJson ?? this.valueJson,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CacheMetadataCompanion(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$PakPerkDatabase extends GeneratedDatabase {
  _$PakPerkDatabase(QueryExecutor e) : super(e);
  $PakPerkDatabaseManager get managers => $PakPerkDatabaseManager(this);
  late final $CachedPapersTable cachedPapers = $CachedPapersTable(this);
  late final $FeedQueriesTable feedQueries = $FeedQueriesTable(this);
  late final $FeedEntriesTable feedEntries = $FeedEntriesTable(this);
  late final $CachedProcessingTable cachedProcessing = $CachedProcessingTable(
    this,
  );
  late final $CachedIntroductionsTable cachedIntroductions =
      $CachedIntroductionsTable(this);
  late final $CachedConnectionsTable cachedConnections =
      $CachedConnectionsTable(this);
  late final $CachedCommentPagesTable cachedCommentPages =
      $CachedCommentPagesTable(this);
  late final $CachedChatsTable cachedChats = $CachedChatsTable(this);
  late final $LibraryItemsTable libraryItems = $LibraryItemsTable(this);
  late final $CommentDraftsTable commentDrafts = $CommentDraftsTable(this);
  late final $BlockedUsersTable blockedUsers = $BlockedUsersTable(this);
  late final $SyncOutboxTable syncOutbox = $SyncOutboxTable(this);
  late final $LibrarySyncStatesTable librarySyncStates =
      $LibrarySyncStatesTable(this);
  late final $CacheMetadataTable cacheMetadata = $CacheMetadataTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    cachedPapers,
    feedQueries,
    feedEntries,
    cachedProcessing,
    cachedIntroductions,
    cachedConnections,
    cachedCommentPages,
    cachedChats,
    libraryItems,
    commentDrafts,
    blockedUsers,
    syncOutbox,
    librarySyncStates,
    cacheMetadata,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'feed_queries',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('feed_entries', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('feed_entries', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_processing', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_introductions', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_connections', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_comment_pages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'cached_papers',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_chats', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$CachedPapersTableCreateCompanionBuilder =
    CachedPapersCompanion Function({
      required String paperId,
      required String arxivBaseId,
      Value<int?> arxivVersion,
      required String metadataJson,
      required DateTime publishedAt,
      required DateTime updatedAt,
      required DateTime lastAccessedAt,
      required DateTime expiresAt,
      Value<bool> pinnedByLibrary,
      Value<int> rowid,
    });
typedef $$CachedPapersTableUpdateCompanionBuilder =
    CachedPapersCompanion Function({
      Value<String> paperId,
      Value<String> arxivBaseId,
      Value<int?> arxivVersion,
      Value<String> metadataJson,
      Value<DateTime> publishedAt,
      Value<DateTime> updatedAt,
      Value<DateTime> lastAccessedAt,
      Value<DateTime> expiresAt,
      Value<bool> pinnedByLibrary,
      Value<int> rowid,
    });

final class $$CachedPapersTableReferences
    extends
        BaseReferences<_$PakPerkDatabase, $CachedPapersTable, CachedPaperRow> {
  $$CachedPapersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$FeedEntriesTable, List<FeedEntryRow>>
  _feedEntriesRefsTable(_$PakPerkDatabase db) => MultiTypedResultKey.fromTable(
    db.feedEntries,
    aliasName: 'cached_papers__paper_id__feed_entries__paper_id',
  );

  $$FeedEntriesTableProcessedTableManager get feedEntriesRefs {
    final manager = $$FeedEntriesTableTableManager($_db, $_db.feedEntries)
        .filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(_feedEntriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CachedProcessingTable, List<CachedProcessingRow>>
  _cachedProcessingRefsTable(_$PakPerkDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedProcessing,
        aliasName: 'cached_papers__paper_id__cached_processing__paper_id',
      );

  $$CachedProcessingTableProcessedTableManager get cachedProcessingRefs {
    final manager =
        $$CachedProcessingTableTableManager($_db, $_db.cachedProcessing).filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _cachedProcessingRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CachedIntroductionsTable,
    List<CachedIntroductionRow>
  >
  _cachedIntroductionsRefsTable(_$PakPerkDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedIntroductions,
        aliasName: 'cached_papers__paper_id__cached_introductions__paper_id',
      );

  $$CachedIntroductionsTableProcessedTableManager get cachedIntroductionsRefs {
    final manager =
        $$CachedIntroductionsTableTableManager(
          $_db,
          $_db.cachedIntroductions,
        ).filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _cachedIntroductionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CachedConnectionsTable, List<CachedConnectionRow>>
  _cachedConnectionsRefsTable(_$PakPerkDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedConnections,
        aliasName: 'cached_papers__paper_id__cached_connections__paper_id',
      );

  $$CachedConnectionsTableProcessedTableManager get cachedConnectionsRefs {
    final manager =
        $$CachedConnectionsTableTableManager(
          $_db,
          $_db.cachedConnections,
        ).filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _cachedConnectionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CachedCommentPagesTable,
    List<CachedCommentPageRow>
  >
  _cachedCommentPagesRefsTable(_$PakPerkDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedCommentPages,
        aliasName: 'cached_papers__paper_id__cached_comment_pages__paper_id',
      );

  $$CachedCommentPagesTableProcessedTableManager get cachedCommentPagesRefs {
    final manager =
        $$CachedCommentPagesTableTableManager(
          $_db,
          $_db.cachedCommentPages,
        ).filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(
      _cachedCommentPagesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CachedChatsTable, List<CachedChatRow>>
  _cachedChatsRefsTable(_$PakPerkDatabase db) => MultiTypedResultKey.fromTable(
    db.cachedChats,
    aliasName: 'cached_papers__paper_id__cached_chats__paper_id',
  );

  $$CachedChatsTableProcessedTableManager get cachedChatsRefs {
    final manager = $$CachedChatsTableTableManager($_db, $_db.cachedChats)
        .filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(_cachedChatsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$CommentDraftsTable, List<CommentDraftRow>>
  _commentDraftsRefsTable(_$PakPerkDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.commentDrafts,
        aliasName: 'cached_papers__paper_id__comment_drafts__paper_id',
      );

  $$CommentDraftsTableProcessedTableManager get commentDraftsRefs {
    final manager = $$CommentDraftsTableTableManager($_db, $_db.commentDrafts)
        .filter(
          (f) => f.paperId.paperId.sqlEquals($_itemColumn<String>('paper_id')!),
        );

    final cache = $_typedResult.readTableOrNull(_commentDraftsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$CachedPapersTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedPapersTable> {
  $$CachedPapersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get paperId => $composableBuilder(
    column: $table.paperId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get arxivBaseId => $composableBuilder(
    column: $table.arxivBaseId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get arxivVersion => $composableBuilder(
    column: $table.arxivVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get publishedAt => $composableBuilder(
    column: $table.publishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinnedByLibrary => $composableBuilder(
    column: $table.pinnedByLibrary,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> feedEntriesRefs(
    Expression<bool> Function($$FeedEntriesTableFilterComposer f) f,
  ) {
    final $$FeedEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.feedEntries,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedEntriesTableFilterComposer(
            $db: $db,
            $table: $db.feedEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedProcessingRefs(
    Expression<bool> Function($$CachedProcessingTableFilterComposer f) f,
  ) {
    final $$CachedProcessingTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedProcessing,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedProcessingTableFilterComposer(
            $db: $db,
            $table: $db.cachedProcessing,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedIntroductionsRefs(
    Expression<bool> Function($$CachedIntroductionsTableFilterComposer f) f,
  ) {
    final $$CachedIntroductionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedIntroductions,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedIntroductionsTableFilterComposer(
            $db: $db,
            $table: $db.cachedIntroductions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedConnectionsRefs(
    Expression<bool> Function($$CachedConnectionsTableFilterComposer f) f,
  ) {
    final $$CachedConnectionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedConnections,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedConnectionsTableFilterComposer(
            $db: $db,
            $table: $db.cachedConnections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedCommentPagesRefs(
    Expression<bool> Function($$CachedCommentPagesTableFilterComposer f) f,
  ) {
    final $$CachedCommentPagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedCommentPages,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedCommentPagesTableFilterComposer(
            $db: $db,
            $table: $db.cachedCommentPages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedChatsRefs(
    Expression<bool> Function($$CachedChatsTableFilterComposer f) f,
  ) {
    final $$CachedChatsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedChats,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedChatsTableFilterComposer(
            $db: $db,
            $table: $db.cachedChats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> commentDraftsRefs(
    Expression<bool> Function($$CommentDraftsTableFilterComposer f) f,
  ) {
    final $$CommentDraftsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.commentDrafts,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentDraftsTableFilterComposer(
            $db: $db,
            $table: $db.commentDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$CachedPapersTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedPapersTable> {
  $$CachedPapersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get paperId => $composableBuilder(
    column: $table.paperId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get arxivBaseId => $composableBuilder(
    column: $table.arxivBaseId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get arxivVersion => $composableBuilder(
    column: $table.arxivVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get publishedAt => $composableBuilder(
    column: $table.publishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinnedByLibrary => $composableBuilder(
    column: $table.pinnedByLibrary,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedPapersTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedPapersTable> {
  $$CachedPapersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get paperId =>
      $composableBuilder(column: $table.paperId, builder: (column) => column);

  GeneratedColumn<String> get arxivBaseId => $composableBuilder(
    column: $table.arxivBaseId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get arxivVersion => $composableBuilder(
    column: $table.arxivVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metadataJson => $composableBuilder(
    column: $table.metadataJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get publishedAt => $composableBuilder(
    column: $table.publishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<bool> get pinnedByLibrary => $composableBuilder(
    column: $table.pinnedByLibrary,
    builder: (column) => column,
  );

  Expression<T> feedEntriesRefs<T extends Object>(
    Expression<T> Function($$FeedEntriesTableAnnotationComposer a) f,
  ) {
    final $$FeedEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.feedEntries,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.feedEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> cachedProcessingRefs<T extends Object>(
    Expression<T> Function($$CachedProcessingTableAnnotationComposer a) f,
  ) {
    final $$CachedProcessingTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedProcessing,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedProcessingTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedProcessing,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> cachedIntroductionsRefs<T extends Object>(
    Expression<T> Function($$CachedIntroductionsTableAnnotationComposer a) f,
  ) {
    final $$CachedIntroductionsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.paperId,
          referencedTable: $db.cachedIntroductions,
          getReferencedColumn: (t) => t.paperId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedIntroductionsTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedIntroductions,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> cachedConnectionsRefs<T extends Object>(
    Expression<T> Function($$CachedConnectionsTableAnnotationComposer a) f,
  ) {
    final $$CachedConnectionsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.paperId,
          referencedTable: $db.cachedConnections,
          getReferencedColumn: (t) => t.paperId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedConnectionsTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedConnections,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> cachedCommentPagesRefs<T extends Object>(
    Expression<T> Function($$CachedCommentPagesTableAnnotationComposer a) f,
  ) {
    final $$CachedCommentPagesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.paperId,
          referencedTable: $db.cachedCommentPages,
          getReferencedColumn: (t) => t.paperId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedCommentPagesTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedCommentPages,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> cachedChatsRefs<T extends Object>(
    Expression<T> Function($$CachedChatsTableAnnotationComposer a) f,
  ) {
    final $$CachedChatsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedChats,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedChatsTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedChats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> commentDraftsRefs<T extends Object>(
    Expression<T> Function($$CommentDraftsTableAnnotationComposer a) f,
  ) {
    final $$CommentDraftsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.commentDrafts,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CommentDraftsTableAnnotationComposer(
            $db: $db,
            $table: $db.commentDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$CachedPapersTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedPapersTable,
          CachedPaperRow,
          $$CachedPapersTableFilterComposer,
          $$CachedPapersTableOrderingComposer,
          $$CachedPapersTableAnnotationComposer,
          $$CachedPapersTableCreateCompanionBuilder,
          $$CachedPapersTableUpdateCompanionBuilder,
          (CachedPaperRow, $$CachedPapersTableReferences),
          CachedPaperRow,
          PrefetchHooks Function({
            bool feedEntriesRefs,
            bool cachedProcessingRefs,
            bool cachedIntroductionsRefs,
            bool cachedConnectionsRefs,
            bool cachedCommentPagesRefs,
            bool cachedChatsRefs,
            bool commentDraftsRefs,
          })
        > {
  $$CachedPapersTableTableManager(
    _$PakPerkDatabase db,
    $CachedPapersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedPapersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedPapersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedPapersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> paperId = const Value.absent(),
                Value<String> arxivBaseId = const Value.absent(),
                Value<int?> arxivVersion = const Value.absent(),
                Value<String> metadataJson = const Value.absent(),
                Value<DateTime> publishedAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime> lastAccessedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<bool> pinnedByLibrary = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedPapersCompanion(
                paperId: paperId,
                arxivBaseId: arxivBaseId,
                arxivVersion: arxivVersion,
                metadataJson: metadataJson,
                publishedAt: publishedAt,
                updatedAt: updatedAt,
                lastAccessedAt: lastAccessedAt,
                expiresAt: expiresAt,
                pinnedByLibrary: pinnedByLibrary,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String paperId,
                required String arxivBaseId,
                Value<int?> arxivVersion = const Value.absent(),
                required String metadataJson,
                required DateTime publishedAt,
                required DateTime updatedAt,
                required DateTime lastAccessedAt,
                required DateTime expiresAt,
                Value<bool> pinnedByLibrary = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedPapersCompanion.insert(
                paperId: paperId,
                arxivBaseId: arxivBaseId,
                arxivVersion: arxivVersion,
                metadataJson: metadataJson,
                publishedAt: publishedAt,
                updatedAt: updatedAt,
                lastAccessedAt: lastAccessedAt,
                expiresAt: expiresAt,
                pinnedByLibrary: pinnedByLibrary,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedPapersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                feedEntriesRefs = false,
                cachedProcessingRefs = false,
                cachedIntroductionsRefs = false,
                cachedConnectionsRefs = false,
                cachedCommentPagesRefs = false,
                cachedChatsRefs = false,
                commentDraftsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (feedEntriesRefs) db.feedEntries,
                    if (cachedProcessingRefs) db.cachedProcessing,
                    if (cachedIntroductionsRefs) db.cachedIntroductions,
                    if (cachedConnectionsRefs) db.cachedConnections,
                    if (cachedCommentPagesRefs) db.cachedCommentPages,
                    if (cachedChatsRefs) db.cachedChats,
                    if (commentDraftsRefs) db.commentDrafts,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (feedEntriesRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          FeedEntryRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._feedEntriesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).feedEntriesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (cachedProcessingRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CachedProcessingRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._cachedProcessingRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedProcessingRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (cachedIntroductionsRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CachedIntroductionRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._cachedIntroductionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedIntroductionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (cachedConnectionsRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CachedConnectionRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._cachedConnectionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedConnectionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (cachedCommentPagesRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CachedCommentPageRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._cachedCommentPagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedCommentPagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (cachedChatsRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CachedChatRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._cachedChatsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedChatsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                      if (commentDraftsRefs)
                        await $_getPrefetchedData<
                          CachedPaperRow,
                          $CachedPapersTable,
                          CommentDraftRow
                        >(
                          currentTable: table,
                          referencedTable: $$CachedPapersTableReferences
                              ._commentDraftsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$CachedPapersTableReferences(
                                db,
                                table,
                                p0,
                              ).commentDraftsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.paperId == item.paperId,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$CachedPapersTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedPapersTable,
      CachedPaperRow,
      $$CachedPapersTableFilterComposer,
      $$CachedPapersTableOrderingComposer,
      $$CachedPapersTableAnnotationComposer,
      $$CachedPapersTableCreateCompanionBuilder,
      $$CachedPapersTableUpdateCompanionBuilder,
      (CachedPaperRow, $$CachedPapersTableReferences),
      CachedPaperRow,
      PrefetchHooks Function({
        bool feedEntriesRefs,
        bool cachedProcessingRefs,
        bool cachedIntroductionsRefs,
        bool cachedConnectionsRefs,
        bool cachedCommentPagesRefs,
        bool cachedChatsRefs,
        bool commentDraftsRefs,
      })
    >;
typedef $$FeedQueriesTableCreateCompanionBuilder =
    FeedQueriesCompanion Function({
      required String queryKey,
      Value<String?> category,
      Value<String?> nextCursor,
      required DateTime refreshedAt,
      Value<bool> exhausted,
      Value<String?> etag,
      Value<int> entryCount,
      Value<int> rowid,
    });
typedef $$FeedQueriesTableUpdateCompanionBuilder =
    FeedQueriesCompanion Function({
      Value<String> queryKey,
      Value<String?> category,
      Value<String?> nextCursor,
      Value<DateTime> refreshedAt,
      Value<bool> exhausted,
      Value<String?> etag,
      Value<int> entryCount,
      Value<int> rowid,
    });

final class $$FeedQueriesTableReferences
    extends BaseReferences<_$PakPerkDatabase, $FeedQueriesTable, FeedQueryRow> {
  $$FeedQueriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$FeedEntriesTable, List<FeedEntryRow>>
  _feedEntriesRefsTable(_$PakPerkDatabase db) => MultiTypedResultKey.fromTable(
    db.feedEntries,
    aliasName: 'feed_queries__query_key__feed_entries__query_key',
  );

  $$FeedEntriesTableProcessedTableManager get feedEntriesRefs {
    final manager = $$FeedEntriesTableTableManager($_db, $_db.feedEntries)
        .filter(
          (f) =>
              f.queryKey.queryKey.sqlEquals($_itemColumn<String>('query_key')!),
        );

    final cache = $_typedResult.readTableOrNull(_feedEntriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$FeedQueriesTableFilterComposer
    extends Composer<_$PakPerkDatabase, $FeedQueriesTable> {
  $$FeedQueriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get queryKey => $composableBuilder(
    column: $table.queryKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get refreshedAt => $composableBuilder(
    column: $table.refreshedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get exhausted => $composableBuilder(
    column: $table.exhausted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get entryCount => $composableBuilder(
    column: $table.entryCount,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> feedEntriesRefs(
    Expression<bool> Function($$FeedEntriesTableFilterComposer f) f,
  ) {
    final $$FeedEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queryKey,
      referencedTable: $db.feedEntries,
      getReferencedColumn: (t) => t.queryKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedEntriesTableFilterComposer(
            $db: $db,
            $table: $db.feedEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$FeedQueriesTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $FeedQueriesTable> {
  $$FeedQueriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get queryKey => $composableBuilder(
    column: $table.queryKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get refreshedAt => $composableBuilder(
    column: $table.refreshedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get exhausted => $composableBuilder(
    column: $table.exhausted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get entryCount => $composableBuilder(
    column: $table.entryCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FeedQueriesTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $FeedQueriesTable> {
  $$FeedQueriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get queryKey =>
      $composableBuilder(column: $table.queryKey, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get refreshedAt => $composableBuilder(
    column: $table.refreshedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get exhausted =>
      $composableBuilder(column: $table.exhausted, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<int> get entryCount => $composableBuilder(
    column: $table.entryCount,
    builder: (column) => column,
  );

  Expression<T> feedEntriesRefs<T extends Object>(
    Expression<T> Function($$FeedEntriesTableAnnotationComposer a) f,
  ) {
    final $$FeedEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queryKey,
      referencedTable: $db.feedEntries,
      getReferencedColumn: (t) => t.queryKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.feedEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$FeedQueriesTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $FeedQueriesTable,
          FeedQueryRow,
          $$FeedQueriesTableFilterComposer,
          $$FeedQueriesTableOrderingComposer,
          $$FeedQueriesTableAnnotationComposer,
          $$FeedQueriesTableCreateCompanionBuilder,
          $$FeedQueriesTableUpdateCompanionBuilder,
          (FeedQueryRow, $$FeedQueriesTableReferences),
          FeedQueryRow,
          PrefetchHooks Function({bool feedEntriesRefs})
        > {
  $$FeedQueriesTableTableManager(_$PakPerkDatabase db, $FeedQueriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FeedQueriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FeedQueriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FeedQueriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> queryKey = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> nextCursor = const Value.absent(),
                Value<DateTime> refreshedAt = const Value.absent(),
                Value<bool> exhausted = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<int> entryCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FeedQueriesCompanion(
                queryKey: queryKey,
                category: category,
                nextCursor: nextCursor,
                refreshedAt: refreshedAt,
                exhausted: exhausted,
                etag: etag,
                entryCount: entryCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String queryKey,
                Value<String?> category = const Value.absent(),
                Value<String?> nextCursor = const Value.absent(),
                required DateTime refreshedAt,
                Value<bool> exhausted = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<int> entryCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FeedQueriesCompanion.insert(
                queryKey: queryKey,
                category: category,
                nextCursor: nextCursor,
                refreshedAt: refreshedAt,
                exhausted: exhausted,
                etag: etag,
                entryCount: entryCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$FeedQueriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({feedEntriesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (feedEntriesRefs) db.feedEntries],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (feedEntriesRefs)
                    await $_getPrefetchedData<
                      FeedQueryRow,
                      $FeedQueriesTable,
                      FeedEntryRow
                    >(
                      currentTable: table,
                      referencedTable: $$FeedQueriesTableReferences
                          ._feedEntriesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$FeedQueriesTableReferences(
                            db,
                            table,
                            p0,
                          ).feedEntriesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.queryKey == item.queryKey,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$FeedQueriesTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $FeedQueriesTable,
      FeedQueryRow,
      $$FeedQueriesTableFilterComposer,
      $$FeedQueriesTableOrderingComposer,
      $$FeedQueriesTableAnnotationComposer,
      $$FeedQueriesTableCreateCompanionBuilder,
      $$FeedQueriesTableUpdateCompanionBuilder,
      (FeedQueryRow, $$FeedQueriesTableReferences),
      FeedQueryRow,
      PrefetchHooks Function({bool feedEntriesRefs})
    >;
typedef $$FeedEntriesTableCreateCompanionBuilder =
    FeedEntriesCompanion Function({
      required String queryKey,
      required int position,
      required String paperId,
      required DateTime insertedAt,
      Value<int> rowid,
    });
typedef $$FeedEntriesTableUpdateCompanionBuilder =
    FeedEntriesCompanion Function({
      Value<String> queryKey,
      Value<int> position,
      Value<String> paperId,
      Value<DateTime> insertedAt,
      Value<int> rowid,
    });

final class $$FeedEntriesTableReferences
    extends BaseReferences<_$PakPerkDatabase, $FeedEntriesTable, FeedEntryRow> {
  $$FeedEntriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $FeedQueriesTable _queryKeyTable(_$PakPerkDatabase db) => db
      .feedQueries
      .createAlias('feed_entries__query_key__feed_queries__query_key');

  $$FeedQueriesTableProcessedTableManager get queryKey {
    final $_column = $_itemColumn<String>('query_key')!;

    final manager = $$FeedQueriesTableTableManager(
      $_db,
      $_db.feedQueries,
    ).filter((f) => f.queryKey.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_queryKeyTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('feed_entries__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$FeedEntriesTableFilterComposer
    extends Composer<_$PakPerkDatabase, $FeedEntriesTable> {
  $$FeedEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get insertedAt => $composableBuilder(
    column: $table.insertedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$FeedQueriesTableFilterComposer get queryKey {
    final $$FeedQueriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queryKey,
      referencedTable: $db.feedQueries,
      getReferencedColumn: (t) => t.queryKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedQueriesTableFilterComposer(
            $db: $db,
            $table: $db.feedQueries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FeedEntriesTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $FeedEntriesTable> {
  $$FeedEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get insertedAt => $composableBuilder(
    column: $table.insertedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$FeedQueriesTableOrderingComposer get queryKey {
    final $$FeedQueriesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queryKey,
      referencedTable: $db.feedQueries,
      getReferencedColumn: (t) => t.queryKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedQueriesTableOrderingComposer(
            $db: $db,
            $table: $db.feedQueries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FeedEntriesTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $FeedEntriesTable> {
  $$FeedEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<DateTime> get insertedAt => $composableBuilder(
    column: $table.insertedAt,
    builder: (column) => column,
  );

  $$FeedQueriesTableAnnotationComposer get queryKey {
    final $$FeedQueriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queryKey,
      referencedTable: $db.feedQueries,
      getReferencedColumn: (t) => t.queryKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FeedQueriesTableAnnotationComposer(
            $db: $db,
            $table: $db.feedQueries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FeedEntriesTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $FeedEntriesTable,
          FeedEntryRow,
          $$FeedEntriesTableFilterComposer,
          $$FeedEntriesTableOrderingComposer,
          $$FeedEntriesTableAnnotationComposer,
          $$FeedEntriesTableCreateCompanionBuilder,
          $$FeedEntriesTableUpdateCompanionBuilder,
          (FeedEntryRow, $$FeedEntriesTableReferences),
          FeedEntryRow,
          PrefetchHooks Function({bool queryKey, bool paperId})
        > {
  $$FeedEntriesTableTableManager(_$PakPerkDatabase db, $FeedEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FeedEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FeedEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FeedEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> queryKey = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String> paperId = const Value.absent(),
                Value<DateTime> insertedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FeedEntriesCompanion(
                queryKey: queryKey,
                position: position,
                paperId: paperId,
                insertedAt: insertedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String queryKey,
                required int position,
                required String paperId,
                required DateTime insertedAt,
                Value<int> rowid = const Value.absent(),
              }) => FeedEntriesCompanion.insert(
                queryKey: queryKey,
                position: position,
                paperId: paperId,
                insertedAt: insertedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$FeedEntriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({queryKey = false, paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (queryKey) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.queryKey,
                                referencedTable: $$FeedEntriesTableReferences
                                    ._queryKeyTable(db),
                                referencedColumn: $$FeedEntriesTableReferences
                                    ._queryKeyTable(db)
                                    .queryKey,
                              )
                              as T;
                    }
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable: $$FeedEntriesTableReferences
                                    ._paperIdTable(db),
                                referencedColumn: $$FeedEntriesTableReferences
                                    ._paperIdTable(db)
                                    .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$FeedEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $FeedEntriesTable,
      FeedEntryRow,
      $$FeedEntriesTableFilterComposer,
      $$FeedEntriesTableOrderingComposer,
      $$FeedEntriesTableAnnotationComposer,
      $$FeedEntriesTableCreateCompanionBuilder,
      $$FeedEntriesTableUpdateCompanionBuilder,
      (FeedEntryRow, $$FeedEntriesTableReferences),
      FeedEntryRow,
      PrefetchHooks Function({bool queryKey, bool paperId})
    >;
typedef $$CachedProcessingTableCreateCompanionBuilder =
    CachedProcessingCompanion Function({
      required String paperId,
      required String versionKey,
      Value<int> generation,
      required String payloadJson,
      required DateTime updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });
typedef $$CachedProcessingTableUpdateCompanionBuilder =
    CachedProcessingCompanion Function({
      Value<String> paperId,
      Value<String> versionKey,
      Value<int> generation,
      Value<String> payloadJson,
      Value<DateTime> updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });

final class $$CachedProcessingTableReferences
    extends
        BaseReferences<
          _$PakPerkDatabase,
          $CachedProcessingTable,
          CachedProcessingRow
        > {
  $$CachedProcessingTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('cached_processing__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedProcessingTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedProcessingTable> {
  $$CachedProcessingTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedProcessingTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedProcessingTable> {
  $$CachedProcessingTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedProcessingTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedProcessingTable> {
  $$CachedProcessingTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedProcessingTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedProcessingTable,
          CachedProcessingRow,
          $$CachedProcessingTableFilterComposer,
          $$CachedProcessingTableOrderingComposer,
          $$CachedProcessingTableAnnotationComposer,
          $$CachedProcessingTableCreateCompanionBuilder,
          $$CachedProcessingTableUpdateCompanionBuilder,
          (CachedProcessingRow, $$CachedProcessingTableReferences),
          CachedProcessingRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CachedProcessingTableTableManager(
    _$PakPerkDatabase db,
    $CachedProcessingTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedProcessingTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedProcessingTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedProcessingTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> paperId = const Value.absent(),
                Value<String> versionKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedProcessingCompanion(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String paperId,
                required String versionKey,
                Value<int> generation = const Value.absent(),
                required String payloadJson,
                required DateTime updatedAt,
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedProcessingCompanion.insert(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedProcessingTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable:
                                    $$CachedProcessingTableReferences
                                        ._paperIdTable(db),
                                referencedColumn:
                                    $$CachedProcessingTableReferences
                                        ._paperIdTable(db)
                                        .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedProcessingTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedProcessingTable,
      CachedProcessingRow,
      $$CachedProcessingTableFilterComposer,
      $$CachedProcessingTableOrderingComposer,
      $$CachedProcessingTableAnnotationComposer,
      $$CachedProcessingTableCreateCompanionBuilder,
      $$CachedProcessingTableUpdateCompanionBuilder,
      (CachedProcessingRow, $$CachedProcessingTableReferences),
      CachedProcessingRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$CachedIntroductionsTableCreateCompanionBuilder =
    CachedIntroductionsCompanion Function({
      required String paperId,
      required String versionKey,
      required int generation,
      required String payloadJson,
      required DateTime updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });
typedef $$CachedIntroductionsTableUpdateCompanionBuilder =
    CachedIntroductionsCompanion Function({
      Value<String> paperId,
      Value<String> versionKey,
      Value<int> generation,
      Value<String> payloadJson,
      Value<DateTime> updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });

final class $$CachedIntroductionsTableReferences
    extends
        BaseReferences<
          _$PakPerkDatabase,
          $CachedIntroductionsTable,
          CachedIntroductionRow
        > {
  $$CachedIntroductionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('cached_introductions__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedIntroductionsTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedIntroductionsTable> {
  $$CachedIntroductionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedIntroductionsTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedIntroductionsTable> {
  $$CachedIntroductionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedIntroductionsTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedIntroductionsTable> {
  $$CachedIntroductionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedIntroductionsTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedIntroductionsTable,
          CachedIntroductionRow,
          $$CachedIntroductionsTableFilterComposer,
          $$CachedIntroductionsTableOrderingComposer,
          $$CachedIntroductionsTableAnnotationComposer,
          $$CachedIntroductionsTableCreateCompanionBuilder,
          $$CachedIntroductionsTableUpdateCompanionBuilder,
          (CachedIntroductionRow, $$CachedIntroductionsTableReferences),
          CachedIntroductionRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CachedIntroductionsTableTableManager(
    _$PakPerkDatabase db,
    $CachedIntroductionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedIntroductionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedIntroductionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CachedIntroductionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> paperId = const Value.absent(),
                Value<String> versionKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedIntroductionsCompanion(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String paperId,
                required String versionKey,
                required int generation,
                required String payloadJson,
                required DateTime updatedAt,
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedIntroductionsCompanion.insert(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedIntroductionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable:
                                    $$CachedIntroductionsTableReferences
                                        ._paperIdTable(db),
                                referencedColumn:
                                    $$CachedIntroductionsTableReferences
                                        ._paperIdTable(db)
                                        .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedIntroductionsTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedIntroductionsTable,
      CachedIntroductionRow,
      $$CachedIntroductionsTableFilterComposer,
      $$CachedIntroductionsTableOrderingComposer,
      $$CachedIntroductionsTableAnnotationComposer,
      $$CachedIntroductionsTableCreateCompanionBuilder,
      $$CachedIntroductionsTableUpdateCompanionBuilder,
      (CachedIntroductionRow, $$CachedIntroductionsTableReferences),
      CachedIntroductionRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$CachedConnectionsTableCreateCompanionBuilder =
    CachedConnectionsCompanion Function({
      required String paperId,
      required String versionKey,
      Value<int> generation,
      required String payloadJson,
      required DateTime updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });
typedef $$CachedConnectionsTableUpdateCompanionBuilder =
    CachedConnectionsCompanion Function({
      Value<String> paperId,
      Value<String> versionKey,
      Value<int> generation,
      Value<String> payloadJson,
      Value<DateTime> updatedAt,
      Value<DateTime?> expiresAt,
      Value<int> rowid,
    });

final class $$CachedConnectionsTableReferences
    extends
        BaseReferences<
          _$PakPerkDatabase,
          $CachedConnectionsTable,
          CachedConnectionRow
        > {
  $$CachedConnectionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('cached_connections__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedConnectionsTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedConnectionsTable> {
  $$CachedConnectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConnectionsTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedConnectionsTable> {
  $$CachedConnectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConnectionsTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedConnectionsTable> {
  $$CachedConnectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedConnectionsTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedConnectionsTable,
          CachedConnectionRow,
          $$CachedConnectionsTableFilterComposer,
          $$CachedConnectionsTableOrderingComposer,
          $$CachedConnectionsTableAnnotationComposer,
          $$CachedConnectionsTableCreateCompanionBuilder,
          $$CachedConnectionsTableUpdateCompanionBuilder,
          (CachedConnectionRow, $$CachedConnectionsTableReferences),
          CachedConnectionRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CachedConnectionsTableTableManager(
    _$PakPerkDatabase db,
    $CachedConnectionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedConnectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedConnectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedConnectionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> paperId = const Value.absent(),
                Value<String> versionKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedConnectionsCompanion(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String paperId,
                required String versionKey,
                Value<int> generation = const Value.absent(),
                required String payloadJson,
                required DateTime updatedAt,
                Value<DateTime?> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedConnectionsCompanion.insert(
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedConnectionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable:
                                    $$CachedConnectionsTableReferences
                                        ._paperIdTable(db),
                                referencedColumn:
                                    $$CachedConnectionsTableReferences
                                        ._paperIdTable(db)
                                        .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedConnectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedConnectionsTable,
      CachedConnectionRow,
      $$CachedConnectionsTableFilterComposer,
      $$CachedConnectionsTableOrderingComposer,
      $$CachedConnectionsTableAnnotationComposer,
      $$CachedConnectionsTableCreateCompanionBuilder,
      $$CachedConnectionsTableUpdateCompanionBuilder,
      (CachedConnectionRow, $$CachedConnectionsTableReferences),
      CachedConnectionRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$CachedCommentPagesTableCreateCompanionBuilder =
    CachedCommentPagesCompanion Function({
      required String pageKey,
      required String paperId,
      Value<String?> viewerAccountId,
      Value<String?> cursor,
      required String payloadJson,
      required DateTime fetchedAt,
      required DateTime expiresAt,
      Value<String?> etag,
      Value<int> rowid,
    });
typedef $$CachedCommentPagesTableUpdateCompanionBuilder =
    CachedCommentPagesCompanion Function({
      Value<String> pageKey,
      Value<String> paperId,
      Value<String?> viewerAccountId,
      Value<String?> cursor,
      Value<String> payloadJson,
      Value<DateTime> fetchedAt,
      Value<DateTime> expiresAt,
      Value<String?> etag,
      Value<int> rowid,
    });

final class $$CachedCommentPagesTableReferences
    extends
        BaseReferences<
          _$PakPerkDatabase,
          $CachedCommentPagesTable,
          CachedCommentPageRow
        > {
  $$CachedCommentPagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('cached_comment_pages__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedCommentPagesTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedCommentPagesTable> {
  $$CachedCommentPagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get pageKey => $composableBuilder(
    column: $table.pageKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get viewerAccountId => $composableBuilder(
    column: $table.viewerAccountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedCommentPagesTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedCommentPagesTable> {
  $$CachedCommentPagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get pageKey => $composableBuilder(
    column: $table.pageKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get viewerAccountId => $composableBuilder(
    column: $table.viewerAccountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedCommentPagesTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedCommentPagesTable> {
  $$CachedCommentPagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get pageKey =>
      $composableBuilder(column: $table.pageKey, builder: (column) => column);

  GeneratedColumn<String> get viewerAccountId => $composableBuilder(
    column: $table.viewerAccountId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedCommentPagesTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedCommentPagesTable,
          CachedCommentPageRow,
          $$CachedCommentPagesTableFilterComposer,
          $$CachedCommentPagesTableOrderingComposer,
          $$CachedCommentPagesTableAnnotationComposer,
          $$CachedCommentPagesTableCreateCompanionBuilder,
          $$CachedCommentPagesTableUpdateCompanionBuilder,
          (CachedCommentPageRow, $$CachedCommentPagesTableReferences),
          CachedCommentPageRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CachedCommentPagesTableTableManager(
    _$PakPerkDatabase db,
    $CachedCommentPagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedCommentPagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedCommentPagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedCommentPagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> pageKey = const Value.absent(),
                Value<String> paperId = const Value.absent(),
                Value<String?> viewerAccountId = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> fetchedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedCommentPagesCompanion(
                pageKey: pageKey,
                paperId: paperId,
                viewerAccountId: viewerAccountId,
                cursor: cursor,
                payloadJson: payloadJson,
                fetchedAt: fetchedAt,
                expiresAt: expiresAt,
                etag: etag,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String pageKey,
                required String paperId,
                Value<String?> viewerAccountId = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                required String payloadJson,
                required DateTime fetchedAt,
                required DateTime expiresAt,
                Value<String?> etag = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedCommentPagesCompanion.insert(
                pageKey: pageKey,
                paperId: paperId,
                viewerAccountId: viewerAccountId,
                cursor: cursor,
                payloadJson: payloadJson,
                fetchedAt: fetchedAt,
                expiresAt: expiresAt,
                etag: etag,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedCommentPagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable:
                                    $$CachedCommentPagesTableReferences
                                        ._paperIdTable(db),
                                referencedColumn:
                                    $$CachedCommentPagesTableReferences
                                        ._paperIdTable(db)
                                        .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedCommentPagesTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedCommentPagesTable,
      CachedCommentPageRow,
      $$CachedCommentPagesTableFilterComposer,
      $$CachedCommentPagesTableOrderingComposer,
      $$CachedCommentPagesTableAnnotationComposer,
      $$CachedCommentPagesTableCreateCompanionBuilder,
      $$CachedCommentPagesTableUpdateCompanionBuilder,
      (CachedCommentPageRow, $$CachedCommentPagesTableReferences),
      CachedCommentPageRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$CachedChatsTableCreateCompanionBuilder =
    CachedChatsCompanion Function({
      required String sessionId,
      required String readerKey,
      Value<String?> paperId,
      Value<String?> versionKey,
      Value<int> generation,
      required String payloadJson,
      required DateTime updatedAt,
      required DateTime expiresAt,
      Value<int> rowid,
    });
typedef $$CachedChatsTableUpdateCompanionBuilder =
    CachedChatsCompanion Function({
      Value<String> sessionId,
      Value<String> readerKey,
      Value<String?> paperId,
      Value<String?> versionKey,
      Value<int> generation,
      Value<String> payloadJson,
      Value<DateTime> updatedAt,
      Value<DateTime> expiresAt,
      Value<int> rowid,
    });

final class $$CachedChatsTableReferences
    extends
        BaseReferences<_$PakPerkDatabase, $CachedChatsTable, CachedChatRow> {
  $$CachedChatsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('cached_chats__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager? get paperId {
    final $_column = $_itemColumn<String>('paper_id');
    if ($_column == null) return null;
    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedChatsTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CachedChatsTable> {
  $$CachedChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get readerKey => $composableBuilder(
    column: $table.readerKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatsTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CachedChatsTable> {
  $$CachedChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get readerKey => $composableBuilder(
    column: $table.readerKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatsTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CachedChatsTable> {
  $$CachedChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get readerKey =>
      $composableBuilder(column: $table.readerKey, builder: (column) => column);

  GeneratedColumn<String> get versionKey => $composableBuilder(
    column: $table.versionKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get generation => $composableBuilder(
    column: $table.generation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedChatsTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CachedChatsTable,
          CachedChatRow,
          $$CachedChatsTableFilterComposer,
          $$CachedChatsTableOrderingComposer,
          $$CachedChatsTableAnnotationComposer,
          $$CachedChatsTableCreateCompanionBuilder,
          $$CachedChatsTableUpdateCompanionBuilder,
          (CachedChatRow, $$CachedChatsTableReferences),
          CachedChatRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CachedChatsTableTableManager(_$PakPerkDatabase db, $CachedChatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sessionId = const Value.absent(),
                Value<String> readerKey = const Value.absent(),
                Value<String?> paperId = const Value.absent(),
                Value<String?> versionKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedChatsCompanion(
                sessionId: sessionId,
                readerKey: readerKey,
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sessionId,
                required String readerKey,
                Value<String?> paperId = const Value.absent(),
                Value<String?> versionKey = const Value.absent(),
                Value<int> generation = const Value.absent(),
                required String payloadJson,
                required DateTime updatedAt,
                required DateTime expiresAt,
                Value<int> rowid = const Value.absent(),
              }) => CachedChatsCompanion.insert(
                sessionId: sessionId,
                readerKey: readerKey,
                paperId: paperId,
                versionKey: versionKey,
                generation: generation,
                payloadJson: payloadJson,
                updatedAt: updatedAt,
                expiresAt: expiresAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedChatsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable: $$CachedChatsTableReferences
                                    ._paperIdTable(db),
                                referencedColumn: $$CachedChatsTableReferences
                                    ._paperIdTable(db)
                                    .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedChatsTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CachedChatsTable,
      CachedChatRow,
      $$CachedChatsTableFilterComposer,
      $$CachedChatsTableOrderingComposer,
      $$CachedChatsTableAnnotationComposer,
      $$CachedChatsTableCreateCompanionBuilder,
      $$CachedChatsTableUpdateCompanionBuilder,
      (CachedChatRow, $$CachedChatsTableReferences),
      CachedChatRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$LibraryItemsTableCreateCompanionBuilder =
    LibraryItemsCompanion Function({
      required String accountId,
      required String paperId,
      Value<String> listState,
      required DateTime clientUpdatedAt,
      Value<DateTime?> serverUpdatedAt,
      Value<bool> deleted,
      Value<DateTime?> savedAt,
      Value<DateTime?> removedAt,
      Value<int?> revision,
      Value<String?> lastOperationId,
      Value<bool?> canonicalDeleted,
      Value<DateTime?> canonicalSavedAt,
      Value<DateTime?> canonicalRemovedAt,
      Value<int> rowid,
    });
typedef $$LibraryItemsTableUpdateCompanionBuilder =
    LibraryItemsCompanion Function({
      Value<String> accountId,
      Value<String> paperId,
      Value<String> listState,
      Value<DateTime> clientUpdatedAt,
      Value<DateTime?> serverUpdatedAt,
      Value<bool> deleted,
      Value<DateTime?> savedAt,
      Value<DateTime?> removedAt,
      Value<int?> revision,
      Value<String?> lastOperationId,
      Value<bool?> canonicalDeleted,
      Value<DateTime?> canonicalSavedAt,
      Value<DateTime?> canonicalRemovedAt,
      Value<int> rowid,
    });

class $$LibraryItemsTableFilterComposer
    extends Composer<_$PakPerkDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get paperId => $composableBuilder(
    column: $table.paperId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get listState => $composableBuilder(
    column: $table.listState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get clientUpdatedAt => $composableBuilder(
    column: $table.clientUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get removedAt => $composableBuilder(
    column: $table.removedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastOperationId => $composableBuilder(
    column: $table.lastOperationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get canonicalDeleted => $composableBuilder(
    column: $table.canonicalDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get canonicalSavedAt => $composableBuilder(
    column: $table.canonicalSavedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get canonicalRemovedAt => $composableBuilder(
    column: $table.canonicalRemovedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibraryItemsTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get paperId => $composableBuilder(
    column: $table.paperId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get listState => $composableBuilder(
    column: $table.listState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get clientUpdatedAt => $composableBuilder(
    column: $table.clientUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get removedAt => $composableBuilder(
    column: $table.removedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastOperationId => $composableBuilder(
    column: $table.lastOperationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get canonicalDeleted => $composableBuilder(
    column: $table.canonicalDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get canonicalSavedAt => $composableBuilder(
    column: $table.canonicalSavedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get canonicalRemovedAt => $composableBuilder(
    column: $table.canonicalRemovedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryItemsTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get paperId =>
      $composableBuilder(column: $table.paperId, builder: (column) => column);

  GeneratedColumn<String> get listState =>
      $composableBuilder(column: $table.listState, builder: (column) => column);

  GeneratedColumn<DateTime> get clientUpdatedAt => $composableBuilder(
    column: $table.clientUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<DateTime> get savedAt =>
      $composableBuilder(column: $table.savedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get removedAt =>
      $composableBuilder(column: $table.removedAt, builder: (column) => column);

  GeneratedColumn<int> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);

  GeneratedColumn<String> get lastOperationId => $composableBuilder(
    column: $table.lastOperationId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get canonicalDeleted => $composableBuilder(
    column: $table.canonicalDeleted,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get canonicalSavedAt => $composableBuilder(
    column: $table.canonicalSavedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get canonicalRemovedAt => $composableBuilder(
    column: $table.canonicalRemovedAt,
    builder: (column) => column,
  );
}

class $$LibraryItemsTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $LibraryItemsTable,
          LibraryItemRow,
          $$LibraryItemsTableFilterComposer,
          $$LibraryItemsTableOrderingComposer,
          $$LibraryItemsTableAnnotationComposer,
          $$LibraryItemsTableCreateCompanionBuilder,
          $$LibraryItemsTableUpdateCompanionBuilder,
          (
            LibraryItemRow,
            BaseReferences<
              _$PakPerkDatabase,
              $LibraryItemsTable,
              LibraryItemRow
            >,
          ),
          LibraryItemRow,
          PrefetchHooks Function()
        > {
  $$LibraryItemsTableTableManager(
    _$PakPerkDatabase db,
    $LibraryItemsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> paperId = const Value.absent(),
                Value<String> listState = const Value.absent(),
                Value<DateTime> clientUpdatedAt = const Value.absent(),
                Value<DateTime?> serverUpdatedAt = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<DateTime?> savedAt = const Value.absent(),
                Value<DateTime?> removedAt = const Value.absent(),
                Value<int?> revision = const Value.absent(),
                Value<String?> lastOperationId = const Value.absent(),
                Value<bool?> canonicalDeleted = const Value.absent(),
                Value<DateTime?> canonicalSavedAt = const Value.absent(),
                Value<DateTime?> canonicalRemovedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemsCompanion(
                accountId: accountId,
                paperId: paperId,
                listState: listState,
                clientUpdatedAt: clientUpdatedAt,
                serverUpdatedAt: serverUpdatedAt,
                deleted: deleted,
                savedAt: savedAt,
                removedAt: removedAt,
                revision: revision,
                lastOperationId: lastOperationId,
                canonicalDeleted: canonicalDeleted,
                canonicalSavedAt: canonicalSavedAt,
                canonicalRemovedAt: canonicalRemovedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String paperId,
                Value<String> listState = const Value.absent(),
                required DateTime clientUpdatedAt,
                Value<DateTime?> serverUpdatedAt = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<DateTime?> savedAt = const Value.absent(),
                Value<DateTime?> removedAt = const Value.absent(),
                Value<int?> revision = const Value.absent(),
                Value<String?> lastOperationId = const Value.absent(),
                Value<bool?> canonicalDeleted = const Value.absent(),
                Value<DateTime?> canonicalSavedAt = const Value.absent(),
                Value<DateTime?> canonicalRemovedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemsCompanion.insert(
                accountId: accountId,
                paperId: paperId,
                listState: listState,
                clientUpdatedAt: clientUpdatedAt,
                serverUpdatedAt: serverUpdatedAt,
                deleted: deleted,
                savedAt: savedAt,
                removedAt: removedAt,
                revision: revision,
                lastOperationId: lastOperationId,
                canonicalDeleted: canonicalDeleted,
                canonicalSavedAt: canonicalSavedAt,
                canonicalRemovedAt: canonicalRemovedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibraryItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $LibraryItemsTable,
      LibraryItemRow,
      $$LibraryItemsTableFilterComposer,
      $$LibraryItemsTableOrderingComposer,
      $$LibraryItemsTableAnnotationComposer,
      $$LibraryItemsTableCreateCompanionBuilder,
      $$LibraryItemsTableUpdateCompanionBuilder,
      (
        LibraryItemRow,
        BaseReferences<_$PakPerkDatabase, $LibraryItemsTable, LibraryItemRow>,
      ),
      LibraryItemRow,
      PrefetchHooks Function()
    >;
typedef $$CommentDraftsTableCreateCompanionBuilder =
    CommentDraftsCompanion Function({
      required String draftId,
      Value<String?> accountId,
      required String paperId,
      required String body,
      Value<String?> clientRequestId,
      Value<String?> lastAttemptedBody,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$CommentDraftsTableUpdateCompanionBuilder =
    CommentDraftsCompanion Function({
      Value<String> draftId,
      Value<String?> accountId,
      Value<String> paperId,
      Value<String> body,
      Value<String?> clientRequestId,
      Value<String?> lastAttemptedBody,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$CommentDraftsTableReferences
    extends
        BaseReferences<
          _$PakPerkDatabase,
          $CommentDraftsTable,
          CommentDraftRow
        > {
  $$CommentDraftsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $CachedPapersTable _paperIdTable(_$PakPerkDatabase db) => db
      .cachedPapers
      .createAlias('comment_drafts__paper_id__cached_papers__paper_id');

  $$CachedPapersTableProcessedTableManager get paperId {
    final $_column = $_itemColumn<String>('paper_id')!;

    final manager = $$CachedPapersTableTableManager(
      $_db,
      $_db.cachedPapers,
    ).filter((f) => f.paperId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_paperIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CommentDraftsTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CommentDraftsTable> {
  $$CommentDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastAttemptedBody => $composableBuilder(
    column: $table.lastAttemptedBody,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$CachedPapersTableFilterComposer get paperId {
    final $$CachedPapersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableFilterComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentDraftsTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CommentDraftsTable> {
  $$CommentDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastAttemptedBody => $composableBuilder(
    column: $table.lastAttemptedBody,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$CachedPapersTableOrderingComposer get paperId {
    final $$CachedPapersTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableOrderingComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentDraftsTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CommentDraftsTable> {
  $$CommentDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get draftId =>
      $composableBuilder(column: $table.draftId, builder: (column) => column);

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastAttemptedBody => $composableBuilder(
    column: $table.lastAttemptedBody,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$CachedPapersTableAnnotationComposer get paperId {
    final $$CachedPapersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.paperId,
      referencedTable: $db.cachedPapers,
      getReferencedColumn: (t) => t.paperId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedPapersTableAnnotationComposer(
            $db: $db,
            $table: $db.cachedPapers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CommentDraftsTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CommentDraftsTable,
          CommentDraftRow,
          $$CommentDraftsTableFilterComposer,
          $$CommentDraftsTableOrderingComposer,
          $$CommentDraftsTableAnnotationComposer,
          $$CommentDraftsTableCreateCompanionBuilder,
          $$CommentDraftsTableUpdateCompanionBuilder,
          (CommentDraftRow, $$CommentDraftsTableReferences),
          CommentDraftRow,
          PrefetchHooks Function({bool paperId})
        > {
  $$CommentDraftsTableTableManager(
    _$PakPerkDatabase db,
    $CommentDraftsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CommentDraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CommentDraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CommentDraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> draftId = const Value.absent(),
                Value<String?> accountId = const Value.absent(),
                Value<String> paperId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> clientRequestId = const Value.absent(),
                Value<String?> lastAttemptedBody = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CommentDraftsCompanion(
                draftId: draftId,
                accountId: accountId,
                paperId: paperId,
                body: body,
                clientRequestId: clientRequestId,
                lastAttemptedBody: lastAttemptedBody,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String draftId,
                Value<String?> accountId = const Value.absent(),
                required String paperId,
                required String body,
                Value<String?> clientRequestId = const Value.absent(),
                Value<String?> lastAttemptedBody = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CommentDraftsCompanion.insert(
                draftId: draftId,
                accountId: accountId,
                paperId: paperId,
                body: body,
                clientRequestId: clientRequestId,
                lastAttemptedBody: lastAttemptedBody,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CommentDraftsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({paperId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (paperId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.paperId,
                                referencedTable: $$CommentDraftsTableReferences
                                    ._paperIdTable(db),
                                referencedColumn: $$CommentDraftsTableReferences
                                    ._paperIdTable(db)
                                    .paperId,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CommentDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CommentDraftsTable,
      CommentDraftRow,
      $$CommentDraftsTableFilterComposer,
      $$CommentDraftsTableOrderingComposer,
      $$CommentDraftsTableAnnotationComposer,
      $$CommentDraftsTableCreateCompanionBuilder,
      $$CommentDraftsTableUpdateCompanionBuilder,
      (CommentDraftRow, $$CommentDraftsTableReferences),
      CommentDraftRow,
      PrefetchHooks Function({bool paperId})
    >;
typedef $$BlockedUsersTableCreateCompanionBuilder =
    BlockedUsersCompanion Function({
      required String accountId,
      required String blockedUserId,
      required String handle,
      Value<String?> displayName,
      required DateTime createdAt,
      Value<bool> serverConfirmed,
      Value<int> rowid,
    });
typedef $$BlockedUsersTableUpdateCompanionBuilder =
    BlockedUsersCompanion Function({
      Value<String> accountId,
      Value<String> blockedUserId,
      Value<String> handle,
      Value<String?> displayName,
      Value<DateTime> createdAt,
      Value<bool> serverConfirmed,
      Value<int> rowid,
    });

class $$BlockedUsersTableFilterComposer
    extends Composer<_$PakPerkDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blockedUserId => $composableBuilder(
    column: $table.blockedUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get handle => $composableBuilder(
    column: $table.handle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get serverConfirmed => $composableBuilder(
    column: $table.serverConfirmed,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BlockedUsersTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blockedUserId => $composableBuilder(
    column: $table.blockedUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get handle => $composableBuilder(
    column: $table.handle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get serverConfirmed => $composableBuilder(
    column: $table.serverConfirmed,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BlockedUsersTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $BlockedUsersTable> {
  $$BlockedUsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get blockedUserId => $composableBuilder(
    column: $table.blockedUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get handle =>
      $composableBuilder(column: $table.handle, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get serverConfirmed => $composableBuilder(
    column: $table.serverConfirmed,
    builder: (column) => column,
  );
}

class $$BlockedUsersTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $BlockedUsersTable,
          BlockedUserRow,
          $$BlockedUsersTableFilterComposer,
          $$BlockedUsersTableOrderingComposer,
          $$BlockedUsersTableAnnotationComposer,
          $$BlockedUsersTableCreateCompanionBuilder,
          $$BlockedUsersTableUpdateCompanionBuilder,
          (
            BlockedUserRow,
            BaseReferences<
              _$PakPerkDatabase,
              $BlockedUsersTable,
              BlockedUserRow
            >,
          ),
          BlockedUserRow,
          PrefetchHooks Function()
        > {
  $$BlockedUsersTableTableManager(
    _$PakPerkDatabase db,
    $BlockedUsersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BlockedUsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BlockedUsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BlockedUsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> blockedUserId = const Value.absent(),
                Value<String> handle = const Value.absent(),
                Value<String?> displayName = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<bool> serverConfirmed = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BlockedUsersCompanion(
                accountId: accountId,
                blockedUserId: blockedUserId,
                handle: handle,
                displayName: displayName,
                createdAt: createdAt,
                serverConfirmed: serverConfirmed,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String blockedUserId,
                required String handle,
                Value<String?> displayName = const Value.absent(),
                required DateTime createdAt,
                Value<bool> serverConfirmed = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BlockedUsersCompanion.insert(
                accountId: accountId,
                blockedUserId: blockedUserId,
                handle: handle,
                displayName: displayName,
                createdAt: createdAt,
                serverConfirmed: serverConfirmed,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BlockedUsersTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $BlockedUsersTable,
      BlockedUserRow,
      $$BlockedUsersTableFilterComposer,
      $$BlockedUsersTableOrderingComposer,
      $$BlockedUsersTableAnnotationComposer,
      $$BlockedUsersTableCreateCompanionBuilder,
      $$BlockedUsersTableUpdateCompanionBuilder,
      (
        BlockedUserRow,
        BaseReferences<_$PakPerkDatabase, $BlockedUsersTable, BlockedUserRow>,
      ),
      BlockedUserRow,
      PrefetchHooks Function()
    >;
typedef $$SyncOutboxTableCreateCompanionBuilder =
    SyncOutboxCompanion Function({
      required String operationId,
      Value<String?> accountId,
      required String entityKind,
      required String entityId,
      required String operation,
      required String payloadJson,
      required DateTime createdAt,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastErrorCode,
      Value<String> state,
      Value<DateTime?> startedAt,
      Value<DateTime?> updatedAt,
      Value<int> rowid,
    });
typedef $$SyncOutboxTableUpdateCompanionBuilder =
    SyncOutboxCompanion Function({
      Value<String> operationId,
      Value<String?> accountId,
      Value<String> entityKind,
      Value<String> entityId,
      Value<String> operation,
      Value<String> payloadJson,
      Value<DateTime> createdAt,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastErrorCode,
      Value<String> state,
      Value<DateTime?> startedAt,
      Value<DateTime?> updatedAt,
      Value<int> rowid,
    });

class $$SyncOutboxTableFilterComposer
    extends Composer<_$PakPerkDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operation => $composableBuilder(
    column: $table.operation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncOutboxTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operation => $composableBuilder(
    column: $table.operation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncOutboxTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $SyncOutboxTable> {
  $$SyncOutboxTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get operation =>
      $composableBuilder(column: $table.operation, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SyncOutboxTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $SyncOutboxTable,
          SyncOutboxRow,
          $$SyncOutboxTableFilterComposer,
          $$SyncOutboxTableOrderingComposer,
          $$SyncOutboxTableAnnotationComposer,
          $$SyncOutboxTableCreateCompanionBuilder,
          $$SyncOutboxTableUpdateCompanionBuilder,
          (
            SyncOutboxRow,
            BaseReferences<_$PakPerkDatabase, $SyncOutboxTable, SyncOutboxRow>,
          ),
          SyncOutboxRow,
          PrefetchHooks Function()
        > {
  $$SyncOutboxTableTableManager(_$PakPerkDatabase db, $SyncOutboxTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncOutboxTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncOutboxTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncOutboxTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> operationId = const Value.absent(),
                Value<String?> accountId = const Value.absent(),
                Value<String> entityKind = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> operation = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<DateTime?> startedAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncOutboxCompanion(
                operationId: operationId,
                accountId: accountId,
                entityKind: entityKind,
                entityId: entityId,
                operation: operation,
                payloadJson: payloadJson,
                createdAt: createdAt,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
                state: state,
                startedAt: startedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String operationId,
                Value<String?> accountId = const Value.absent(),
                required String entityKind,
                required String entityId,
                required String operation,
                required String payloadJson,
                required DateTime createdAt,
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<DateTime?> startedAt = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncOutboxCompanion.insert(
                operationId: operationId,
                accountId: accountId,
                entityKind: entityKind,
                entityId: entityId,
                operation: operation,
                payloadJson: payloadJson,
                createdAt: createdAt,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
                state: state,
                startedAt: startedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncOutboxTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $SyncOutboxTable,
      SyncOutboxRow,
      $$SyncOutboxTableFilterComposer,
      $$SyncOutboxTableOrderingComposer,
      $$SyncOutboxTableAnnotationComposer,
      $$SyncOutboxTableCreateCompanionBuilder,
      $$SyncOutboxTableUpdateCompanionBuilder,
      (
        SyncOutboxRow,
        BaseReferences<_$PakPerkDatabase, $SyncOutboxTable, SyncOutboxRow>,
      ),
      SyncOutboxRow,
      PrefetchHooks Function()
    >;
typedef $$LibrarySyncStatesTableCreateCompanionBuilder =
    LibrarySyncStatesCompanion Function({
      required String accountId,
      Value<int> lastRevision,
      Value<bool> initialized,
      Value<DateTime?> lastFullSyncAt,
      Value<int> rowid,
    });
typedef $$LibrarySyncStatesTableUpdateCompanionBuilder =
    LibrarySyncStatesCompanion Function({
      Value<String> accountId,
      Value<int> lastRevision,
      Value<bool> initialized,
      Value<DateTime?> lastFullSyncAt,
      Value<int> rowid,
    });

class $$LibrarySyncStatesTableFilterComposer
    extends Composer<_$PakPerkDatabase, $LibrarySyncStatesTable> {
  $$LibrarySyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastRevision => $composableBuilder(
    column: $table.lastRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get initialized => $composableBuilder(
    column: $table.initialized,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibrarySyncStatesTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $LibrarySyncStatesTable> {
  $$LibrarySyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastRevision => $composableBuilder(
    column: $table.lastRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get initialized => $composableBuilder(
    column: $table.initialized,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibrarySyncStatesTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $LibrarySyncStatesTable> {
  $$LibrarySyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<int> get lastRevision => $composableBuilder(
    column: $table.lastRevision,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get initialized => $composableBuilder(
    column: $table.initialized,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => column,
  );
}

class $$LibrarySyncStatesTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $LibrarySyncStatesTable,
          LibrarySyncStateRow,
          $$LibrarySyncStatesTableFilterComposer,
          $$LibrarySyncStatesTableOrderingComposer,
          $$LibrarySyncStatesTableAnnotationComposer,
          $$LibrarySyncStatesTableCreateCompanionBuilder,
          $$LibrarySyncStatesTableUpdateCompanionBuilder,
          (
            LibrarySyncStateRow,
            BaseReferences<
              _$PakPerkDatabase,
              $LibrarySyncStatesTable,
              LibrarySyncStateRow
            >,
          ),
          LibrarySyncStateRow,
          PrefetchHooks Function()
        > {
  $$LibrarySyncStatesTableTableManager(
    _$PakPerkDatabase db,
    $LibrarySyncStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibrarySyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibrarySyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibrarySyncStatesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<int> lastRevision = const Value.absent(),
                Value<bool> initialized = const Value.absent(),
                Value<DateTime?> lastFullSyncAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibrarySyncStatesCompanion(
                accountId: accountId,
                lastRevision: lastRevision,
                initialized: initialized,
                lastFullSyncAt: lastFullSyncAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                Value<int> lastRevision = const Value.absent(),
                Value<bool> initialized = const Value.absent(),
                Value<DateTime?> lastFullSyncAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibrarySyncStatesCompanion.insert(
                accountId: accountId,
                lastRevision: lastRevision,
                initialized: initialized,
                lastFullSyncAt: lastFullSyncAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibrarySyncStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $LibrarySyncStatesTable,
      LibrarySyncStateRow,
      $$LibrarySyncStatesTableFilterComposer,
      $$LibrarySyncStatesTableOrderingComposer,
      $$LibrarySyncStatesTableAnnotationComposer,
      $$LibrarySyncStatesTableCreateCompanionBuilder,
      $$LibrarySyncStatesTableUpdateCompanionBuilder,
      (
        LibrarySyncStateRow,
        BaseReferences<
          _$PakPerkDatabase,
          $LibrarySyncStatesTable,
          LibrarySyncStateRow
        >,
      ),
      LibrarySyncStateRow,
      PrefetchHooks Function()
    >;
typedef $$CacheMetadataTableCreateCompanionBuilder =
    CacheMetadataCompanion Function({
      required String key,
      required String valueJson,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$CacheMetadataTableUpdateCompanionBuilder =
    CacheMetadataCompanion Function({
      Value<String> key,
      Value<String> valueJson,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$CacheMetadataTableFilterComposer
    extends Composer<_$PakPerkDatabase, $CacheMetadataTable> {
  $$CacheMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CacheMetadataTableOrderingComposer
    extends Composer<_$PakPerkDatabase, $CacheMetadataTable> {
  $$CacheMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get valueJson => $composableBuilder(
    column: $table.valueJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CacheMetadataTableAnnotationComposer
    extends Composer<_$PakPerkDatabase, $CacheMetadataTable> {
  $$CacheMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CacheMetadataTableTableManager
    extends
        RootTableManager<
          _$PakPerkDatabase,
          $CacheMetadataTable,
          CacheMetadataRow,
          $$CacheMetadataTableFilterComposer,
          $$CacheMetadataTableOrderingComposer,
          $$CacheMetadataTableAnnotationComposer,
          $$CacheMetadataTableCreateCompanionBuilder,
          $$CacheMetadataTableUpdateCompanionBuilder,
          (
            CacheMetadataRow,
            BaseReferences<
              _$PakPerkDatabase,
              $CacheMetadataTable,
              CacheMetadataRow
            >,
          ),
          CacheMetadataRow,
          PrefetchHooks Function()
        > {
  $$CacheMetadataTableTableManager(
    _$PakPerkDatabase db,
    $CacheMetadataTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CacheMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CacheMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CacheMetadataTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> valueJson = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CacheMetadataCompanion(
                key: key,
                valueJson: valueJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String valueJson,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CacheMetadataCompanion.insert(
                key: key,
                valueJson: valueJson,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CacheMetadataTableProcessedTableManager =
    ProcessedTableManager<
      _$PakPerkDatabase,
      $CacheMetadataTable,
      CacheMetadataRow,
      $$CacheMetadataTableFilterComposer,
      $$CacheMetadataTableOrderingComposer,
      $$CacheMetadataTableAnnotationComposer,
      $$CacheMetadataTableCreateCompanionBuilder,
      $$CacheMetadataTableUpdateCompanionBuilder,
      (
        CacheMetadataRow,
        BaseReferences<
          _$PakPerkDatabase,
          $CacheMetadataTable,
          CacheMetadataRow
        >,
      ),
      CacheMetadataRow,
      PrefetchHooks Function()
    >;

class $PakPerkDatabaseManager {
  final _$PakPerkDatabase _db;
  $PakPerkDatabaseManager(this._db);
  $$CachedPapersTableTableManager get cachedPapers =>
      $$CachedPapersTableTableManager(_db, _db.cachedPapers);
  $$FeedQueriesTableTableManager get feedQueries =>
      $$FeedQueriesTableTableManager(_db, _db.feedQueries);
  $$FeedEntriesTableTableManager get feedEntries =>
      $$FeedEntriesTableTableManager(_db, _db.feedEntries);
  $$CachedProcessingTableTableManager get cachedProcessing =>
      $$CachedProcessingTableTableManager(_db, _db.cachedProcessing);
  $$CachedIntroductionsTableTableManager get cachedIntroductions =>
      $$CachedIntroductionsTableTableManager(_db, _db.cachedIntroductions);
  $$CachedConnectionsTableTableManager get cachedConnections =>
      $$CachedConnectionsTableTableManager(_db, _db.cachedConnections);
  $$CachedCommentPagesTableTableManager get cachedCommentPages =>
      $$CachedCommentPagesTableTableManager(_db, _db.cachedCommentPages);
  $$CachedChatsTableTableManager get cachedChats =>
      $$CachedChatsTableTableManager(_db, _db.cachedChats);
  $$LibraryItemsTableTableManager get libraryItems =>
      $$LibraryItemsTableTableManager(_db, _db.libraryItems);
  $$CommentDraftsTableTableManager get commentDrafts =>
      $$CommentDraftsTableTableManager(_db, _db.commentDrafts);
  $$BlockedUsersTableTableManager get blockedUsers =>
      $$BlockedUsersTableTableManager(_db, _db.blockedUsers);
  $$SyncOutboxTableTableManager get syncOutbox =>
      $$SyncOutboxTableTableManager(_db, _db.syncOutbox);
  $$LibrarySyncStatesTableTableManager get librarySyncStates =>
      $$LibrarySyncStatesTableTableManager(_db, _db.librarySyncStates);
  $$CacheMetadataTableTableManager get cacheMetadata =>
      $$CacheMetadataTableTableManager(_db, _db.cacheMetadata);
}
