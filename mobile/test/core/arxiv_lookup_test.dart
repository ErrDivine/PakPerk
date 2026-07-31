import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/demo_asset_store.dart';
import 'package:pakperk/core/cache/versioned_derived_cache.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/arxiv_identifier.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/repository/paper_repository.dart';

import '../support/fakes.dart';

void main() {
  group('arXiv identifier validation', () {
    test('normalizes versions while preserving legacy base casing', () {
      final modern = ArxivIdentifier.tryParse('2401.12345v002');
      expect(modern?.baseId, '2401.12345');
      expect(modern?.version, 2);
      expect(modern?.queryId, '2401.12345v2');

      final legacy = ArxivIdentifier.tryParse('math.GT/0309136v3');
      expect(legacy?.baseId, 'math.GT/0309136');
      expect(legacy?.queryId, 'math.GT/0309136v3');
      expect(legacy?.encodedRouteSegment, 'math.GT%2F0309136v3');
    });

    test('rejects traversal, URLs, oversized IDs, and version zero', () {
      for (final value in [
        '',
        ' 2401.12345',
        '../../2401.12345',
        'https://arxiv.org/abs/2401.12345',
        '2401.12345v0',
        '2401.12345v4294967296',
        'hep-th//9901001',
        List.filled(65, 'x').join(),
      ]) {
        expect(ArxivIdentifier.tryParse(value), isNull, reason: value);
      }
    });
  });

  test('API safely encodes a legacy exact-ID path', () async {
    final legacyPaper = _withArxiv(samplePaper, 'math.GT/0309136v3');
    final adapter = _PaperResponseAdapter(legacyPaper);
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
      ..httpClientAdapter = adapter;
    final client = ApiClient(
      baseUrl: 'http://localhost:8080',
      sessionId: '00000000-0000-4000-8000-000000000099',
      dio: dio,
    );
    addTearDown(client.dispose);

    final result = await client.getPaperByArxiv('math.GT/0309136v3');

    expect(result.arxivId, 'math.GT/0309136v3');
    expect(
      adapter.requestUri.toString(),
      'http://localhost:8080/v1/papers/by-arxiv/math.GT%2F0309136v3',
    );
  });

  test('API rejects malformed IDs before opening a request', () async {
    final adapter = _PaperResponseAdapter(samplePaper);
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
      ..httpClientAdapter = adapter;
    final client = ApiClient(
      baseUrl: 'http://localhost:8080',
      sessionId: '00000000-0000-4000-8000-000000000099',
      dio: dio,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.getPaperByArxiv('../2401.12345'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_ARXIV_ID',
        ),
      ),
    );
    expect(adapter.calls, 0);
  });

  test(
    'repository caches a network exact-ID result under strict policy',
    () async {
      final prepared = samplePaper.copyWith(
        capabilities: const PaperCapabilities(
          introduction: true,
          chat: true,
          connections: true,
        ),
      );
      final store = MemoryLocalStore();
      final repository = PaperRepository(
        api: _ArxivApiClient(paper: prepared),
        localStore: store,
        demoContent: _SinglePaperDemoStore(prepared),
        fulltextPolicy: ClientFulltextPolicy.strict,
      );
      addTearDown(repository.dispose);

      final result = await repository.getPaperByArxiv(prepared.arxivId);

      expect(result.origin, DataOrigin.network);
      expect(result.value.capabilities.allReady, isTrue);
      expect(store.papers[prepared.paperId]?.capabilities.allReady, isFalse);
    },
  );

  test(
    'repository accepts case differences in legacy arXiv responses',
    () async {
      final requested = _withArxiv(samplePaper, 'math.GT/0309136v3');
      final returned = _withArxiv(samplePaper, 'MATH.gt/0309136v4');
      final repository = PaperRepository(
        api: _ArxivApiClient(paper: returned),
        localStore: MemoryLocalStore(),
        demoContent: _SinglePaperDemoStore(requested),
        fulltextPolicy: ClientFulltextPolicy.prototype,
      );
      addTearDown(repository.dispose);

      final result = await repository.getPaperByArxiv(requested.arxivId);

      expect(result.origin, DataOrigin.network);
      expect(result.value.arxivId, returned.arxivId);
    },
  );

  test(
    'late older metadata cannot replace or invalidate a newer version',
    () async {
      final older = _withArxiv(samplePaper, '1706.03762v6');
      final newer = _withArxiv(samplePaper, '1706.03762v7');
      final store = MemoryLocalStore()
        ..papers[newer.paperId] = newer
        ..introductions[newer.paperId] = sampleIntroduction;
      final repository = PaperRepository(
        api: _ArxivApiClient(paper: older),
        localStore: store,
        demoContent: _SinglePaperDemoStore(newer),
        fulltextPolicy: ClientFulltextPolicy.prototype,
      );
      addTearDown(repository.dispose);

      final result = await repository.getPaperByArxiv(older.arxivId);

      expect(result.value.arxivId, newer.arxivId);
      expect(store.papers[newer.paperId]?.arxivId, newer.arxivId);
      expect(store.introductions[newer.paperId], same(sampleIntroduction));
    },
  );

  test(
    'late same-version older timestamp cannot regress cached metadata',
    () async {
      final current = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['updated_at'] = DateTime.utc(2026, 7, 31).toIso8601String()
          ..['title'] = 'Current metadata',
      );
      final stale = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['updated_at'] = DateTime.utc(2026, 7, 30).toIso8601String()
          ..['title'] = 'Stale metadata',
      );
      final store = MemoryLocalStore()
        ..papers[current.paperId] = current
        ..introductions[current.paperId] = sampleIntroduction;
      final repository = PaperRepository(
        api: _ArxivApiClient(paper: stale),
        localStore: store,
        demoContent: _SinglePaperDemoStore(current),
        fulltextPolicy: ClientFulltextPolicy.prototype,
      );
      addTearDown(repository.dispose);

      final result = await repository.getPaperByArxiv(stale.arxivId);

      expect(result.value.title, 'Current metadata');
      expect(store.papers[current.paperId]?.title, 'Current metadata');
      expect(store.introductions[current.paperId], same(sampleIntroduction));
    },
  );

  test(
    'late derived response is rejected after the paper version advances',
    () async {
      final response = Completer<PaperIntroduction>();
      final oldPaper = _withArxiv(samplePaper, '1706.03762v6');
      final newPaper = _withArxiv(samplePaper, '1706.03762v7');
      final store = _VersionedMemoryStore()
        ..papers[oldPaper.paperId] = oldPaper;
      final repository = PaperRepository(
        api: _IntroductionApiClient(response.future),
        localStore: store,
        demoContent: _SinglePaperDemoStore(newPaper),
        fulltextPolicy: ClientFulltextPolicy.prototype,
      );
      addTearDown(repository.dispose);

      final pending = repository.getIntroduction(oldPaper.paperId);
      await Future<void>.delayed(Duration.zero);
      await store.savePaper(newPaper);
      response.complete(sampleIntroduction);

      await expectLater(
        pending,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'STALE_PAPER_VERSION',
          ),
        ),
      );
      expect(store.introductions[oldPaper.paperId], isNull);
    },
  );

  test('repository uses masked device cache while offline', () async {
    final prepared = samplePaper.copyWith(
      capabilities: const PaperCapabilities(
        introduction: true,
        chat: true,
        connections: true,
      ),
    );
    final store = MemoryLocalStore()..papers[prepared.paperId] = prepared;
    final repository = PaperRepository(
      api: _ArxivApiClient(error: _offline()),
      localStore: store,
      demoContent: _SinglePaperDemoStore(prepared),
      fulltextPolicy: ClientFulltextPolicy.strict,
    );
    addTearDown(repository.dispose);

    final result = await repository.getPaperByArxiv(prepared.arxivId);

    expect(result.origin, DataOrigin.deviceCache);
    expect(result.offline, isTrue);
    expect(result.value.capabilities.allReady, isFalse);
  });

  test('repository uses bundled metadata fallback while offline', () async {
    final repository = PaperRepository(
      api: _ArxivApiClient(error: _offline()),
      localStore: MemoryLocalStore(),
      demoContent: _SinglePaperDemoStore(samplePaper),
      fulltextPolicy: ClientFulltextPolicy.prototype,
    );
    addTearDown(repository.dispose);

    final result = await repository.getPaperByArxiv(samplePaper.arxivId);

    expect(result.origin, DataOrigin.bundledDemo);
    expect(result.value.paperId, samplePaper.paperId);
  });
}

