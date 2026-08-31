import 'paper.dart';
import '../../features/document_reader/reader_entry_context.dart';
import '../../features/reader_modes/reader_mode.dart';
import 'semantic_span.dart';

String feedReaderKey(PaperSummary paper) =>
    'feed:${paper.paperId}:${paper.arxivId}';

String routeReaderKey(String routeId, PaperSummary paper) =>
    'route:$routeId:${paper.arxivId}';

enum AppBranch {
  read,
  you,
  library;

  /// Persistence indexes deliberately keep the v0.0 `Read = 0, You = 1`
  /// mapping. The visible shell order is a separate concern so adding Library
  /// cannot restore an older user's saved You session into the wrong account.
  static AppBranch fromIndex(int index) => switch (index) {
    1 => AppBranch.you,
    2 => AppBranch.library,
    _ => AppBranch.read,
  };

  /// The visible v0.1 destination order: Read, Library, You.
  int get shellIndex => switch (this) {
    AppBranch.read => 0,
    AppBranch.library => 1,
    AppBranch.you => 2,
  };

  static AppBranch fromShellIndex(int index) => switch (index) {
    1 => AppBranch.library,
    2 => AppBranch.you,
    _ => AppBranch.read,
  };
}

enum PaperStage {
  abstractView,
  introduction,
  connections;

  String get label => switch (this) {
    PaperStage.abstractView => 'Abstract',
    PaperStage.introduction => 'Introduction',
    PaperStage.connections => 'Connections',
  };

  static PaperStage fromIndex(int value) =>
      PaperStage.values[value.clamp(0, PaperStage.values.length - 1)];
}

class ReaderNavigationState {
  const ReaderNavigationState({
    this.stageIndex = 0,
    this.abstractOffset = 0,
    this.introductionOffset = 0,
    this.connectionsOffset = 0,
    this.chatSheetOpen = false,
    this.chatThreadId,
    this.prepareRequested = false,
    this.depthMode = ReaderDepthMode.skim,
    this.semanticDensity = SemanticDensity.key,
    this.checkpointBlockId,
    this.checkpointScrollFraction,
  });

  final int stageIndex;
  final double abstractOffset;
  final double introductionOffset;
  final double connectionsOffset;
  final bool chatSheetOpen;
  final String? chatThreadId;
  final bool prepareRequested;
  final ReaderDepthMode depthMode;
  final SemanticDensity semanticDensity;

  /// Exact server-checkpoint anchors are private, account-owned state.
  ///
  /// They may live in memory while the verified account is active, but
  /// [toJson] deliberately does not place them in the unscoped application
  /// restoration record. Account-scoped Drift storage remains authoritative
  /// across launches.
  final String? checkpointBlockId;
  final double? checkpointScrollFraction;

  double offsetFor(PaperStage stage) => switch (stage) {
    PaperStage.abstractView => abstractOffset,
    PaperStage.introduction => introductionOffset,
    PaperStage.connections => connectionsOffset,
  };

  ReaderNavigationState copyWith({
    int? stageIndex,
    double? abstractOffset,
    double? introductionOffset,
    double? connectionsOffset,
    bool? chatSheetOpen,
    String? chatThreadId,
    bool clearChatThreadId = false,
    bool? prepareRequested,
    ReaderDepthMode? depthMode,
    SemanticDensity? semanticDensity,
    String? checkpointBlockId,
    bool clearCheckpointBlockId = false,
    double? checkpointScrollFraction,
    bool clearCheckpointScrollFraction = false,
  }) => ReaderNavigationState(
    stageIndex: stageIndex ?? this.stageIndex,
    abstractOffset: abstractOffset ?? this.abstractOffset,
    introductionOffset: introductionOffset ?? this.introductionOffset,
    connectionsOffset: connectionsOffset ?? this.connectionsOffset,
    chatSheetOpen: chatSheetOpen ?? this.chatSheetOpen,
    chatThreadId: clearChatThreadId ? null : chatThreadId ?? this.chatThreadId,
    prepareRequested: prepareRequested ?? this.prepareRequested,
    depthMode: depthMode ?? this.depthMode,
    semanticDensity: semanticDensity ?? this.semanticDensity,
    checkpointBlockId: clearCheckpointBlockId
        ? null
        : checkpointBlockId ?? this.checkpointBlockId,
    checkpointScrollFraction: clearCheckpointScrollFraction
        ? null
        : checkpointScrollFraction ?? this.checkpointScrollFraction,
  );

  factory ReaderNavigationState.fromJson(
    Map<String, dynamic> json,
  ) => ReaderNavigationState(
    stageIndex: (json['stage_index'] as num?)?.toInt() ?? 0,
    abstractOffset: (json['abstract_offset'] as num?)?.toDouble() ?? 0,
    introductionOffset: (json['introduction_offset'] as num?)?.toDouble() ?? 0,
    connectionsOffset: (json['connections_offset'] as num?)?.toDouble() ?? 0,
    chatSheetOpen: json['chat_sheet_open'] as bool? ?? false,
    chatThreadId: json['chat_thread_id']?.toString(),
    prepareRequested: json['prepare_requested'] as bool? ?? false,
    depthMode: ReaderDepthMode.fromWire(json['depth_mode']),
    semanticDensity: SemanticDensity.fromRestoration(json['semantic_density']),
    // Older Plan 03 development builds wrote exact account-owned checkpoint
    // anchors into this unscoped record. Ignore them on decode so an upgrade
    // cannot revive one account's position under another identity.
    checkpointBlockId: null,
    checkpointScrollFraction: null,
  );

