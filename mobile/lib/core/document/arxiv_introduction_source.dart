import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../api/request_cancellation.dart';
import '../models/arxiv_identifier.dart';
import '../models/introduction.dart';

/// The PDF parser is still the fallback. Never mix different paper versions.
class ArxivIntroductionSource {
  static const sourceRevision = 3;
  ArxivIntroductionSource({Dio? client})
    : _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: false,
            ),
          );
  final Dio _client;
  static const maximumBytes = 8 * 1024 * 1024;

  Future<PaperIntroduction?> load(
    PaperIntroduction original,
    String arxivId,
    RequestCancellation? cancellation,
  ) async {
    final identifier = ArxivIdentifier.tryParse(arxivId);
    // Unversioned URLs can silently serve newer text than the PDF being read.
    if (identifier == null || identifier.version == null) return null;
    final uri = Uri.https('arxiv.org', '/html/${identifier.queryId}');
    try {
      final response = await _client.get<ResponseBody>(
        uri.toString(),
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancellation?.dioToken,
      );
      final body = response.data;
      if (body == null) return null;
      final bytes = <int>[];
      await for (final chunk in body.stream) {
        bytes.addAll(chunk);
        if (bytes.length > maximumBytes) {
          throw const FormatException('arXiv HTML too large');
        }
      }
      if (cancellation?.isCancelled == true) return null;
      return parseArxivIntroduction(utf8.decode(bytes), uri, original);
    } on DioException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void dispose() => _client.close(force: true);
}

