import '../document/visual_asset_limits.dart';
import 'paper_passport.dart';
import 'provenance.dart';
import 'semantic_span.dart';

/// A retained mobile reader snapshot is deliberately smaller than the server
/// corpus. Pagination and ListView virtualization keep a large paper usable;
/// this ceiling prevents an adversarial document from turning that bounded
/// window into multi-gigabyte resident state.
const documentSnapshotMaximumBlocks = 2000;
const documentSnapshotMaximumTextCodeUnits = 8 * 1024 * 1024;
const maximumDocumentFigures = 2048;
const maximumDocumentTables = 2048;
const maximumDocumentEquations = 4096;
const maximumTableRows = 512;
const maximumTableColumns = 64;
const maximumTableCells = 8192;
final _figureAssetRevisionPattern = RegExp(r'^[0-9a-f]{64}$');

enum DocumentBlockKind {
  heading,
  paragraph,
  listItem,
  quote,
  theoremDefinition,
  caption,
  equationContext,
  tableContext,
  figureContext,
  footnote,
  other;

  String get wireValue => switch (this) {
    DocumentBlockKind.heading => 'heading',
    DocumentBlockKind.paragraph => 'paragraph',
    DocumentBlockKind.listItem => 'list_item',
    DocumentBlockKind.quote => 'quote',
    DocumentBlockKind.theoremDefinition => 'theorem_definition',
    DocumentBlockKind.caption => 'caption',
    DocumentBlockKind.equationContext => 'equation_context',
    DocumentBlockKind.tableContext => 'table_context',
    DocumentBlockKind.figureContext => 'figure_context',
    DocumentBlockKind.footnote => 'footnote',
    DocumentBlockKind.other => 'other',
  };

  static DocumentBlockKind fromWire(Object? value) => switch (value) {
    'heading' => DocumentBlockKind.heading,
    'paragraph' => DocumentBlockKind.paragraph,
    'list_item' => DocumentBlockKind.listItem,
    'quote' => DocumentBlockKind.quote,
    'theorem' ||
    'definition' ||
    'theorem_definition' => DocumentBlockKind.theoremDefinition,
    'caption' => DocumentBlockKind.caption,
    'equation_context' => DocumentBlockKind.equationContext,
    'table_context' => DocumentBlockKind.tableContext,
    'figure_context' => DocumentBlockKind.figureContext,
    'footnote' => DocumentBlockKind.footnote,
    _ => DocumentBlockKind.other,
  };
}

final class DocumentBoundingBox {
  const DocumentBoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  factory DocumentBoundingBox.fromJson(Map<String, dynamic> json) {
    final left = (json['left'] as num?)?.toDouble();
    final top = (json['top'] as num?)?.toDouble();
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();
    if (left == null ||
        top == null ||
        width == null ||
        height == null ||
        left < 0 ||
        top < 0 ||
        width < 0 ||
        height < 0 ||
        left + width > 1.001 ||
        top + height > 1.001) {
      throw const FormatException('Invalid normalized bounding box.');
    }
    return DocumentBoundingBox(
      left: left,
      top: top,
      width: width,
      height: height,
    );
  }

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };
}

final class DocumentSourceLocator {
  const DocumentSourceLocator({
    this.sourceElementId,
    this.pageNumber,
    this.boundingBox,
  });

  final String? sourceElementId;
  final int? pageNumber;
  final DocumentBoundingBox? boundingBox;

  factory DocumentSourceLocator.fromJson(Map<String, dynamic> json) {
    final pageNumber = _positiveInt(json['page_number']);
    final box = json['bounding_box'];
    return DocumentSourceLocator(
      sourceElementId: _optionalText(json['source_element_id'], 512),
      pageNumber: pageNumber,
      boundingBox: box == null
          ? null
          : DocumentBoundingBox.fromJson(_requiredMap(box)),
    );
  }

  Map<String, Object?> toJson() => {
    'source_element_id': sourceElementId,
    'page_number': pageNumber,
    'bounding_box': boundingBox?.toJson(),
  };
}

final class DocumentInlineSpan {
  const DocumentInlineSpan({
    required this.kind,
    required this.start,
    required this.end,
    this.targetId,
    this.label,
  });

  final String kind;
  final int start;
  final int end;
  final String? targetId;
  final String? label;

  factory DocumentInlineSpan.fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toInt() ?? -1;
    final end = (json['end'] as num?)?.toInt() ?? -1;
    if (start < 0 || end <= start) {
      throw const FormatException('Invalid inline span.');
    }
    return DocumentInlineSpan(
      kind: _requiredText(json['kind'], 64),
      start: start,
      end: end,
      targetId: _optionalText(json['target_id'], 512),
      label: _optionalText(json['label'], 1024),
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kind,
    'start': start,
    'end': end,
    'target_id': targetId,
    'label': label,
  };
}

final class DocumentSection {
  DocumentSection({
    required this.id,
    required this.stableKey,
    required this.title,
    required this.level,
    required this.ordinal,
    required Iterable<String> blockIds,
    Iterable<String> sectionPath = const [],
    this.pageStart,
    this.pageEnd,
  }) : blockIds = List.unmodifiable(blockIds),
       sectionPath = List.unmodifiable(sectionPath);

  final String id;
  final String stableKey;
  final String title;
  final int level;
  final int ordinal;
  final List<String> blockIds;
  final List<String> sectionPath;
  final int? pageStart;
  final int? pageEnd;

