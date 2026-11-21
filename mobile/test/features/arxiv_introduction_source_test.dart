import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/document/arxiv_introduction_source.dart';

const original = PaperIntroduction(
  paperId: 'paper',
  generation: 3,
  heading: 'Introduction',
  paragraphs: [],
  detectionConfidence: .9,
  originalPdfUrl: 'https://arxiv.org/pdf/1909.04849v1',
);

void main() {
  test(
    'keeps paragraphs, captions, figures and tables separate and stops at next section',
    () {
      final source = '''<article class="ltx_document">
    <div><img src="x1.png"></div><figure><figcaption>Figure 1: Teaser</figcaption></figure>
    <section class="ltx_section" id="S1"><h2>1 Introduction</h2>
    <div class="ltx_para"><p>It is natural to model such ambiguities with a latent variable during learning, but most prior work focuses on model architecture. This sentence must stay intact.</p></div>
    <figure><img src="x2.png"><figcaption>Figure 2: Caption only.</figcaption></figure>
    <p>Here we study <math alttext="x^2"><semantics><msup><mi>x</mi><mn>2</mn></msup><annotation>x^2</annotation></semantics></math> and preserve symbols and Unicode: 中文 α. The paragraph after the figure continues separately without losing text.</p>
    <figure class="ltx_table"><figcaption>Table 1: Results</figcaption><table>
    <tr><th rowspan="2">Model</th><th colspan="2">Score</th></tr>
    <tr><th>A</th><th>B</th></tr><tr><td>M1</td><td>9</td><td>8</td></tr></table></figure>
    <span class="ltx_note">A distracting footnote.</span>
    </section><section class="ltx_section"><h2>2 Related Work</h2><p>Not introduction.</p></section></article>''';
      final result = parseArxivIntroduction(
        source,
        Uri.parse('https://arxiv.org/html/1909.04849v1'),
        original,
      )!;
      expect(result.sourceBlocks.map((b) => b.kind), [
        'figure',
        'paragraph',
        'figure',
        'paragraph',
        'table',
      ]);
      final text = result.sourceBlocks
          .where((b) => b.kind == 'paragraph')
          .map((b) => b.text)
          .join('\n');
      expect(text, contains('natural to model such ambiguities'));
      expect(text, isNot(contains('Caption only')));
      expect(text, isNot(contains('Related Work')));
      expect(text, isNot(contains('distracting footnote')));
      expect(text, contains(r'$x^2$'));
      expect(
        result.sourceBlocks.first.images.single,
        'https://arxiv.org/html/x1.png',
      );
      expect(result.sourceBlocks.last.rows, [
        ['Model', 'Score', ''],
        ['', 'A', 'B'],
        ['M1', '9', '8'],
      ]);
      final restored = PaperIntroduction.fromJson(
        jsonDecode(jsonEncode(result.toJson())),
      );
      expect(restored.sourceBlocks.last.rows, result.sourceBlocks.last.rows);
      expect(restored.sourceUrl, result.sourceUrl);
    },
  );

  test('rejects missing/insubstantial introduction and unsafe image URLs', () {
    expect(
      parseArxivIntroduction(
        '<article></article>',
        Uri.parse('https://arxiv.org/html/1909.04849v1'),
        original,
      ),
      isNull,
    );
    final text = 'A valid substantial opening paragraph. ' * 10;
    final result = parseArxivIntroduction(
      '<article class="ltx_document"><section class="ltx_section"><h2>Introduction</h2><p>$text</p><figure><img src="https://evil.invalid/a.png"><figcaption>caption</figcaption></figure></section></article>',
      Uri.parse('https://arxiv.org/html/1909.04849v1'),
      original,
    )!;
    expect(result.sourceBlocks.any((b) => b.images.isNotEmpty), isFalse);
  });

  // Opt-in real arXiv regression: downloaded sources live outside tracked assets.
  const realSources = String.fromEnvironment('PDF_REGRESSION_DIR');
  if (realSources.isNotEmpty) {
    test(
      'real PDF corpus: original failure plus three recent difficult papers',
      () {
        final report = <String, Object?>{};
        for (final id in [
          '1909.04849',
          '2611.26586',
          '2611.26538',
          '2611.26450',
        ]) {
          final source = File('$realSources/$id.html').readAsStringSync();
          final result = parseArxivIntroduction(
            source,
            Uri.parse('https://arxiv.org/html/${id}v1'),
            original,
          );
          expect(result, isNotNull, reason: id);
          final blocks = result!.sourceBlocks;
          final paragraphs = blocks
              .where((b) => b.kind == 'paragraph')
              .toList();
          final text = paragraphs.map((b) => b.text).join('\n');
          expect(text.length, greaterThan(500), reason: id);
          expect(text, isNot(contains('2 Related Work')), reason: id);
          for (final block in blocks.where((b) => b.rows.isNotEmpty)) {
            expect(
              block.rows.map((r) => r.length).toSet().length,
              1,
              reason: '$id table columns',
            );
          }
          if (id == '1909.04849') {
            expect(text, contains('natural to model such ambiguities'));
            expect(text, contains('a span in the document'));
            expect(
              text,
              isNot(contains('The answer text is mentioned five times')),
            );
            expect(blocks.any((b) => b.kind == 'figure'), isTrue);
            expect(blocks.any((b) => b.kind == 'table'), isTrue);
          }
          if (id == '2611.26586') {
            expect(
              blocks.where((b) => b.kind == 'figure').first.images,
              isNotEmpty,
              reason: 'Image and caption are adjacent siblings in arXiv HTML',
            );
          }
          if (id == '2611.26538') {
            expect(
              blocks.where((b) => b.kind == 'figure').first.vectorHtml,
              contains('<svg'),
            );
          }
          report[id] = {
            'paragraphs': paragraphs.length,
            'figures': blocks.where((b) => b.kind == 'figure').length,
            'tables': blocks.where((b) => b.kind == 'table').length,
            'equations': blocks.where((b) => b.kind == 'equation').length,
            'characters': text.length,
            'source': result.sourceUrl,
          };
        }
        File(
          '$realSources/results.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      },
    );
  }
}
