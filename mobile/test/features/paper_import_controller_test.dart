import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_v2_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_api.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:pakperk/features/library/paper_import_controller.dart';

import '../support/fakes.dart';

void main() {
  group('PaperImportController', () {
    for (final exactInput in <({String input, PaperImportSourceKind kind})>[
      (
        input: 'https://arxiv.org/pdf/1706.03762v7.pdf',
        kind: PaperImportSourceKind.arxivUrl,
      ),
      (input: '1706.03762v7', kind: PaperImportSourceKind.arxivId),
    ]) {
      testWidgets(
        'imports exact ${exactInput.kind.name} without title search',
        (tester) async {
          final remote = _FakePaperResolutionRemote();
          final controller = _controller(remote);
          addTearDown(controller.dispose);

          controller.updateInput(exactInput.input);
          await tester.pump(const Duration(seconds: 1));

          expect(controller.state.phase, PaperImportPhase.ready);
          expect(remote.searches, isEmpty);

          final import = controller.submit();
          expect(remote.imports, hasLength(1));
          final request = remote.imports.single;
          expect(request.source.kind, exactInput.kind);
          expect(
            request.saveSourceKind,
            exactInput.kind == PaperImportSourceKind.arxivUrl
                ? LibrarySaveSourceKind.arxivUrl
                : LibrarySaveSourceKind.arxivId,
          );
          expect(
            request.source.value,
            exactInput.kind == PaperImportSourceKind.arxivUrl
                ? 'https://arxiv.org/abs/1706.03762v7'
                : '1706.03762v7',
          );
          expect(request.expectedAuthEpoch, 7);
          expect(controller.state.placeholder?.operationId, _operationId);

          request.response.complete(_importResult(request));
          expect(await import, isNotNull);
          expect(controller.state.phase, PaperImportPhase.succeeded);
        },
      );
    }

    testWidgets(
      'debounces only title input for 400 ms and requires candidate selection',
      (tester) async {
        final remote = _FakePaperResolutionRemote();
        final controller = _controller(remote);
        addTearDown(controller.dispose);

        controller.updateInput('  Attention   Is All You Need  ');
        expect(controller.state.phase, PaperImportPhase.waitingForSearch);

        await tester.pump(const Duration(milliseconds: 399));
        expect(remote.searches, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(remote.searches, hasLength(1));
        expect(remote.searches.single.query, 'Attention Is All You Need');
        expect(controller.state.phase, PaperImportPhase.searching);

        remote.searches.single.response.complete(
          _searchResult('Attention Is All You Need'),
        );
        await tester.pump(const Duration(milliseconds: 1));
        expect(controller.state.phase, PaperImportPhase.choosingCandidate);
        expect(controller.state.canSubmit, isFalse);
        expect(await controller.submit(), isNull);
        expect(remote.imports, isEmpty);

        controller.selectCandidate(_candidate);
        expect(controller.state.selectedCandidate, same(_candidate));
        expect(controller.state.canSubmit, isTrue);

        final import = controller.submit();
        expect(remote.imports, hasLength(1));
        expect(
          remote.imports.single.source.kind,
          PaperImportSourceKind.arxivId,
        );
        expect(remote.imports.single.source.value, _candidate.arxivId);
        expect(
          remote.imports.single.saveSourceKind,
          LibrarySaveSourceKind.titleSearch,
        );
        remote.imports.single.response.complete(
          _importResult(remote.imports.single),
        );
        expect(await import, isNotNull);
      },
    );

    testWidgets(
      'keeps an operation-scoped placeholder and reuses its id on retry',
      (tester) async {
        var generatedIds = 0;
        final remote = _FakePaperResolutionRemote();
        final controller = _controller(
          remote,
          operationId: () {
            generatedIds += 1;
            return _operationId;
          },
        );
        addTearDown(controller.dispose);

        controller.updateInput('1706.03762v7');
        final firstImport = controller.submit();
        final firstRequest = remote.imports.single;
        expect(controller.state.phase, PaperImportPhase.importing);
        expect(
          controller.state.placeholder,
          isA<PaperImportPlaceholder>()
              .having((value) => value.operationId, 'operationId', _operationId)
              .having((value) => value.label, 'label', '1706.03762v7'),
        );

        firstRequest.response.completeError(
          const ApiException(
            code: 'PAPER_IMPORT_UNAVAILABLE',
            message: 'Try this import again.',
            retryable: true,
            statusCode: 503,
          ),
        );
        expect(await firstImport, isNull);
        expect(controller.state.phase, PaperImportPhase.failed);
        expect(controller.state.placeholder?.operationId, _operationId);
        expect(
          controller.state.failure?.retryAction,
          PaperImportRetryAction.import,
        );

        final retry = controller.retry();
        expect(remote.imports, hasLength(2));
        final retryRequest = remote.imports.last;
        expect(retryRequest.operationId, firstRequest.operationId);
        expect(generatedIds, 1);
        retryRequest.response.complete(_importResult(retryRequest));
        expect(await retry, isNotNull);
        expect(controller.state.placeholder, isNull);
      },
    );

    testWidgets('resumed title result preserves title-search provenance', (
      tester,
    ) async {
      final remote = _FakePaperResolutionRemote();
      final controller = _controller(
        remote,
        initialSaveSourceKind: LibrarySaveSourceKind.titleSearch,
      );
      addTearDown(controller.dispose);
      controller.updateInput('1706.03762v7');
      final import = controller.submit();
      expect(
        remote.imports.single.saveSourceKind,
        LibrarySaveSourceKind.titleSearch,
      );
      remote.imports.single.response.complete(
        _importResult(remote.imports.single),
      );
      expect(await import, isNotNull);
    });

    testWidgets(
      'cancels and ignores work across account generation and auth epoch changes',
      (tester) async {
        final remote = _FakePaperResolutionRemote();
        final controller = _controller(remote, titleDebounce: Duration.zero);
        addTearDown(controller.dispose);

        controller.updateInput('Attention Is All You Need');
        await tester.pump(const Duration(milliseconds: 1));
        final staleSearch = remote.searches.single;
        controller.updateScope(
          const PaperImportAccountScope(
            accountId: 'account-a',
            authEpoch: 7,
            accountGeneration: 2,
          ),
        );
        expect(staleSearch.cancellation?.isCancelled, isTrue);
        expect(controller.state.phase, PaperImportPhase.idle);

        staleSearch.response.complete(_searchResult(staleSearch.query));
        await tester.pump();
        expect(controller.state.phase, PaperImportPhase.idle);
        expect(controller.state.candidates, isEmpty);

        controller.updateInput('1706.03762v7');
        final staleImportFuture = controller.submit();
        final staleImport = remote.imports.single;
        controller.updateScope(
          const PaperImportAccountScope(
            accountId: 'account-b',
            authEpoch: 8,
            accountGeneration: 3,
          ),
        );
        expect(staleImport.cancellation?.isCancelled, isTrue);
        staleImport.response.complete(_importResult(staleImport));
        expect(await staleImportFuture, isNull);
        expect(controller.state.phase, PaperImportPhase.idle);
        expect(controller.state.result, isNull);
        expect(controller.scope?.authEpoch, 8);
      },
    );

    testWidgets(
      'disabled title search fails clearly without blocking exact imports',
      (tester) async {
        final remote = _FakePaperResolutionRemote();
        final controller = _controller(remote, titleSearchEnabled: false);
        addTearDown(controller.dispose);

        controller.updateInput('Attention Is All You Need');
        await tester.pump(const Duration(seconds: 1));
        expect(remote.searches, isEmpty);
        expect(controller.state.phase, PaperImportPhase.failed);
        expect(controller.state.failure?.code, 'TITLE_SEARCH_UNAVAILABLE');
        expect(controller.state.failure?.retryable, isFalse);

        controller.updateInput('1706.03762v7');
        expect(controller.state.phase, PaperImportPhase.ready);
        final import = controller.submit();
        expect(remote.imports, hasLength(1));
        remote.imports.single.response.complete(
          _importResult(remote.imports.single),
        );
        expect(await import, isNotNull);
      },
    );
  });
}

PaperImportController _controller(
  _FakePaperResolutionRemote remote, {
  PaperImportOperationIdFactory? operationId,
  Duration titleDebounce = PaperImportController.defaultTitleDebounce,
  bool titleSearchEnabled = true,
  LibrarySaveSourceKind? initialSaveSourceKind,
}) => PaperImportController(
  remote: remote,
  scope: const PaperImportAccountScope(
    accountId: 'account-a',
    authEpoch: 7,
    accountGeneration: 1,
  ),
  operationId: operationId ?? () => _operationId,
  titleDebounce: titleDebounce,
  titleSearchEnabled: titleSearchEnabled,
  initialSaveSourceKind: initialSaveSourceKind,
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
    final request = _SearchRequest(
      query: query,
      expectedAuthEpoch: expectedAuthEpoch,
      limit: limit,
      cancellation: cancellation,
    );
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
      expectedAuthEpoch: expectedAuthEpoch,
      cancellation: cancellation,
    );
    imports.add(request);
    return request.response.future;
  }
}

final class _SearchRequest {
  _SearchRequest({
    required this.query,
    required this.expectedAuthEpoch,
    required this.limit,
    required this.cancellation,
  });

  final String query;
  final int expectedAuthEpoch;
  final int limit;
  final RequestCancellation? cancellation;
  final Completer<PaperSearchResult> response = Completer<PaperSearchResult>();
}

final class _ImportRequest {
  _ImportRequest({
    required this.source,
    required this.operationId,
    required this.saveSourceKind,
    required this.expectedAuthEpoch,
    required this.cancellation,
  });

  final PaperImportSource source;
  final String operationId;
  final LibrarySaveSourceKind saveSourceKind;
  final int expectedAuthEpoch;
  final RequestCancellation? cancellation;
  final Completer<PaperImportResult> response = Completer<PaperImportResult>();
}

const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
