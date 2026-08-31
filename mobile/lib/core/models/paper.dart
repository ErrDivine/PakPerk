import 'dart:convert';

import 'arxiv_identifier.dart';

class PaperVersionKey {
  const PaperVersionKey({required this.paperId, required this.arxivId});

  final String paperId;
  final String arxivId;

  @override
  bool operator ==(Object other) =>
      other is PaperVersionKey &&
      other.paperId == paperId &&
      other.arxivId == arxivId;

  @override
  int get hashCode => Object.hash(paperId, arxivId);
}

class PaperCapabilities {
  const PaperCapabilities({
    this.metadata = true,
    this.introduction = false,
    this.chat = false,
    this.connections = false,
    this.visualObjects = false,
    this.terms = false,
    this.semanticFacets = false,
    this.paperPassport = false,
  });

  final bool metadata;
  final bool introduction;
  final bool chat;
  final bool connections;
  final bool visualObjects;
  final bool terms;
  final bool semanticFacets;
  final bool paperPassport;

  bool get allReady => introduction && chat && connections;

  factory PaperCapabilities.fromJson(Map<String, dynamic>? json) {
    final value = json ?? const <String, dynamic>{};
    return PaperCapabilities(
      metadata: value['metadata'] as bool? ?? true,
      introduction: value['introduction'] as bool? ?? false,
      chat: value['chat'] as bool? ?? false,
      connections: value['connections'] as bool? ?? false,
      visualObjects: value['visual_objects'] as bool? ?? false,
      terms: value['terms'] as bool? ?? false,
      semanticFacets: value['semantic_facets'] as bool? ?? false,
      paperPassport: value['paper_passport'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'metadata': metadata,
    'introduction': introduction,
    'chat': chat,
    'connections': connections,
    'visual_objects': visualObjects,
    'terms': terms,
    'semantic_facets': semanticFacets,
    'paper_passport': paperPassport,
  };
}

class PaperSummary {
  const PaperSummary({
    required this.paperId,
    required this.arxivId,
    required this.title,
    required this.abstractText,
    required this.authors,
    required this.primaryCategory,
    required this.categories,
    required this.publishedAt,
    required this.updatedAt,
    required this.absUrl,
    required this.pdfUrl,
    this.capabilities = const PaperCapabilities(),
  });

  final String paperId;
  final String arxivId;
  final String title;
  final String abstractText;
  final List<String> authors;
  final String primaryCategory;
  final List<String> categories;
  final DateTime publishedAt;
  final DateTime updatedAt;
  final String absUrl;
  final String pdfUrl;
  final PaperCapabilities capabilities;

  String get arxivBaseId => arxivId.replaceFirst(RegExp(r'v\d+$'), '');
  ArxivIdentifier? get normalizedArxivIdentifier =>
      ArxivIdentifier.tryParse(arxivId);
  Uri? get canonicalAbsUri => normalizedArxivIdentifier?.canonicalAbsUri;
  Uri? get canonicalPdfUri => normalizedArxivIdentifier?.canonicalPdfUri;
  PaperVersionKey get versionKey =>
      PaperVersionKey(paperId: paperId, arxivId: arxivId);

  factory PaperSummary.fromJson(Map<String, dynamic> json) {
    final rawArxivId = _requiredString(json, 'arxiv_id');
    final identifier = ArxivIdentifier.tryParse(rawArxivId);
    if (identifier == null) {
      throw FormatException('Invalid arXiv identifier: $rawArxivId');
    }
    final normalizedArxivId = identifier.queryId;
    return PaperSummary(
      paperId: _requiredString(json, 'paper_id'),
      arxivId: normalizedArxivId,
      title: _requiredString(
        json,
        'title',
      ).replaceAll(RegExp(r'\s+'), ' ').trim(),
      abstractText: (json['abstract'] ?? json['abstract_text'] ?? '')
          .toString()
          .trim(),
      authors: _stringList(json['authors']),
      primaryCategory:
          (json['primary_category'] ?? json['category'] ?? 'unknown')
              .toString(),
      categories: _stringList(json['categories']),
      publishedAt: _date(json['published_at']),
      updatedAt: _date(json['updated_at'] ?? json['published_at']),
      // Never persist or later launch an origin supplied by the API/cache.
      // arXiv links are derived from the already validated exact identifier.
      absUrl: identifier.canonicalAbsUri.toString(),
      pdfUrl: identifier.canonicalPdfUri.toString(),
      capabilities: PaperCapabilities.fromJson(
        _mapOrNull(json['capabilities']),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'paper_id': paperId,
    'arxiv_id': arxivId,
    'title': title,
    'abstract': abstractText,
    'authors': authors,
    'primary_category': primaryCategory,
    'categories': categories,
    'published_at': publishedAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'abs_url': canonicalAbsUri?.toString(),
    'pdf_url': canonicalPdfUri?.toString(),
    'capabilities': capabilities.toJson(),
  };

  PaperSummary copyWith({PaperCapabilities? capabilities}) => PaperSummary(
    paperId: paperId,
    arxivId: arxivId,
    title: title,
    abstractText: abstractText,
    authors: authors,
    primaryCategory: primaryCategory,
    categories: categories,
    publishedAt: publishedAt,
    updatedAt: updatedAt,
    absUrl: absUrl,
    pdfUrl: pdfUrl,
    capabilities: capabilities ?? this.capabilities,
  );
}

class FeedPage {
  const FeedPage({required this.items, this.nextCursor});

  final List<PaperSummary> items;
  final String? nextCursor;

  factory FeedPage.fromJson(Map<String, dynamic> json) => FeedPage(
    items: (json['items'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              PaperSummary.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false),
    nextCursor: json['next_cursor']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'items': items.map((paper) => paper.toJson()).toList(growable: false),
    'next_cursor': nextCursor,
  };

  String encode() => jsonEncode(toJson());
}

Map<String, dynamic>? _mapOrNull(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) {
        if (item is Map) {
          return (item['name'] ?? item['display_name'] ?? '').toString();
        }
        return item.toString();
      })
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw FormatException('Missing required paper field: $key');
  }
  return value;
}

DateTime _date(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