  factory DocumentSection.fromJson(Map<String, dynamic> json) {
    final rawPath = json['section_path'] is List
        ? json['section_path'] as List
        : const <Object?>[];
    final sectionPath = _boundedStringList(rawPath, maximumItems: 32);
    final level =
        (json['level'] as num?)?.toInt() ?? sectionPath.length.clamp(1, 8);
    final ordinal = (json['ordinal'] as num?)?.toInt() ?? 0;
    final blockId = json['block_id'];
    final rawBlocks =
        json['block_ids'] ??
        (blockId == null ? const <Object?>[] : <Object?>[blockId]);
    if (level < 1 || level > 8 || ordinal < 0 || rawBlocks is! List) {
      throw const FormatException('Invalid document section.');
    }
    return DocumentSection(
      id: _requiredText(json['block_id'] ?? json['id'], 128),
      stableKey: _requiredText(
        json['stable_key'] ?? json['block_id'] ?? json['id'],
        256,
      ),
      title: _requiredText(json['heading'] ?? json['title'], 1024),
      level: level,
      ordinal: ordinal,
      blockIds: _boundedStringList(rawBlocks, maximumItems: 4096),
      sectionPath: sectionPath,
      pageStart: _positiveInt(json['page_start']),
      pageEnd: _positiveInt(json['page_end']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'stable_key': stableKey,
    'title': title,
    'level': level,
    'ordinal': ordinal,
    'block_ids': blockIds,
    'section_path': sectionPath,
    'page_start': pageStart,
    'page_end': pageEnd,
  };
}

final class DocumentOutline {
  DocumentOutline({
    required this.paperId,
    required this.generation,
    required Iterable<DocumentSection> sections,
    required this.provenance,
  }) : sections = List.unmodifiable(sections);

  final String paperId;
  final int generation;
  final List<DocumentSection> sections;
  final ProvenanceSummary provenance;

  factory DocumentOutline.fromJson(Map<String, dynamic> json) {
    final generation = _generation(json);
    final raw = json['items'] ?? json['sections'];
    if (raw is! List || raw.length > 2048) {
      throw const FormatException('Invalid document outline.');
    }
    final sections =
        raw
            .map((value) {
              if (value is! Map) {
                throw const FormatException('Invalid outline item.');
              }
              return DocumentSection.fromJson(Map<String, dynamic>.from(value));
            })
            .toList(growable: false)
          ..sort((left, right) => left.ordinal.compareTo(right.ordinal));
    return DocumentOutline(
      paperId: _requiredText(json['paper_id'], 128),
      generation: generation,
      sections: sections,
      provenance: ProvenanceSummary.fromJson(_map(json['provenance'])),
    );
  }

  Map<String, Object?> toJson() => {
    'paper_id': paperId,
    'generation': generation,
    'items': sections.map((value) => value.toJson()).toList(growable: false),
    'provenance': provenance.toJson(),
  };
}

final class DocumentBlock {
  DocumentBlock({
    required this.id,
    required this.paperId,
    required this.generation,
    required this.stableKey,
    required this.ordinal,
    required Iterable<String> sectionPath,
    required this.kind,
    required this.text,
    required this.contentHash,
    this.pageStart,
    this.pageEnd,
    this.sourceLocator,
    this.inlineSpans = const [],
  }) : sectionPath = List.unmodifiable(sectionPath);

  final String id;
  final String paperId;
  final int generation;
  final String stableKey;
  final int ordinal;
  final List<String> sectionPath;
  final DocumentBlockKind kind;
  final String text;
  final int? pageStart;
  final int? pageEnd;
  final String contentHash;
  final DocumentSourceLocator? sourceLocator;
  final List<DocumentInlineSpan> inlineSpans;

  String get sectionLabel =>
      sectionPath.isEmpty ? 'Document' : sectionPath.join(' · ');

  factory DocumentBlock.fromJson(
    Map<String, dynamic> json, {
    String? envelopePaperId,
    int? envelopeGeneration,
  }) {
    final ordinal = (json['ordinal'] as num?)?.toInt() ?? -1;
    final pageStart = (json['page_start'] as num?)?.toInt();
    final pageEnd = (json['page_end'] as num?)?.toInt();
    final rawPath = json['section_path'] ?? const <Object?>[];
    final text = json['text']?.toString() ?? '';
    if (ordinal < 0 ||
        rawPath is! List ||
        text.length > 1 << 20 ||
        (pageStart != null && pageStart < 1) ||
        (pageEnd != null &&
            (pageEnd < 1 || (pageStart != null && pageEnd < pageStart)))) {
      throw const FormatException('Invalid document block.');
    }
    return DocumentBlock(
      id: _requiredText(json['id'], 128),
      paperId: _requiredText(json['paper_id'] ?? envelopePaperId, 128),
      generation: _generation({
        'generation': json['generation'] ?? envelopeGeneration,
      }),
      stableKey: _requiredText(json['stable_key'], 512),
      ordinal: ordinal,
      sectionPath: _boundedStringList(rawPath, maximumItems: 16),
      kind: DocumentBlockKind.fromWire(json['kind']),
      text: text,
      pageStart: pageStart,
      pageEnd: pageEnd,
      contentHash: _requiredText(json['content_hash'], 256),
      sourceLocator: json['source_locator'] is Map
          ? DocumentSourceLocator.fromJson(_requiredMap(json['source_locator']))
          : null,
      inlineSpans: _decodeList(
        json['inline_spans'] ?? const <Object?>[],
        DocumentInlineSpan.fromJson,
        4096,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'paper_id': paperId,
    'generation': generation,
    'stable_key': stableKey,
    'ordinal': ordinal,
    'section_path': sectionPath,
    'kind': kind.wireValue,
    'text': text,
    'page_start': pageStart,
    'page_end': pageEnd,
    'content_hash': contentHash,
    'source_locator': sourceLocator?.toJson(),
    'inline_spans': inlineSpans.map((value) => value.toJson()).toList(),
  };
}

final class DocumentBlockPage {
  DocumentBlockPage({
    required this.paperId,
    required this.generation,
    required Iterable<DocumentBlock> blocks,
    required this.nextCursor,
    required this.provenance,
  }) : blocks = List.unmodifiable(blocks);

  final String paperId;
  final int generation;
  final List<DocumentBlock> blocks;
  final String? nextCursor;
  final ProvenanceSummary provenance;

  factory DocumentBlockPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List || raw.length > 100) {
      throw const FormatException('Invalid document block page.');
    }
    final cursor = json['next_cursor']?.toString().trim();
    return DocumentBlockPage(
      paperId: _requiredText(json['paper_id'], 128),
      generation: _generation(json),
      blocks: raw.map((value) {
        if (value is! Map) throw const FormatException('Invalid block item.');
        return DocumentBlock.fromJson(
          Map<String, dynamic>.from(value),
          envelopePaperId: _requiredText(json['paper_id'], 128),
          envelopeGeneration: _generation(json),
        );
      }),
      nextCursor: cursor?.isNotEmpty == true && cursor!.length <= 1024
          ? cursor
          : null,
      provenance: ProvenanceSummary.fromJson(_map(json['provenance'])),
    );
  }
}

enum DocumentObjectStatus { ready, partial, uncertain, unavailable, failed }

DocumentObjectStatus _objectStatus(Object? value) => switch (value) {
  'ready' => DocumentObjectStatus.ready,
  'caption_only' => DocumentObjectStatus.partial,
  'supported' => DocumentObjectStatus.ready,
  'partial' => DocumentObjectStatus.partial,
  'uncertain' => DocumentObjectStatus.uncertain,
  'failed' => DocumentObjectStatus.failed,
  _ => DocumentObjectStatus.unavailable,
};

abstract interface class DocumentEvidenceObject {
  String get id;
  String get label;
  String? get caption;
  int? get page;
  List<String> get sourceBlockIds;
  List<DocumentObjectReference> get referencedBy;
  DocumentObjectStatus get status;
  String? get limitation;
}

final class DocumentObjectReference {
  DocumentObjectReference({
    required this.blockId,
    required this.startOffset,
    required this.endOffset,
    required this.context,
    required Iterable<String> sectionPath,
    this.marker,
    this.pageNumber,
  }) : sectionPath = List.unmodifiable(sectionPath) {
    if (startOffset < 0 || endOffset <= startOffset) {
      throw const FormatException('Invalid visual object reference range.');
    }
  }

  final String blockId;
  final int startOffset;
  final int endOffset;
  final String? marker;
  final String context;
  final List<String> sectionPath;
  final int? pageNumber;

  String get sectionLabel =>
      sectionPath.isEmpty ? 'Document' : sectionPath.join(' · ');

  factory DocumentObjectReference.fromJson(Map<String, dynamic> json) {
    final startOffset = (json['start_offset'] as num?)?.toInt() ?? -1;
    final endOffset = (json['end_offset'] as num?)?.toInt() ?? -1;
    return DocumentObjectReference(
      blockId: _requiredText(json['block_id'], 128),
      startOffset: startOffset,
      endOffset: endOffset,
      marker: _optionalText(json['marker'], 1024),
      context: _requiredText(json['context'], 4096),
      sectionPath: _boundedStringList(
        json['section_path'] is List ? json['section_path'] as List : const [],
        maximumItems: 32,
      ),
      pageNumber: _positiveInt(json['page_number']),
    );
  }

  Map<String, Object?> toJson() => {
    'block_id': blockId,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'marker': marker,
    'context': context,
    'section_path': sectionPath,
    'page_number': pageNumber,
  };
}

final class DocumentFigure implements DocumentEvidenceObject {
  DocumentFigure({
    required this.id,
    required this.label,
    required this.caption,
    required this.page,
    required Iterable<String> sourceBlockIds,
    Iterable<DocumentObjectReference> referencedBy = const [],
    required this.status,
    required this.limitation,
    this.altText,
    this.assetUrl,
    this.assetRevision,
    this.checksum,
    this.ordinal = 0,
    this.assetAvailable = false,
    this.assetRequestable = false,
    this.width,
    this.height,
    this.contentHash,
    this.sourceLocator,
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds),
       referencedBy = List.unmodifiable(referencedBy);

  @override
  final String id;
  @override
  final String label;
  @override
  final String? caption;
  @override
  final int? page;
  @override
  final List<String> sourceBlockIds;
  @override
  final List<DocumentObjectReference> referencedBy;
  @override
  final DocumentObjectStatus status;
  @override
  final String? limitation;
  final String? altText;
  final String? assetUrl;
  final String? assetRevision;
  final String? checksum;
  final int ordinal;
  final bool assetAvailable;
  final bool assetRequestable;
  final int? width;
  final int? height;
  final String? contentHash;
  final DocumentSourceLocator? sourceLocator;

  factory DocumentFigure.fromJson(Map<String, dynamic> json) {
    final id = _requiredText(json['id'], 128);
    final advertisedAsset = json['asset_available'] == true;
    final advertisedRequestable = json['asset_requestable'] == true;
    final rawAssetUrl = _optionalText(json['asset_url'], 2048);
    final assetRevision = rawAssetUrl == null
        ? null
        : _figureAssetRevision(rawAssetUrl, id);
    final width = _positiveInt(json['width']);
    final height = _positiveInt(json['height']);
    final status = _objectStatus(json['extraction_status'] ?? json['status']);
    final assetRequestable =
        advertisedRequestable &&
        rawAssetUrl != null &&
        assetRevision != null &&
        status == DocumentObjectStatus.ready &&
        width != null &&
        height != null &&
        validVisualAssetDimensions(width, height);
    final assetAvailable = advertisedAsset && assetRequestable;
    return DocumentFigure(
      id: id,
      label: _requiredText(json['label'] ?? 'Figure', 256),
      caption: _optionalText(json['caption'], 16000),
      page: _positiveInt(json['page_number'] ?? json['page']),
      sourceBlockIds: _boundedStringList(
        json['source_block_ids'] is List
            ? json['source_block_ids'] as List
            : const [],
        maximumItems: 128,
      ),
      referencedBy: _decodeList(
        json['referenced_by'],
        DocumentObjectReference.fromJson,
        128,
      ),
      status: status,
      limitation: _optionalText(json['limitation'], 1024),
      altText: _optionalText(json['alt_text'], 4000),
      assetUrl: assetRequestable ? rawAssetUrl : null,
      assetRevision: assetRequestable ? assetRevision : null,
      checksum: _optionalText(json['checksum'], 256),
      ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
      assetAvailable: assetAvailable,
      assetRequestable: assetRequestable,
      width: width,
      height: height,
      contentHash: _optionalText(json['content_hash'], 256),
      sourceLocator: json['source_locator'] is Map
          ? DocumentSourceLocator.fromJson(_requiredMap(json['source_locator']))
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'caption': caption,
    'page': page,
    'source_block_ids': sourceBlockIds,
    'referenced_by': referencedBy.map((value) => value.toJson()).toList(),
    'status': status.name,
    'limitation': limitation,
    'alt_text': altText,
    'asset_url': assetUrl,
    'checksum': checksum,
    'ordinal': ordinal,
    'asset_available': assetAvailable,
    'asset_requestable': assetRequestable,
    'width': width,
    'height': height,
    'content_hash': contentHash,
    'source_locator': sourceLocator?.toJson(),
  };
}

final class DocumentTableCell {
  const DocumentTableCell({
    required this.text,
    required this.header,
    required this.rowSpan,
    required this.columnSpan,
  });
  final String text;
  final bool header;
  final int rowSpan;
  final int columnSpan;
  factory DocumentTableCell.fromJson(Map<String, dynamic> json) {
    final rowSpan = (json['row_span'] as num?)?.toInt() ?? 1;
    final columnSpan = (json['column_span'] as num?)?.toInt() ?? 1;
    if (rowSpan < 1 ||
        rowSpan > maximumTableRows ||
        columnSpan < 1 ||
        columnSpan > maximumTableColumns) {
      throw const FormatException('Invalid table cell span.');
    }
    return DocumentTableCell(
      text: _requiredText(json['text'], 16000),
      header: json['header'] == true,
      rowSpan: rowSpan,
      columnSpan: columnSpan,
    );
  }

  Map<String, Object?> toJson() => {
    'text': text,
    'header': header,
    'row_span': rowSpan,
    'column_span': columnSpan,
  };
}

final class DocumentTable implements DocumentEvidenceObject {
  DocumentTable({
    required this.id,
    required this.label,
    required this.caption,
    required this.page,
    required Iterable<String> sourceBlockIds,
    Iterable<DocumentObjectReference> referencedBy = const [],
    required this.status,
    required this.limitation,
    required Iterable<String> columns,
    required Iterable<List<String>> rows,
    this.ordinal = 0,
    this.plainText,
    this.contentHash,
    this.sourceLocator,
    this.schemaVersion,
    this.structureRows = const [],
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds),
       referencedBy = List.unmodifiable(referencedBy),
       columns = List.unmodifiable(columns),
       rows = List.unmodifiable(rows.map(List<String>.unmodifiable));

  @override
  final String id;
  @override
  final String label;
  @override
  final String? caption;
  @override
  final int? page;
  @override
  final List<String> sourceBlockIds;
  @override
  final List<DocumentObjectReference> referencedBy;
  @override
  final DocumentObjectStatus status;
  @override
  final String? limitation;
  final List<String> columns;
  final List<List<String>> rows;
  final int ordinal;
  final String? plainText;
  final String? contentHash;
  final DocumentSourceLocator? sourceLocator;
  final String? schemaVersion;
  final List<List<DocumentTableCell>> structureRows;

  factory DocumentTable.fromJson(Map<String, dynamic> json) {
    final structure = json['structure'];
    final structureMap = structure is Map
        ? Map<String, dynamic>.from(structure)
        : const <String, dynamic>{};
    final structuredRows = structureMap['rows'];
    if (structuredRows is List) _validateRawTableRows(structuredRows);
    final exactRows = structuredRows is List
        ? structuredRows
              .map((row) {
                if (row is! List) {
                  throw const FormatException('Invalid table row.');
                }
                return row
                    .map((cell) {
                      if (cell is! Map) {
                        throw const FormatException('Invalid table cell.');
                      }
                      return DocumentTableCell.fromJson(
                        Map<String, dynamic>.from(cell),
                      );
                    })
                    .toList(growable: false);
              })
              .toList(growable: false)
        : const <List<DocumentTableCell>>[];
    final rawRows = structuredRows is List ? structuredRows : json['rows'];
    if (rawRows is List && !identical(rawRows, structuredRows)) {
      _validateRawTableRows(rawRows);
    }
    final decodedRows = rawRows is List
        ? rawRows
              .map((row) {
                if (row is! List) {
                  throw const FormatException('Invalid table row.');
                }
                return row
                    .map((cell) {
                      if (cell is Map) {
                        return _requiredText(cell['text'], 16000);
                      }
                      return _requiredText(cell, 16000);
                    })
                    .toList(growable: false);
              })
              .toList(growable: false)
        : const <List<String>>[];
    final inferredColumnCount = exactRows.isNotEmpty
        ? exactRows
              .map(
                (row) =>
                    row.fold<int>(0, (total, cell) => total + cell.columnSpan),
              )
              .fold<int>(
                0,
                (maximum, count) => count > maximum ? count : maximum,
              )
        : decodedRows.isEmpty
        ? 0
        : decodedRows.first.length;
    final rawColumns = json['columns'] is List
        ? json['columns'] as List
        : inferredColumnCount == 0
        ? const <Object?>[]
        : List<Object?>.generate(inferredColumnCount, (i) => 'Column ${i + 1}');
    if (rawColumns.length > maximumTableColumns ||
        decodedRows.length > maximumTableRows) {
      throw const FormatException('Invalid table data.');
    }
    final columns = _boundedStringList(
      rawColumns,
      maximumItems: maximumTableColumns,
    );
    final rows = decodedRows
        .map((row) {
          if (exactRows.isEmpty && row.length != columns.length) {
            throw const FormatException('Invalid table row.');
          }
          return _boundedStringList(row, maximumItems: maximumTableColumns);
        })
        .toList(growable: false);
    return DocumentTable(
      id: _requiredText(json['id'], 128),
      label: _requiredText(json['label'] ?? 'Table', 256),
      caption: _optionalText(json['caption'], 16000),
      page: _positiveInt(json['page_number'] ?? json['page']),
      sourceBlockIds: _boundedStringList(
        json['source_block_ids'] is List
            ? json['source_block_ids'] as List
            : const [],
        maximumItems: 128,
      ),
      referencedBy: _decodeList(
        json['referenced_by'],
        DocumentObjectReference.fromJson,
        128,
      ),
      status: _objectStatus(json['extraction_status'] ?? json['status']),
      limitation: _optionalText(json['limitation'], 1024),
      columns: columns,
      rows: rows,
      ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
      plainText: _optionalText(json['plain_text'], 64000),
      contentHash: _optionalText(json['content_hash'], 256),
      sourceLocator: json['source_locator'] is Map
          ? DocumentSourceLocator.fromJson(_requiredMap(json['source_locator']))
          : null,
      schemaVersion: _optionalText(structureMap['schema_version'], 64),
      structureRows: exactRows,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'caption': caption,
    'page': page,
    'source_block_ids': sourceBlockIds,
    'referenced_by': referencedBy.map((value) => value.toJson()).toList(),
    'status': status.name,
    'limitation': limitation,
    'columns': columns,
    'rows': rows,
    'ordinal': ordinal,
    'plain_text': plainText,
    'content_hash': contentHash,
    'source_locator': sourceLocator?.toJson(),
    'structure': schemaVersion == null && structureRows.isEmpty
        ? null
        : {
            'schema_version': schemaVersion,
            'rows': structureRows
                .map((row) => row.map((cell) => cell.toJson()).toList())
                .toList(),
          },
  };
}

void _validateRawTableRows(List<dynamic> rows) {
  if (rows.length > maximumTableRows) {
    throw const FormatException('Invalid table row count.');
  }
  var cells = 0;
  for (final row in rows) {
    if (row is! List || row.length > maximumTableColumns) {
      throw const FormatException('Invalid table shape.');
    }
    cells += row.length;
    if (cells > maximumTableCells) {
      throw const FormatException('Invalid table cell count.');
    }
  }
}

final class DocumentEquation implements DocumentEvidenceObject {
  DocumentEquation({
    required this.id,
    required this.label,
    required this.caption,
    required this.page,
    required Iterable<String> sourceBlockIds,
    Iterable<DocumentObjectReference> referencedBy = const [],
    required this.status,
    required this.limitation,
    this.latex,
    this.mathMl,
    this.plainText,
    this.ordinal = 0,
    this.contextBlockId,
    this.contentHash,
    this.sourceLocator,
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds),
       referencedBy = List.unmodifiable(referencedBy);

  @override
  final String id;
  @override
  final String label;
  @override
  final String? caption;
  @override
  final int? page;
  @override
  final List<String> sourceBlockIds;
  @override
  final List<DocumentObjectReference> referencedBy;
  @override
  final DocumentObjectStatus status;
  @override
  final String? limitation;
  final String? latex;
  final String? mathMl;
  final String? plainText;
  final int ordinal;
  final String? contextBlockId;
  final String? contentHash;
  final DocumentSourceLocator? sourceLocator;

  factory DocumentEquation.fromJson(Map<String, dynamic> json) {
    return DocumentEquation(
      id: _requiredText(json['id'], 128),
      label: _requiredText(json['label'] ?? 'Equation', 256),
      caption: _optionalText(json['caption'], 16000),
      page: _positiveInt(json['page_number'] ?? json['page']),
      sourceBlockIds: _boundedStringList(
        json['source_block_ids'] is List
            ? json['source_block_ids'] as List
            : const [],
        maximumItems: 128,
      ),
      referencedBy: _decodeList(
        json['referenced_by'],
        DocumentObjectReference.fromJson,
        128,
      ),
      status: _objectStatus(json['confidence_status'] ?? json['status']),
      limitation: _optionalText(json['limitation'], 1024),
      latex: _optionalText(json['latex'], 32000),
      mathMl: _optionalText(json['mathml'], 64000),
      plainText: _optionalText(json['plain_text'], 8000),
      ordinal: (json['ordinal'] as num?)?.toInt() ?? 0,
      contextBlockId: _optionalText(json['context_block_id'], 128),
      contentHash: _optionalText(json['content_hash'], 256),
      sourceLocator: json['source_locator'] is Map
          ? DocumentSourceLocator.fromJson(_requiredMap(json['source_locator']))
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'caption': caption,
    'page': page,
    'source_block_ids': sourceBlockIds,
    'referenced_by': referencedBy.map((value) => value.toJson()).toList(),
    'status': status.name,
    'limitation': limitation,
    'latex': latex,
    'mathml': mathMl,
    'plain_text': plainText,
    'ordinal': ordinal,
    'context_block_id': contextBlockId,
    'content_hash': contentHash,
    'source_locator': sourceLocator?.toJson(),
  };
}

enum PaperTermKind {
  term('term', 'Term'),
  acronym('acronym', 'Acronym'),
  symbol('symbol', 'Symbol'),
  method('method', 'Method'),
  dataset('dataset', 'Dataset');

  const PaperTermKind(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static PaperTermKind fromWire(Object? value) => switch (value) {
    'term' => PaperTermKind.term,
    'acronym' => PaperTermKind.acronym,
    'symbol' => PaperTermKind.symbol,
    'method' => PaperTermKind.method,
    'dataset' => PaperTermKind.dataset,
    _ => throw const FormatException('Invalid term kind.'),
  };
}

enum TermDefinitionStatus {
  available('available', 'Available'),
  notFound('not_found', 'Not found'),
  notApplicable('not_applicable', 'Not applicable'),
  uncertain('uncertain', 'Uncertain');

  const TermDefinitionStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static TermDefinitionStatus fromWire(Object? value) => switch (value) {
    'available' => TermDefinitionStatus.available,
    'not_found' => TermDefinitionStatus.notFound,
    'not_applicable' => TermDefinitionStatus.notApplicable,
    'uncertain' => TermDefinitionStatus.uncertain,
    _ => throw const FormatException('Invalid term definition status.'),
  };
}

enum TermDefinitionSource {
  currentPaper('current_paper', 'Current paper', 0),
  citedPaper('cited_paper', 'Cited paper', 1),
  glossary('glossary', 'Trusted glossary', 2),
  generated('generated', 'Generated explanation', 3);

  const TermDefinitionSource(this.wireValue, this.label, this.precedence);

  final String wireValue;
  final String label;
  final int precedence;

  static TermDefinitionSource fromWire(Object? value) => switch (value) {
    'current_paper' => TermDefinitionSource.currentPaper,
    'cited_paper' => TermDefinitionSource.citedPaper,
    'glossary' => TermDefinitionSource.glossary,
    'generated' => TermDefinitionSource.generated,
    _ => throw const FormatException('Invalid definition source.'),
  };
}

enum TermDefinitionConfidence {
  supported('supported', 'Supported'),
  inferred('inferred', 'Inferred'),
  uncertain('uncertain', 'Uncertain');

  const TermDefinitionConfidence(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static TermDefinitionConfidence fromWire(Object? value) => switch (value) {
    'supported' => TermDefinitionConfidence.supported,
    'inferred' => TermDefinitionConfidence.inferred,
    'uncertain' => TermDefinitionConfidence.uncertain,
    _ => throw const FormatException('Invalid definition confidence.'),
  };
}

final class TermOccurrence {
  TermOccurrence({
    required this.blockId,
    required this.startOffset,
    required this.endOffset,
    this.occurrenceOrdinal = 0,
  }) {
    if (!_isStrictUuid(blockId) ||
        startOffset < 0 ||
        startOffset > _maximumWireUint32 ||
        endOffset <= startOffset ||
        endOffset > _maximumWireUint32 ||
        occurrenceOrdinal < 0 ||
        occurrenceOrdinal > _maximumWireUint32) {
      throw const FormatException('Invalid term occurrence.');
    }
  }

  final String blockId;
  final int startOffset;
  final int endOffset;
  final int occurrenceOrdinal;

  factory TermOccurrence.fromJson(Map<String, dynamic> json) {
    return TermOccurrence(
      blockId: _requiredStrictUuid(json['block_id']),
      startOffset: _requiredWireInteger(json['start_offset']),
      endOffset: _requiredWireInteger(json['end_offset']),
      occurrenceOrdinal: _requiredWireInteger(json['occurrence_ordinal']),
    );
  }

  Map<String, Object?> toJson() => {
    'block_id': blockId,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'occurrence_ordinal': occurrenceOrdinal,
  };
}

final class TermDefinition {
  TermDefinition({
    required this.id,
    required this.sourceType,
    required Iterable<String> sourceBlockIds,
    required this.definition,
    required this.confidenceStatus,
    this.modelId,
    this.promptVersion,
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds) {
    if (!_isStrictUuid(id) ||
        this.sourceBlockIds.length > 64 ||
        this.sourceBlockIds.any((value) => !_isStrictUuid(value)) ||
        this.sourceBlockIds.toSet().length != this.sourceBlockIds.length ||
        (sourceType != TermDefinitionSource.generated &&
            this.sourceBlockIds.isEmpty) ||
        !_isBoundedScalarText(definition, 100000) ||
        !_isOptionalBoundedScalarText(modelId, 128) ||
        !_isOptionalBoundedScalarText(promptVersion, 128)) {
      throw const FormatException('Invalid term definition.');
    }
  }

  final String id;
  final TermDefinitionSource sourceType;
  final List<String> sourceBlockIds;
  final String definition;
  final TermDefinitionConfidence confidenceStatus;
  final String? modelId;
  final String? promptVersion;

  factory TermDefinition.fromJson(Map<String, dynamic> json) => TermDefinition(
    id: _requiredStrictUuid(json['id']),
    sourceType: TermDefinitionSource.fromWire(json['source_type']),
    sourceBlockIds: _strictUuidList(json['source_block_ids'], maximumItems: 64),
    definition: _requiredScalarText(json['definition'], 100000),
    confidenceStatus: TermDefinitionConfidence.fromWire(
      json['confidence_status'],
    ),
    modelId: _optionalScalarText(json['model_id'], 128),
    promptVersion: _optionalScalarText(json['prompt_version'], 128),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'source_type': sourceType.wireValue,
    'source_block_ids': sourceBlockIds,
    'definition': definition,
    'confidence_status': confidenceStatus.wireValue,
    if (modelId != null) 'model_id': modelId,
    if (promptVersion != null) 'prompt_version': promptVersion,
  };
}

final class PaperTerm {
  PaperTerm({
    required this.id,
    required this.displayTerm,
    required this.kind,
    required this.definitionStatus,
    required Iterable<String> sourceBlockIds,
    required Iterable<TermOccurrence> occurrences,
    required this.normalizedTerm,
    this.canonicalTopicId,
    Iterable<TermDefinition> definitions = const [],
  }) : sourceBlockIds = List.unmodifiable(sourceBlockIds),
       occurrences = List.unmodifiable(occurrences),
       definitions = List.unmodifiable(definitions) {
    if (!_isStrictUuid(id) ||
        !_isBoundedScalarText(displayTerm, 512) ||
        !_isBoundedScalarText(normalizedTerm, 512) ||
        (canonicalTopicId != null && !_isStrictUuid(canonicalTopicId!)) ||
        this.sourceBlockIds.length > 128 ||
        this.sourceBlockIds.any((value) => !_isStrictUuid(value)) ||
        this.sourceBlockIds.toSet().length != this.sourceBlockIds.length ||
        this.occurrences.length > 4096 ||
        this.definitions.length > 128) {
      throw const FormatException('Invalid paper term.');
    }
    final occurrenceKeys = <String>{};
    for (final occurrence in this.occurrences) {
      if (!occurrenceKeys.add(
        '${occurrence.blockId}:${occurrence.occurrenceOrdinal}',
      )) {
        throw const FormatException('Duplicate term occurrence.');
      }
    }
    final definitionIds = <String>{};
    if (this.definitions.any((value) => !definitionIds.add(value.id))) {
      throw const FormatException('Duplicate term definition.');
    }
    if (definitionStatus == TermDefinitionStatus.available &&
        this.definitions.isEmpty) {
      throw const FormatException('Available term has no definition.');
    }
  }

  final String id;
  final String displayTerm;
  final PaperTermKind kind;
  final TermDefinitionStatus definitionStatus;
  final List<String> sourceBlockIds;
  final List<TermOccurrence> occurrences;
  final String normalizedTerm;
  final String? canonicalTopicId;
  final List<TermDefinition> definitions;

  String? get definition => definitions.firstOrNull?.definition;

  factory PaperTerm.fromJson(Map<String, dynamic> json) {
    final rawOccurrences = json['occurrences'] ?? const <Object?>[];
    if (rawOccurrences is! List || rawOccurrences.length > 4096) {
      throw const FormatException('Invalid term occurrences.');
    }
    final rawDefinitions = json['definitions'] ?? const <Object?>[];
    if (rawDefinitions is! List || rawDefinitions.length > 128) {
      throw const FormatException('Invalid term definitions.');
    }
    final definitions = rawDefinitions
        .map((raw) {
          if (raw is! Map) throw const FormatException('Invalid definition.');
          return TermDefinition.fromJson(Map<String, dynamic>.from(raw));
        })
        .toList(growable: false);
    return PaperTerm(
      id: _requiredStrictUuid(json['id']),
      displayTerm: _requiredScalarText(json['display_term'], 512),
      kind: PaperTermKind.fromWire(json['kind']),
      definitionStatus: TermDefinitionStatus.fromWire(
        json['definition_status'],
      ),
      sourceBlockIds: _strictUuidList(
        json['source_block_ids'] ?? const <Object?>[],
        maximumItems: 128,
      ),
      occurrences: rawOccurrences.map((raw) {
        if (raw is! Map) throw const FormatException('Invalid occurrence.');
        return TermOccurrence.fromJson(Map<String, dynamic>.from(raw));
      }),
      normalizedTerm: _requiredScalarText(
        json['normalized_term'] ?? json['display_term'],
        512,
      ),
      canonicalTopicId: json['canonical_topic_id'] == null
          ? null
          : _requiredStrictUuid(json['canonical_topic_id']),
      definitions: definitions,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'normalized_term': normalizedTerm,
    'display_term': displayTerm,
    'kind': kind.wireValue,
    'definition_status': definitionStatus.wireValue,
    if (canonicalTopicId != null) 'canonical_topic_id': canonicalTopicId,
    'source_block_ids': sourceBlockIds,
    'occurrences': occurrences.map((value) => value.toJson()).toList(),
    'definitions': definitions.map((value) => value.toJson()).toList(),
  };
}

final class DocumentSnapshot {
  DocumentSnapshot({
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.outline,
    required Iterable<DocumentBlock> blocks,
    required Iterable<DocumentFigure> figures,
    required Iterable<DocumentTable> tables,
    required Iterable<DocumentEquation> equations,
    required Iterable<PaperTerm> terms,
    Iterable<SemanticSpan> semanticSpans = const [],
    required this.passport,
    required this.provenance,
    required this.fetchedAt,
    this.nextCursor,
    this.passportIncluded = false,
    this.semanticFacetsIncluded = false,
    this.visualObjectsIncluded = false,
  }) : blocks = _boundedSnapshotBlocks(blocks),
       figures = List.unmodifiable(figures),
       tables = List.unmodifiable(tables),
       equations = List.unmodifiable(equations),
       terms = List.unmodifiable(terms),
       semanticSpans = _boundedSemanticSpans(semanticSpans);

  final String paperId;
  final String versionKey;
  final int generation;
  final DocumentOutline outline;
  final List<DocumentBlock> blocks;
  final List<DocumentFigure> figures;
  final List<DocumentTable> tables;
  final List<DocumentEquation> equations;
  final List<PaperTerm> terms;
  final List<SemanticSpan> semanticSpans;
  final PaperPassport? passport;
  final ProvenanceSummary provenance;
  final DateTime fetchedAt;
  final String? nextCursor;
  final bool passportIncluded;
  final bool semanticFacetsIncluded;
  final bool visualObjectsIncluded;

  bool includesCapabilities({
    required bool passport,
    required bool semanticFacets,
    required bool visualObjects,
  }) =>
      (!passport || passportIncluded) &&
      (!semanticFacets || semanticFacetsIncluded) &&
      (!visualObjects || visualObjectsIncluded);

  DocumentSnapshot withVisualObjects({
    required Iterable<DocumentFigure> figures,
    required Iterable<DocumentTable> tables,
    required Iterable<DocumentEquation> equations,
  }) => DocumentSnapshot(
    paperId: paperId,
    versionKey: versionKey,
    generation: generation,
    outline: outline,
    blocks: blocks,
    figures: figures,
    tables: tables,
    equations: equations,
    terms: terms,
    semanticSpans: semanticSpans,
    passport: passport,
    provenance: provenance,
    fetchedAt: fetchedAt,
    nextCursor: nextCursor,
    passportIncluded: passportIncluded,
    semanticFacetsIncluded: semanticFacetsIncluded,
    visualObjectsIncluded: true,
  );

  DocumentSnapshot appendPage(DocumentBlockPage page) {
    if (page.paperId != paperId ||
        page.generation != generation ||
        page.blocks.any(
          (block) => block.paperId != paperId || block.generation != generation,
        )) {
      throw const FormatException('Document page scope mismatch.');
    }
    final existingIds = blocks.map((block) => block.id).toSet();
    final existingOrdinals = blocks.map((block) => block.ordinal).toSet();
    final pageIds = <String>{};
    final pageOrdinals = <int>{};
    var previousOrdinal = blocks.lastOrNull?.ordinal;
    for (final block in page.blocks) {
      if (!pageIds.add(block.id) ||
          !pageOrdinals.add(block.ordinal) ||
          existingIds.contains(block.id) ||
          existingOrdinals.contains(block.ordinal) ||
          (previousOrdinal != null && block.ordinal <= previousOrdinal)) {
        throw const FormatException('Document page overlaps cached blocks.');
      }
      previousOrdinal = block.ordinal;
    }
    if (page.blocks.isEmpty && page.nextCursor != null) {
      throw const FormatException('Empty document page cannot continue.');
    }
    return DocumentSnapshot(
      paperId: paperId,
      versionKey: versionKey,
      generation: generation,
      outline: outline,
      blocks: [...blocks, ...page.blocks],
      figures: figures,
      tables: tables,
      equations: equations,
      terms: terms,
      semanticSpans: semanticSpans,
      passport: passport,
      provenance: provenance,
      fetchedAt: fetchedAt,
      nextCursor: page.nextCursor,
      passportIncluded: passportIncluded,
      semanticFacetsIncluded: semanticFacetsIncluded,
      visualObjectsIncluded: visualObjectsIncluded,
    );
  }

  factory DocumentSnapshot.fromJson(Map<String, dynamic> json) {
    final generation = _generation(json);
    final outline = DocumentOutline.fromJson(_requiredMap(json['outline']));
    final blocks = _decodeList(
      json['blocks'],
      DocumentBlock.fromJson,
      documentSnapshotMaximumBlocks,
    );
    final figures = _decodeList(json['figures'], DocumentFigure.fromJson, 2048);
    final tables = _decodeList(json['tables'], DocumentTable.fromJson, 2048);
    final equations = _decodeList(
      json['equations'],
      DocumentEquation.fromJson,
      4096,
    );
    final terms = _decodeList(json['terms'], PaperTerm.fromJson, 10000);
    final rawSemanticSpans = json['semantic_spans'];
    final semanticSpans = rawSemanticSpans == null
        ? const <SemanticSpan>[]
        : _decodeList(
            rawSemanticSpans,
            SemanticSpan.fromJson,
            maximumSemanticSpans,
          );
    final paperId = _requiredText(json['paper_id'], 128);
    if (outline.paperId != paperId ||
        outline.generation != generation ||
        blocks.any(
          (block) => block.paperId != paperId || block.generation != generation,
        )) {
      throw const FormatException('Document generation mismatch.');
    }
    final passport = switch (json['passport']) {
      final Map value => PaperPassport.fromJson(
        Map<String, dynamic>.from(value),
      ),
      null => null,
      _ => throw const FormatException('Invalid cached Passport.'),
    };
    if (passport != null &&
        (passport.paperId != paperId ||
            passport.generation != generation ||
            !passportVersionMatchesVersionKey(
              passport,
              json['version_key']?.toString() ?? '',
            ))) {
      throw const FormatException('Passport generation mismatch.');
    }
    final fetchedAt = DateTime.tryParse(
      json['fetched_at']?.toString() ?? '',
    )?.toUtc();
    if (fetchedAt == null) {
      throw const FormatException('Missing document cache timestamp.');
    }
    return DocumentSnapshot(
      paperId: paperId,
      versionKey: _requiredText(json['version_key'], 512),
      generation: generation,
      outline: outline,
      blocks: blocks..sort((a, b) => a.ordinal.compareTo(b.ordinal)),
      figures: figures,
      tables: tables,
      equations: equations,
      terms: terms,
      semanticSpans: semanticSpans,
      passport: passport,
      provenance: ProvenanceSummary.fromJson(_map(json['provenance'])),
      fetchedAt: fetchedAt,
      nextCursor: _optionalText(json['next_cursor'], 1024),
      passportIncluded: json['passport_included'] == true || passport != null,
      semanticFacetsIncluded:
          json['semantic_facets_included'] == true && rawSemanticSpans is List,
      visualObjectsIncluded:
          json['visual_objects_included'] == true ||
          figures.isNotEmpty ||
          tables.isNotEmpty ||
          equations.isNotEmpty,
    );
  }

  Map<String, Object?> toJson() => {
    'paper_id': paperId,
    'version_key': versionKey,
    'generation': generation,
    'outline': outline.toJson(),
    'blocks': blocks.map((value) => value.toJson()).toList(growable: false),
    'figures': figures.map((value) => value.toJson()).toList(growable: false),
    'tables': tables.map((value) => value.toJson()).toList(growable: false),
    'equations': equations
        .map((value) => value.toJson())
        .toList(growable: false),
    'terms': terms.map((value) => value.toJson()).toList(growable: false),
    'semantic_spans': semanticSpans
        .map((value) => value.toJson())
        .toList(growable: false),
    'passport': passport?.toJson(),
    'provenance': provenance.toJson(),
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'next_cursor': nextCursor,
    'passport_included': passportIncluded,
    'semantic_facets_included': semanticFacetsIncluded,
    'visual_objects_included': visualObjectsIncluded,
  };
}

List<SemanticSpan> _boundedSemanticSpans(Iterable<SemanticSpan> values) {
  final spans = List<SemanticSpan>.unmodifiable(values);
  if (spans.length > maximumSemanticSpans ||
      spans.map((value) => value.id).toSet().length != spans.length ||
      spans.map((value) => value.ordinal).toSet().length != spans.length) {
    throw const FormatException('Invalid semantic span collection.');
  }
  return spans;
}

List<DocumentBlock> _boundedSnapshotBlocks(Iterable<DocumentBlock> values) {
  final blocks = List<DocumentBlock>.unmodifiable(values);
  if (blocks.length > documentSnapshotMaximumBlocks) {
    throw const FormatException('Document snapshot block limit exceeded.');
  }
  var textCodeUnits = 0;
  for (final block in blocks) {
    textCodeUnits += block.text.length;
    if (textCodeUnits > documentSnapshotMaximumTextCodeUnits) {
      throw const FormatException('Document snapshot text budget exceeded.');
    }
  }
  return blocks;
}

List<T> _decodeList<T>(
  Object? raw,
  T Function(Map<String, dynamic>) decode,
  int maximum,
) {
  if (raw == null) return <T>[];
  if (raw is! List || raw.length > maximum) {
    throw const FormatException('Invalid document collection.');
  }
  return raw
      .map((value) {
        if (value is! Map) {
          throw const FormatException('Invalid document item.');
        }
        return decode(Map<String, dynamic>.from(value));
      })
      .toList(growable: false);
}

String? _figureAssetRevision(String value, String figureId) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.isNotEmpty ||
      uri.host.isNotEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      !uri.path.startsWith('/')) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.length != 6 ||
      segments[0] != 'v1' ||
      segments[1] != 'papers' ||
      segments[2].isEmpty ||
      segments[3] != 'figures' ||
      segments[4] != figureId ||
      segments[5] != 'asset') {
    return null;
  }
  final parameters = uri.queryParametersAll;
  if (parameters.length != 2 ||
      parameters['generation']?.length != 1 ||
      parameters['revision']?.length != 1) {
    return null;
  }
  final revision = parameters['revision']!.single;
  return (int.tryParse(parameters['generation']!.single) ?? 0) > 0 &&
          _figureAssetRevisionPattern.hasMatch(revision)
      ? revision
      : null;
}

int _generation(Map<String, dynamic> json) {
  final value = (json['generation'] as num?)?.toInt() ?? 0;
  if (value <= 0) throw const FormatException('Invalid document generation.');
  return value;
}

int? _positiveInt(Object? value) {
  final number = (value as num?)?.toInt();
  return number != null && number > 0 ? number : null;
}

String _requiredText(Object? value, int maximum) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maximum) {
    throw const FormatException('Missing required document value.');
  }
  return text;
}

String? _optionalText(Object? value, int maximum) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  if (text.length > maximum) {
    throw const FormatException('Document value is too long.');
  }
  return text;
}

int _requiredWireInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw const FormatException('Invalid integer value.');
}

String _requiredScalarText(Object? value, int maximumScalars) {
  if (value is! String || value.contains('\u0000')) {
    throw const FormatException('Invalid text value.');
  }
  final text = value.trim();
  if (text.isEmpty || text.runes.length > maximumScalars) {
    throw const FormatException('Invalid text value.');
  }
  return text;
}

String? _optionalScalarText(Object? value, int maximumScalars) =>
    value == null ? null : _requiredScalarText(value, maximumScalars);

bool _isBoundedScalarText(String value, int maximumScalars) =>
    value.isNotEmpty &&
    !value.contains('\u0000') &&
    value.runes.length <= maximumScalars;

bool _isOptionalBoundedScalarText(String? value, int maximumScalars) =>
    value == null || _isBoundedScalarText(value, maximumScalars);

String _requiredStrictUuid(Object? value) {
  final text = _requiredScalarText(value, 36).toLowerCase();
  if (!_isStrictUuid(text)) throw const FormatException('Invalid UUID.');
  return text;
}

bool _isStrictUuid(String value) =>
    _strictUuid.hasMatch(value) && value != _nilUuid;

List<String> _strictUuidList(Object? raw, {required int maximumItems}) {
  if (raw is! List || raw.length > maximumItems) {
    throw const FormatException('Invalid UUID collection.');
  }
  final values = raw.map(_requiredStrictUuid).toList(growable: false);
  if (values.toSet().length != values.length) {
    throw const FormatException('Duplicate UUID value.');
  }
  return values;
}

List<String> _boundedStringList(
  List<dynamic> values, {
  required int maximumItems,
}) {
  if (values.length > maximumItems) {
    throw const FormatException('Document collection is too large.');
  }
  return values
      .map((value) => _requiredText(value, 2048))
      .toList(growable: false);
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

Map<String, dynamic> _requiredMap(Object? value) {
  if (value is! Map) throw const FormatException('Missing document object.');
  return Map<String, dynamic>.from(value);
}

const _maximumWireUint32 = 0xffffffff;
const _nilUuid = '00000000-0000-0000-0000-000000000000';
final _strictUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