PaperSummary _withArxiv(PaperSummary paper, String arxivId) {
  return PaperSummary.fromJson(
    paper.toJson()
      ..['arxiv_id'] = arxivId
      ..['abs_url'] = 'https://arxiv.org/abs/$arxivId'
      ..['pdf_url'] = 'https://arxiv.org/pdf/$arxivId',
  );
}

ApiException _offline() => const ApiException(
  code: 'NETWORK_UNAVAILABLE',
  message: 'Offline',
  retryable: true,
  isOffline: true,
);

class _ArxivApiClient extends ApiClient {
  _ArxivApiClient({this.paper, this.error})
    : super(
        baseUrl: 'http://localhost:8080',
        sessionId: '00000000-0000-4000-8000-000000000099',
      );

  final PaperSummary? paper;
  final ApiException? error;

  @override
  Future<PaperSummary> getPaperByArxiv(
    String arxivId, {
    RequestCancellation? cancellation,
  }) async {
    if (error case final value?) throw value;
    return paper ?? samplePaper;
  }
}

class _IntroductionApiClient extends ApiClient {
  _IntroductionApiClient(this.response)
    : super(
        baseUrl: 'http://localhost:8080',
        sessionId: '00000000-0000-4000-8000-000000000099',
      );

  final Future<PaperIntroduction> response;

