import '../library/library_models.dart';
import '../library/library_v2_models.dart';
import '../models/arxiv_identifier.dart';
import '../models/paper.dart';
import 'paper_input_classifier.dart';

enum PaperImportSourceKind { arxivId, arxivUrl }

extension PaperImportSourceKindWire on PaperImportSourceKind {
  String get wireValue => switch (this) {
    PaperImportSourceKind.arxivId => 'arxiv_id',
    PaperImportSourceKind.arxivUrl => 'arxiv_url',
  };

  static PaperImportSourceKind parse(Object? value) => switch (value) {
    'arxiv_id' => PaperImportSourceKind.arxivId,
    'arxiv_url' => PaperImportSourceKind.arxivUrl,
    _ => throw const FormatException('Invalid paper import source kind.'),
  };
}

final class PaperImportSource {
  const PaperImportSource({required this.kind, required this.value});

  factory PaperImportSource.fromClassification(
    ClassifiedPaperInput classification,
  ) {
    final identifier = classification.identifier;
    if (identifier == null) {
      throw ArgumentError.value(
        classification,
        'classification',
        'Title searches must be resolved to a candidate before import.',
      );
    }
    return PaperImportSource(
      kind: switch (classification.kind) {
        PaperInputKind.arxivId => PaperImportSourceKind.arxivId,
        PaperInputKind.arxivUrl => PaperImportSourceKind.arxivUrl,
        PaperInputKind.title => throw StateError('Unreachable title import.'),
      },
      value: classification.kind == PaperInputKind.arxivUrl
          ? identifier.canonicalAbsUri.toString()
          : identifier.queryId,
    );
  }

  final PaperImportSourceKind kind;
  final String value;

  LibrarySaveSourceKind get directSaveSourceKind => switch (kind) {
    PaperImportSourceKind.arxivId => LibrarySaveSourceKind.arxivId,
    PaperImportSourceKind.arxivUrl => LibrarySaveSourceKind.arxivUrl,
  };

  Map<String, Object?> toJson() => {'kind': kind.wireValue, 'value': value};
}

final class PaperSearchCandidate {
  const PaperSearchCandidate({
    required this.arxivId,
    required this.title,
    required this.authors,
    required this.abstractText,
    required this.primaryCategory,
    required this.categories,
    required this.publishedAt,
    required this.updatedAt,
    required this.absUri,
    required this.rank,
  });

  final String arxivId;
  final String title;
  final List<String> authors;
  final String abstractText;
  final String primaryCategory;
  final List<String> categories;
  final DateTime publishedAt;
  final DateTime updatedAt;
  final Uri absUri;
  final int rank;

  PaperImportSource get importSource =>
      PaperImportSource(kind: PaperImportSourceKind.arxivId, value: arxivId);

  factory PaperSearchCandidate.fromJson(Map<String, dynamic> json) {
    final rawArxivId = _requiredString(json, 'arxiv_id', maximumLength: 64);
    final identifier = ArxivIdentifier.tryParse(rawArxivId);
    if (identifier == null) {
      throw const FormatException('Invalid search candidate arXiv ID.');
    }
    final match = _requiredMap(json, 'match');
    if (match['kind'] != 'title') {
      throw const FormatException('Invalid search candidate match kind.');
    }
    final rank = match['rank'];
    if (rank is! int || rank < 1 || rank > 10) {
      throw const FormatException('Invalid search candidate rank.');
    }
    final publishedAt = _requiredUtcDate(json, 'published_at');
    final updatedAt = _requiredUtcDate(json, 'updated_at');
    if (updatedAt.isBefore(publishedAt)) {
      throw const FormatException('Candidate update predates publication.');
    }
    final rawAbsUrl = _requiredString(json, 'abs_url', maximumLength: 512);
    if (Uri.tryParse(rawAbsUrl) != identifier.canonicalAbsUri) {
      throw const FormatException('Candidate arXiv URL is not canonical.');
    }
    return PaperSearchCandidate(
      arxivId: identifier.queryId,
      title: _requiredString(json, 'title', maximumLength: 4096),
      authors: _requiredStringList(
        json,
        'authors',
        maximumItems: 100,
        maximumItemLength: 512,
      ),
      abstractText: _requiredString(json, 'abstract', maximumLength: 65536),
      primaryCategory: _requiredString(
        json,
        'primary_category',
        maximumLength: 64,
      ),
      categories: _requiredStringList(
        json,
        'categories',
        maximumItems: 64,
        maximumItemLength: 64,
      ),
      publishedAt: publishedAt,
      updatedAt: updatedAt,
      absUri: identifier.canonicalAbsUri,
      rank: rank,
    );
  }
}

final class PaperSearchResult {
  const PaperSearchResult({
    required this.queryId,
    required this.normalizedQuery,
    required this.candidates,
  });

