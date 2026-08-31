import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_history_store.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_v2_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/features/library/library_collections_view.dart';
import 'package:pakperk/features/library/library_destination.dart';
import 'package:pakperk/features/library/library_history_controller.dart';
import 'package:pakperk/features/library/library_workspace_models.dart';

void main() {
  test('library state compatibility maps legacy To Read to Inbox', () {
    expect(LibraryItemState.tryFromStorage('to_read'), LibraryItemState.inbox);
    expect(LibraryItemState.values.where((state) => state.isActive), [
      LibraryItemState.inbox,
      LibraryItemState.readNext,
      LibraryItemState.reading,
    ]);
    expect(LibraryItemState.reviewed.isActive, isFalse);
    expect(LibraryItemState.archived.isActive, isFalse);
  });

  test('pending final removal keeps queue authority unresolved', () {
    final authority = LibraryWorkspaceAuthority.from(
      items: [_item(1, state: LibraryItemState.reviewed)],
      pendingIntents: const LibraryPendingIntentCounts(saves: 0, removes: 1),
      checkpoint: const LibrarySyncCheckpoint(
        initialized: true,
        lastRevision: 9,
      ),
    );

    expect(authority.activeItemCount, 0);
    expect(authority.finishingQueue, isTrue);
    expect(authority.queueBlocksDiscovery, isTrue);
    expect(authority.authorityComplete, isFalse);
  });

  testWidgets('shows five states, provenance, and Library add-paper entry', (
    tester,
  ) async {
    var addCalls = 0;
    await _pump(
      tester,
      items: [
        _item(1, state: LibraryItemState.inbox),
        _item(2, state: LibraryItemState.reviewed),
      ],
      canAddPaper: true,
      onAddPaper: () => addCalls += 1,
    );

    for (final state in LibraryItemState.values) {
      expect(
        find.byKey(ValueKey('library-state-${state.storageValue}')),
        findsOneWidget,
      );
    }
    expect(find.text('Added by title search'), findsOneWidget);
    expect(find.text('2 active To Read'), findsNothing);
    expect(find.text('1 active To Read'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-add-paper')));
    expect(addCalls, 1);

    await tester.tap(find.byKey(const ValueKey('library-state-reviewed')));
    await tester.pumpAndSettle();
    expect(find.text('Library paper 2'), findsOneWidget);
    expect(find.text('Library paper 1'), findsNothing);
  });

  testWidgets('editor returns state note list tag and bound revision', (
    tester,
  ) async {
    final item = _item(
      1,
      state: LibraryItemState.inbox,
      reminderAt: DateTime.now().toUtc().add(const Duration(days: 2)),
    );
    LibraryItemEditDraft? recorded;
    int? recordedRevision;
    await _pump(
      tester,
      items: [item],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, draft, revision) async {
        recorded = draft;
        recordedRevision = revision;
      },
    );

    await tester.tap(
      find.byKey(ValueKey('library-edit-${item.paper.paperId}')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-editor-state')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reviewed').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('library-editor-note')),
      'Compare the evaluation setup',
    );
    await tester.enterText(
      find.byKey(const ValueKey('library-editor-lists')),
      'Journal club, Methods',
    );
    await tester.enterText(
      find.byKey(const ValueKey('library-editor-tags')),
      'evaluation, transformers',
    );
    final save = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(recorded?.state, LibraryItemState.reviewed);
    expect(recorded?.privateNote, 'Compare the evaluation setup');
    expect(recorded?.listNames, ['Journal club', 'Methods']);
    expect(recorded?.tagNames, ['evaluation', 'transformers']);
    expect(recorded?.reminderAt, isNull);
    expect(recordedRevision, 12);
    expect(find.byKey(const ValueKey('library-editor-save')), findsNothing);
  });

  testWidgets('editor sets and explicitly clears a UTC reminder', (
    tester,
  ) async {
    LibraryItemEditDraft? recorded;
    final item = _item(1);
    await _pump(
      tester,
      items: [item],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, draft, __) async => recorded = draft,
    );
    await tester.tap(
      find.byKey(ValueKey('library-edit-${item.paper.paperId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-editor-reminder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(recorded?.reminderAt, isNotNull);
    expect(recorded!.reminderAt!.isUtc, isTrue);
    expect(recorded!.reminderAt!.isAfter(DateTime.now().toUtc()), isTrue);

    recorded = null;
    final selected = _item(
      2,
      reminderAt: DateTime.now().toUtc().add(const Duration(days: 2)),
    );
    await _pump(
      tester,
      items: [selected],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, draft, __) async => recorded = draft,
    );
    await tester.tap(
      find.byKey(ValueKey('library-edit-${selected.paper.paperId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('library-editor-clear-reminder')),
    );
    await tester.pump();
    final clearSave = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(clearSave);
    await tester.tap(clearSave);
    await tester.pumpAndSettle();
    expect(recorded?.reminderAt, isNull);
  });

  testWidgets('editor exposes immediate retry after a queueing failure', (
    tester,
  ) async {
    var attempts = 0;
    await _pump(
      tester,
      items: [_item(1)],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, __, ___) async {
        attempts += 1;
        if (attempts == 1) throw StateError('offline');
      },
    );

    await tester.tap(
      find.byKey(ValueKey('library-edit-${_item(1).paper.paperId}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('library-editor-note')),
      'Retry this note',
    );
    final save = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      find.text('Changes were not queued on this device. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    final retry = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(retry);
    await tester.pump();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Organize paper'), findsNothing);
  });

  testWidgets(
    'notification rollback preserves visibility and clear without new setting',
    (tester) async {
      LibraryItemEditDraft? recorded;
      final stored = _item(
        1,
        reminderAt: DateTime.now().toUtc().add(const Duration(days: 2)),
      );
      await _pump(
        tester,
        items: [stored],
        capabilities: const LibraryEditorCapabilities.all(reminders: false),
        onEdit: (_, draft, __) async => recorded = draft,
      );
      await tester.tap(
        find.byKey(ValueKey('library-edit-${stored.paper.paperId}')),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Notifications are unavailable in this build. You can still clear this reminder.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('library-editor-clear-reminder')),
      );
      final save = find.byKey(const ValueKey('library-editor-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(recorded?.reminderAt, isNull);

      recorded = null;
      final withoutReminder = _item(2);
      await _pump(
        tester,
        items: [withoutReminder],
        capabilities: const LibraryEditorCapabilities.all(reminders: false),
        onEdit: (_, draft, __) async => recorded = draft,
      );
      await tester.tap(
        find.byKey(ValueKey('library-edit-${withoutReminder.paper.paperId}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Turn on in-app notifications to set a reminder.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('library-editor-reminder')));
      await tester.pump();
      expect(find.text('Choose reminder date'), findsNothing);
      expect(recorded, isNull);
    },
  );

  testWidgets('editing after a due reminder clears it on the explicit save', (
    tester,
  ) async {
    LibraryItemEditDraft? recorded;
    final item = _item(
      1,
      privateNote: 'Original note',
      reminderAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );
    await _pump(
      tester,
      items: [item],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, draft, __) async => recorded = draft,
    );
    await tester.tap(
      find.byKey(ValueKey('library-edit-${item.paper.paperId}')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('saving clears it'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('library-editor-note')),
      'Updated note',
    );
    final save = find.byKey(const ValueKey('library-editor-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(recorded?.privateNote, 'Updated note');
    expect(recorded?.reminderAt, isNull);
  });

  testWidgets('account epoch change closes and clears an open private editor', (
    tester,
  ) async {
    const scopeA = LibraryEditorScope(accountId: 'account-a', authEpoch: 4);
    const scopeB = LibraryEditorScope(accountId: 'account-b', authEpoch: 5);
    final scope = ValueNotifier<LibraryEditorScope?>(scopeA);
    addTearDown(scope.dispose);
    final item = _item(
      1,
      privateNote: 'Account A private note',
      reminderAt: DateTime.now().toUtc().add(const Duration(days: 2)),
    );
    await _pump(
      tester,
      items: [item],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, __, ___) async {},
      accountScopeListenable: scope,
      expectedAccountScope: scopeA,
    );

    await tester.tap(
      find.byKey(ValueKey('library-edit-${item.paper.paperId}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Account A private note'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-editor-clear-reminder')),
      findsOneWidget,
    );

    scope.value = scopeB;
    await tester.pump();
    await tester.pump();

    expect(find.text('Account A private note'), findsNothing);
    expect(find.text('Organize paper'), findsNothing);
  });

  testWidgets('narrow 200 percent text and reduced motion remain usable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      items: [_item(1, state: LibraryItemState.inbox)],
      capabilities: const LibraryEditorCapabilities.all(),
      onEdit: (_, __, ___) async {},
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedSwitcher && widget.duration == Duration.zero,
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('library-state-inbox'))).height,
      greaterThanOrEqualTo(48),
    );

    final editButton = find.byKey(
      ValueKey('library-edit-${_item(1).paper.paperId}'),
    );
    await tester.scrollUntilVisible(
      editButton,
      220,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    await tester.tap(editButton);
    await tester.pump();
    expect(find.text('Organize paper'), findsOneWidget);
    final reminder = find.byKey(const ValueKey('library-editor-reminder'));
    await tester.scrollUntilVisible(
      reminder,
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.getSize(reminder).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v2 History and private collection management are explicit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    PaperSummary? openedHistoryPaper;
    String? newListName;
    List<String>? reorderedIds;
    const lists = [
      LibraryV2LocalList(
        id: '10000000-0000-4000-8000-000000000001',
        name: 'Methods',
        description: 'Compare evaluation designs',
        sortOrder: 0,
        syncPending: false,
      ),
      LibraryV2LocalList(
        id: '10000000-0000-4000-8000-000000000002',
        name: 'Journal club',
        description: null,
        sortOrder: 1000,
        syncPending: true,
      ),
    ];
    const tags = [
      LibraryV2LocalTag(
        id: '20000000-0000-4000-8000-000000000001',
        name: 'Evaluation',
        syncPending: false,
      ),
    ];
    await _pump(
      tester,
      items: [_item(1)],
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
      libraryV2Enabled: true,
      lists: lists,
      tags: tags,
      history: LibraryHistoryState(
        enabled: true,
        loading: false,
        entries: [
          LibraryHistoryEntry(
            paper: _item(2).paper,
            openedAt: DateTime.utc(2026, 8, 19, 10),
          ),
        ],
      ),
      onOpenHistoryPaper: (paper) => openedHistoryPaper = paper,
      onSaveList: (_, name, __, ___) async => newListName = name,
      onDeleteList: (_) async {},
      onReorderLists: (ids) async => reorderedIds = ids,
      onSaveTag: (_, __) async {},
      onDeleteTag: (_) async {},
    );

    expect(find.byKey(const ValueKey('library-view-history')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('library-view-history'))).height,
      greaterThanOrEqualTo(48),
    );
    final history = find.byKey(const ValueKey('library-view-history'));
    final verticalLibraryScroll = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    await tester.drag(verticalLibraryScroll, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(history);
    await tester.pump();
    expect(find.text('Keep private paper history'), findsOneWidget);
    final historyPaper = find.byKey(
      ValueKey('library-history-paper-${_item(2).paper.paperId}'),
    );
    await _revealInLibrary(tester, verticalLibraryScroll, historyPaper);
    await tester.tap(historyPaper);
    expect(openedHistoryPaper?.paperId, _item(2).paper.paperId);

    final collections = find.byKey(const ValueKey('library-view-collections'));
    await tester.dragUntilVisible(
      collections,
      verticalLibraryScroll,
      const Offset(0, 400),
    );
    await _revealInLibrary(tester, verticalLibraryScroll, collections);
    await tester.tap(collections);
    await tester.pump();
    expect(find.text('Private organization'), findsOneWidget);
    expect(find.text('Journal club'), findsOneWidget);
    final tag = find.byKey(
      const ValueKey('library-tag-20000000-0000-4000-8000-000000000001'),
    );
    await _revealInLibrary(tester, verticalLibraryScroll, tag);
    expect(tester.getSize(tag).height, greaterThanOrEqualTo(48));

    final moveDown = find.byKey(
      const ValueKey('library-list-down-10000000-0000-4000-8000-000000000001'),
    );
    await _revealInLibrary(tester, verticalLibraryScroll, moveDown);
    await tester.tap(moveDown);
    await tester.pump();
    expect(reorderedIds, [lists[1].id, lists[0].id]);

    final addList = find.byKey(const ValueKey('library-list-add'));
    await _revealInLibrary(tester, verticalLibraryScroll, addList);
    await tester.tap(addList);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('library-list-name-input')),
      'Replication',
    );
    await tester.tap(find.text('Save list'));
    await tester.pumpAndSettle();
    expect(newListName, 'Replication');
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switch closes private collection editor before save', (
    tester,
  ) async {
    const scopeA = LibraryEditorScope(accountId: 'account-a', authEpoch: 4);
    const scopeB = LibraryEditorScope(accountId: 'account-b', authEpoch: 5);
    final scope = ValueNotifier<LibraryEditorScope?>(scopeA);
    addTearDown(scope.dispose);
    var saves = 0;
    await _pump(
      tester,
      items: [_item(1)],
      libraryV2Enabled: true,
      accountScopeListenable: scope,
      expectedAccountScope: scopeA,
      onSaveList: (_, __, ___, ____) async => saves += 1,
      onDeleteList: (_) async {},
      onReorderLists: (_) async {},
      onSaveTag: (_, __) async {},
      onDeleteTag: (_) async {},
    );

    await tester.tap(find.byKey(const ValueKey('library-view-collections')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('library-list-add')));
    await tester.pumpAndSettle();
    expect(find.text('New private list'), findsOneWidget);

    scope.value = scopeB;
    await tester.pump();
    await tester.pump();

    expect(find.text('New private list'), findsNothing);
    expect(saves, 0);
  });

  testWidgets('account switch before first dialog frame cannot expose editor', (
    tester,
  ) async {
    const scopeA = LibraryEditorScope(accountId: 'account-a', authEpoch: 4);
    const scopeB = LibraryEditorScope(accountId: 'account-b', authEpoch: 5);
    final scope = ValueNotifier<LibraryEditorScope?>(scopeA);
    addTearDown(scope.dispose);
    var saves = 0;
    await _pump(
      tester,
      items: [_item(1)],
      libraryV2Enabled: true,
      accountScopeListenable: scope,
      expectedAccountScope: scopeA,
      onSaveList: (_, __, ___, ____) async => saves += 1,
      onDeleteList: (_) async {},
      onReorderLists: (_) async {},
      onSaveTag: (_, __) async {},
      onDeleteTag: (_) async {},
    );

    await tester.tap(find.byKey(const ValueKey('library-view-collections')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('library-list-add')));
    scope.value = scopeB;
    await tester.pump();
    await tester.pump();

    expect(find.text('New private list'), findsNothing);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _revealInLibrary(
  WidgetTester tester,
  Finder scrollable,
  Finder target,
) async {
  final position = tester.state<ScrollableState>(scrollable).position;
  await position.ensureVisible(
    tester.renderObject(target),
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pump();
}

Future<void> _pump(
  WidgetTester tester, {
  required List<LibraryListItem> items,
  LibraryEditorCapabilities capabilities =
      const LibraryEditorCapabilities.none(),
  LibraryItemEditCallback? onEdit,
  bool canAddPaper = false,
  VoidCallback? onAddPaper,
  MediaQueryData media = const MediaQueryData(),
  ValueListenable<LibraryEditorScope?>? accountScopeListenable,
  LibraryEditorScope? expectedAccountScope,
  bool libraryV2Enabled = false,
  List<LibraryV2LocalList> lists = const [],
  List<LibraryV2LocalTag> tags = const [],
  LibraryHistoryState history = const LibraryHistoryState(loading: false),
  ValueChanged<PaperSummary>? onOpenHistoryPaper,
  LibraryListSaveCallback? onSaveList,
  LibraryListDeleteCallback? onDeleteList,
  LibraryListReorderCallback? onReorderLists,
  LibraryTagSaveCallback? onSaveTag,
  LibraryTagDeleteCallback? onDeleteTag,
}) async {
  final authority = LibraryWorkspaceAuthority.from(
    items: items,
    pendingIntents: const LibraryPendingIntentCounts.empty(),
    checkpoint: const LibrarySyncCheckpoint(
      initialized: true,
      lastRevision: 12,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: media.textScaler,
            disableAnimations: media.disableAnimations,
            accessibleNavigation: media.accessibleNavigation,
          ),
          child: LibraryDestinationView(
            items: items,
            authority: authority,
            onOpenPaper: (_) {},
            editorCapabilities: capabilities,
            onEdit: onEdit,
            canAddPaper: canAddPaper,
            onAddPaper: onAddPaper,
            accountScopeListenable: accountScopeListenable,
            expectedAccountScope: expectedAccountScope,
            libraryV2Enabled: libraryV2Enabled,
            lists: lists,
            tags: tags,
            history: history,
            onHistoryEnabledChanged: (_) {},
            onClearHistory: () {},
            onOpenHistoryPaper: onOpenHistoryPaper,
            onSaveList: onSaveList,
            onDeleteList: onDeleteList,
            onReorderLists: onReorderLists,
            onSaveTag: onSaveTag,
            onDeleteTag: onDeleteTag,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

LibraryListItem _item(
  int number, {
  LibraryItemState state = LibraryItemState.inbox,
  String? privateNote,
  DateTime? reminderAt,
}) {
  final timestamp = DateTime.utc(2026, 8, number);
  final suffix = number.toString().padLeft(12, '0');
  return LibraryListItem(
    paper: PaperSummary(
      paperId: '17060376-2000-4000-8000-$suffix',
      arxivId: '2401.${number.toString().padLeft(5, '0')}v1',
      title: 'Library paper $number',
      abstractText: 'Abstract',
      authors: const ['Ada Reader', 'Grace Hopper'],
      primaryCategory: 'cs.AI',
      categories: const ['cs.AI'],
      publishedAt: timestamp,
      updatedAt: timestamp,
      absUrl: 'https://arxiv.org/abs/2401.00001v1',
      pdfUrl: 'https://arxiv.org/pdf/2401.00001v1',
    ),
    savedAt: timestamp,
    savedState: const LibrarySavedState(saved: true, syncPending: false),
    state: state,
    privateNote: privateNote,
    saveSourceKind: LibrarySaveSourceKind.titleSearch,
    reminderAt: reminderAt,
  );
}
