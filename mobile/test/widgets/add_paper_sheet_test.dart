import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_v2_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_api.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/library/add_paper_sheet.dart';
import 'package:pakperk/features/library/paper_import_controller.dart';

import '../support/fakes.dart';

void main() {
  testWidgets(
    'exact import reports pending, canonical success, and closed lifecycle',
    (tester) async {
      final remote = _FakePaperResolutionRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);
      final lifecycle = <PaperImportLifecycleEvent>[];
      final imported = <PaperImportResult>[];
      PaperImportResult? finished;
      PaperImportResult? organizeRequested;

      await _pumpSheet(
        tester,
        controller: controller,
        onLifecycle: lifecycle.add,
        onImported: imported.add,
        onDone: (result) => finished = result,
        onOrganize: (result) => organizeRequested = result,
      );

      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('add-paper-input')),
      );
      expect(
        input.decoration?.labelText,
        'Paste an arXiv link or search by paper title',
      );
      expect(input.decoration?.helperText, contains('arXiv ID'));

      expect(_semanticsWithLabel('Add paper modal sheet'), findsOneWidget);
      expect(_semanticsWithLabel('Drag handle'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('add-paper-close'))).height,
        greaterThanOrEqualTo(48),
      );

      await tester.enterText(
        find.byKey(const ValueKey('add-paper-input')),
        'https://arxiv.org/pdf/1706.03762v7.pdf',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('add-paper-ready')), findsOneWidget);
      expect(remote.searches, isEmpty);

      final primary = find.byKey(const ValueKey('add-paper-primary-action'));
      expect(tester.getSize(primary).height, greaterThanOrEqualTo(48));
      await tester.tap(primary);
      await tester.pump(const Duration(milliseconds: 200));

      expect(remote.imports, hasLength(1));
      expect(
        lifecycle.single,
        isA<PaperImportLifecycleEvent>()
            .having(
              (event) => event.phase,
              'phase',
              PaperImportLifecyclePhase.importing,
            )
            .having((event) => event.operationId, 'operationId', _operationId)
            .having((event) => event.terminal, 'terminal', isFalse),
      );
      expect(_semanticsWithLabel('Adding paper to To Read'), findsOneWidget);

      remote.imports.single.response.complete(
        _importResult(remote.imports.single),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(imported, hasLength(1));
      expect(lifecycle, hasLength(2));
      expect(lifecycle.last.phase, PaperImportLifecyclePhase.succeeded);
      expect(lifecycle.last.operationId, _operationId);
      expect(lifecycle.last.result, same(imported.single));
      expect(lifecycle.last.terminal, isTrue);
      expect(
        _semanticsWithLabel('${samplePaper.title} added to To Read'),
        findsOneWidget,
      );

      expect(find.byKey(const ValueKey('add-paper-organize')), findsOneWidget);
      expect(find.text('Organize or remind'), findsOneWidget);
      expect(find.byIcon(Icons.alarm_add_outlined), findsOneWidget);
      expect(find.byKey(const ValueKey('add-paper-done')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-paper-organize')));
      await tester.pump();
      expect(finished, same(imported.single));
      expect(organizeRequested, same(imported.single));
      expect(lifecycle.last.phase, PaperImportLifecyclePhase.closed);
      expect(lifecycle.last.operationId, _operationId);
      expect(
        lifecycle.where(
          (event) => event.phase == PaperImportLifecyclePhase.succeeded,
        ),
        hasLength(1),
      );
    },
  );

  testWidgets('notification rollback offers organize without reminder copy', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpSheet(
      tester,
      controller: controller,
      onDone: (_) {},
      onOrganize: (_) {},
      remindersAvailable: false,
    );
    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      '1706.03762',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-paper-primary-action')));
    await tester.pump();
    remote.imports.single.response.complete(
      _importResult(remote.imports.single),
    );
    await tester.pumpAndSettle();

    expect(find.text('Organize paper'), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.text('Organize or remind'), findsNothing);
    expect(find.byIcon(Icons.alarm_add_outlined), findsNothing);
  });

  testWidgets('title search requires a 400 ms pause and explicit selection', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    await _pumpSheet(tester, controller: controller);

    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      'Attention Is All You Need',
    );
    await tester.pump(const Duration(milliseconds: 399));
    expect(remote.searches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(remote.searches, hasLength(1));
    expect(remote.imports, isEmpty);

    remote.searches.single.response.complete(
      _searchResult(remote.searches.single.query),
    );
    await tester.pump();
    final candidate = find.byKey(
      ValueKey('paper-search-candidate-${_candidate.arxivId}'),
    );
    expect(candidate, findsOneWidget);
    expect(tester.getSize(candidate).height, greaterThanOrEqualTo(48));
    final published = _candidate.publishedAt.toUtc();
    final publishedLabel =
        '${published.year}-'
        '${published.month.toString().padLeft(2, '0')}-'
        '${published.day.toString().padLeft(2, '0')}';
    expect(
      find.text('$publishedLabel · ${_candidate.primaryCategory}'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.label ?? '').contains(
              'Published $publishedLabel. '
              'Category ${_candidate.primaryCategory}.',
            ),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Nothing is added until you select a result and confirm.'),
      findsOneWidget,
    );
    expect(find.text('Add selected paper'), findsNothing);

    await tester.tap(candidate);
    await tester.pump();
    expect(find.text('Add selected paper'), findsOneWidget);
    expect(remote.imports, isEmpty);

    await tester.tap(find.byKey(const ValueKey('add-paper-primary-action')));
    await tester.pump();
    expect(remote.imports, hasLength(1));
    expect(remote.imports.single.source.kind, PaperImportSourceKind.arxivId);
    expect(remote.imports.single.source.value, _candidate.arxivId);
  });

  testWidgets('retry is immediate, accessible, and keeps the operation id', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    final lifecycle = <PaperImportLifecycleEvent>[];
    await _pumpSheet(
      tester,
      controller: controller,
      onLifecycle: lifecycle.add,
    );

    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      '1706.03762v7',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-paper-primary-action')));
    await tester.pump(const Duration(milliseconds: 200));
    final first = remote.imports.single;
    first.response.completeError(
      const ApiException(
        code: 'PAPER_IMPORT_UNAVAILABLE',
        message: 'The paper service is temporarily unavailable.',
        retryable: true,
        statusCode: 503,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      _semanticsWithLabel(
        'Couldn’t add this paper. '
        'The paper service is temporarily unavailable.',
      ),
      findsOneWidget,
    );
    final retry = find.byKey(const ValueKey('add-paper-retry'));
    expect(retry, findsOneWidget);
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.failed);
    expect(lifecycle.last.operationId, _operationId);
    expect(lifecycle.last.terminal, isFalse);

    await tester.tap(retry);
    await tester.pump();
    expect(remote.imports, hasLength(2));
    expect(remote.imports.last.operationId, first.operationId);
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.importing);
    expect(lifecycle.last.operationId, _operationId);
  });

  testWidgets('scope invalidation terminally cancels the pending operation', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote);
    addTearDown(controller.dispose);
    final lifecycle = <PaperImportLifecycleEvent>[];
    await _pumpSheet(
      tester,
      controller: controller,
      onLifecycle: lifecycle.add,
    );

    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      '1706.03762v7',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-paper-primary-action')));
    await tester.pump();
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.importing);

    controller.updateScope(
      const PaperImportAccountScope(
        accountId: 'account-b',
        authEpoch: 8,
        accountGeneration: 2,
      ),
    );
    await tester.pump();
    expect(remote.imports.single.cancellation?.isCancelled, isTrue);
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.cancelled);
    expect(lifecycle.last.operationId, _operationId);
    expect(lifecycle.last.terminal, isTrue);
  });

  testWidgets('modal presenter follows account-scope invalidation', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final scope = ValueNotifier<PaperImportAccountScope?>(_scope);
    addTearDown(scope.dispose);
    final lifecycle = <PaperImportLifecycleEvent>[];
    Future<PaperImportResult?>? modalResult;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              key: const ValueKey('open-add-paper'),
              onPressed: () {
                modalResult = showAddPaperSheet(
                  context: context,
                  remote: remote,
                  scope: _scope,
                  accountScopeListenable: scope,
                  operationId: () => _operationId,
                  onLifecycle: lifecycle.add,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-add-paper')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      '1706.03762v7',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-paper-primary-action')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(remote.imports, hasLength(1));
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.importing);

    scope.value = null;
    await tester.pump(const Duration(milliseconds: 200));
    expect(remote.imports.single.cancellation?.isCancelled, isTrue);
    expect(lifecycle.last.phase, PaperImportLifecyclePhase.cancelled);
    expect(lifecycle.last.operationId, _operationId);
    expect(find.byKey(const ValueKey('add-paper-unavailable')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-paper-close')));
    await tester.pumpAndSettle();
    expect(await modalResult!, isNull);
  });

  testWidgets(
    'respects keyboard and horizontal safe areas with reduced motion',
    (tester) async {
      final remote = _FakePaperResolutionRemote();
      final controller = _controller(remote);
      addTearDown(controller.dispose);
      const media = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.fromLTRB(11, 0, 13, 17),
        viewPadding: EdgeInsets.fromLTRB(11, 0, 13, 17),
        viewInsets: EdgeInsets.only(bottom: 180),
        disableAnimations: true,
      );

      await _pumpSheet(tester, controller: controller, media: media);

      final keyboardPadding = tester.widget<AnimatedPadding>(
        find.byKey(const ValueKey('add-paper-keyboard-padding')),
      );
      expect(keyboardPadding.duration, Duration.zero);
      expect(keyboardPadding.padding, const EdgeInsets.only(bottom: 180));
      final safeArea = tester.widget<SafeArea>(
        find.byKey(const ValueKey('add-paper-safe-area')),
      );
      expect(safeArea.top, isFalse);
      expect(safeArea.left, isTrue);
      expect(safeArea.right, isTrue);
      expect(safeArea.bottom, isTrue);
      final stateSwitcher = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('add-paper-state-switcher')),
      );
      expect(stateSwitcher.duration, Duration.zero);
    },
  );

  testWidgets('disabled title search gives exact-input guidance', (
    tester,
  ) async {
    final remote = _FakePaperResolutionRemote();
    final controller = _controller(remote, titleSearchEnabled: false);
    addTearDown(controller.dispose);
    await _pumpSheet(tester, controller: controller);

    expect(
      find.text('Title search is unavailable. Paste an arXiv link or ID.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('add-paper-input')),
      'Attention Is All You Need',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(remote.searches, isEmpty);
    expect(find.text('Title search unavailable'), findsOneWidget);
    expect(
      find.text('Paste an arXiv link or ID to add this paper.'),
      findsOneWidget,
    );
  });
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required PaperImportController controller,
  PaperImportLifecycleCallback? onLifecycle,
  ValueChanged<PaperImportResult>? onImported,
  ValueChanged<PaperImportResult>? onDone,
  ValueChanged<PaperImportResult>? onOrganize,
  bool remindersAvailable = true,
  MediaQueryData media = const MediaQueryData(size: Size(390, 844)),
}) => tester.pumpWidget(
  MaterialApp(
    theme: PakPerkTheme.light(),
    home: MediaQuery(
      data: media,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: AddPaperSheet(
          controller: controller,
          autofocus: false,
          onDismiss: () {},
          onLifecycle: onLifecycle,
          onImported: onImported,
          onDone: onDone,
          onOrganize: onOrganize,
          remindersAvailable: remindersAvailable,
        ),
      ),
    ),
  ),
);

