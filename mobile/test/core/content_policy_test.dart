import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/demo_asset_store.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/chat/chat_controller.dart';

import '../support/fakes.dart';

void main() {
  final preparedPaper = samplePaper.copyWith(
    capabilities: const PaperCapabilities(
      introduction: true,
      chat: true,
      connections: true,
    ),
  );

  test('unknown client policy names fail closed to strict mode', () {
    expect(
      ClientFulltextPolicy.fromWire('prototype'),
      ClientFulltextPolicy.prototype,
    );
    expect(
      ClientFulltextPolicy.fromWire('strict'),
      ClientFulltextPolicy.strict,
    );
    expect(ClientFulltextPolicy.fromWire('typo'), ClientFulltextPolicy.strict);
  });

  test(
    'server policy denial never falls back to cached or bundled derived data',
    () async {
      final api = _PolicyApiClient(
        introductionError: _policyDenied(),
        connectionsError: _policyDenied(),
      );
      final store = MemoryLocalStore()
        ..introductions[samplePaper.paperId] = sampleIntroduction
        ..connections[samplePaper.paperId] = sampleConnections;
      final repository = PaperRepository(
        api: api,
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );

      await expectLater(
        repository.getIntroduction(samplePaper.paperId),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'FULLTEXT_POLICY_DENIED',
          ),
        ),
      );
      await expectLater(
        repository.getConnections(samplePaper.paperId),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'FULLTEXT_POLICY_DENIED',
          ),
        ),
      );
    },
  );

  test(
    'prototype uses cached derived data only for transient failures',
    () async {
      final store = MemoryLocalStore()
        ..introductions[samplePaper.paperId] = sampleIntroduction;
      final transientRepository = PaperRepository(
        api: _PolicyApiClient(introductionError: _offline()),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );
      final result = await transientRepository.getIntroduction(
        samplePaper.paperId,
      );
      expect(result.origin, DataOrigin.deviceCache);

      final permanentRepository = PaperRepository(
        api: _PolicyApiClient(
          introductionError: const ApiException(
            code: 'PAPER_NOT_FOUND',
            message: 'Missing',
            statusCode: 404,
          ),
        ),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );
      await expectLater(
        permanentRepository.getIntroduction(samplePaper.paperId),
        throwsA(isA<ApiException>()),
      );

      final newGenerationRepository = PaperRepository(
        api: _PolicyApiClient(
          introductionError: const ApiException(
            code: 'CAPABILITY_NOT_READY',
            message: 'The current generation is still processing.',
            retryable: true,
            statusCode: 409,
          ),
        ),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );
      await expectLater(
        newGenerationRepository.getIntroduction(samplePaper.paperId),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'CAPABILITY_NOT_READY',
          ),
        ),
      );
    },
  );

  test(
    'strict offline mode disables all device and bundled derived fallbacks',
    () async {
      final store = MemoryLocalStore()
        ..introductions[samplePaper.paperId] = sampleIntroduction
        ..connections[samplePaper.paperId] = sampleConnections;
      final repository = PaperRepository(
        api: _PolicyApiClient(
          introductionError: _offline(),
          connectionsError: _offline(),
        ),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
        fulltextPolicy: ClientFulltextPolicy.strict,
      );

      await expectLater(
        repository.getIntroduction(samplePaper.paperId),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        repository.getConnections(samplePaper.paperId),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'strict stale feed fallback and processing cache advertise metadata only',
    () async {
      final store = MemoryLocalStore()
        ..feed = FeedPage(items: [preparedPaper])
        ..processing[samplePaper.paperId] = sampleProcessing;
      final repository = PaperRepository(
        api: _PolicyApiClient(
          feedError: _offline(),
          processingError: _offline(),
        ),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
        fulltextPolicy: ClientFulltextPolicy.strict,
      );

      final cached = await repository.getCachedFeed();
      expect(cached.value.items.single.capabilities.introduction, isFalse);
      expect(cached.value.items.single.capabilities.chat, isFalse);
      expect(cached.value.items.single.capabilities.connections, isFalse);

      final revalidated = await repository.getFeed();
      expect(revalidated.value.items.single.capabilities.introduction, isFalse);
      expect(revalidated.value.items.single.capabilities.chat, isFalse);
      expect(revalidated.value.items.single.capabilities.connections, isFalse);

      final processing = await repository.getProcessing(samplePaper.paperId);
      expect(processing.value.capabilities.introduction, isFalse);
      expect(processing.value.stage, ProcessingStage.failedTerminal);
      expect(processing.value.lastErrorCode, 'FULLTEXT_POLICY_DENIED');
    },
  );

  test(
    'strict mode accepts network-derived data authorized by the backend',
    () async {
      final store = MemoryLocalStore();
      final repository = PaperRepository(
        api: _PolicyApiClient(introduction: sampleIntroduction),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
        fulltextPolicy: ClientFulltextPolicy.strict,
      );

      final result = await repository.getIntroduction(samplePaper.paperId);
      expect(result.origin, DataOrigin.network);
      expect(result.value, sampleIntroduction);
      expect(store.introductions, isEmpty);
    },
  );

  test('strict restart does not restore a prototype chat snapshot', () async {
    const readerKey = 'feed:policy-test';
    final store = MemoryLocalStore()
      ..chats[readerKey] = ChatSnapshot(
        threadId: 'prototype-thread',
        messages: [
          ChatMessage(
            id: 'prototype-answer',
            role: ChatRole.assistant,
            content: 'Cached prototype-derived answer.',
            createdAt: DateTime.utc(2026, 7, 29),
          ),
        ],
      );

    final strict = await loadRestorableChatSnapshot(
      store: store,
      readerKey: readerKey,
      allowDerivedDeviceFallback: false,
    );
    final prototype = await loadRestorableChatSnapshot(
      store: store,
      readerKey: readerKey,
      allowDerivedDeviceFallback: true,
    );

    expect(strict, isNull);
    expect(
      prototype?.messages.single.content,
      'Cached prototype-derived answer.',
    );
  });

  test(
    'a newly observed arXiv version clears older derived device data',
    () async {
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = sampleProcessing
        ..introductions[samplePaper.paperId] = sampleIntroduction
        ..connections[samplePaper.paperId] = sampleConnections;
      final repository = PaperRepository(
        api: _PolicyApiClient(),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );

      await repository.cacheFeed(FeedPage(items: [samplePaper]));
      expect(store.processing, isNotEmpty);
      expect(store.introductions, isNotEmpty);
      expect(store.connections, isNotEmpty);

      final newerPaper = _atVersion(samplePaper, '1706.03762v8');
      await repository.cacheFeed(FeedPage(items: [newerPaper]));

      expect(store.papers[samplePaper.paperId]?.arxivId, '1706.03762v8');
      expect(store.processing, isEmpty);
      expect(store.introductions, isEmpty);
      expect(store.connections, isEmpty);
    },
  );

  test(
    'paper detail refresh also invalidates an older cached generation',
    () async {
      final newerPaper = _atVersion(samplePaper, '1706.03762v8');
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..introductions[samplePaper.paperId] = sampleIntroduction;
      final repository = PaperRepository(
        api: _PolicyApiClient(paper: newerPaper),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );

      final result = await repository.getPaper(samplePaper.paperId);

      expect(result.value.arxivId, '1706.03762v8');
      expect(store.introductions, isEmpty);
    },
  );

  test(
    'filtered feed discovery invalidates versions without replacing feed',
    () async {
      final newerPaper = _atVersion(samplePaper, '1706.03762v8');
      final store = MemoryLocalStore()
        ..feed = FeedPage(items: [samplePaper])
        ..papers[samplePaper.paperId] = samplePaper
        ..connections[samplePaper.paperId] = sampleConnections;
      final repository = PaperRepository(
        api: _PolicyApiClient(),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );

      await repository.cacheFeed(
        FeedPage(items: [newerPaper]),
        replaceFeed: false,
      );

      expect(store.feed?.items.single.arxivId, samplePaper.arxivId);
      expect(store.papers[samplePaper.paperId]?.arxivId, '1706.03762v8');
      expect(store.connections, isEmpty);
    },
  );

  test('bundled derived data cannot cross an arXiv version boundary', () async {
    final store = MemoryLocalStore()
      ..papers[samplePaper.paperId] = _atVersion(samplePaper, '1706.03762v8');
    final repository = PaperRepository(
      api: _PolicyApiClient(
        introductionError: _offline(),
        connectionsError: _offline(),
        processingError: _offline(),
      ),
      localStore: store,
      demoContent: _DemoStore(preparedPaper),
    );

    await expectLater(
      repository.getIntroduction(samplePaper.paperId),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      repository.getConnections(samplePaper.paperId),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      repository.getProcessing(samplePaper.paperId),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'stale feed metadata cannot replace a newer stored paper version',
    () async {
      final newerPaper = _atVersion(samplePaper, '1706.03762v8');
      final store = MemoryLocalStore()
        ..feed = FeedPage(items: [samplePaper])
        ..papers[samplePaper.paperId] = newerPaper
        ..introductions[samplePaper.paperId] = sampleIntroduction;
      final repository = PaperRepository(
        api: _PolicyApiClient(feedError: _offline()),
        localStore: store,
        demoContent: _DemoStore(preparedPaper),
      );

      final cached = await repository.getCachedFeed();
      final offline = await repository.getFeed();

      expect(cached.value.items.single.arxivId, '1706.03762v8');
      expect(offline.value.items.single.arxivId, '1706.03762v8');
      expect(store.papers[samplePaper.paperId]?.arxivId, '1706.03762v8');
      expect(store.introductions, isNotEmpty);
    },
  );

  test('matching bundled version remains available offline', () async {
    final store = MemoryLocalStore()..papers[samplePaper.paperId] = samplePaper;
    final repository = PaperRepository(
      api: _PolicyApiClient(
        introductionError: _offline(),
        connectionsError: _offline(),
        processingError: _offline(),
      ),
      localStore: store,
      demoContent: _DemoStore(preparedPaper),
    );

    expect(
      (await repository.getIntroduction(samplePaper.paperId)).origin,
      DataOrigin.bundledDemo,
    );
    expect(
      (await repository.getConnections(samplePaper.paperId)).origin,
      DataOrigin.bundledDemo,
    );
    expect(
      (await repository.getProcessing(samplePaper.paperId)).origin,
      DataOrigin.bundledDemo,
    );
  });
}

PaperSummary _atVersion(PaperSummary paper, String arxivId) {
  final json = paper.toJson()
    ..['arxiv_id'] = arxivId
    ..['abs_url'] = 'https://arxiv.org/abs/$arxivId'
    ..['pdf_url'] = 'https://arxiv.org/pdf/$arxivId';
  return PaperSummary.fromJson(json);
}

ApiException _policyDenied() => const ApiException(
  code: 'FULLTEXT_POLICY_DENIED',
  message: 'Derived content is denied.',
  statusCode: 403,
);

ApiException _offline() => const ApiException(
  code: 'NETWORK_UNAVAILABLE',
  message: 'Offline',
  retryable: true,
  isOffline: true,
);

class _PolicyApiClient extends ApiClient {
  _PolicyApiClient({
    this.feedError,
    this.processingError,
    this.introductionError,
    this.connectionsError,
    this.introduction,
    this.paper,
  }) : super(
         baseUrl: 'http://localhost:8080',
         sessionId: '00000000-0000-4000-8000-000000000099',
       );

  final ApiException? feedError;
  final ApiException? processingError;
  final ApiException? introductionError;
  final ApiException? connectionsError;
  final PaperIntroduction? introduction;
  final PaperSummary? paper;

  @override
  Future<FeedPage> getFeed({
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) async {
    throw feedError ?? _offline();
  }

  @override
  Future<PaperSummary> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  }) async => paper ?? samplePaper;

  @override
  Future<PaperProcessingState> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    throw processingError ?? _offline();
  }

  @override
  Future<PaperIntroduction> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    if (introductionError case final error?) throw error;
    return introduction ?? sampleIntroduction;
  }

  @override
  Future<PaperConnections> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    if (connectionsError case final error?) throw error;
    return sampleConnections;
  }
}

class _DemoStore implements DemoContentStore {
  _DemoStore(this.paper);

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
  Future<PaperConnections?> loadConnections(String paperId) async =>
      paper.paperId == paperId ? sampleConnections : null;

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async =>
      paper.paperId == paperId ? sampleIntroduction : null;
}