PaperIntroduction? parseArxivIntroduction(
  String source,
  Uri uri,
  PaperIntroduction original,
) {
  final document = html.parse(source);
  final article = document.querySelector('article.ltx_document');
  if (article == null) return null;
  dom.Element? introduction;
  for (final section in article.querySelectorAll('section.ltx_section')) {
    final heading = section.children
        .where((e) => RegExp(r'^h[1-6]$').hasMatch(e.localName ?? ''))
        .firstOrNull;
    final label = heading?.text
        .replaceFirst(
          RegExp(r'^\s*(?:\d+(?:\.\d+)*[.)]?\s*|[IVX]+[.)]?\s+)'),
          '',
        )
        .trim()
        .toLowerCase();
    if (label != null && RegExp(r'^introduction(?:\s|$)').hasMatch(label)) {
      introduction = section;
      break;
    }
  }
  if (introduction == null) return null;
  // Remove author notes, hidden accessible duplicates, scripts and navigation.
  for (final node in article.querySelectorAll(
    'script, style, .ltx_note, .ltx_role_refnum, .ltx_tag_note, .ltx_ERROR',
  )) {
    node.remove();
  }
  final blocks = <IntroductionSourceBlock>[];
  final paragraphs = <IntroductionParagraph>[];

  void walk(dom.Element node) {
    final tag = node.localName;
    if (tag == 'figure') {
      final caption = node.querySelector('figcaption');
      final images = node
          .querySelectorAll('img')
          .map((image) => _imageUri(uri, image.attributes['src']))
          .whereType<String>()
          .toList();
      // arXiv sometimes emits a teaser image in an adjacent image-only block,
      // with its caption in an otherwise empty figure (e.g. 2611.26586v1).
      final preceding = node.previousElementSibling;
      if (images.isEmpty &&
          preceding != null &&
          preceding.text.trim().isEmpty &&
          preceding.querySelector('figure') == null) {
        images.addAll(
          preceding
              .querySelectorAll('img')
              .map((image) => _imageUri(uri, image.attributes['src']))
              .whereType<String>(),
        );
      }
      final table = node.querySelector('table:not(.ltx_eqn_table)');
      final svg = node.querySelector('svg');
      final objectUri = _imageUri(
        uri,
        node.querySelector('object')?.attributes['data'],
      );
      final viewBox = svg?.attributes['viewBox']?.split(RegExp(r'\s+'));
      final width =
          double.tryParse(svg?.attributes['width'] ?? '') ??
          (viewBox?.length == 4 ? double.tryParse(viewBox![2]) : null);
      final height =
          double.tryParse(svg?.attributes['height'] ?? '') ??
          (viewBox?.length == 4 ? double.tryParse(viewBox![3]) : null);
      if (table != null) {
        blocks.add(
          IntroductionSourceBlock(
            kind: 'table',
            text: _inline(caption, uri),
            rows: _tableRows(table, uri),
          ),
        );
      } else if (images.isNotEmpty ||
          svg != null ||
          objectUri != null ||
          caption != null) {
        blocks.add(
          IntroductionSourceBlock(
            kind: 'figure',
            text: _inline(caption, uri),
            images: images,
            vectorHtml:
                svg?.outerHtml ??
                (objectUri == null ? null : '<img src="$objectUri">'),
            aspectRatio:
                width != null && height != null && width > 0 && height > 0
                ? (width / height).clamp(.2, 8)
                : 1.6,
          ),
        );
      }
      return;
    }
    if (node.classes.contains('ltx_equation') ||
        node.classes.contains('ltx_eqn_table')) {
      final math = node
          .querySelectorAll('math')
          .map((m) => m.attributes['alttext'] ?? m.text)
          .join(r' \quad ');
      if (math.isNotEmpty) {
        blocks.add(IntroductionSourceBlock(kind: 'equation', text: math));
      }
      return;
    }
    if (tag == 'table') {
      blocks.add(
        IntroductionSourceBlock(
          kind: 'table',
          text: '',
          rows: _tableRows(node, uri),
        ),
      );
      return;
    }
    if (tag == 'p' || tag == 'li') {
      final text = _inline(node, uri).trim();
      if (text.isNotEmpty) {
        blocks.add(
          IntroductionSourceBlock(
            kind: 'paragraph',
            text: tag == 'li' ? '• $text' : text,
          ),
        );
        paragraphs.add(
          IntroductionParagraph(
            ordinal: paragraphs.length,
            text: node.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          ),
        );
      }
      return;
    }
    if (RegExp(r'^h[1-6]$').hasMatch(tag ?? '')) {
      // The screen already displays the Introduction heading.
      if (node.parent != introduction) {
        blocks.add(
          IntroductionSourceBlock(kind: 'heading', text: node.text.trim()),
        );
      }
      return;
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  // Teasers may be wrapped in logical blocks before the abstract/Introduction.
  for (final sibling in introduction.parent!.children) {
    if (sibling == introduction) break;
    if (sibling.localName == 'figure') {
      walk(sibling);
    } else {
      for (final figure in sibling.querySelectorAll('figure')) {
        walk(figure);
      }
    }
  }
  walk(introduction);
  if (paragraphs.fold<int>(0, (n, p) => n + p.text.length) < 200) return null;
  return PaperIntroduction(
    paperId: original.paperId,
    generation: original.generation,
    heading: original.heading,
    // Retain resolved citations and PDF-page locators for navigation. Display
    // uses sourceBlocks, whose order and boundaries come from the author HTML.
    paragraphs: original.paragraphs,
    detectionConfidence: 1,
    originalPdfUrl: original.originalPdfUrl,
    sourceBlocks: blocks,
    sourceUrl: uri.toString(),
    sourceRevision: ArxivIntroductionSource.sourceRevision,
  );
}

String? _imageUri(Uri base, String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = base.resolve(value);
  return uri.scheme == 'https' && uri.host == 'arxiv.org'
      ? uri.toString()
      : null;
}

String _inline(dom.Node? node, Uri base) {
  if (node == null) return '';
  if (node is dom.Text) {
    return node.data
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(RegExp(r'[\\`*\[\]_$#>!|+.\-]'), (m) => '\\${m[0]}');
  }
  if (node is! dom.Element) return '';
  if (node.localName == 'math') {
    return '\$${node.attributes['alttext'] ?? node.text}\$';
  }
  if (node.localName == 'br') return ' ';
  final text = node.nodes.map((child) => _inline(child, base)).join();
  if (node.localName == 'a') {
    final uri = base.resolve(node.attributes['href'] ?? '');
    if (uri.scheme == 'https' && uri.host == 'arxiv.org') {
      return '[$text]($uri)';
    }
  }
  if (node.localName == 'em' || node.localName == 'i') return '*$text*';
  if (node.localName == 'strong' || node.localName == 'b') return '**$text**';
  return text;
}

List<List<String>> _tableRows(dom.Element table, Uri uri) {
  final rows = <List<String>>[];
  final occupied = <int, int>{};
  for (final row in table.querySelectorAll('tr')) {
    if (rows.length >= 200) break;
    final cells = <String>[];
    var column = 0;
    for (final cell in row.children.where(
      (e) => e.localName == 'td' || e.localName == 'th',
    )) {
      while ((occupied[column] ?? 0) > 0) {
        cells.add('');
        column++;
      }
      final colspan = (int.tryParse(cell.attributes['colspan'] ?? '') ?? 1)
          .clamp(1, 30);
      final rowspan = (int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1)
          .clamp(1, 200);
      cells.add(_inline(cell, uri).trim());
      for (var span = 0; span < colspan; span++) {
        if (span > 0) cells.add('');
        occupied[column++] = rowspan;
      }
      if (column >= 30) break;
    }
    rows.add(cells);
    occupied.updateAll((_, remaining) => remaining - 1);
  }
  final columns = rows.fold<int>(
    0,
    (count, row) => row.length > count ? row.length : count,
  );
  return rows
      .map((row) => [...row, ...List.filled(columns - row.length, '')])
      .toList();
}
