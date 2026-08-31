import '../models/paper.dart';

enum DiscoverySearchSort { relevance, recency }

final class DiscoverySearchFilters {
  DiscoverySearchFilters({
    Iterable<String> categories = const [],
    Iterable<String> topics = const [],
    this.publishedAfter,
    this.publishedBefore,
  }) : categories = List.unmodifiable(categories),
       topics = List.unmodifiable(topics) {
    if (this.categories.length > 8 || this.topics.length > 8) {
      throw ArgumentError('Search filters exceed the server bounds.');
    }
  }

  final List<String> categories;
  final List<String> topics;
  final String? publishedAfter;
  final String? publishedBefore;

  Map<String, Object?> toJson() => {
    'categories': categories,
    'topics': topics,
    'published_after': publishedAfter,
    'published_before': publishedBefore,
    'sources': const ['arxiv'],
  };

  factory DiscoverySearchFilters.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'categories',
      'topics',
      'published_after',
      'published_before',
      'sources',
    });
    final sources = _strings(json['sources'], maximumItems: 1);
    if (sources.any((value) => value != 'arxiv')) {
      throw const FormatException('Unknown search source.');
    }
    return DiscoverySearchFilters(
      categories: _strings(json['categories'], maximumItems: 8),
      topics: _strings(json['topics'], maximumItems: 8),
      publishedAfter: _date(json['published_after']),
      publishedBefore: _date(json['published_before']),
    );
  }
}

final class DiscoverySearchResult {
  const DiscoverySearchResult({
    required this.paper,
    required this.matchKind,
    required this.relevanceBucket,
  });

  final PaperSummary paper;
  final String matchKind;
  final int relevanceBucket;

  factory DiscoverySearchResult.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'paper',
      'match_kind',
      'relevance_bucket',
      'source',
    });
    const matches = {
      'exact_arxiv_id',
      'exact_doi',
      'exact_title',
      'exact_author',
      'phrase',
      'related_text',
    };
    final match = json['match_kind'];
    final bucket = json['relevance_bucket'];
    if (match is! String ||
        !matches.contains(match) ||
        bucket is! int ||
        json['source'] != 'arxiv') {
      throw const FormatException('Invalid search result.');
    }
    return DiscoverySearchResult(
      paper: PaperSummary.fromJson(_map(json['paper'])),
      matchKind: match,
      relevanceBucket: bucket,
    );
  }
}

final class DiscoveryRelatedTopic {
  const DiscoveryRelatedTopic({
    required this.topicId,
    required this.label,
    required this.sourceVocabulary,
  });

  final String topicId;
  final String label;
  final String sourceVocabulary;

  factory DiscoveryRelatedTopic.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'topic_id', 'label', 'source_vocabulary'});
    return DiscoveryRelatedTopic(
      topicId: _uuid(json['topic_id']),
      label: _bounded(json['label'], 160),
      sourceVocabulary: _bounded(json['source_vocabulary'], 64),
    );
  }
}

final class DiscoverySearchSuggestions {
  const DiscoverySearchSuggestions({
    required this.normalizedQuery,
    required this.items,
  });

  final String normalizedQuery;
  final List<DiscoveryRelatedTopic> items;

  factory DiscoverySearchSuggestions.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {'normalized_query', 'items'});
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 8) {
      throw const FormatException('Invalid search suggestions.');
    }
    return DiscoverySearchSuggestions(
      normalizedQuery: _bounded(json['normalized_query'], 300),
      items: List.unmodifiable(
        rawItems.map((value) => DiscoveryRelatedTopic.fromJson(_map(value))),
      ),
    );
  }
}

final class DiscoverySearchPage {
  const DiscoverySearchPage({
    required this.normalizedQuery,
    required this.items,
    required this.nextCursor,
    required this.matchesReturned,
    required this.relatedTopics,
    required this.disclaimer,
  });

  final String normalizedQuery;
  final List<DiscoverySearchResult> items;
  final String? nextCursor;
  final int matchesReturned;
  final List<DiscoveryRelatedTopic> relatedTopics;
  final String? disclaimer;

