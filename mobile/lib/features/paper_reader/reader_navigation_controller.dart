import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/cache/feed_cache_persistence.dart';
import '../../core/cache/local_store.dart';
import '../../core/content_policy.dart';
import '../../core/models/paper.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';

const maxRestoredRouteDepth = 32;
const maxRestoredReaderStates = 64;

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
  }) : _store = store,
       super(
         _normalizeRestorationState(
           _applyRestorationPolicy(initial, fulltextPolicy),
           dropUnknownRouteReaders: true,
         ),
       ) {
    _publishLiveCacheProtection();
  }

  final LocalStore _store;
  Timer? _persistTimer;

  void setActiveBranch(int index) {
    final safeIndex = index == 1 ? 1 : 0;
    if (safeIndex == state.activeBranchIndex) return;
    state = state.copyWith(activeBranchIndex: safeIndex);
    _schedulePersist();
  }

  void setFeedIndex(int index) {
    final safeIndex = index < 0 ? 0 : index;
    if (safeIndex == state.feedIndex && state.feedPaperId == null) return;
    state = state.copyWith(feedIndex: safeIndex, clearFeedPaperReference: true);
    _schedulePersist();
  }

  void setFeedPosition(int index, PaperSummary paper) {
    final safeIndex = index < 0 ? 0 : index;
    if (safeIndex == state.feedIndex &&
        state.feedPaperId == paper.paperId &&
        state.feedArxivId == paper.arxivId) {
      return;
    }
    state = state.copyWith(
      feedIndex: safeIndex,
      feedPaperId: paper.paperId,
      feedArxivId: paper.arxivId,
    );
    _schedulePersist();
  }

  void updateReader(
    String readerKey,
    ReaderNavigationState Function(ReaderNavigationState current) update,
  ) {
    final readers = Map<String, ReaderNavigationState>.from(state.readerStates);
    // Map insertion order is the restoration-state LRU. Refresh the entry so
    // long reading sessions retain the most recently touched papers.
    readers.remove(readerKey);
    readers[readerKey] = update(
      state.readerStates[readerKey] ?? const ReaderNavigationState(),
    );
    state = _normalizeRestorationState(state.copyWith(readerStates: readers));
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
    state = _normalizeRestorationState(
      state.copyWith(
        routeStack: [
          ...state.routeStack,
          PaperRouteEntry(routeId: routeId, paper: paper),
        ],
      ),
    );
    _schedulePersist();
    return routeId;
  }

  bool popPaper({String? routeId}) {
    if (state.routeStack.isEmpty) return false;
    if (routeId != null && state.routeStack.last.routeId != routeId) {
      return false;
    }
    final popped = state.routeStack.last;
    final readers = Map<String, ReaderNavigationState>.from(state.readerStates)
      ..remove(popped.readerKey);
    state = _normalizeRestorationState(
      state.copyWith(
        routeStack: state.routeStack.sublist(0, state.routeStack.length - 1),
        readerStates: readers,
      ),
    );
    _schedulePersist();
    return true;
  }

  bool popToFeed() {
    if (state.routeStack.isEmpty) return false;
    final readers = Map<String, ReaderNavigationState>.from(state.readerStates);
    for (final entry in state.routeStack) {
      readers.remove(entry.readerKey);
    }
    state = _normalizeRestorationState(
      state.copyWith(routeStack: const [], readerStates: readers),
    );
    _schedulePersist();
    return true;
  }

  void clearAnonymousChatState() {
    final readers = state.readerStates.map(
      (key, value) => MapEntry(
        key,
        value.copyWith(chatSheetOpen: false, clearChatThreadId: true),
      ),
    );
    state = state.copyWith(readerStates: readers);
    _schedulePersist();
  }

  Future<void> resetAfterLocalDataClear() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    state = const AppRestorationState();
    _publishLiveCacheProtection();
    await _store.saveRestoration(state);
  }

  void updateRoutePaper(String routeId, PaperSummary paper) {
    final routeIndex = state.routeStack.indexWhere(
      (entry) => entry.routeId == routeId,
    );
    if (routeIndex < 0) return;
    final previousEntry = state.routeStack[routeIndex];
    if (previousEntry.paper.versionKey == paper.versionKey) return;
    final updated = state.routeStack
        .map(
          (entry) => entry.routeId == routeId
              ? PaperRouteEntry(routeId: entry.routeId, paper: paper)
              : entry,
        )
        .toList(growable: false);
    final readers = Map<String, ReaderNavigationState>.from(state.readerStates);
    if (previousEntry.readerKey != updated[routeIndex].readerKey) {
      // A new arXiv version is a new reader scope. Stage, scroll, preparation,
      // and anonymous chat state must not cross the version boundary.
      readers.remove(previousEntry.readerKey);
      readers.remove(updated[routeIndex].readerKey);
    }
    state = _normalizeRestorationState(
      state.copyWith(routeStack: updated, readerStates: readers),
    );
    _schedulePersist();
  }

  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    _publishLiveCacheProtection();
    await _store.saveRestoration(state);
  }

  void _schedulePersist() {
    _publishLiveCacheProtection();
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 250),
      () => _store.saveRestoration(state),
    );
  }

  void _publishLiveCacheProtection() {
    final store = _store;
    if (store is LiveRestorationCacheProtection) {
      (store as LiveRestorationCacheProtection).updateLiveRestorationProtection(
        state,
      );
    }
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

AppRestorationState _normalizeRestorationState(
  AppRestorationState input, {
  bool dropUnknownRouteReaders = false,
}) {
  final routeStart = input.routeStack.length > maxRestoredRouteDepth
      ? input.routeStack.length - maxRestoredRouteDepth
      : 0;
  final routes = input.routeStack.sublist(routeStart);
  final inputRouteReaderKeys = input.routeStack
      .map((entry) => entry.readerKey)
      .toSet();
  final routeReaderKeys = routes.map((entry) => entry.readerKey).toSet();
  final truncatedRouteReaderKeys = inputRouteReaderKeys.difference(
    routeReaderKeys,
  );
  final protectedReaderKeys = <String>{...routeReaderKeys};
  if (input.feedPaperId case final paperId?) {
    final arxivId = input.feedArxivId;
    if (arxivId != null) {
      protectedReaderKeys.add('feed:$paperId:$arxivId');
    }
  }

  final readers = Map<String, ReaderNavigationState>.fromEntries(
    input.readerStates.entries.where((entry) {
      if (truncatedRouteReaderKeys.contains(entry.key)) return false;
      return !dropUnknownRouteReaders ||
          !entry.key.startsWith('route:') ||
          routeReaderKeys.contains(entry.key);
    }),
  );
  if (readers.length > maxRestoredReaderStates) {
    for (final key in readers.keys.toList(growable: false)) {
      if (readers.length <= maxRestoredReaderStates) break;
      if (!protectedReaderKeys.contains(key)) readers.remove(key);
    }
  }

  return input.copyWith(routeStack: routes, readerStates: readers);
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