  Map<String, dynamic> toJson() => {
    'stage_index': stageIndex,
    'abstract_offset': abstractOffset,
    'introduction_offset': introductionOffset,
    'connections_offset': connectionsOffset,
    'chat_sheet_open': chatSheetOpen,
    if (chatThreadId != null) 'chat_thread_id': chatThreadId,
    'prepare_requested': prepareRequested,
    'depth_mode': depthMode.wireValue,
    'semantic_density': semanticDensity.wireValue,
  };
}

class PaperRouteEntry {
  const PaperRouteEntry({
    required this.routeId,
    required this.paper,
    this.entryContext = const ReaderEntryContext.external(),
  });

  final String routeId;
  final PaperSummary paper;
  final ReaderEntryContext entryContext;

  String get readerKey => routeReaderKey(routeId, paper);

  factory PaperRouteEntry.fromJson(Map<String, dynamic> json) =>
      PaperRouteEntry(
        routeId: (json['route_id'] ?? '').toString(),
        paper: PaperSummary.fromJson(
          Map<String, dynamic>.from(json['paper'] as Map),
        ),
        entryContext: switch (json['entry_context']) {
          final Map value => ReaderEntryContext.fromJson(
            Map<String, dynamic>.from(value),
          ),
          _ => const ReaderEntryContext.external(),
        },
      );

  Map<String, dynamic> toJson() => {
    'route_id': routeId,
    'paper': paper.toJson(),
    'entry_context': entryContext.toJson(),
  };
}

class AppRestorationState {
  const AppRestorationState({
    this.activeBranchIndex = 0,
    this.feedIndex = 0,
    this.feedPaperId,
    this.feedArxivId,
    this.routeStack = const [],
    this.readerStates = const {},
  }) : assert(
         (feedPaperId == null) == (feedArxivId == null),
         'Feed paper identity and version must be persisted together.',
       );

  /// The selected root destination persistence index.
  ///
  /// `0` is Read, `1` remains You for v0.0 compatibility, and `2` is Library.
  ///
  /// Keeping this alongside the reader state gives the application a small,
  /// deterministic fallback when platform Navigator restoration is not
  /// available (for example after a process restart from a launcher icon).
  final int activeBranchIndex;
  AppBranch get activeBranch => AppBranch.fromIndex(activeBranchIndex);
  final int feedIndex;
  final String? feedPaperId;
  final String? feedArxivId;
  final List<PaperRouteEntry> routeStack;
  final Map<String, ReaderNavigationState> readerStates;

  ReaderNavigationState readerState(String readerKey) =>
      readerStates[readerKey] ?? const ReaderNavigationState();

  AppRestorationState copyWith({
    int? activeBranchIndex,
    int? feedIndex,
    String? feedPaperId,
    String? feedArxivId,
    bool clearFeedPaperReference = false,
    List<PaperRouteEntry>? routeStack,
    Map<String, ReaderNavigationState>? readerStates,
  }) => AppRestorationState(
    activeBranchIndex: activeBranchIndex ?? this.activeBranchIndex,
    feedIndex: feedIndex ?? this.feedIndex,
    feedPaperId: clearFeedPaperReference
        ? null
        : feedPaperId ?? this.feedPaperId,
    feedArxivId: clearFeedPaperReference
        ? null
        : feedArxivId ?? this.feedArxivId,
    routeStack: routeStack ?? this.routeStack,
    readerStates: readerStates ?? this.readerStates,
  );

  factory AppRestorationState.fromJson(Map<String, dynamic> json) {
    final rawReaders = json['reader_states'];
    final rawFeedPaperId = json['feed_paper_id']?.toString().trim();
    final rawFeedArxivId = json['feed_arxiv_id']?.toString().trim();
    final hasFeedReference =
        rawFeedPaperId != null &&
        rawFeedPaperId.isNotEmpty &&
        rawFeedArxivId != null &&
        rawFeedArxivId.isNotEmpty;
    return AppRestorationState(
      activeBranchIndex: _restoredBranchIndex(json['active_branch_index']),
      feedIndex: (json['feed_index'] as num?)?.toInt() ?? 0,
      feedPaperId: hasFeedReference ? rawFeedPaperId : null,
      feedArxivId: hasFeedReference ? rawFeedArxivId : null,
      routeStack: (json['route_stack'] as List<dynamic>? ?? const [])
          .map(
            (value) => PaperRouteEntry.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where((entry) => entry.routeId.isNotEmpty)
          .toList(growable: false),
      readerStates: rawReaders is Map
          ? rawReaders.map(
              (key, value) => MapEntry(
                key.toString(),
                ReaderNavigationState.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              ),
            )
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'active_branch_index': activeBranchIndex,
    'feed_index': feedIndex,
    if (feedPaperId != null && feedArxivId != null) ...{
      'feed_paper_id': feedPaperId,
      'feed_arxiv_id': feedArxivId,
    },
    'route_stack': routeStack
        .map((entry) => entry.toJson())
        .toList(growable: false),
    'reader_states': readerStates.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };
}

int _restoredBranchIndex(Object? value) {
  final index = value is num ? value.toInt() : 0;
  return switch (index) {
    1 => 1,
    2 => 2,
    _ => 0,
  };
}

/// Pure committed-page gate used by the reader and unit-tested independently.
class PrepareIntentGate {
  PrepareIntentGate({bool alreadyRequested = false})
    : _requested = alreadyRequested;

  bool _requested;
  bool get requested => _requested;

  bool onCommittedPage(int pageIndex) {
    if (pageIndex != PaperStage.introduction.index || _requested) {
      return false;
    }
    _requested = true;
    return true;
  }
}
