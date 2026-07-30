String relationLabel(String relationType) {
  switch (relationType) {
    case 'builds_on':
      return 'Builds on';
    case 'uses':
      return 'Uses';
    case 'extends':
      return 'Extends';
    case 'applies':
      return 'Applies';
    case 'compares_with':
      return 'Compares with';
    case 'contrasts_with':
      return 'Contrasts with';
    case 'background':
      return 'Background';
    case 'related_work':
      return 'Related work';
    default:
      return 'Connected work';
  }
}

class KeyConnection {
  const KeyConnection({
    required this.referenceId,
    required this.paperId,
    required this.arxivId,
    required this.title,
    required this.authors,
    required this.year,
    required this.relationType,
    required this.summary,
    this.confidence,
  });

  final String referenceId;
  final String paperId;
  final String arxivId;
  final String title;
  final List<String> authors;
  final int? year;
  final String relationType;
  final String summary;
  final double? confidence;

  factory KeyConnection.fromJson(Map<String, dynamic> json) => KeyConnection(
        referenceId: (json['reference_id'] ?? '').toString(),
        paperId: (json['paper_id'] ?? '').toString(),
        arxivId: (json['arxiv_id'] ?? '').toString(),
        title: (json['title'] ?? 'Untitled reference').toString(),
        authors: (json['authors'] as List<dynamic>? ?? const [])
            .map(
              (author) => author is Map
                  ? (author['name'] ?? '').toString()
                  : author.toString(),
            )
            .where((author) => author.isNotEmpty)
            .toList(growable: false),
        year: (json['year'] as num?)?.toInt(),
        relationType: (json['relation_type'] ?? 'unknown').toString(),
        summary: (json['summary'] ?? '').toString(),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'reference_id': referenceId,
        'paper_id': paperId,
        'arxiv_id': arxivId,
        'title': title,
        'authors': authors,
        'year': year,
        'relation_type': relationType,
        'summary': summary,
        if (confidence != null) 'confidence': confidence,
      };
}

class PaperReference {
  const PaperReference({
    required this.ordinal,
    required this.rawText,
    required this.resolved,
    this.paperId,
    this.arxivId,
    this.title,
    this.resolutionStatus = 'unresolved',
  });

  final int ordinal;
  final String rawText;
  final bool resolved;
  final String? paperId;
  final String? arxivId;
  final String? title;
  final String resolutionStatus;

  bool get isNavigable =>
      resolved && paperId != null && paperId!.trim().isNotEmpty;

  factory PaperReference.fromJson(Map<String, dynamic> json) => PaperReference(
        ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
        rawText: (json['raw_text'] ?? json['citation'] ?? '').toString(),
        resolved: json['resolved'] as bool? ??
            (json['resolution_status'] == 'resolved'),
        paperId: json['paper_id']?.toString(),
        arxivId: json['arxiv_id']?.toString(),
        title: json['title']?.toString(),
        resolutionStatus:
            (json['resolution_status'] ?? 'unresolved').toString(),
      );

  Map<String, dynamic> toJson() => {
        'ordinal': ordinal,
        'raw_text': rawText,
        'resolved': resolved,
        if (paperId != null) 'paper_id': paperId,
        if (arxivId != null) 'arxiv_id': arxivId,
        if (title != null) 'title': title,
        'resolution_status': resolutionStatus,
      };
}

class PaperConnections {
  const PaperConnections({
    required this.paperId,
    required this.ready,
    required this.keyConnections,
    required this.references,
  });

  final String paperId;
  final bool ready;
  final List<KeyConnection> keyConnections;
  final List<PaperReference> references;

  factory PaperConnections.fromJson(
    Map<String, dynamic> json,
  ) =>
      PaperConnections(
        paperId: (json['paper_id'] ?? '').toString(),
        ready: json['ready'] as bool? ?? false,
        keyConnections: (json['key_connections'] as List<dynamic>? ?? const [])
            .map(
              (value) => KeyConnection.fromJson(
                  Map<String, dynamic>.from(value as Map)),
            )
            .toList(growable: false),
        references: (json['references'] as List<dynamic>? ?? const [])
            .map(
              (value) => PaperReference.fromJson(
                  Map<String, dynamic>.from(value as Map)),
            )
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'paper_id': paperId,
        'ready': ready,
        'key_connections':
            keyConnections.map((connection) => connection.toJson()).toList(),
        'references':
            references.map((reference) => reference.toJson()).toList(),
      };
}
