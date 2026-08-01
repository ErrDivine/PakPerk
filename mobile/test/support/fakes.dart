import 'dart:async';

import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/cache/feed_prefetch_config.dart';
import 'package:pakperk/core/cache/local_store.dart';
import 'package:pakperk/core/models/arxiv_identifier.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/connections.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/core/settings/appearance.dart';

final samplePaper = PaperSummary(
  paperId: '17060376-2000-4000-8000-000000000001',
  arxivId: '1706.03762v7',
  title: 'Attention Is All You Need',
  abstractText:
      'A Transformer architecture based entirely on attention mechanisms.',
  authors: const ['Ashish Vaswani', 'Noam Shazeer'],
  primaryCategory: 'cs.CL',
  categories: const ['cs.CL', 'cs.LG'],
  publishedAt: DateTime.utc(2017, 6, 12),
  updatedAt: DateTime.utc(2023, 8, 2),
  absUrl: 'https://arxiv.org/abs/1706.03762v7',
  pdfUrl: 'https://arxiv.org/pdf/1706.03762v7',
);

final sampleIntroduction = PaperIntroduction(
  paperId: samplePaper.paperId,
  generation: 1,
  heading: '1 Introduction',
  paragraphs: const [
    IntroductionParagraph(
      ordinal: 0,
      text: 'The Transformer removes recurrence from sequence modeling.',
      pageStart: 1,
      pageEnd: 1,
    ),
  ],
  detectionConfidence: .99,
  originalPdfUrl: samplePaper.pdfUrl,
);

final sampleProcessing = PaperProcessingState(
  paperId: samplePaper.paperId,
  overallState: 'ready',
  stage: ProcessingStage.ready,
  capabilities: const PaperCapabilities(
    introduction: true,
    chat: true,
    connections: true,
  ),
  retryable: false,
  updatedAt: DateTime.utc(2026, 7, 29),
);

final sampleConnections = PaperConnections(
  paperId: samplePaper.paperId,
  ready: true,
  keyConnections: const [],
  references: const [],
);

class MemoryLocalStore implements LocalStore {
  String? sessionId;
  int sessionRotations = 0;
  AppRestorationState restoration = const AppRestorationState();
  FeedPage? feed;
  final Map<String, PaperSummary> papers = {};
  final Map<String, PaperProcessingState> processing = {};
  final Map<String, PaperIntroduction> introductions = {};
  final Map<String, PaperConnections> connections = {};
  final Map<String, ChatSnapshot> chats = {};
  int accountDeletionCommentPurgeCalls = 0;
  AppAppearance appearance = AppAppearance.system;

  @override
  Future<void> clearAllLocalData() async {
    sessionId = null;
    restoration = const AppRestorationState();
    feed = null;
    papers.clear();
    processing.clear();
    introductions.clear();
    connections.clear();
    chats.clear();
    appearance = AppAppearance.system;
  }

  @override
  Future<void> purgeAccountDeletionCommentSnapshots() async {
    accountDeletionCommentPurgeCalls += 1;
  }

  @override
  Future<String> getOrCreateSessionId() async =>
      sessionId ??= '00000000-0000-4000-8000-000000000099';

  @override
  Future<String> rotateAnonymousSession() async {
    sessionRotations += 1;
    sessionId =
        '00000000-0000-4000-8000-${sessionRotations.toString().padLeft(12, '0')}';
    chats.clear();
    restoration = restoration.copyWith(
      readerStates: restoration.readerStates.map(
        (key, reader) => MapEntry(
          key,
          reader.copyWith(chatSheetOpen: false, clearChatThreadId: true),
        ),
      ),
    );
    return sessionId!;
  }

  @override
  Future<AppRestorationState> loadRestoration() async => restoration;

  @override
  Future<void> saveRestoration(AppRestorationState value) async {
    restoration = value;
  }

  @override
  Future<AppAppearance> loadAppearance() async => appearance;

  @override
  Future<void> saveAppearance(AppAppearance value) async {
    appearance = value;
  }

  @override
  Future<FeedPage?> loadFeed() async => feed;

  @override
  Future<void> saveFeed(FeedPage value) async {
    feed = value;
  }