Finder _semanticsWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
  description: 'Semantics with label "$label"',
);

const _scope = PaperImportAccountScope(
  accountId: 'account-a',
  authEpoch: 7,
  accountGeneration: 1,
);

PaperImportController _controller(
  _FakePaperResolutionRemote remote, {
  bool titleSearchEnabled = true,
}) => PaperImportController(
  remote: remote,
  scope: const PaperImportAccountScope(
    accountId: 'account-a',
    authEpoch: 7,
    accountGeneration: 1,
  ),
  operationId: () => _operationId,
  titleSearchEnabled: titleSearchEnabled,
);

final _candidate = PaperSearchCandidate(
  arxivId: samplePaper.arxivId,
  title: samplePaper.title,
  authors: samplePaper.authors,
  abstractText: samplePaper.abstractText,
  primaryCategory: samplePaper.primaryCategory,
  categories: samplePaper.categories,
  publishedAt: samplePaper.publishedAt,
  updatedAt: samplePaper.updatedAt,
  absUri: Uri.parse(samplePaper.absUrl),
  rank: 1,
);

PaperSearchResult _searchResult(String query) => PaperSearchResult(
  queryId: _operationId,
  normalizedQuery: query,
  candidates: [_candidate],
);

PaperImportResult _importResult(_ImportRequest request) => PaperImportResult(
  resolution: PaperImportResolution(
    inputKind: request.source.kind,
    canonicalArxivId: samplePaper.arxivId,
  ),
  item: LibraryV2Item(
    paperId: samplePaper.paperId,
    state: LibraryItemState.inbox,
    privateNote: null,
    saveSourceKind: request.saveSourceKind,
    reminderAt: null,
    savedAt: DateTime.utc(2026, 8, 19, 8),
    updatedAt: DateTime.utc(2026, 8, 19, 8),
    reviewedAt: null,
    archivedAt: null,
    removed: false,
    removedAt: null,
    revision: 42,
    lastOperationId: request.operationId,
  ),
  paper: samplePaper,
  syncRevision: 42,
);

