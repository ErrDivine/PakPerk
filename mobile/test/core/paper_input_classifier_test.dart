import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/paper_resolution/paper_input_classifier.dart';

void main() {
  const classifier = PaperInputClassifier();

  group('PaperInputClassifier', () {
    test('accepts bare modern, prefixed, and legacy arXiv identifiers', () {
      final modern = classifier.classify('2401.12345v2');
      expect(modern.kind, PaperInputKind.arxivId);
      expect(modern.normalizedValue, '2401.12345v2');

      final prefixed = classifier.classify(' arXiv:2401.12345 ');
      expect(prefixed.kind, PaperInputKind.arxivId);
      expect(prefixed.normalizedValue, '2401.12345');

      final legacy = classifier.classify('hep-th/9901001v3');
      expect(legacy.kind, PaperInputKind.arxivId);
      expect(legacy.normalizedValue, 'hep-th/9901001v3');
    });

    test('accepts only canonical HTTPS arXiv abstract and PDF URLs', () {
      for (final input in <String>[
        'https://arxiv.org/abs/2401.12345v2',
        'https://arxiv.org/pdf/2401.12345v2',
        'https://arxiv.org/pdf/2401.12345v2.pdf',
        'https://arxiv.org/abs/hep-th/9901001v3',
      ]) {
        final result = classifier.classify(input);
        expect(result.kind, PaperInputKind.arxivUrl, reason: input);
        expect(result.isExact, isTrue, reason: input);
      }
    });

    test('rejects deceptive or unsupported URL-shaped input', () {
      for (final input in <String>[
        'http://arxiv.org/abs/2401.12345',
        'https://www.arxiv.org/abs/2401.12345',
        'https://export.arxiv.org/abs/2401.12345',
        'https://arxiv.org.evil.example/abs/2401.12345',
        'https://user@arxiv.org/abs/2401.12345',
        'https://arxiv.org:8443/abs/2401.12345',
        'https://arxiv.org/abs/2401.12345?download=1',
        'https://arxiv.org/abs/2401.12345#page=2',
        'https://arxiv.org/abs/2401%2e12345',
        'https://example.com/paper.pdf',
        'arxiv.org/abs/2401.12345',
      ]) {
        expect(
          () => classifier.classify(input),
          throwsA(
            isA<PaperInputException>().having(
              (error) => error.reason,
              'reason',
              PaperInputError.unsupportedUrl,
            ),
          ),
          reason: input,
        );
      }
    });

    test('normalizes a bounded title without treating it as an identifier', () {
      final result = classifier.classify('  Attention\n  Is\tAll You Need  ');

      expect(result.kind, PaperInputKind.title);
      expect(result.normalizedValue, 'Attention Is All You Need');
      expect(result.identifier, isNull);
    });

    test('rejects empty, short, overlong, control, and malformed ID input', () {
      expect(
        () => classifier.classify('  '),
        throwsA(
          isA<PaperInputException>().having(
            (error) => error.reason,
            'reason',
            PaperInputError.empty,
          ),
        ),
      );
      expect(
        () => classifier.classify('AI'),
        throwsA(
          isA<PaperInputException>().having(
            (error) => error.reason,
            'reason',
            PaperInputError.invalidTitle,
          ),
        ),
      );
      expect(
        () => classifier.classify('x' * 301),
        throwsA(isA<PaperInputException>()),
      );
      expect(
        () => classifier.classify('safe\u0000title'),
        throwsA(isA<PaperInputException>()),
      );
      expect(
        () => classifier.classify('arXiv:2401.12345v0'),
        throwsA(
          isA<PaperInputException>().having(
            (error) => error.reason,
            'reason',
            PaperInputError.invalidIdentifier,
          ),
        ),
      );
    });
  });
}
