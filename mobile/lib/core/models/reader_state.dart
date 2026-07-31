import 'paper.dart';

String feedReaderKey(PaperSummary paper) =>
    'feed:${paper.paperId}:${paper.arxivId}';

String routeReaderKey(String routeId, PaperSummary paper) =>
    'route:$routeId:${paper.arxivId}';

enum AppBranch {
  read,
  you;

  static AppBranch fromIndex(int index) =>
      index == AppBranch.you.index ? AppBranch.you : AppBranch.read;
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
  });

  final int stageIndex;
  final double abstractOffset;
  final double introductionOffset;
  final double connectionsOffset;
  final bool chatSheetOpen;
  final String? chatThreadId;
  final bool prepareRequested;

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
  }) =>
      ReaderNavigationState(
        stageIndex: stageIndex ?? this.stageIndex,
        abstractOffset: abstractOffset ?? this.abstractOffset,
        introductionOffset: introductionOffset ?? this.introductionOffset,
        connectionsOffset: connectionsOffset ?? this.connectionsOffset,
        chatSheetOpen: chatSheetOpen ?? this.chatSheetOpen,
        chatThreadId:
            clearChatThreadId ? null : chatThreadId ?? this.chatThreadId,
        prepareRequested: prepareRequested ?? this.prepareRequested,
      );

  factory ReaderNavigationState.fromJson(
    Map<String, dynamic> json,
  ) =>
      ReaderNavigationState(
        stageIndex: (json['stage_index'] as num?)?.toInt() ?? 0,
        abstractOffset: (json['abstract_offset'] as num?)?.toDouble() ?? 0,
        introductionOffset:
            (json['introduction_offset'] as num?)?.toDouble() ?? 0,
        connectionsOffset:
            (json['connections_offset'] as num?)?.toDouble() ?? 0,
        chatSheetOpen: json['chat_sheet_open'] as bool? ?? false,
        chatThreadId: json['chat_thread_id']?.toString(),
        prepareRequested: json['prepare_requested'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'stage_index': stageIndex,
        'abstract_offset': abstractOffset,
        'introduction_offset': introductionOffset,
        'connections_offset': connectionsOffset,
        'chat_sheet_open': chatSheetOpen,
        if (chatThreadId != null) 'chat_thread_id': chatThreadId,
        'prepare_requested': prepareRequested,
      };
}

class PaperRouteEntry {
  const PaperRouteEntry({required this.routeId, required this.paper});

  final String routeId;
  final PaperSummary paper;

  String get readerKey => routeReaderKey(routeId, paper);

  factory PaperRouteEntry.fromJson(Map<String, dynamic> json) =>
      PaperRouteEntry(
        routeId: (json['route_id'] ?? '').toString(),
        paper: PaperSummary.fromJson(
          Map<String, dynamic>.from(json['paper'] as Map),
        ),
      );

  Map<String, dynamic> toJson() => {
        'route_id': routeId,
        'paper': paper.toJson(),
      };
}

class AppRestorationState {
  const AppRestorationState({
    this.activeBranchIndex = 0,
    this.feedIndex = 0,
    this.routeStack = const [],
    this.readerStates = const {},
  });

  /// The selected root destination: `0` for Read and `1` for You.
  ///
  /// Keeping this alongside the reader state gives the application a small,
  /// deterministic fallback when platform Navigator restoration is not
  /// available (for example after a process restart from a launcher icon).
  final int activeBranchIndex;
  AppBranch get activeBranch => AppBranch.fromIndex(activeBranchIndex);
  final int feedIndex;
  final List<PaperRouteEntry> routeStack;
  final Map<String, ReaderNavigationState> readerStates;

  ReaderNavigationState readerState(String readerKey) =>
      readerStates[readerKey] ?? const ReaderNavigationState();

  AppRestorationState copyWith({
    int? activeBranchIndex,
    int? feedIndex,
    List<PaperRouteEntry>? routeStack,
    Map<String, ReaderNavigationState>? readerStates,
  }) =>
      AppRestorationState(
        activeBranchIndex: activeBranchIndex ?? this.activeBranchIndex,
        feedIndex: feedIndex ?? this.feedIndex,
        routeStack: routeStack ?? this.routeStack,
        readerStates: readerStates ?? this.readerStates,
      );

  factory AppRestorationState.fromJson(Map<String, dynamic> json) {
    final rawReaders = json['reader_states'];
    return AppRestorationState(
      activeBranchIndex: _restoredBranchIndex(json['active_branch_index']),
      feedIndex: (json['feed_index'] as num?)?.toInt() ?? 0,
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
        'route_stack':
            routeStack.map((entry) => entry.toJson()).toList(growable: false),
        'reader_states': readerStates.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };
}

int _restoredBranchIndex(Object? value) {
  final index = value is num ? value.toInt() : 0;
  return index == 1 ? 1 : 0;
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