  factory DiscoverySearchPage.fromJson(
    Map<String, dynamic> json, {
    required bool explore,
  }) {
    final expected = {
      'normalized_query',
      'items',
      'next_cursor',
      'diagnostics',
      'related_topics',
      if (explore) 'disclaimer',
    };
    _exactKeys(json, expected);
    final rawItems = json['items'];
    final rawDiagnostics = json['diagnostics'];
    final rawTopics = json['related_topics'];
    if (rawItems is! List || rawDiagnostics is! List || rawTopics is! List) {
      throw const FormatException('Invalid search page.');
    }
    var returned = 0;
    for (final raw in rawDiagnostics) {
      final value = _map(raw);
      _exactKeys(value, const {
        'source',
        'status',
        'coverage',
        'matches_returned',
      });
      if (value['source'] != 'arxiv' ||
          (value['status'] != 'queried' && value['status'] != 'no_matches') ||
          value['coverage'] != 'partial' ||
          value['matches_returned'] is! int ||
          (value['matches_returned'] as int) < 0) {
        throw const FormatException('Invalid source diagnostics.');
      }
      returned += value['matches_returned'] as int;
    }
    const disclaimer =
        "Explore searches Pakperk's bounded local arXiv metadata cache. "
        'It is not a systematic or complete literature search.';
    if (explore && json['disclaimer'] != disclaimer) {
      throw const FormatException('Invalid Explore disclaimer.');
    }
    return DiscoverySearchPage(
      normalizedQuery: _bounded(json['normalized_query'], 300),
      items: List.unmodifiable(
        rawItems.map((value) => DiscoverySearchResult.fromJson(_map(value))),
      ),
      nextCursor: json['next_cursor'] == null
          ? null
          : _bounded(json['next_cursor'], 512),
      matchesReturned: returned,
      relatedTopics: List.unmodifiable(
        rawTopics.map((value) => DiscoveryRelatedTopic.fromJson(_map(value))),
      ),
      disclaimer: explore ? disclaimer : null,
    );
  }
}

final class DiscoverySavedSearch {
  const DiscoverySavedSearch({
    required this.id,
    required this.query,
    required this.filters,
    required this.sort,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String query;
  final DiscoverySearchFilters filters;
  final DiscoverySearchSort sort;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DiscoverySavedSearch.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'id',
      'query',
      'filters',
      'sort',
      'revision',
      'created_at',
      'updated_at',
    });
    final sort = switch (json['sort']) {
      'relevance' => DiscoverySearchSort.relevance,
      'recency' => DiscoverySearchSort.recency,
      _ => throw const FormatException('Invalid search sort.'),
    };
    final revision = json['revision'];
    if (revision is! int || revision <= 0) {
      throw const FormatException('Invalid saved-search revision.');
    }
    return DiscoverySavedSearch(
      id: _uuid(json['id']),
      query: _bounded(json['query'], 300),
      filters: DiscoverySearchFilters.fromJson(_map(json['filters'])),
      sort: sort,
      revision: revision,
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected response shape.');
  }
}

String _bounded(Object? value, int length) {
  if (value is! String ||
      value.isEmpty ||
      value.length > length ||
      value.runes.any((rune) => rune < 0x20)) {
    throw const FormatException('Invalid text.');
  }
  return value;
}

String _uuid(Object? value) {
  final text = _bounded(value, 36).toLowerCase();
  if (!_uuidPattern.hasMatch(text)) {
    throw const FormatException('Invalid UUID.');
  }
  return text;
}

DateTime _timestamp(Object? value) {
  final raw = _bounded(value, 64);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !raw.endsWith('Z')) {
    throw const FormatException('Invalid timestamp.');
  }
  return parsed.toUtc();
}

String? _date(Object? value) {
  if (value == null) return null;
  final raw = _bounded(value, 10);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw) ||
      DateTime.tryParse('${raw}T00:00:00Z') == null) {
    throw const FormatException('Invalid date.');
  }
  return raw;
}

List<String> _strings(Object? value, {required int maximumItems}) {
  if (value is! List || value.length > maximumItems) {
    throw const FormatException('Invalid string list.');
  }
  return value.map((item) => _bounded(item, 160)).toList(growable: false);
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
