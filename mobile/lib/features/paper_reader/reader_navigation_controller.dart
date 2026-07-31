import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/cache/local_store.dart';
import '../../core/content_policy.dart';
import '../../core/models/paper.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';

final appRestorationControllerProvider =
    StateNotifierProvider<AppRestorationController, AppRestorationState>((ref) {
  final controller = AppRestorationController(
    store: ref.watch(localStoreProvider),
    initial: ref.watch(initialRestorationProvider),
    fulltextPolicy: ref.watch(clientFulltextPolicyProvider),
  );
  ref.listen<String>(anonymousSessionIdProvider, (previous, next) {
    if (previous != null && previous != next) {
      controller.clearAnonymousChatState();
    }
  });
  return controller;
});

final activeAppBranchProvider = Provider<AppBranch>((ref) {
  return ref.watch(appRestorationControllerProvider).activeBranch;
});

class AppRestorationController extends StateNotifier<AppRestorationState> {
  AppRestorationController({
    required LocalStore store,
    required AppRestorationState initial,
    ClientFulltextPolicy fulltextPolicy = ClientFulltextPolicy.prototype,
  })  : _store = store,
        super(_applyRestorationPolicy(initial, fulltextPolicy));

  final LocalStore _store;
  Timer? _persistTimer;

  void setActiveBranch(int index) {
    final safeIndex = index == 1 ? 1 : 0;
    if (safeIndex == state.activeBranchIndex) return;
    state = state.copyWith(activeBranchIndex: safeIndex);
    _schedulePersist();
  }

  void setFeedIndex(int index) {
    if (index == state.feedIndex) return;
    state = state.copyWith(feedIndex: index < 0 ? 0 : index);
    _schedulePersist();
  }

  void updateReader(
    String readerKey,
    ReaderNavigationState Function(ReaderNavigationState current) update,
  ) {
    final readers = Map<String, ReaderNavigationState>.from(state.readerStates);
    readers[readerKey] = update(
      readers[readerKey] ?? const ReaderNavigationState(),
    );
    state = state.copyWith(readerStates: readers);
    _schedulePersist();
  }

  bool markPrepareRequestedOnCommittedPage(String readerKey, int pageIndex) {
    if (pageIndex != PaperStage.introduction.index) return false;
    final current = state.readerState(readerKey);
    if (current.prepareRequested) return false;
    updateReader(readerKey, (value) => value.copyWith(prepareRequested: true));
    return true;
  }

  String pushPaper(PaperSummary paper) {
    final routeId = const Uuid().v4();
    state = state.copyWith(
      routeStack: [
        ...state.routeStack,
        PaperRouteEntry(routeId: routeId, paper: paper),
      ],
    );
    _schedulePersist();
    return routeId;
  }

  bool popPaper({String? routeId}) {
    if (state.routeStack.isEmpty) return false;
    if (routeId != null && state.routeStack.last.routeId != routeId) {
      return false;
    }
    state = state.copyWith(
      routeStack: state.routeStack.sublist(0, state.routeStack.length - 1),
    );
    _schedulePersist();
    return true;
  }

  bool popToFeed() {
    if (state.routeStack.isEmpty) return false;
    state = state.copyWith(routeStack: const []);
    _schedulePersist();
    return true;
  }

  void clearAnonymousChatState() {
    final readers = state.readerStates.map(
      (key, value) => MapEntry(
        key,
        value.copyWith(
          chatSheetOpen: false,
          clearChatThreadId: true,
        ),
      ),
    );
    state = state.copyWith(readerStates: readers);
    _schedulePersist();
  }

  void updateRoutePaper(String routeId, PaperSummary paper) {
    final updated = state.routeStack
        .map(
          (entry) => entry.routeId == routeId
              ? PaperRouteEntry(routeId: entry.routeId, paper: paper)
              : entry,
        )
        .toList(growable: false);
    state = state.copyWith(routeStack: updated);
    _schedulePersist();
  }

  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _store.saveRestoration(state);
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 250),
      () => _store.saveRestoration(state),
    );
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    // The app lifecycle observer calls flush before suspension. This final
    // best-effort write covers provider-container disposal in tests.
    unawaited(_store.saveRestoration(state));
    super.dispose();
  }
}

AppRestorationState _applyRestorationPolicy(
  AppRestorationState initial,
  ClientFulltextPolicy policy,
) {
  if (policy.allowsDerivedDeviceFallback) return initial;
  return initial.copyWith(
    routeStack: initial.routeStack
        .map(
          (entry) => PaperRouteEntry(
            routeId: entry.routeId,
            paper: policy.maskCachedPaper(entry.paper),
          ),
        )
        .toList(growable: false),
    readerStates: initial.readerStates.map(
      (key, value) => MapEntry(
        key,
        value.copyWith(
          stageIndex: PaperStage.abstractView.index,
          chatSheetOpen: false,
          clearChatThreadId: true,
        ),
      ),
    ),
  );
}

final readerNavigationStateProvider =
    Provider.family<ReaderNavigationState, String>((ref, readerKey) {
  return ref.watch(appRestorationControllerProvider).readerState(readerKey);
});

final paperReaderNavigationControllerProvider =
    Provider.family<PaperReaderNavigationController, String>((ref, readerKey) {
  return PaperReaderNavigationController(ref, readerKey);
});

class PaperReaderNavigationController {
  const PaperReaderNavigationController(this._ref, this.readerKey);

  final Ref _ref;
  final String readerKey;

  AppRestorationController get _controller =>
      _ref.read(appRestorationControllerProvider.notifier);

  void setStage(int stageIndex) {
    _controller.updateReader(
      readerKey,
      (value) => value.copyWith(stageIndex: stageIndex),
    );
  }

  void setScrollOffset(PaperStage stage, double offset) {
    final safeOffset = offset.isFinite && offset > 0 ? offset : 0.0;
    _controller.updateReader(
      readerKey,
      (value) => switch (stage) {
        PaperStage.abstractView => value.copyWith(abstractOffset: safeOffset),
        PaperStage.introduction => value.copyWith(
            introductionOffset: safeOffset,
          ),
        PaperStage.connections => value.copyWith(connectionsOffset: safeOffset),
      },
    );
  }

  bool commitPreparationIntent(int pageIndex) =>
      _controller.markPrepareRequestedOnCommittedPage(readerKey, pageIndex);

  void setChatSheetOpen(bool open) {
    _controller.updateReader(
      readerKey,
      (value) => value.copyWith(chatSheetOpen: open),
    );
  }

  void setChatThreadId(String? threadId) {
    _controller.updateReader(
      readerKey,
      (value) => value.copyWith(
        chatThreadId: threadId,
        clearChatThreadId: threadId == null,
      ),
    );
  }
}
