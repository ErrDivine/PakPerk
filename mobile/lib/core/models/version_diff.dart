import 'document_block.dart';

enum VersionDiffStatus {
  pending,
  ready,
  partial,
  failed;

  static VersionDiffStatus fromWire(Object? value) => switch (value) {
    'pending' => VersionDiffStatus.pending,
    'ready' => VersionDiffStatus.ready,
    'partial' => VersionDiffStatus.partial,
    'failed' => VersionDiffStatus.failed,
    _ => throw const FormatException('Invalid version diff status.'),
  };
}

enum VersionDiffItemKind {
  metadata,
  section,
  block,
  figure,
  table,
  equation,
  passportField,
  reference,
  annotationAnchor;

  static VersionDiffItemKind fromWire(Object? value) => switch (value) {
    'metadata' => VersionDiffItemKind.metadata,
    'section' => VersionDiffItemKind.section,
    'block' => VersionDiffItemKind.block,
    'figure' => VersionDiffItemKind.figure,
    'table' => VersionDiffItemKind.table,
    'equation' => VersionDiffItemKind.equation,
    'passport_field' => VersionDiffItemKind.passportField,
    'reference' => VersionDiffItemKind.reference,
    'annotation_anchor' => VersionDiffItemKind.annotationAnchor,
    _ => throw const FormatException('Invalid version diff item kind.'),
  };

  String get label => switch (this) {
    VersionDiffItemKind.passportField => 'Passport field',
    VersionDiffItemKind.annotationAnchor => 'Annotation anchor',
    _ => name[0].toUpperCase() + name.substring(1),
  };
}

enum VersionChangeType {
  added,
  removed,
  modified,
  moved;

  static VersionChangeType fromWire(Object? value) => switch (value) {
    'added' => VersionChangeType.added,
    'removed' => VersionChangeType.removed,
    'modified' => VersionChangeType.modified,
    'moved' => VersionChangeType.moved,
    _ => throw const FormatException('Invalid version change type.'),
  };
}

enum DiffConfidenceStatus {
  supported,
  uncertain,
  unavailable;

  static DiffConfidenceStatus fromWire(Object? value) => switch (value) {
    'supported' => DiffConfidenceStatus.supported,
    'uncertain' => DiffConfidenceStatus.uncertain,
    'unavailable' => DiffConfidenceStatus.unavailable,
    _ => throw const FormatException('Invalid diff confidence status.'),
  };
}

final class DocumentVersion {
  const DocumentVersion({
    required this.generation,
    required this.arxivVersion,
    required this.arxivId,
    required this.sourceAbsUrl,
    required this.sourcePdfUrl,
    required this.schemaVersion,
    required this.parserId,
    required this.parserVersion,
    required this.documentHash,
    required this.isCurrent,
    required this.generatedAt,
  });

  final int generation;
  final int arxivVersion;
  final String arxivId;
  final Uri sourceAbsUrl;
  final Uri sourcePdfUrl;
  final String schemaVersion;
  final String parserId;
  final String parserVersion;
  final String documentHash;
  final bool isCurrent;
  final DateTime generatedAt;

  factory DocumentVersion.fromJson(Map<String, dynamic> json) {
    final arxivVersion = _positive(
      json['arxiv_version'],
      'version.arxiv_version',
    );
    final arxivId = _text(json['arxiv_id'], 'version.arxiv_id');
    final sourceAbsUrl = _sourceUri(
      json['source_abs_url'],
      'source_abs_url',
      pathPrefix: '/abs/',
    );
    final sourcePdfUrl = _sourceUri(
      json['source_pdf_url'],
      'source_pdf_url',
      pathPrefix: '/pdf/',
    );
    if (_sourceIdentity(sourceAbsUrl, '/abs/') != arxivId ||
        _sourceIdentity(sourcePdfUrl, '/pdf/') != arxivId ||
        !arxivId.endsWith('v$arxivVersion')) {
      throw const FormatException('Invalid retained version source identity.');
    }
    return DocumentVersion(
      generation: _positive(json['generation'], 'version.generation'),
      arxivVersion: arxivVersion,
      arxivId: arxivId,
      sourceAbsUrl: sourceAbsUrl,
      sourcePdfUrl: sourcePdfUrl,
      schemaVersion: _text(json['schema_version'], 'schema_version'),
      parserId: _text(json['parser_id'], 'parser_id'),
      parserVersion: _text(json['parser_version'], 'parser_version'),
      documentHash: _text(json['document_hash'], 'document_hash'),
      isCurrent:
          json['is_current'] as bool? ??
          (throw const FormatException('Invalid version current state.')),
      generatedAt: _date(json['generated_at'], 'generated_at'),
    );
  }

