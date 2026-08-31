import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_action_failure.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/features/library/library_destination.dart';
import 'package:pakperk/features/library/library_workspace_models.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'queue-owned alert stays usable at narrow large text without private data',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PaperSummary? reviewed;
      LibraryActionFailure? dismissed;
      final failure = LibraryActionFailure(
        operationId: _operationA,
        kind: LibraryActionFailureKind.paperAdd,
        action: LibraryActionFailureAction.reviewPaper,
        occurredAt: DateTime.utc(2026, 8, 28),
        paper: samplePaper,
      );

      await _pump(
        tester,
        failure: failure,
        textScaler: const TextScaler.linear(2),
        onOpenPaper: (paper) => reviewed = paper,
        onDismiss: (value) => dismissed = value,
      );

      expect(find.text('2 active To Read'), findsOneWidget);
      expect(find.text('A Library change wasn’t saved'), findsOneWidget);
      expect(find.text(samplePaper.title), findsOneWidget);
      expect(find.text(_operationA), findsNothing);
      expect(find.text('account-a'), findsNothing);
      expect(find.text('PRIVATE_UPSTREAM_DETAIL'), findsNothing);
      expect(find.text('do not expose this note'), findsNothing);
      expect(tester.takeException(), isNull);

      final review = find.byKey(
        ValueKey(('library-action-failure-review', failure)),
      );
      final dismiss = find.byKey(
        ValueKey(('library-action-failure-dismiss', failure)),
      );
      expect(tester.getSize(review).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(dismiss).height, greaterThanOrEqualTo(48));
      expect(tester.getSemantics(dismiss).label, contains('Dismiss'));

      await tester.ensureVisible(review);
      await tester.pump();
      await tester.tap(review);
      expect(reviewed, samplePaper);
      await tester.ensureVisible(dismiss);
      await tester.pump();
      await tester.tap(dismiss);
      expect(dismissed, failure);
    },
  );

  testWidgets('collection and sign-in notices route to explicit actions', (
    tester,
  ) async {
    final collectionFailure = LibraryActionFailure(
      operationId: _operationA,
      kind: LibraryActionFailureKind.collectionsEdit,
      action: LibraryActionFailureAction.reviewCollections,
      occurredAt: DateTime.utc(2026, 8, 28),
    );
    await _pump(tester, failure: collectionFailure, libraryV2Enabled: true);

    final collectionReview = find.byKey(
      ValueKey(('library-action-failure-review', collectionFailure)),
    );
    await tester.ensureVisible(collectionReview);
    await tester.tap(collectionReview);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('library-collections-view')),
      findsOneWidget,
    );

    var signInCalls = 0;
    final signInFailure = LibraryActionFailure(
      operationId: _operationB,
      kind: LibraryActionFailureKind.paperEdit,
      action: LibraryActionFailureAction.signIn,
      occurredAt: DateTime.utc(2026, 8, 28),
    );
    await _pump(
      tester,
      failure: signInFailure,
      onSignIn: () => signInCalls += 1,
    );
    expect(
      find.text('Sign in again, then review the change you wanted to make.'),
      findsOneWidget,
    );
    final signIn = find.byKey(
      ValueKey(('library-action-failure-review', signInFailure)),
    );
    await tester.ensureVisible(signIn);
    await tester.tap(signIn);
    expect(signInCalls, 1);
  });

  testWidgets('disabled v2 collection review stays in the visible Library', (
    tester,
  ) async {
    final failure = LibraryActionFailure(
      operationId: _operationA,
      kind: LibraryActionFailureKind.collectionsEdit,
      action: LibraryActionFailureAction.reviewCollections,
      occurredAt: DateTime.utc(2026, 8, 28),
    );
    await _pump(tester, failure: failure);

    await tester.tap(
      find.byKey(ValueKey(('library-action-failure-review', failure))),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('library-collections-view')),
      findsNothing,
    );
    expect(find.text('Review Library'), findsOneWidget);
    expect(
      find.text(
        'This lists-and-tags change wasn’t saved. Review your Library before '
        'trying again.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('last confirmed lists and tags were restored'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('library-state-inbox')), findsOneWidget);
  });

  testWidgets('paper edit review opens the retained item editor', (
    tester,
  ) async {
    final item = LibraryListItem(
      paper: samplePaper,
      savedAt: DateTime.utc(2026, 8, 20),
      savedState: const LibrarySavedState(saved: true, syncPending: false),
    );
    final failure = LibraryActionFailure(
      operationId: _operationA,
      kind: LibraryActionFailureKind.paperEdit,
      action: LibraryActionFailureAction.reviewItem,
      occurredAt: DateTime.utc(2026, 8, 28),
      paper: samplePaper,
    );
    await _pump(
      tester,
      failure: failure,
      items: [item],
      libraryV2Enabled: true,
      editorCapabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, __, ___) async {},
    );

    expect(
      find.text(
        'This paper change wasn’t saved. Review the paper in your Library '
        'before trying again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('confirmed paper details'), findsNothing);

    await tester.tap(
      find.byKey(ValueKey(('library-action-failure-review', failure))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-editor-note')), findsOneWidget);
  });

  testWidgets('missing retained item falls back to safe paper navigation', (
    tester,
  ) async {
    PaperSummary? opened;
    final failure = LibraryActionFailure(
      operationId: _operationB,
      kind: LibraryActionFailureKind.paperEdit,
      action: LibraryActionFailureAction.reviewItem,
      occurredAt: DateTime.utc(2026, 8, 28),
      paper: samplePaper,
    );
    await _pump(
      tester,
      failure: failure,
      libraryV2Enabled: true,
      onOpenPaper: (paper) => opened = paper,
    );

    await tester.tap(
      find.byKey(ValueKey(('library-action-failure-review', failure))),
    );

    expect(opened, samplePaper);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required LibraryActionFailure failure,
  TextScaler textScaler = TextScaler.noScaling,
  bool libraryV2Enabled = false,
  List<LibraryListItem> items = const [],
  LibraryEditorCapabilities editorCapabilities =
      const LibraryEditorCapabilities.none(),
  LibraryItemEditCallback? onEdit,
  ValueChanged<PaperSummary>? onOpenPaper,
  ValueChanged<LibraryActionFailure>? onDismiss,
  VoidCallback? onSignIn,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: LibraryDestinationView(
            items: items,
            authority: const LibraryWorkspaceAuthority(
              activeItemCount: 2,
              pendingSaveCount: 0,
              pendingRemoveCount: 0,
              checkpoint: LibrarySyncCheckpoint(
                initialized: true,
                lastRevision: 12,
              ),
            ),
            offline: true,
            actionFailures: [failure],
            onOpenPaper: (_) {},
            onOpenActionFailurePaper: onOpenPaper,
            onDismissActionFailure: onDismiss,
            onSignIn: onSignIn,
            editorCapabilities: editorCapabilities,
            onEdit: onEdit,
            libraryV2Enabled: libraryV2Enabled,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _operationA = '00000000-0000-4000-8000-000000000001';
const _operationB = '00000000-0000-4000-8000-000000000002';
