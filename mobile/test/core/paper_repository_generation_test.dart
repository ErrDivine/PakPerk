import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_client.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/demo_asset_store.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/repository/paper_repository.dart';

import '../support/fakes.dart';

void main() {
  test(
    'repository rejects every response older than cached processing',
    () async {
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = _processingAtGeneration(2);
      final repository = PaperRepository(
        api: _GenerationApiClient(
          introduction: sampleIntroduction,
          connections: sampleConnections,
          chat: const ChatAnswer(
            answerMarkdown: 'Stale answer',
            insufficientEvidence: false,
            evidence: [],
            suggestedFollowUps: [],
            generation: 1,
          ),
        ),
        localStore: store,
        demoContent: const _EmptyDemoStore(),
      );
      addTearDown(repository.dispose);

      for (final request in <Future<Object> Function()>[
        () => repository.getIntroduction(samplePaper.paperId),
        () => repository.getConnections(samplePaper.paperId),
        () =>
            repository.sendChat(paperId: samplePaper.paperId, message: 'Why?'),
      ]) {
        await expectLater(
          request(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'STALE_PAPER_VERSION',
            ),
          ),
        );
      }
      expect(store.introductions, isEmpty);
      expect(store.connections, isEmpty);
    },
  );

  test(
    'newer server generation is published but not cached without status',
    () async {
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = sampleProcessing;
      final introduction = _introductionAtGeneration(2);
      final repository = PaperRepository(
        api: _GenerationApiClient(introduction: introduction),
        localStore: store,
        demoContent: const _EmptyDemoStore(),
      );
      addTearDown(repository.dispose);

      final result = await repository.getIntroduction(samplePaper.paperId);

      expect(result.value.generation, 2);
      expect(result.origin, DataOrigin.network);
      expect(store.introductions, isEmpty);
    },
  );
}

PaperProcessingState _processingAtGeneration(int generation) =>
    PaperProcessingState.fromJson(
      sampleProcessing.toJson()..['generation'] = generation,
    );

PaperIntroduction _introductionAtGeneration(int generation) =>
    PaperIntroduction.fromJson(
      sampleIntroduction.toJson()..['generation'] = generation,
    );

class _GenerationApiClient extends ApiClient {
  _GenerationApiClient({this.introduction, this.connections, this.chat})
    : super(
        baseUrl: 'http://localhost:8080',
        sessionId: '00000000-0000-4000-8000-000000000001',
      );

  final PaperIntroduction? introduction;
  final PaperConnections? connections;
  final ChatAnswer? chat;

  @override
  Future<PaperIntroduction> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) async => introduction ?? sampleIntroduction;

  @override
  Future<PaperConnections> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) async => connections ?? sampleConnections;

  @override
  Future<ChatAnswer> sendChat({
    required String paperId,
    required String message,
    String? threadId,
    RequestCancellation? cancellation,
  }) async =>
      chat ??
      const ChatAnswer(
        answerMarkdown: 'Current answer',
        insufficientEvidence: false,
        evidence: [],
        suggestedFollowUps: [],
      );
}

class _EmptyDemoStore implements DemoContentStore {
  const _EmptyDemoStore();

  @override
  Future<PaperSummary?> findFallbackPaper(String paperId) async => null;

  @override
  Future<PaperSummary?> findFallbackPaperByArxiv(String arxivBaseId) async =>
      null;

  @override
  Future<FeedPage> loadFallbackFeed() async => const FeedPage(items: []);

  @override
  Future<PaperConnections?> loadConnections(String paperId) async => null;

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async => null;
}