  @override
  Future<PaperSummary?> loadPaper(String paperId) async => papers[paperId];

  @override
  Future<PaperSummary?> findPaperByArxiv(String arxivBaseId) async {
    final candidates = <PaperSummary>{...papers.values, ...?feed?.items}.where(
      (paper) => paper.arxivBaseId.toLowerCase() == arxivBaseId.toLowerCase(),
    );
    PaperSummary? latest;
    for (final paper in candidates) {
      if (latest == null || _preferPaper(paper, latest)) {
        latest = paper;
      }
    }
    return latest;
  }

  @override
  Future<void> savePaper(PaperSummary value) async {
    final current = papers[value.paperId];
    if (current != null && _preferPaper(current, value)) return;
    if (current != null && current.arxivId != value.arxivId) {
      await clearDerived(value.paperId);
      chats.removeWhere(
        (readerKey, _) => readerKey.endsWith(':${current.arxivId}'),
      );
    }
    papers[value.paperId] = value;
  }

  @override
  Future<void> clearDerived(String paperId) async {
    processing.remove(paperId);
    introductions.remove(paperId);
    connections.remove(paperId);
  }

  @override
  Future<PaperProcessingState?> loadProcessing(String paperId) async =>
      processing[paperId];

  @override
  Future<void> saveProcessing(PaperProcessingState value) async {
    processing[value.paperId] = value;
  }

  @override
  Future<PaperIntroduction?> loadIntroduction(String paperId) async =>
      introductions[paperId];

  @override
  Future<void> saveIntroduction(PaperIntroduction value) async {
    introductions[value.paperId] = value;
  }

  @override
  Future<PaperConnections?> loadConnections(String paperId) async =>
      connections[paperId];

  @override
  Future<void> saveConnections(PaperConnections value) async {
    connections[value.paperId] = value;
  }

  @override
  Future<ChatSnapshot?> loadChat(String readerKey) async => chats[readerKey];

  @override
  Future<void> saveChat(String readerKey, ChatSnapshot value) async {
    chats[readerKey] = value;
  }
}

bool _preferPaper(PaperSummary candidate, PaperSummary current) {
  if (candidate.arxivBaseId.toLowerCase() !=
      current.arxivBaseId.toLowerCase()) {
    return true;
  }
  final candidateVersion = ArxivIdentifier.tryParse(candidate.arxivId)?.version;
  final currentVersion = ArxivIdentifier.tryParse(current.arxivId)?.version;
  if ((candidateVersion ?? 0) != (currentVersion ?? 0)) {
    return (candidateVersion ?? 0) > (currentVersion ?? 0);
  }
  return candidate.updatedAt.isAfter(current.updatedAt);
}

class FakePaperDataSource implements PaperDataSource {
  FakePaperDataSource({
    this.paper,
    this.arxivPaper,
    this.processing,
    this.prepareResult,
    this.introduction,
    this.connections,
    this.chatAnswer,
  });

  PaperSummary? paper;
  PaperSummary? arxivPaper;
  PaperProcessingState? processing;
  PaperProcessingState? prepareResult;
  PaperIntroduction? introduction;
  PaperConnections? connections;
  ChatAnswer? chatAnswer;
  final Map<String, PaperSummary> papersById = {};
  int prepareCalls = 0;
  int processingCalls = 0;
  int introductionCalls = 0;
  int connectionCalls = 0;
  int paperCalls = 0;
  int paperByArxivCalls = 0;
  int feedCalls = 0;
  int chatCalls = 0;
  bool offline = false;
  DataOrigin contentOrigin = DataOrigin.network;
  Completer<RepositoryValue<FeedPage>>? networkFeedCompleter;
  Completer<RepositoryValue<FeedPage>>? cachedFeedCompleter;
  Completer<RepositoryValue<PaperSummary>>? paperByArxivCompleter;
  Completer<void>? cacheFeedCompleter;
  FeedPage? cachedFeed;
  FeedPage? networkFeed;
  final List<FeedPage> cachedFeedWrites = [];
  final List<bool> cachedFeedReplaceFlags = [];
  final List<int> cachedFeedLimits = [];
  final List<int> feedLimits = [];
  RequestCancellation? lastFeedCancellation;
  RequestCancellation? lastPaperCancellation;
  RequestCancellation? lastPaperByArxivCancellation;
  String? lastArxivId;
  RequestCancellation? lastPrepareCancellation;
  RequestCancellation? lastProcessingCancellation;
  RequestCancellation? lastIntroductionCancellation;
  RequestCancellation? lastConnectionsCancellation;
  RequestCancellation? lastChatCancellation;

