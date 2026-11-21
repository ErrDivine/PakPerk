class IntroductionCitationReference {
  const IntroductionCitationReference({
    required this.paperId,
    required this.title,
  });

  final String paperId;
  final String title;

  factory IntroductionCitationReference.fromJson(Map<String, dynamic> json) =>
      IntroductionCitationReference(
        paperId: (json['paper_id'] ?? '').toString(),
        title: (json['title'] ?? 'Untitled paper').toString(),
      );

  Map<String, dynamic> toJson() => {'paper_id': paperId, 'title': title};
}

class IntroductionCitation {
  const IntroductionCitation({
    required this.start,
    required this.end,
    required this.marker,
    required this.references,
  });

  final int start;
  final int end;
  final String marker;
  final List<IntroductionCitationReference> references;

  bool get isNavigable =>
      references.any((reference) => reference.paperId.trim().isNotEmpty);

  factory IntroductionCitation.fromJson(Map<String, dynamic> json) =>
      IntroductionCitation(
        start: (json['start'] as num?)?.toInt() ?? 0,
        end: (json['end'] as num?)?.toInt() ?? 0,
        marker: (json['marker'] ?? '').toString(),
        references: (json['references'] as List<dynamic>? ?? const [])
            .map(
              (value) => IntroductionCitationReference.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .where((reference) => reference.paperId.trim().isNotEmpty)
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'marker': marker,
    'references': references.map((reference) => reference.toJson()).toList(),
  };
}

class IntroductionParagraph {
  const IntroductionParagraph({
    required this.ordinal,
    required this.text,
    this.heading,
    this.citations = const [],
    this.pageStart,
    this.pageEnd,
  });

  final int ordinal;
  final String text;
  final String? heading;
  final List<IntroductionCitation> citations;
  final int? pageStart;
  final int? pageEnd;

  factory IntroductionParagraph.fromJson(Map<String, dynamic> json) =>
      IntroductionParagraph(
        ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
        text: (json['text'] ?? '').toString().trim(),
        heading: json['heading']?.toString(),
        citations: (json['citations'] as List<dynamic>? ?? const [])
            .map(
              (value) => IntroductionCitation.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .where((citation) => citation.isNavigable)
            .toList(growable: false),
        pageStart: (json['page_start'] as num?)?.toInt(),
        pageEnd: (json['page_end'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
    'ordinal': ordinal,
    'text': text,
    if (heading != null) 'heading': heading,
    if (citations.isNotEmpty)
      'citations': citations.map((citation) => citation.toJson()).toList(),
    if (pageStart != null) 'page_start': pageStart,
    if (pageEnd != null) 'page_end': pageEnd,
  };
}

/// Ordered content from the same arXiv version, without PDF column inference.
class IntroductionSourceBlock {
  const IntroductionSourceBlock({
    required this.kind,
    required this.text,
    this.images = const [],
    this.rows = const [],
    this.vectorHtml,
    this.aspectRatio = 1.6,
  });
  final String kind;
  final String text;
  final List<String> images;
  final List<List<String>> rows;
  final String? vectorHtml;
  final double aspectRatio;

  factory IntroductionSourceBlock.fromJson(Map<String, dynamic> json) =>
      IntroductionSourceBlock(
        kind: json['kind'] as String,
        text: json['text'] as String,
        images: (json['images'] as List? ?? []).cast<String>(),
        vectorHtml: json['vector_html'] as String?,
        aspectRatio: (json['aspect_ratio'] as num?)?.toDouble() ?? 1.6,
        rows: (json['rows'] as List? ?? [])
            .map((row) => (row as List).cast<String>())
            .toList(),
      );
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'text': text,
    if (images.isNotEmpty) 'images': images,
    if (rows.isNotEmpty) 'rows': rows,
    if (vectorHtml != null) 'vector_html': vectorHtml,
    if (vectorHtml != null) 'aspect_ratio': aspectRatio,
  };
}

class PaperIntroduction {
  const PaperIntroduction({
    required this.paperId,
    required this.generation,
    required this.heading,
    required this.paragraphs,
    required this.detectionConfidence,
    required this.originalPdfUrl,
    this.sourceBlocks = const [],
    this.sourceUrl,
    this.sourceRevision = 0,
  });

  final String paperId;
  final int generation;
  final String heading;
  final List<IntroductionParagraph> paragraphs;
  final double detectionConfidence;
  final String originalPdfUrl;
  final List<IntroductionSourceBlock> sourceBlocks;
  final String? sourceUrl;
  final int sourceRevision;

  factory PaperIntroduction.fromJson(Map<String, dynamic> json) {
    final nestedDetection = json['detection'];
    final detection = nestedDetection is Map
        ? Map<String, dynamic>.from(nestedDetection)
        : const <String, dynamic>{};
    return PaperIntroduction(
      paperId: (json['paper_id'] ?? '').toString(),
      generation: (json['generation'] as num?)?.toInt() ?? 1,
      heading: (json['heading'] ?? 'Introduction').toString(),
      paragraphs: (json['paragraphs'] as List<dynamic>? ?? const [])
          .map(
            (value) => IntroductionParagraph.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where((paragraph) => paragraph.text.isNotEmpty)
          .toList(growable: false),
      detectionConfidence:
          (json['detection_confidence'] as num?)?.toDouble() ??
          (detection['confidence'] as num?)?.toDouble() ??
          0,
      originalPdfUrl: (json['original_pdf_url'] ?? '').toString(),
      sourceUrl: json['source_url'] as String?,
      sourceRevision: (json['source_revision'] as num?)?.toInt() ?? 0,
      sourceBlocks: (json['source_blocks'] as List? ?? [])
          .map(
            (value) => IntroductionSourceBlock.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'paper_id': paperId,
    'generation': generation,
    'heading': heading,
    'paragraphs': paragraphs.map((paragraph) => paragraph.toJson()).toList(),
    'detection_confidence': detectionConfidence,
    'original_pdf_url': originalPdfUrl,
    if (sourceUrl != null) 'source_url': sourceUrl,
    if (sourceUrl != null) 'source_revision': sourceRevision,
    if (sourceBlocks.isNotEmpty)
      'source_blocks': sourceBlocks.map((block) => block.toJson()).toList(),
  };
}
