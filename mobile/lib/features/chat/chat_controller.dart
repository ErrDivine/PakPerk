import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/cache/local_store.dart';
import '../../core/cache/versioned_derived_cache.dart';
import '../../core/models/chat.dart';
import '../../core/providers.dart';
import '../../core/repository/paper_repository.dart';
import '../paper_reader/reader_navigation_controller.dart';

class ChatControllerArgs {
  const ChatControllerArgs({required this.paperId, required this.readerKey});

  final String paperId;
  final String readerKey;

  @override
  bool operator ==(Object other) =>
      other is ChatControllerArgs &&
      other.paperId == paperId &&
      other.readerKey == readerKey;

  @override
  int get hashCode => Object.hash(paperId, readerKey);
}

class ChatState {
  const ChatState({
    this.threadId,
    this.messages = const [],
    this.generation,
    this.restoring = true,
    this.sending = false,
    this.offline = false,
    this.errorMessage,
  });

  final String? threadId;
  final List<ChatMessage> messages;
  final int? generation;
  final bool restoring;
  final bool sending;
  final bool offline;
  final String? errorMessage;

  ChatState copyWith({
    String? threadId,
    bool clearThreadId = false,
    List<ChatMessage>? messages,
    int? generation,
    bool clearGeneration = false,
    bool? restoring,
    bool? sending,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
  }) => ChatState(
    threadId: clearThreadId ? null : threadId ?? this.threadId,
    messages: messages ?? this.messages,
    generation: clearGeneration ? null : generation ?? this.generation,
    restoring: restoring ?? this.restoring,
    sending: sending ?? this.sending,
    offline: offline ?? this.offline,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final chatControllerProvider = StateNotifierProvider.autoDispose
    .family<ChatController, ChatState, ChatControllerArgs>((ref, args) {
      return ChatController(
        args: args,
        repository: ref.watch(paperRepositoryProvider),
        store: ref.watch(localStoreProvider),
        readerNavigation: ref.watch(
          paperReaderNavigationControllerProvider(args.readerKey),
        ),
        allowDerivedDeviceFallback: ref
            .watch(clientFulltextPolicyProvider)
            .allowsDerivedDeviceFallback,
      );
    });

class ChatController extends StateNotifier<ChatState> {
  ChatController({
    required this.args,
    required PaperDataSource repository,
    required LocalStore store,
    required PaperReaderNavigationController readerNavigation,
    required bool allowDerivedDeviceFallback,
  }) : _repository = repository,
       _store = store,
       _readerNavigation = readerNavigation,
       _allowDerivedDeviceFallback = allowDerivedDeviceFallback,
       super(const ChatState()) {
    unawaited(_restore());
  }

  final ChatControllerArgs args;
  final PaperDataSource _repository;
  final LocalStore _store;
  final PaperReaderNavigationController _readerNavigation;
  final bool _allowDerivedDeviceFallback;
  RequestCancellation? _requests;
  int? _expectedGeneration;
  int _scopeRevision = 0;

  Future<void> _restore() async {
    final snapshot = await loadRestorableChatSnapshot(
      store: _store,
      readerKey: args.readerKey,
      allowDerivedDeviceFallback: _allowDerivedDeviceFallback,
    );
    final processing = await _store.loadProcessing(args.paperId);
    if (!mounted) return;
    final expectedGeneration = _expectedGeneration;
    final processingGeneration = switch (processing?.generation) {
      final generation? when generation > 0 => generation,
      _ => null,
    };
    if (snapshot == null ||
        snapshot.generation == null ||
        (expectedGeneration != null
            ? snapshot.generation != expectedGeneration
            : processingGeneration != null &&
                  snapshot.generation != processingGeneration)) {
      _expectedGeneration ??= processingGeneration;
      state = state.copyWith(generation: _expectedGeneration, restoring: false);
      return;
    }
    _expectedGeneration ??= snapshot.generation;
    state = state.copyWith(
      threadId: snapshot.threadId,
      messages: snapshot.messages,
      generation: snapshot.generation,
      restoring: false,
    );
  }

  /// Clears every generation-scoped transcript surface synchronously.
  void acceptGeneration(int generation) {
    if (generation <= 0) return;
    final previousGeneration = _expectedGeneration ?? state.generation;
    _expectedGeneration = generation;
    if (previousGeneration == generation) return;
    _scopeRevision += 1;
    if (previousGeneration == null) {
      // Constrain an in-flight restore without manufacturing or overwriting a
      // transcript merely because processing was observed for the first time.
      if (!state.restoring) state = state.copyWith(generation: generation);
      return;
    }
    _requests?.cancel('The paper processing generation changed.');
    state = ChatState(generation: generation, restoring: false);
    _readerNavigation.setChatThreadId(null);
    unawaited(_persist());
  }

  Future<void> send(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || state.restoring || state.sending) return;
    final expectedGeneration = _expectedGeneration ?? state.generation;
    if (expectedGeneration == null || expectedGeneration <= 0) return;
    final scopeRevision = _scopeRevision;
    final request = _activeRequests;
    final threadId = state.threadId;
    final safeMessage = message.length > 500
        ? message.substring(0, 500)
        : message;
    final userMessage = ChatMessage(
      id: const Uuid().v4(),
      role: ChatRole.user,
      content: safeMessage,
      createdAt: DateTime.now().toUtc(),
    );
    state = state.copyWith(
      messages: _lastSixTurns([...state.messages, userMessage]),
      sending: true,
      clearError: true,
    );
    await _persist();
    if (!_isCurrentScope(scopeRevision, expectedGeneration, request)) return;

    try {
      final answer = await _repository.sendChat(
        paperId: args.paperId,
        message: safeMessage,
        threadId: threadId,
        cancellation: request,
      );
      if (!_isCurrentScope(scopeRevision, expectedGeneration, request)) return;
      final assistant = ChatMessage(
        id: const Uuid().v4(),
        role: ChatRole.assistant,
        content: answer.answerMarkdown,
        createdAt: DateTime.now().toUtc(),
        evidence: answer.evidence,
        insufficientEvidence: answer.insufficientEvidence,
      );
      if (answer.generation != expectedGeneration) {
        throw const ApiException(
          code: 'STALE_PAPER_VERSION',
          message: 'The paper changed generation while chat was answering.',
          retryable: true,
          statusCode: 409,
        );
      }
      final nextThreadId = answer.threadId ?? state.threadId;
      state = state.copyWith(
        threadId: nextThreadId,
        clearThreadId: nextThreadId == null,
        messages: _lastSixTurns([...state.messages, assistant]),
        generation: answer.generation,
        sending: false,
        offline: false,
      );
      _readerNavigation.setChatThreadId(nextThreadId);
      await _persist();
    } on ApiException catch (error) {
      if (error.cancelled ||
          !_isCurrentScope(scopeRevision, expectedGeneration, request)) {
        return;
      }
      state = state.copyWith(
        sending: false,
        offline: error.isOffline,
        errorMessage: error.isOffline
            ? 'You’re offline. Reconnect to ask a new question.'
            : error.code.contains('MODEL') || error.code.contains('LLM')
            ? 'Paper chat is temporarily unavailable. The introduction and connections still work.'
            : error.message,
      );
      await _persist();
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  List<ChatMessage> _lastSixTurns(List<ChatMessage> messages) {
    const maximumMessages = 12;
    if (messages.length <= maximumMessages) return messages;
    return messages.sublist(messages.length - maximumMessages);
  }

  Future<void> _persist() {
    if (!_allowDerivedDeviceFallback) return Future<void>.value();
    final generation = state.generation;
    if (generation == null || generation <= 0) return Future<void>.value();
    final snapshot = ChatSnapshot(
      threadId: state.threadId,
      messages: state.messages,
      generation: generation,
    );
    final store = _store;
    if (store is GenerationScopedChatCache) {
      return _persistGenerationScopedChat(
        store as GenerationScopedChatCache,
        snapshot,
        generation,
      );
    }
    return store.saveChat(args.readerKey, snapshot);
  }

  Future<void> _persistGenerationScopedChat(
    GenerationScopedChatCache store,
    ChatSnapshot snapshot,
    int generation,
  ) async {
    final paper = await _store.loadPaper(args.paperId);
    if (paper == null || paper.paperId != args.paperId) return;
    await store.saveChatForGeneration(
      args.readerKey,
      snapshot,
      expectedVersionKey: paper.versionKey,
      expectedGeneration: generation,
    );
  }

  @override
  void dispose() {
    _requests?.cancel('The paper chat was closed.');
    super.dispose();
  }

  RequestCancellation get _activeRequests {
    final current = _requests;
    if (current != null && !current.isCancelled) return current;
    return _requests = RequestCancellation();
  }

  bool _isCurrentScope(
    int revision,
    int generation,
    RequestCancellation request,
  ) =>
      mounted &&
      revision == _scopeRevision &&
      _expectedGeneration == generation &&
      identical(_requests, request) &&
      !request.isCancelled;
}

Future<ChatSnapshot?> loadRestorableChatSnapshot({
  required LocalStore store,
  required String readerKey,
  required bool allowDerivedDeviceFallback,
}) {
  if (!allowDerivedDeviceFallback) {
    return Future<ChatSnapshot?>.value();
  }
  return store.loadChat(readerKey);
}