  final String queryId;
  final String normalizedQuery;
  final List<PaperSearchCandidate> candidates;

  factory PaperSearchResult.fromJson(Map<String, dynamic> json) {
    final queryId = _requiredUuid(json, 'query_id');
    final normalizedQuery = _requiredString(
      json,
      'normalized_query',
      maximumLength: 300,
    );
    if (normalizedQuery.runes.length < 3 ||
        normalizedQuery != _normalizeWhitespace(normalizedQuery)) {
      throw const FormatException('Invalid normalized search query.');
    }
    final rawCandidates = json['candidates'];
    if (rawCandidates is! List || rawCandidates.length > 10) {
      throw const FormatException('Invalid search candidates.');
    }
    final candidates = rawCandidates
        .map(
          (candidate) => candidate is Map
              ? PaperSearchCandidate.fromJson(
                  Map<String, dynamic>.from(candidate),
                )
              : throw const FormatException('Invalid search candidate.'),
        )
        .toList(growable: false);
    final identities = <String>{};
    for (var index = 0; index < candidates.length; index += 1) {
      final candidate = candidates[index];
      if (candidate.rank != index + 1 || !identities.add(candidate.arxivId)) {
        throw const FormatException('Search candidates are not canonical.');
      }
    }
    return PaperSearchResult(
      queryId: queryId,
      normalizedQuery: normalizedQuery,
      candidates: candidates,
    );
  }
}

final class PaperImportResolution {
  const PaperImportResolution({
    required this.inputKind,
    required this.canonicalArxivId,
  });

  final PaperImportSourceKind inputKind;
  final String canonicalArxivId;

  factory PaperImportResolution.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'input_kind', 'canonical_arxiv_id'});
    final kind = PaperImportSourceKindWire.parse(json['input_kind']);
    final rawIdentifier = _requiredString(
      json,
      'canonical_arxiv_id',
      maximumLength: 64,
    );
    final identifier = ArxivIdentifier.tryParse(rawIdentifier);
    if (identifier == null) {
      throw const FormatException('Invalid canonical import identifier.');
    }
    return PaperImportResolution(
      inputKind: kind,
      canonicalArxivId: identifier.queryId,
    );
  }
}

final class PaperImportResult {
  const PaperImportResult({
    required this.resolution,
    required this.item,
    required this.paper,
    required this.syncRevision,
  });

  final PaperImportResolution resolution;
  final LibraryV2Item item;
  final PaperSummary paper;
  final int syncRevision;

  factory PaperImportResult.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'result',
      'resolution',
      'item',
      'paper',
      'sync_revision',
    });
    if (json['result'] != 'saved') {
      throw const FormatException('Invalid paper import result.');
    }
    final resolution = PaperImportResolution.fromJson(
      _requiredMap(json, 'resolution'),
    );
    final item = LibraryV2Item.fromJson(_requiredMap(json, 'item'));
    final paper = PaperSummary.fromJson(_requiredMap(json, 'paper'));
    final syncRevision = json['sync_revision'];
    if (syncRevision is! int ||
        syncRevision <= 0 ||
        item.removed ||
        item.state != LibraryItemState.inbox ||
        item.paperId != paper.paperId ||
        item.revision != syncRevision ||
        paper.arxivId != resolution.canonicalArxivId) {
      throw const FormatException('Inconsistent paper import response.');
    }
    return PaperImportResult(
      resolution: resolution,
      item: item,
      paper: paper,
      syncRevision: syncRevision,
    );
  }
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('Invalid $key.');
  return Map<String, dynamic>.from(value);
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.difference(expected).isNotEmpty ||
      expected.difference(actual).isNotEmpty) {
    throw const FormatException('Unexpected paper-import response shape.');
  }
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20 && rune != 0x0a)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String _requiredUuid(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key, maximumLength: 36);
  if (!_uuid.hasMatch(value)) throw FormatException('Invalid $key.');
  return value.toLowerCase();
}

List<String> _requiredStringList(
  Map<String, dynamic> json,
  String key, {
  required int maximumItems,
  required int maximumItemLength,
}) {
  final value = json[key];
  if (value is! List || value.isEmpty || value.length > maximumItems) {
    throw FormatException('Invalid $key.');
  }
  return value
      .map(
        (item) => item is String
            ? _requiredString(
                {key: item},
                key,
                maximumLength: maximumItemLength,
              )
            : throw FormatException('Invalid $key.'),
      )
      .toList(growable: false);
}

DateTime _requiredUtcDate(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key, maximumLength: 64);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !value.endsWith('Z')) {
    throw FormatException('Invalid $key.');
  }
  return parsed.toUtc();
}

String _normalizeWhitespace(String value) =>
    value.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