  Map<String, Object?> toJson() => {
    'generation': generation,
    'arxiv_version': arxivVersion,
    'arxiv_id': arxivId,
    'source_abs_url': sourceAbsUrl.toString(),
    'source_pdf_url': sourcePdfUrl.toString(),
    'schema_version': schemaVersion,
    'parser_id': parserId,
    'parser_version': parserVersion,
    'document_hash': documentHash,
    'is_current': isCurrent,
    'generated_at': generatedAt.toUtc().toIso8601String(),
  };
}

/// The newest valid old-to-new pair available for a version comparison.
///
/// Version-history responses are newest-first today, but callers must not
/// couple comparison direction to transport ordering. A diff always moves
/// from the lower retained document generation to the higher one.
final class DocumentVersionComparison {
  const DocumentVersionComparison({required this.from, required this.to});

  final DocumentVersion from;
  final DocumentVersion to;
}

DocumentVersionComparison? latestDocumentVersionComparison(
  Iterable<DocumentVersion> versions,
) {
  final ordered = versions.toList(growable: false)
    ..sort((left, right) => right.generation.compareTo(left.generation));
  if (ordered.length < 2) return null;
  return DocumentVersionComparison(from: ordered[1], to: ordered[0]);
}

final class VersionDiffItem {
  const VersionDiffItem({
    required this.id,
    required this.ordinal,
    required this.kind,
    required this.changeType,
    required this.confidenceStatus,
    this.oldObjectId,
    this.newObjectId,
    this.similarity,
    this.oldContentHash,
    this.newContentHash,
    this.oldSource,
    this.newSource,
  });

  final String id;
  final int ordinal;
  final VersionDiffItemKind kind;
  final String? oldObjectId;
  final String? newObjectId;
  final VersionChangeType changeType;
  final double? similarity;
  final String? oldContentHash;
  final String? newContentHash;
  final DiffConfidenceStatus confidenceStatus;
  final VersionDiffSourceTarget? oldSource;
  final VersionDiffSourceTarget? newSource;

  factory VersionDiffItem.fromJson(Map<String, dynamic> json) {
    final similarity = (json['similarity'] as num?)?.toDouble();
    if (similarity != null && (similarity < 0 || similarity > 1)) {
      throw const FormatException('Invalid diff similarity.');
    }
    return VersionDiffItem(
      id: _uuidValue(json['id'], 'diff_item.id'),
      ordinal: _nonNegative(json['ordinal'], 'diff_item.ordinal'),
      kind: VersionDiffItemKind.fromWire(json['kind']),
      oldObjectId: _optionalUuid(json['old_object_id'], 'old_object_id'),
      newObjectId: _optionalUuid(json['new_object_id'], 'new_object_id'),
      changeType: VersionChangeType.fromWire(json['change_type']),
      similarity: similarity,
      oldContentHash: _optionalText(json['old_content_hash']),
      newContentHash: _optionalText(json['new_content_hash']),
      confidenceStatus: DiffConfidenceStatus.fromWire(
        json['confidence_status'],
      ),
      oldSource: json['old_source'] == null
          ? null
          : VersionDiffSourceTarget.fromJson(_map(json['old_source'])),
      newSource: json['new_source'] == null
          ? null
          : VersionDiffSourceTarget.fromJson(_map(json['new_source'])),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'ordinal': ordinal,
    'kind': switch (kind) {
      VersionDiffItemKind.passportField => 'passport_field',
      VersionDiffItemKind.annotationAnchor => 'annotation_anchor',
      _ => kind.name,
    },
    'old_object_id': oldObjectId,
    'new_object_id': newObjectId,
    'change_type': changeType.name,
    'similarity': similarity,
    'old_content_hash': oldContentHash,
    'new_content_hash': newContentHash,
    'confidence_status': confidenceStatus.name,
    'old_source': oldSource?.toJson(),
    'new_source': newSource?.toJson(),
  };
}

final class VersionDiffSourceTarget {
  const VersionDiffSourceTarget({
    required this.objectId,
    required this.generation,
    required this.sourceAbsUrl,
    required this.sourcePdfUrl,
    this.pageStart,
    this.pageEnd,
    this.sourceLocator,
    this.sourcePageUrl,
  });

