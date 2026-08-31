import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/document/mathml_latex_adapter.dart';

void main() {
  test('converts bounded Presentation MathML without replacing its source', () {
    const source =
        '<math alttext="x equals a squared over b">'
        '<mrow><mi>x</mi><mo>=</mo><mfrac>'
        '<msup><mi>a</mi><mn>2</mn></msup><mi>b</mi>'
        '</mfrac></mrow></math>';

    final result = renderableMathMl(source);

    expect(result, isNotNull);
    expect(result!.latex, r'x=\frac{{a}^{2}}{b}');
    expect(result.altText, 'x equals a squared over b');
    expect(source, contains('<mfrac>'));
  });

  test('ignores inert semantic annotations and supports a matrix', () {
    const source =
        '<math><semantics><mtable>'
        '<mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr>'
        '<mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr>'
        '</mtable><annotation encoding="text/plain">'
        '&lt;script&gt;never executable&lt;/script&gt;'
        '</annotation></semantics></math>';

    expect(
      renderableMathMl(source)?.latex,
      r'\begin{matrix}a & b \\ c & d\end{matrix}',
    );
  });

  test('does not expose unsafe accessibility control characters', () {
    const source = '<math alttext="safe&#x202E;spoof"><mi>x</mi></math>';

    final result = renderableMathMl(source);

    expect(result?.latex, 'x');
    expect(result?.altText, isNull);
  });

  test('rejects executable, external, malformed, and ambiguous markup', () {
    for (final source in [
      '<math><script>run()</script></math>',
      '<math><mi href="https://example.com">x</mi></math>',
      '<!DOCTYPE math [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
          '<math><mi>&x;</mi></math>',
      '<math><mi><![CDATA[x]]></mi></math>',
      '<math><mfrac><mi>x</mi></mfrac></math>',
      '<math><mmultiscripts><mi>x</mi><mi>i</mi></mmultiscripts></math>',
      '<math><merror><mi>x</mi></merror></math>',
      '<math><mi>x</math>',
    ]) {
      expect(renderableMathMl(source), isNull, reason: source);
    }
  });

  test('rejects excessive depth, node count, and bytes', () {
    final deep =
        '<math>${List.filled(65, '<mrow>').join()}<mi>x</mi>'
        '${List.filled(65, '</mrow>').join()}</math>';
    final many = '<math>${List.filled(4097, '<mi>x</mi>').join()}</math>';
    final large =
        '<math><mtext>${List.filled(256 * 1024, 'x').join()}</mtext></math>';

    expect(renderableMathMl(deep), isNull);
    expect(renderableMathMl(many), isNull);
    expect(renderableMathMl(large), isNull);
  });
}
