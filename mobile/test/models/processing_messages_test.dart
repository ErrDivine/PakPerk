import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/processing.dart';

void main() {
  test('every processing stage has a human-readable message', () {
    for (final stage in ProcessingStage.values) {
      final message = processingStageMessage(stage);
      expect(message.trim(), isNotEmpty, reason: stage.wireValue);
      expect(message, isNot(contains('%')));
    }
  });

  test('capability milestones use the required progressive copy', () {
    expect(
      processingStageMessage(ProcessingStage.parsingPdf),
      'Reading the PDF structure…',
    );
    expect(
      processingStageMessage(ProcessingStage.indexingChat),
      'Introduction ready. Indexing later sections for chat…',
    );
    expect(
      processingStageMessage(ProcessingStage.resolvingReferences),
      'Introduction and chat ready. Resolving references…',
    );
  });
}