  final String objectId;
  final int generation;
  final int? pageStart;
  final int? pageEnd;
  final DocumentSourceLocator? sourceLocator;
  final Uri sourceAbsUrl;
  final Uri sourcePdfUrl;
  final Uri? sourcePageUrl;

  int? get exactPageNumber => sourceLocator?.pageNumber ?? pageStart;

  /// Prefer a trustworthy page fragment, while preserving an exact retained
  /// PDF fallback for objects whose parser did not publish a page.
  Uri get preferredSourceUrl => sourcePageUrl ?? sourcePdfUrl;

  factory VersionDiffSourceTarget.fromJson(Map<String, dynamic> json) {
    final pageStart = _optionalPositive(json['page_start'], 'page_start');
    final pageEnd = _optionalPositive(json['page_end'], 'page_end');
    if (pageStart != null && pageEnd != null && pageEnd < pageStart) {
      throw const FormatException('Invalid diff source page range.');
    }
    final locator = json['source_locator'] == null
        ? null
        : DocumentSourceLocator.fromJson(_map(json['source_locator']));
    final exactPage = locator?.pageNumber ?? pageStart;
    final sourceAbsUrl = _sourceUri(
      json['source_abs_url'],
      'source_abs_url',
      pathPrefix: '/abs/',
    );
    final sourcePdfUrl = _sourceUri(
      json['source_pdf_url'],
      'source_pdf_url',
      pathPrefix: '/pdf/',
    );
    final sourcePageUrl = json['source_page_url'] == null
        ? null
        : exactPage == null
        ? (throw const FormatException('Invalid exact diff source URL.'))
        : _sourceUri(
            json['source_page_url'],
            'source_page_url',
            pathPrefix: '/pdf/',
            exactPageFragment: exactPage,
          );
    final sourceIdentityMatches =
        _sourceIdentity(sourceAbsUrl, '/abs/') ==
            _sourceIdentity(sourcePdfUrl, '/pdf/') &&
        (sourcePageUrl == null ||
            sourcePageUrl.path == sourcePdfUrl.path &&
                sourcePageUrl.fragment == 'page=$exactPage');
    if (!sourceIdentityMatches ||
        (exactPage == null) != (sourcePageUrl == null)) {
      throw const FormatException('Invalid exact diff source URL.');
    }
    return VersionDiffSourceTarget(
      objectId: _uuidValue(json['object_id'], 'source.object_id'),
      generation: _positive(json['generation'], 'source.generation'),
      pageStart: pageStart,
      pageEnd: pageEnd,
      sourceLocator: locator,
      sourceAbsUrl: sourceAbsUrl,
      sourcePdfUrl: sourcePdfUrl,
      sourcePageUrl: sourcePageUrl,
    );
  }

  Map<String, Object?> toJson() => {
    'object_id': objectId,
    'generation': generation,
    'page_start': pageStart,
    'page_end': pageEnd,
    'source_locator': sourceLocator?.toJson(),
    'source_abs_url': sourceAbsUrl.toString(),
    'source_pdf_url': sourcePdfUrl.toString(),
    'source_page_url': sourcePageUrl?.toString(),
  };
}

final class VersionDiffSummary {
  const VersionDiffSummary({
    required this.added,
    required this.removed,
    required this.modified,
    required this.moved,
    required this.warnings,
  });

  final int added;
  final int removed;
  final int modified;
  final int moved;
  final List<String> warnings;

  factory VersionDiffSummary.fromJson(Map<String, dynamic> json) =>
      VersionDiffSummary(
        added: _nonNegative(json['added'], 'summary.added'),
        removed: _nonNegative(json['removed'], 'summary.removed'),
        modified: _nonNegative(json['modified'], 'summary.modified'),
        moved: _nonNegative(json['moved'], 'summary.moved'),
        warnings: _strings(json['warnings'], 128),
      );

