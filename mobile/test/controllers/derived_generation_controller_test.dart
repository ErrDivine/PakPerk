import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/chat/chat_controller.dart';
import 'package:pakperk/features/connections/connections_controller.dart';
import 'package:pakperk/features/introduction/introduction_controller.dart';

import '../support/fakes.dart';

void main() {
  test(
    'introduction controller clears a prior processing generation',
    () async {
      final source = FakePaperDataSource(introduction: sampleIntroduction);
      final controller = IntroductionController(
        paperId: samplePaper.paperId,
        repository: source,
      );
      addTearDown(controller.dispose);

      controller.acceptGeneration(1);
      await controller.load();
      expect(controller.state.value?.generation, 1);

      controller.acceptGeneration(2);
      expect(controller.state.value, isNull);
      source.introduction = _introductionAtGeneration(2);
      await controller.load();
      expect(controller.state.value?.generation, 2);
    },
  );

  test(
    'introduction ignores a cancellation-ignoring response from an old scope',
    () async {
      final response = Completer<RepositoryValue<PaperIntroduction>>();
      final source = _DelayedDerivedSource(introductionResponse: response);
      final controller = IntroductionController(
        paperId: samplePaper.paperId,
        repository: source,
      );
      addTearDown(controller.dispose);

      controller.acceptGeneration(1);
      final pending = controller.load();
      await _flushMicrotasks();
      final cancellation = source.lastIntroductionCancellation;

      controller.acceptGeneration(2);
      expect(cancellation?.isCancelled, isTrue);
      response.complete(
        RepositoryValue(
          value: sampleIntroduction,
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await pending;

      expect(controller.state.value, isNull);
      expect(controller.state.loading, isFalse);
      expect(controller.state.notReady, isFalse);
    },
  );

  test('connections controller clears a prior processing generation', () async {
    final source = FakePaperDataSource(connections: sampleConnections);
    final controller = ConnectionsController(
      paperId: samplePaper.paperId,
      repository: source,
    );
    addTearDown(controller.dispose);

    controller.acceptGeneration(1);
    await controller.load();
    expect(controller.state.value?.generation, 1);

    controller.acceptGeneration(2);
    expect(controller.state.value, isNull);
    source.connections = const PaperConnections(
      paperId: '17060376-2000-4000-8000-000000000001',
      generation: 2,
      ready: false,
      keyConnections: [],
      references: [],
    );
    await controller.load();
    expect(controller.state.value?.generation, 2);
  });

  test(
    'connections ignores a cancellation-ignoring response from an old scope',
    () async {
      final response = Completer<RepositoryValue<PaperConnections>>();
      final source = _DelayedDerivedSource(connectionsResponse: response);
      final controller = ConnectionsController(
        paperId: samplePaper.paperId,
        repository: source,
      );
      addTearDown(controller.dispose);

      controller.acceptGeneration(1);
      final pending = controller.load();
      await _flushMicrotasks();
      final cancellation = source.lastConnectionsCancellation;

      controller.acceptGeneration(2);
      expect(cancellation?.isCancelled, isTrue);
      response.complete(
        RepositoryValue(
          value: sampleConnections,
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await pending;

      expect(controller.state.value, isNull);
      expect(controller.state.loading, isFalse);
      expect(controller.state.notReady, isFalse);
    },
  );

  test(
    'chat rejects a response outside the accepted processing generation',
    () async {
      final readerKey = 'feed:${samplePaper.paperId}:${samplePaper.arxivId}';
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = sampleProcessing
        ..chats[readerKey] = ChatSnapshot(
          threadId: 'generation-1-thread',
          generation: 1,
          messages: [
            ChatMessage(
              id: 'old-answer',
              role: ChatRole.assistant,
              content: 'Old generation answer',
              createdAt: DateTime.utc(2026, 7, 31),
            ),
          ],
        );
      final source = FakePaperDataSource(
        chatAnswer: const ChatAnswer(
          answerMarkdown: 'New generation answer',
          insufficientEvidence: false,
          evidence: [],
          suggestedFollowUps: [],
          generation: 2,
          threadId: 'generation-2-thread',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          paperRepositoryProvider.overrideWithValue(source),
          clientFulltextPolicyProvider.overrideWithValue(
            ClientFulltextPolicy.prototype,
          ),
        ],
      );
      addTearDown(container.dispose);
      final args = ChatControllerArgs(
        paperId: samplePaper.paperId,
        readerKey: readerKey,
      );
      final subscription = container.listen(
        chatControllerProvider(args),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final controller = container.read(chatControllerProvider(args).notifier);

      // An initial processing observation must constrain the pending restore,
      // not overwrite a valid transcript with an empty snapshot. Sending is
      // also blocked until restoration has made that transcript authoritative.
      await controller.send('Too early');
      controller.acceptGeneration(1);
      await _flushMicrotasks();
      expect(source.chatCalls, 0);
      expect(
        container.read(chatControllerProvider(args)).messages.single.content,
        'Old generation answer',
      );

      await controller.send('Why?');
      final state = container.read(chatControllerProvider(args));

      expect(state.generation, 1);
      expect(state.threadId, 'generation-1-thread');
      expect(state.messages.map((message) => message.content), [
        'Old generation answer',
        'Why?',
      ]);
      expect(state.errorMessage, contains('changed generation'));
      expect(store.chats[readerKey]?.generation, 1);
    },
  );

  test(
    'chat without a transcript uses the restored processing generation',
    () async {
      final readerKey = 'feed:${samplePaper.paperId}:${samplePaper.arxivId}';
      final store = MemoryLocalStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = sampleProcessing;
      final source = FakePaperDataSource();
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          paperRepositoryProvider.overrideWithValue(source),
          clientFulltextPolicyProvider.overrideWithValue(
            ClientFulltextPolicy.prototype,
          ),
        ],
      );
      addTearDown(container.dispose);
      final args = ChatControllerArgs(
        paperId: samplePaper.paperId,
        readerKey: readerKey,
      );
      final subscription = container.listen(
        chatControllerProvider(args),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final controller = container.read(chatControllerProvider(args).notifier);
      await _flushMicrotasks();

      await controller.send('Why attention?');

      final state = container.read(chatControllerProvider(args));
      expect(source.chatCalls, 1);
      expect(state.generation, 1);
      expect(state.messages.map((message) => message.content), [
        'Why attention?',
        'It uses self-attention.',
      ]);
      expect(state.errorMessage, isNull);
    },
  );

  test(
    'chat generation change during delayed persistence aborts before dispatch',
    () async {
      final readerKey = 'feed:${samplePaper.paperId}:${samplePaper.arxivId}';
      final store = _DelayedChatStore()
        ..papers[samplePaper.paperId] = samplePaper
        ..processing[samplePaper.paperId] = sampleProcessing
        ..chats[readerKey] = const ChatSnapshot(
          threadId: 'generation-1-thread',
          generation: 1,
        );
      final source = FakePaperDataSource();
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          paperRepositoryProvider.overrideWithValue(source),
          clientFulltextPolicyProvider.overrideWithValue(
            ClientFulltextPolicy.prototype,
          ),
        ],
      );
      addTearDown(container.dispose);
      final args = ChatControllerArgs(
        paperId: samplePaper.paperId,
        readerKey: readerKey,
      );
      final subscription = container.listen(
        chatControllerProvider(args),
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final controller = container.read(chatControllerProvider(args).notifier);
      controller.acceptGeneration(1);
      await _flushMicrotasks();

      store.delayNextChatSave();
      final pending = controller.send('Question for generation one');
      await _flushMicrotasks();
      expect(store.delayedSaveStarted, isTrue);

      store.processing[samplePaper.paperId] = _processingAtGeneration(2);
      controller.acceptGeneration(2);
      store.releaseDelayedSave();
      await pending;
      await _flushMicrotasks();

      final state = container.read(chatControllerProvider(args));
      expect(source.chatCalls, 0);
      expect(source.lastChatCancellation, isNull);
      expect(state.generation, 2);
      expect(state.messages, isEmpty);
      expect(state.sending, isFalse);
      expect(store.chats[readerKey]?.generation, 2);
    },
  );
}

PaperIntroduction _introductionAtGeneration(int generation) =>
    PaperIntroduction.fromJson(
      sampleIntroduction.toJson()..['generation'] = generation,
    );

PaperProcessingState _processingAtGeneration(int generation) =>
    PaperProcessingState.fromJson(
      sampleProcessing.toJson()..['generation'] = generation,
    );

class _DelayedDerivedSource extends FakePaperDataSource {
  _DelayedDerivedSource({this.introductionResponse, this.connectionsResponse});

  final Completer<RepositoryValue<PaperIntroduction>>? introductionResponse;
  final Completer<RepositoryValue<PaperConnections>>? connectionsResponse;

  @override
  Future<RepositoryValue<PaperIntroduction>> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) {
    introductionCalls += 1;
    lastIntroductionCancellation = cancellation;
    return introductionResponse?.future ??
        super.getIntroduction(paperId, cancellation: cancellation);
  }

  @override
  Future<RepositoryValue<PaperConnections>> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) {
    connectionCalls += 1;
    lastConnectionsCancellation = cancellation;
    return connectionsResponse?.future ??
        super.getConnections(paperId, cancellation: cancellation);
  }
}

class _DelayedChatStore extends MemoryLocalStore {
  Completer<void>? _chatSaveGate;
  bool _delayNextChatSave = false;
  bool delayedSaveStarted = false;

  void delayNextChatSave() {
    _chatSaveGate = Completer<void>();
    _delayNextChatSave = true;
    delayedSaveStarted = false;
  }

  void releaseDelayedSave() => _chatSaveGate?.complete();

  @override
  Future<void> saveChat(String readerKey, ChatSnapshot value) async {
    if (_delayNextChatSave) {
      _delayNextChatSave = false;
      delayedSaveStarted = true;
      await _chatSaveGate!.future;
    }
    final currentGeneration = processing[samplePaper.paperId]?.generation;
    if (currentGeneration != value.generation) return;
    await super.saveChat(readerKey, value);
  }
}

Future<void> _flushMicrotasks() async {
  for (var index = 0; index < 4; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