  @override
  bool get isOffline => offline;

  @override
  Stream<bool> get offlineChanges => const Stream<bool>.empty();

  @override
  Future<void> cacheFeed(FeedPage value, {bool replaceFeed = true}) async {
    cachedFeedWrites.add(value);
    cachedFeedReplaceFlags.add(replaceFeed);
    await cacheFeedCompleter?.future;
  }

  @override
  Future<RepositoryValue<FeedPage>> getCachedFeed({
    String? category,
    int limit = FeedPrefetchConfig.defaultRemotePageSize,
  }) async {
    cachedFeedLimits.add(limit);
    final pending = cachedFeedCompleter;
    if (pending != null) return pending.future;
    return RepositoryValue(
      value: cachedFeed ?? FeedPage(items: [paper ?? samplePaper]),
      origin: DataOrigin.deviceCache,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<FeedPage>> getFeed({
    String? category,
    String? cursor,
    int limit = FeedPrefetchConfig.defaultRemotePageSize,
    RequestCancellation? cancellation,
  }) async {
    feedCalls += 1;
    feedLimits.add(limit);
    lastFeedCancellation = cancellation;
    if (networkFeedCompleter != null) {
      return networkFeedCompleter!.future;
    }
    return RepositoryValue(
      value: networkFeed ?? FeedPage(items: [paper ?? samplePaper]),
      origin: DataOrigin.network,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperSummary>> getPaper(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    paperCalls += 1;
    lastPaperCancellation = cancellation;
    return RepositoryValue(
      value: papersById[paperId] ?? paper ?? samplePaper,
      origin: DataOrigin.network,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperSummary>> getPaperByArxiv(
    String arxivId, {
    RequestCancellation? cancellation,
  }) async {
    paperByArxivCalls += 1;
    lastArxivId = arxivId;
    lastPaperByArxivCancellation = cancellation;
    if (paperByArxivCompleter != null) return paperByArxivCompleter!.future;
    return RepositoryValue(
      value: arxivPaper ?? paper ?? samplePaper,
      origin: DataOrigin.network,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperProcessingState>> prepare(
    String paperId, {
    bool retry = false,
    RequestCancellation? cancellation,
  }) async {
    lastPrepareCancellation = cancellation;
    prepareCalls += 1;
    return RepositoryValue(
      value: prepareResult ?? processing ?? sampleProcessing,
      origin: DataOrigin.network,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    lastProcessingCancellation = cancellation;
    processingCalls += 1;
    return RepositoryValue(
      value: processing ?? sampleProcessing,
      origin: DataOrigin.network,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperIntroduction>> getIntroduction(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    lastIntroductionCancellation = cancellation;
    introductionCalls += 1;
    return RepositoryValue(
      value: introduction ?? sampleIntroduction,
      origin: contentOrigin,
      offline: offline,
    );
  }

  @override
  Future<RepositoryValue<PaperConnections>> getConnections(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    lastConnectionsCancellation = cancellation;
    connectionCalls += 1;
    return RepositoryValue(
      value: connections ?? sampleConnections,
      origin: contentOrigin,
      offline: offline,
    );
  }

  @override
  Future<ChatAnswer> sendChat({
    required String paperId,
    required String message,
    String? threadId,
    RequestCancellation? cancellation,
  }) async {
    lastChatCancellation = cancellation;
    chatCalls += 1;
    return chatAnswer ??
        const ChatAnswer(
          answerMarkdown: 'It uses self-attention.',
          insufficientEvidence: false,
          evidence: [
            ChatEvidence(
              sectionKind: 'method',
              sectionHeading: '3 Method',
              pageStart: 4,
              pageEnd: 5,
              chunkId: 'chunk-1',
            ),
          ],
          suggestedFollowUps: [],
          threadId: 'thread-1',
        );
  }
}
