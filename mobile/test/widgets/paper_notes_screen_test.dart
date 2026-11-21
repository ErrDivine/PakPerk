import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/features/paper_notes/paper_notes_screen.dart';
import 'package:pakperk/features/paper_notes/paper_notes_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/fakes.dart';

void main() {
  testWidgets('pages survive reopening; Clear affects only the current page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPreferencesPaperNotesStore(
      accountId: 'a',
      paper: samplePaper,
    );
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: PaperNotesScreen(paper: samplePaper, store: store),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    await tester.enterText(
      find.byKey(const ValueKey('paper-notes-editor')),
      'First page',
    );
    await tester.tap(find.byKey(const ValueKey('paper-notes-new-page')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('paper-notes-editor')),
      'Second page',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect((await store.read(samplePaper.arxivBaseId)).pages, [
      'First page',
      'Second page',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await open();
    expect(find.text('First page'), findsOneWidget);
    await tester.tap(find.text('Page 2'));
    await tester.pumpAndSettle();
    expect(find.text('Second page'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paper-notes-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect((await store.read(samplePaper.arxivBaseId)).pages, [
      'First page',
      '',
    ]);
    expect((await store.list()).single.paper.title, samplePaper.title);
  });
  test(
    'account notebooks stay separate and legacy guest notes are preserved',
    () async {
      SharedPreferences.setMockInitialValues({
        'paper_notes_v1:${Uri.encodeComponent(samplePaper.arxivBaseId)}':
            '{"body":"Old note"}',
      });
      const guest = SharedPreferencesPaperNotesStore();
      final a = SharedPreferencesPaperNotesStore(
        accountId: 'a',
        paper: samplePaper,
      );
      const b = SharedPreferencesPaperNotesStore(accountId: 'b');
      expect((await guest.read(samplePaper.arxivBaseId)).pages, ['Old note']);
      expect((await a.read(samplePaper.arxivBaseId)).isEmpty, isTrue);
      await a.write(
        samplePaper.arxivBaseId,
        const PaperNotes(pages: ['A private page', 'Another page']),
      );
      expect((await a.list()).length, 1);
      expect(await b.list(), isEmpty);
      expect((await b.read(samplePaper.arxivBaseId)).isEmpty, isTrue);
    },
  );
}