  Map<String, Object?> toJson() => {
    'added': added,
    'removed': removed,
    'modified': modified,
    'moved': moved,
    'warnings': warnings,
  };
}

final class PaperVersionDiff {
  const PaperVersionDiff({
    required this.id,
    required this.paperId,
    required this.fromGeneration,
    required this.toGeneration,
    required this.fromArxivVersion,
    required this.toArxivVersion,
    required this.fromSourceAbsUrl,
    required this.toSourceAbsUrl,
    required this.algorithmVersion,
    required this.schemaVersion,
    required this.fromParserId,
    required this.fromParserVersion,
    required this.toParserId,
    required this.toParserVersion,
    required this.parserChangeUncertainty,
    required this.status,
    required this.summary,
    required this.items,
    required this.createdAt,
    this.failureCode,
    this.completedAt,
  });

  final String id;
  final String paperId;
  final int fromGeneration;
  final int toGeneration;
  final int fromArxivVersion;
  final int toArxivVersion;
  final Uri fromSourceAbsUrl;
  final Uri toSourceAbsUrl;
  final String algorithmVersion;
  final String schemaVersion;
  final String fromParserId;
  final String fromParserVersion;
  final String toParserId;
  final String toParserVersion;
  final bool parserChangeUncertainty;
  final VersionDiffStatus status;
  final VersionDiffSummary summary;
  final String? failureCode;
  final List<VersionDiffItem> items;
  final DateTime createdAt;
  final DateTime? completedAt;

  factory PaperVersionDiff.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 10000) {
      throw const FormatException('Invalid version diff items.');
    }
    final fromGeneration = _positive(
      json['from_generation'],
      'from_generation',
    );
    final toGeneration = _positive(json['to_generation'], 'to_generation');
    final fromArxivVersion = _positive(
      json['from_arxiv_version'],
      'from_arxiv_version',
    );
    final toArxivVersion = _positive(
      json['to_arxiv_version'],
      'to_arxiv_version',
    );
    final fromSourceAbsUrl = _sourceUri(
      json['from_source_abs_url'],
      'from_source_abs_url',
      pathPrefix: '/abs/',
    );
    final toSourceAbsUrl = _sourceUri(
      json['to_source_abs_url'],
      'to_source_abs_url',
      pathPrefix: '/abs/',
    );
    final fromSourceBase = _versionedSourceBase(
      fromSourceAbsUrl,
      '/abs/',
      fromArxivVersion,
    );
    final toSourceBase = _versionedSourceBase(
      toSourceAbsUrl,
      '/abs/',
      toArxivVersion,
    );
    if (fromSourceBase == null ||
        toSourceBase == null ||
        fromSourceBase != toSourceBase) {
      throw const FormatException('Invalid version diff source identity.');
    }
    final decodedItems = rawItems
        .map((item) => VersionDiffItem.fromJson(_map(item)))
        .toList(growable: false);
    for (final item in decodedItems) {
      final oldSource = item.oldSource;
      final newSource = item.newSource;
      if (oldSource != null &&
              (oldSource.objectId != item.oldObjectId ||
                  oldSource.generation != fromGeneration ||
                  oldSource.sourceAbsUrl != fromSourceAbsUrl) ||
          newSource != null &&
              (newSource.objectId != item.newObjectId ||
                  newSource.generation != toGeneration ||
                  newSource.sourceAbsUrl != toSourceAbsUrl)) {
        throw const FormatException('Invalid version diff source scope.');
      }
    }
    return PaperVersionDiff(
      id: _uuidValue(json['id'], 'diff.id'),
      paperId: _uuidValue(json['paper_id'], 'diff.paper_id'),
      fromGeneration: fromGeneration,
      toGeneration: toGeneration,
      fromArxivVersion: fromArxivVersion,
      toArxivVersion: toArxivVersion,
      fromSourceAbsUrl: fromSourceAbsUrl,
      toSourceAbsUrl: toSourceAbsUrl,
      algorithmVersion: _text(json['algorithm_version'], 'algorithm_version'),
      schemaVersion: _text(json['schema_version'], 'schema_version'),
      fromParserId: _text(json['from_parser_id'], 'from_parser_id'),
      fromParserVersion: _text(
        json['from_parser_version'],
        'from_parser_version',
      ),
      toParserId: _text(json['to_parser_id'], 'to_parser_id'),
      toParserVersion: _text(json['to_parser_version'], 'to_parser_version'),
      parserChangeUncertainty:
          json['parser_change_uncertainty'] as bool? ??
          (throw const FormatException('Invalid parser uncertainty state.')),
      status: VersionDiffStatus.fromWire(json['status']),
      summary: VersionDiffSummary.fromJson(_map(json['summary'])),
      failureCode: _optionalText(json['failure_code']),
      items: decodedItems,
      createdAt: _date(json['created_at'], 'created_at'),
      completedAt: json['completed_at'] == null
          ? null
          : _date(json['completed_at'], 'completed_at'),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'paper_id': paperId,
    'from_generation': fromGeneration,
    'to_generation': toGeneration,
    'from_arxiv_version': fromArxivVersion,
    'to_arxiv_version': toArxivVersion,
    'from_source_abs_url': fromSourceAbsUrl.toString(),
    'to_source_abs_url': toSourceAbsUrl.toString(),
    'algorithm_version': algorithmVersion,
    'schema_version': schemaVersion,
    'from_parser_id': fromParserId,
    'from_parser_version': fromParserVersion,
    'to_parser_id': toParserId,
    'to_parser_version': toParserVersion,
    'parser_change_uncertainty': parserChangeUncertainty,
    'status': status.name,
    'summary': summary.toJson(),
    'failure_code': failureCode,
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'created_at': createdAt.toUtc().toIso8601String(),
    'completed_at': completedAt?.toUtc().toIso8601String(),
  };
}