final class _FakePaperResolutionRemote
    implements PaperResolutionRemoteDataSource {
  final List<_SearchRequest> searches = [];
  final List<_ImportRequest> imports = [];

  @override
  Future<PaperSearchResult> searchByTitle({
    required String query,
    required int expectedAuthEpoch,
    int limit = 8,
    RequestCancellation? cancellation,
  }) {
    final request = _SearchRequest(query: query, cancellation: cancellation);
    searches.add(request);
    return request.response.future;
  }

  @override
  Future<PaperImportResult> importPaper({
    required PaperImportSource source,
    required String operationId,
    required LibrarySaveSourceKind saveSourceKind,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    final request = _ImportRequest(
      source: source,
      operationId: operationId,
      saveSourceKind: saveSourceKind,
      cancellation: cancellation,
    );

    imports.add(request);
    return request.response.future;
  }
}

final class _SearchRequest {
  _SearchRequest({required this.query, required this.cancellation});

  final String query;
  final RequestCancellation? cancellation;
  final Completer<PaperSearchResult> response = Completer<PaperSearchResult>();
}

final class _ImportRequest {
  _ImportRequest({
    required this.source,
    required this.operationId,
    required this.saveSourceKind,
    required this.cancellation,
  });

  final PaperImportSource source;
  final String operationId;
  final LibrarySaveSourceKind saveSourceKind;
  final RequestCancellation? cancellation;
  final Completer<PaperImportResult> response = Completer<PaperImportResult>();
}

const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
