import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/library/library_history_store.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';

final libraryHistoryStoreProvider = Provider<LibraryHistoryStore>(
  (_) => SharedPreferencesLibraryHistoryStore(),
);

final libraryHistoryControllerProvider = StateNotifierProvider.autoDispose
    .family<LibraryHistoryController, LibraryHistoryState, ActiveLibraryScope>((
      ref,
      scope,
    ) {
      final controller = LibraryHistoryController(
        store: ref.watch(libraryHistoryStoreProvider),
        accountId: scope.accountId,
        scopeIsCurrent: () =>
            ref.read(featureFlagsProvider).libraryV2Enabled &&
            ref.read(libraryDisplayScopeProvider) == scope,
      );
      unawaited(controller.load());
      return controller;
    });

final class LibraryHistoryState {
  const LibraryHistoryState({
    this.enabled = false,
    this.entries = const [],
    this.loading = true,
    this.saving = false,
    this.errorMessage,
  });

  final bool enabled;
  final List<LibraryHistoryEntry> entries;
  final bool loading;
  final bool saving;
  final String? errorMessage;

  LibraryHistoryState copyWith({
    bool? enabled,
    List<LibraryHistoryEntry>? entries,
    bool? loading,
    bool? saving,
    String? errorMessage,
    bool clearError = false,
  }) => LibraryHistoryState(
    enabled: enabled ?? this.enabled,
    entries: entries ?? this.entries,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

typedef LibraryHistoryClock = DateTime Function();

final class LibraryHistoryController
    extends StateNotifier<LibraryHistoryState> {
  LibraryHistoryController({
    required LibraryHistoryStore store,
    required String accountId,
    required bool Function() scopeIsCurrent,
    LibraryHistoryClock? clock,
  }) : _store = store,
       _accountId = accountId,
       _scopeIsCurrent = scopeIsCurrent,
       _clock = clock ?? DateTime.now,
       super(const LibraryHistoryState());

  final LibraryHistoryStore _store;
  final String _accountId;
  final bool Function() _scopeIsCurrent;
  final LibraryHistoryClock _clock;
  Future<void>? _load;
  Future<void> _writeTail = Future.value();
  var _generation = 0;

  Future<void> load() => _load ??= _loadSnapshot();

  Future<void> _loadSnapshot() async {
    final generation = ++_generation;
    try {
      final snapshot = await _store.load(_accountId);
      if (!_isCurrent(generation)) return;
      state = LibraryHistoryState(
        enabled: snapshot.enabled,
        entries: snapshot.entries,
        loading: false,
      );
    } on Object {
      if (!_isCurrent(generation)) return;
      state = const LibraryHistoryState(
        loading: false,
        errorMessage: 'Private paper history could not be loaded.',
      );
    }
  }

  Future<void> setEnabled(bool enabled) => _enqueueWrite(() async {
    await load();
    if (!_scopeIsCurrent()) return;
    final snapshot = LibraryHistorySnapshot(
      enabled: enabled,
      entries: enabled ? state.entries : const [],
    );
    await _save(snapshot);
  });

  Future<void> clear() => _enqueueWrite(() async {
    await load();
    if (!_scopeIsCurrent()) return;
    await _save(LibraryHistorySnapshot(enabled: state.enabled));
  });

  Future<void> record(PaperSummary paper) => _enqueueWrite(() async {
    await load();
    if (!_scopeIsCurrent() || !state.enabled) return;
    final openedAt = _clock().toUtc();
    final entries = [
      LibraryHistoryEntry(paper: paper, openedAt: openedAt),
      for (final entry in state.entries)
        if (entry.paper.paperId != paper.paperId) entry,
    ];
    await _save(LibraryHistorySnapshot(enabled: true, entries: entries));
  });

  Future<void> _save(LibraryHistorySnapshot snapshot) async {
    final generation = ++_generation;
    state = state.copyWith(saving: true, clearError: true);
    try {
      await _store.save(_accountId, snapshot);
      if (!_isCurrent(generation)) return;
      state = LibraryHistoryState(
        enabled: snapshot.enabled,
        entries: snapshot.entries,
        loading: false,
      );
    } on Object {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        saving: false,
        errorMessage: 'Private paper history could not be saved.',
      );
    }
  }

  Future<void> _enqueueWrite(Future<void> Function() action) {
    final next = _writeTail.then((_) => action());
    _writeTail = next.catchError((Object _) {});
    return next;
  }

  bool _isCurrent(int generation) =>
      mounted && _generation == generation && _scopeIsCurrent();

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
  }
}
