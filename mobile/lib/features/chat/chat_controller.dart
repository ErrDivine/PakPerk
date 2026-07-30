import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/cache/local_store.dart';
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
    this.restoring = true,
    this.sending = false,
    this.offline = false,
    this.errorMessage,
  });

  final String? threadId;
  final List<ChatMessage> messages;
  final bool restoring;
  final bool sending;
  final bool offline;
  final String? errorMessage;

  ChatState copyWith({
    String? threadId,
    bool clearThreadId = false,
    List<ChatMessage>? messages,
    bool? restoring,
    bool? sending,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
  }) =>
      ChatState(
        threadId: clearThreadId ? null : threadId ?? this.threadId,
        messages: messages ?? this.messages,
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
    allowDerivedDeviceFallback:
        ref.watch(clientFulltextPolicyProvider).allowsDerivedDeviceFallback,
  );
});

class ChatController extends StateNotifier<ChatState> {
  ChatController({
    required this.args,
    required PaperDataSource repository,
    required LocalStore store,
    required PaperReaderNavigationController readerNavigation,
    required bool allowDerivedDeviceFallback,
  })  : _repository = repository,
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
  final RequestCancellation _requests = RequestCancellation();

  Future<void> _restore() async {
    final snapshot = await loadRestorableChatSnapshot(
      store: _store,
      readerKey: args.readerKey,
      allowDerivedDeviceFallback: _allowDerivedDeviceFallback,
    );
    if (!mounted) return;
    state = state.copyWith(
      threadId: snapshot?.threadId,
      messages: snapshot?.messages ?? const [],
      restoring: false,
    );
  }

  Future<void> send(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || state.sending) return;
    final safeMessage =
        message.length > 500 ? message.substring(0, 500) : message;
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

    try {
      final answer = await _repository.sendChat(
        paperId: args.paperId,
        message: safeMessage,
        threadId: state.threadId,
        cancellation: _requests,
      );
      if (!mounted) return;
      final assistant = ChatMessage(
        id: const Uuid().v4(),
        role: ChatRole.assistant,
        content: answer.answerMarkdown,
        createdAt: DateTime.now().toUtc(),
        evidence: answer.evidence,
        insufficientEvidence: answer.insufficientEvidence,
      );
      final threadId = answer.threadId ?? state.threadId;
      state = state.copyWith(
        threadId: threadId,
        messages: _lastSixTurns([...state.messages, assistant]),
        sending: false,
        offline: false,
      );
      _readerNavigation.setChatThreadId(threadId);
      await _persist();
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
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
    return _store.saveChat(
      args.readerKey,
      ChatSnapshot(threadId: state.threadId, messages: state.messages),
    );
  }

  @override
  void dispose() {
    _requests.cancel('The paper chat was closed.');
    super.dispose();
  }
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