  @override
  Future<PaperIntroduction> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) => response;
}

class _VersionedMemoryStore extends MemoryLocalStore
    implements VersionedDerivedCache {
  bool _matches(PaperVersionKey expected) =>
      papers[expected.paperId]?.versionKey == expected;

  @override
  Future<bool> saveProcessingForVersion(
    PaperProcessingState value, {
    required PaperVersionKey expectedVersionKey,
  }) async {
    if (!_matches(expectedVersionKey)) return false;
    await saveProcessing(value);
    return true;
  }

  @override
  Future<bool> saveIntroductionForVersion(
    PaperIntroduction value, {
    required PaperVersionKey expectedVersionKey,
  }) async {
    if (!_matches(expectedVersionKey)) return false;
    await saveIntroduction(value);
    return true;
  }

  @override
  Future<bool> saveConnectionsForVersion(
    PaperConnections value, {
    required PaperVersionKey expectedVersionKey,
  }) async {
    if (!_matches(expectedVersionKey)) return false;
    await saveConnections(value);
    return true;
  }
}

class _SinglePaperDemoStore implements DemoContentStore {
  const _SinglePaperDemoStore(this.paper);

  final PaperSummary paper;

  @override
  Future<PaperSummary?> findFallbackPaper(String paperId) async =>
      paper.paperId == paperId ? paper : null;

  @override
  Future<PaperSummary?> findFallbackPaperByArxiv(String arxivBaseId) async =>
      paper.arxivBaseId.toLowerCase() == arxivBaseId.toLowerCase()
      ? paper
      : null;

  @override
  Future<FeedPage> loadFallbackFeed() async => FeedPage(items: [paper]);

  @override
  Future<PaperConnections?> loadConnections(String paperId) async => null;

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async => null;
}

class _PaperResponseAdapter implements HttpClientAdapter {
  _PaperResponseAdapter(this.paper);

  final PaperSummary paper;
  int calls = 0;
  late Uri requestUri;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    requestUri = options.uri;
    return ResponseBody.fromString(
      jsonEncode({'paper': paper.toJson()}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