int _positive(Object? value, String field) {
  final parsed = (value as num?)?.toInt();
  if (parsed == null || parsed <= 0) throw FormatException('Invalid $field.');
  return parsed;
}

int? _optionalPositive(Object? value, String field) =>
    value == null ? null : _positive(value, field);

int _nonNegative(Object? value, String field) {
  final parsed = (value as num?)?.toInt();
  if (parsed == null || parsed < 0) throw FormatException('Invalid $field.');
  return parsed;
}

String _text(Object? value, String field) {
  if (value is! String || value.isEmpty || value.length > 512) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

String? _optionalText(Object? value) =>
    value == null ? null : _text(value, 'text');

String _uuidValue(Object? value, String field) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (!_uuid.hasMatch(text)) throw FormatException('Invalid $field.');
  return text;
}

String? _optionalUuid(Object? value, String field) =>
    value == null ? null : _uuidValue(value, field);

DateTime _date(Object? value, String field) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toUtc();
  if (parsed == null) throw FormatException('Invalid $field.');
  return parsed;
}

Uri _sourceUri(
  Object? value,
  String field, {
  required String pathPrefix,
  int? exactPageFragment,
}) {
  final uri = Uri.tryParse(value?.toString() ?? '');
  final expectedFragment = exactPageFragment == null
      ? null
      : 'page=$exactPageFragment';
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'arxiv.org' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443) ||
      uri.hasQuery ||
      !uri.path.startsWith(pathPrefix) ||
      uri.path.length == pathPrefix.length ||
      (expectedFragment == null
          ? uri.hasFragment
          : !uri.hasFragment || uri.fragment != expectedFragment)) {
    throw FormatException('Invalid $field.');
  }
  return uri;
}

String _sourceIdentity(Uri uri, String pathPrefix) =>
    uri.path.substring(pathPrefix.length);

String? _versionedSourceBase(Uri uri, String pathPrefix, int version) {
  final identity = _sourceIdentity(uri, pathPrefix);
  final suffix = 'v$version';
  if (!identity.endsWith(suffix) || identity.length == suffix.length) {
    return null;
  }
  return identity.substring(0, identity.length - suffix.length);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected JSON object.');
}

List<String> _strings(Object? value, int maximum) {
  if (value == null) return const [];
  if (value is! List || value.length > maximum) {
    throw const FormatException('Invalid string list.');
  }
  return value.map((item) => _text(item, 'list item')).toList(growable: false);
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
