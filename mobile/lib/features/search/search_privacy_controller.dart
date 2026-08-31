import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/account/account_data_write_barrier.dart';
import '../../core/discovery_search/search_privacy_store.dart';
import 'research_search_models.dart';

@immutable
final class SearchPrivacyState {
  SearchPrivacyState({
    required this.scopeFingerprint,
    required this.available,
    required this.loading,
    required this.enabled,
    required Iterable<PrivateSearchHistoryEntry> entries,
    this.saving = false,
    this.errorMessage,
  }) : entries = List<PrivateSearchHistoryEntry>.unmodifiable(entries);

  factory SearchPrivacyState.unavailable() => SearchPrivacyState(
    scopeFingerprint: null,
    available: false,
    loading: false,
    enabled: false,
    entries: const [],
  );

  final String? scopeFingerprint;
  final bool available;
  final bool loading;
  final bool enabled;
  final List<PrivateSearchHistoryEntry> entries;
  final bool saving;
  final String? errorMessage;

  bool belongsTo(ResearchSearchAccountScope scope) =>
      scopeFingerprint == searchPrivacyScopeFingerprint(scope.accountId);

  SearchPrivacyState copyWith({
    bool? loading,
    bool? enabled,
    Iterable<PrivateSearchHistoryEntry>? entries,
    bool? saving,
    String? errorMessage,
    bool clearError = false,
  }) => SearchPrivacyState(
    scopeFingerprint: scopeFingerprint,
    available: available,
    loading: loading ?? this.loading,
    enabled: enabled ?? this.enabled,
    entries: entries ?? this.entries,
    saving: saving ?? this.saving,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

/// Owns the explicit, account-scoped opt-in for private on-device history.
///
/// Disabled is the durable default. Turning history off also clears its raw
/// queries, and every write joins the same account cleanup barrier as the
/// canonical account-owned stores.
final class SearchPrivacyController extends ChangeNotifier {
  SearchPrivacyController({
    required SearchPrivacyStore store,
    required AccountDataWriteBarrier accountDataWriteBarrier,
    required ResearchSearchAccountScope? accountScope,
    DateTime Function()? clock,
  }) : _store = store,
       _barrier = accountDataWriteBarrier,
       _clock = clock ?? DateTime.now,
       _state = SearchPrivacyState.unavailable() {
    updateAccountScope(accountScope);
  }

  final SearchPrivacyStore _store;
  final AccountDataWriteBarrier _barrier;
  final DateTime Function() _clock;
  ResearchSearchAccountScope? _scope;
  SearchPrivacyState _state;
  int _generation = 0;
  bool _disposed = false;

  SearchPrivacyState get state => _state;

  void updateAccountScope(ResearchSearchAccountScope? next) {
    if (_scope == next || _disposed) return;
    _scope = next;
    final generation = ++_generation;
    if (next == null) {
      _publish(SearchPrivacyState.unavailable());
      return;
    }
    _publish(
      SearchPrivacyState(
        scopeFingerprint: searchPrivacyScopeFingerprint(next.accountId),
        available: true,
        loading: true,
        enabled: false,
        entries: const [],
      ),
    );
    unawaited(_load(next, generation));
  }

  Future<void> reload() async {
    final scope = _scope;
    if (scope == null || _disposed) return;
    final generation = ++_generation;
    _publish(
      SearchPrivacyState(
        scopeFingerprint: searchPrivacyScopeFingerprint(scope.accountId),
        available: true,
        loading: true,
        enabled: false,
        entries: const [],
      ),
    );
    await _load(scope, generation);
  }

  Future<void> _load(ResearchSearchAccountScope scope, int generation) async {
    try {
      final snapshot = await _store.loadHistory(scope.accountId);
      if (!_isCurrent(scope, generation)) return;
      _publish(
        SearchPrivacyState(
          scopeFingerprint: searchPrivacyScopeFingerprint(scope.accountId),
          available: true,
          loading: false,
          enabled: snapshot.enabled,
          entries: snapshot.entries,
        ),
      );
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      _publish(
        SearchPrivacyState(
          scopeFingerprint: searchPrivacyScopeFingerprint(scope.accountId),
          available: true,
          loading: false,
          enabled: false,
          entries: const [],
          errorMessage: 'Private search history could not be loaded.',
        ),
      );
    }
  }

  Future<void> setEnabled(bool enabled) async {
    final scope = _scope;
    if (scope == null ||
        _disposed ||
        _state.saving ||
        enabled == _state.enabled) {
      return;
    }
    final next = PrivateSearchHistorySnapshot(
      enabled: enabled,
      entries: enabled ? _state.entries : const [],
    );
    await _persist(scope, next);
  }

  Future<void> clearHistory() async {
    final scope = _scope;
    if (scope == null || _disposed || _state.saving) return;
    await _persist(
      scope,
      PrivateSearchHistorySnapshot(enabled: _state.enabled, entries: const []),
    );
  }

  Future<void> record(PrivateSearchHistoryMode mode, String query) async {
    final scope = _scope;
    if (scope == null ||
        _disposed ||
        !_state.enabled ||
        _state.loading ||
        !_state.belongsTo(scope)) {
      return;
    }
    final entry = PrivateSearchHistoryEntry(
      query: query,
      mode: mode,
      searchedAt: _clock().toUtc(),
    );
    final dedupeKey = entry.query.toLowerCase();
    final entries = <PrivateSearchHistoryEntry>[
      entry,
      ..._state.entries.where(
        (candidate) =>
            candidate.mode != mode ||
            candidate.query.toLowerCase() != dedupeKey,
      ),
    ].take(PrivateSearchHistorySnapshot.maximumEntries).toList(growable: false);
    await _persist(
      scope,
      PrivateSearchHistorySnapshot(enabled: true, entries: entries),
      showSaving: false,
    );
  }

  Future<void> _persist(
    ResearchSearchAccountScope scope,
    PrivateSearchHistorySnapshot snapshot, {
    bool showSaving = true,
  }) async {
    final generation = ++_generation;
    if (showSaving) _publish(_state.copyWith(saving: true, clearError: true));
    try {
      final written = await _barrier.writeIfCurrent(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
        isCurrent: () => _isCurrent(scope, generation),
        write: () => _store.saveHistory(scope.accountId, snapshot),
      );
      if (!written || !_isCurrent(scope, generation)) return;
      _publish(
        _state.copyWith(
          loading: false,
          enabled: snapshot.enabled,
          entries: snapshot.entries,
          saving: false,
          clearError: true,
        ),
      );
    } on Object {
      if (!_isCurrent(scope, generation)) return;
      _publish(
        _state.copyWith(
          saving: false,
          errorMessage: 'Private search history could not be updated.',
        ),
      );
    }
  }

  bool _isCurrent(ResearchSearchAccountScope scope, int generation) =>
      !_disposed && _scope == scope && _generation == generation;

  void _publish(SearchPrivacyState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _scope = null;
    _state = SearchPrivacyState.unavailable();
    super.dispose();
  }
}
