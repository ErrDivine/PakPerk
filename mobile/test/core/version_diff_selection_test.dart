import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/version_diff.dart';

void main() {
  test('latest comparison is old-to-new regardless of response order', () {
    final v1 = _version(generation: 1, arxivVersion: 1, current: false);
    final v2 = _version(generation: 2, arxivVersion: 2, current: false);
    final v3 = _version(generation: 3, arxivVersion: 3, current: true);

    for (final versions in [
      [v3, v2, v1],
      [v1, v3, v2],
      [v2, v1, v3],
    ]) {
      final pair = latestDocumentVersionComparison(versions);
      expect(pair?.from.generation, 2);
      expect(pair?.to.generation, 3);
    }
  });

  test('comparison is unavailable until two generations are retained', () {
    expect(latestDocumentVersionComparison(const []), isNull);
    expect(
      latestDocumentVersionComparison([
        _version(generation: 1, arxivVersion: 1, current: true),
      ]),
      isNull,
    );
  });
}

DocumentVersion _version({
  required int generation,
  required int arxivVersion,
  required bool current,
}) => DocumentVersion(
  generation: generation,
  arxivVersion: arxivVersion,
  arxivId: '2401.00001v$arxivVersion',
  sourceAbsUrl: Uri.parse('https://arxiv.org/abs/2401.00001v$arxivVersion'),
  sourcePdfUrl: Uri.parse('https://arxiv.org/pdf/2401.00001v$arxivVersion'),
  schemaVersion: 'document-v1',
  parserId: 'grobid',
  parserVersion: '0.8.2',
  documentHash: 'sha256:$generation',
  isCurrent: current,
  generatedAt: DateTime.utc(2026, 8, generation),
);
