import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/features/research/research_controller.dart';

void main() {
  test('selector offsets and context use Unicode scalar positions', () {
    final selector = selectorForBlock(_block('α🙂 方法 works'), '方法');

    expect(selector.start, 3);
    expect(selector.end, 5);
    expect(selector.prefix, 'α🙂 ');
    expect(selector.suffix, ' works');
  });

  test('repeated quote never guesses the first selected occurrence', () {
    final selector = selectorForBlock(
      _block('same quote, then same quote'),
      'same quote',
    );

    expect(selector.exact, 'same quote');
    expect(selector.start, isNull);
    expect(selector.end, isNull);
    expect(selector.prefix, isNull);
    expect(selector.suffix, isNull);
  });

  test('selector omits empty boundary context', () {
    final selector = selectorForBlock(_block('whole block'), 'whole block');

    expect(selector.start, 0);
    expect(selector.end, 11);
    expect(selector.prefix, isNull);
    expect(selector.suffix, isNull);
  });
}

DocumentBlock _block(String text) => DocumentBlock(
  id: '00000000-0000-4000-8000-000000000002',
  paperId: '00000000-0000-4000-8000-000000000001',
  generation: 2,
  stableKey: 'methods:p0',
  ordinal: 0,
  sectionPath: const ['Methods'],
  kind: DocumentBlockKind.paragraph,
  text: text,
  contentHash: 'hash',
);
