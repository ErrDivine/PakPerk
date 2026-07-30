import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';

void main() {
  test('preparation fires only for the first committed Introduction page', () {
    final gate = PrepareIntentGate();

    expect(gate.onCommittedPage(PaperStage.abstractView.index), isFalse);
    expect(gate.onCommittedPage(PaperStage.connections.index), isFalse);
    expect(gate.onCommittedPage(PaperStage.introduction.index), isTrue);
    expect(gate.onCommittedPage(PaperStage.introduction.index), isFalse);
    expect(gate.requested, isTrue);
  });

  test('restored preparation intent never fires again', () {
    final gate = PrepareIntentGate(alreadyRequested: true);
    expect(gate.onCommittedPage(PaperStage.introduction.index), isFalse);
  });
}
