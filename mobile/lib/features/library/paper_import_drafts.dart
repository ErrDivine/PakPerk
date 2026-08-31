import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/library/paper_import_draft_store.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';

final paperImportDraftStoreProvider = Provider<PaperImportDraftStore>(
  (_) => SharedPreferencesPaperImportDraftStore(),
);

final class PaperImportDraftState {
  const PaperImportDraftState({
    required this.scopeFingerprint,
    required this.loading,
    required this.drafts,
    this.errorMessage,
  });

  const PaperImportDraftState.signedOut()
    : scopeFingerprint = null,
      loading = false,
      drafts = const [],
      errorMessage = null;

  final String? scopeFingerprint;
  final bool loading;
  final List<PaperImportDraft> drafts;
  final String? errorMessage;

  bool belongsTo(String accountId) =>
      scopeFingerprint == paperImportDraftScopeFingerprint(accountId);
}

final class PaperImportDraftAuthority {
  const PaperImportDraftAuthority({
    required this.scopeReady,
    required this.pendingCount,
    required this.drafts,
    required this.errorMessage,
  });

  const PaperImportDraftAuthority.signedOut()
    : scopeReady = true,
      pendingCount = 0,
      drafts = const [],
      errorMessage = null;

  final bool scopeReady;
  final int pendingCount;
  final List<PaperImportDraft> drafts;
  final String? errorMessage;

  bool get blocksRecommendations => !scopeReady || pendingCount > 0;
}

final paperImportDraftControllerProvider =
    StateNotifierProvider<PaperImportDraftController, PaperImportDraftState>((
      ref,
    ) {
      final controller = PaperImportDraftController(
        ref.watch(paperImportDraftStoreProvider),
        telemetry: ref.watch(telemetrySinkProvider),
      );
      ref.listen<ActiveLibraryScope?>(verifiedLibraryScopeProvider, (_, next) {
        controller.updateScope(next?.accountId, authEpoch: next?.authEpoch);
      }, fireImmediately: true);
      return controller;
    });

/// Fail-closed, exact-scope view consumed by queue-first authority.
///
/// A signed-in scope is never considered ready until its durable ledger has
/// loaded. Load/decode failures intentionally remain not-ready instead of
/// becoming an empty ledger.
final paperImportDraftAuthorityProvider = Provider<PaperImportDraftAuthority>((
  ref,
) {
  final scope = ref.watch(verifiedLibraryScopeProvider);
  if (scope == null) return const PaperImportDraftAuthority.signedOut();
  final state = ref.watch(paperImportDraftControllerProvider);
  if (!state.belongsTo(scope.accountId) ||
      state.loading ||
      state.errorMessage != null) {
    return PaperImportDraftAuthority(
      scopeReady: false,
      pendingCount: 1,
      drafts: const [],
      errorMessage: state.errorMessage,
    );
  }
  return PaperImportDraftAuthority(
    scopeReady: true,
    pendingCount: state.drafts.length,
    drafts: state.drafts,
    errorMessage: null,
  );
});

final class PaperImportDraftController
    extends StateNotifier<PaperImportDraftState> {
  PaperImportDraftController(
    this._store, {
    TelemetrySink telemetry = const NoopTelemetrySink(),
    DateTime Function()? clock,
  }) : _telemetry = telemetry,
       _clock = clock ?? DateTime.now,
       super(const PaperImportDraftState.signedOut());

  final PaperImportDraftStore _store;
  final TelemetrySink _telemetry;
  final DateTime Function() _clock;
  String? _accountId;
  int? _authEpoch;
  int _generation = 0;

  void updateScope(String? accountId, {int? authEpoch}) {
    if (_accountId == accountId && _authEpoch == authEpoch) return;
    _accountId = accountId;
    _authEpoch = authEpoch;
    final generation = ++_generation;
    if (accountId == null) {
      state = const PaperImportDraftState.signedOut();
      return;
    }
    state = PaperImportDraftState(
      scopeFingerprint: paperImportDraftScopeFingerprint(accountId),
      loading: true,
      drafts: const [],
    );
    unawaited(_load(accountId, generation));
  }

  Future<void> reload() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final generation = ++_generation;
    state = PaperImportDraftState(
      scopeFingerprint: paperImportDraftScopeFingerprint(accountId),
      loading: true,
      drafts: const [],
    );
    await _load(accountId, generation);
  }

  Future<void> _load(String accountId, int generation) async {
    try {
      final drafts = await _store.load(accountId);
      if (!_isCurrent(accountId, generation)) return;
      state = PaperImportDraftState(
        scopeFingerprint: paperImportDraftScopeFingerprint(accountId),
        loading: false,
        drafts: drafts,
      );
      _recordPendingAge(drafts);
    } on Object {
      if (!_isCurrent(accountId, generation)) return;
      state = PaperImportDraftState(
        scopeFingerprint: paperImportDraftScopeFingerprint(accountId),
        loading: false,
        drafts: const [],
        errorMessage:
            'Unresolved Add Paper drafts could not be verified on this device.',
      );
      _recordPendingAge(const [], unavailable: true);
    }
  }

  Future<void> upsert(PaperImportDraft draft) async {
    final accountId = _accountId;
    if (accountId == null || !state.belongsTo(accountId)) return;
    final existing = [...state.drafts];
    final replacing = existing.any(
      (value) => value.operationId == draft.operationId,
    );
    if (!replacing &&
        existing.length >=
            SharedPreferencesPaperImportDraftStore.maximumDrafts) {
      state = PaperImportDraftState(
        scopeFingerprint: state.scopeFingerprint,
        loading: false,
        drafts: state.drafts,
        errorMessage:
            'Resolve or cancel an existing Add Paper draft before adding another.',
      );
      return;
    }
    existing
      ..removeWhere((value) => value.operationId == draft.operationId)
      ..insert(0, draft);
    final next = existing.toList(growable: false);
    state = PaperImportDraftState(
      scopeFingerprint: state.scopeFingerprint,
      loading: false,
      drafts: List.unmodifiable(next),
    );
    final generation = _generation;
    try {
      await _store.save(accountId, next);
      if (_isCurrent(accountId, generation)) _recordPendingAge(next);
    } on Object {
      if (_isCurrent(accountId, generation)) {
        state = PaperImportDraftState(
          scopeFingerprint: state.scopeFingerprint,
          loading: false,
          drafts: state.drafts,
          errorMessage:
              'The unresolved Add Paper draft could not be secured locally.',
        );
      }
    }
  }

  Future<void> markRetryable(String operationId, String failureCode) async {
    final draft = state.drafts.where(
      (value) => value.operationId == operationId,
    );
    if (draft.isEmpty) return;
    await upsert(draft.first.withRetryableFailure(failureCode));
  }

  Future<void> remove(String operationId) async {
    final accountId = _accountId;
    if (accountId == null || !state.belongsTo(accountId)) return;
    final previous = state.drafts;
    final next = previous
        .where((draft) => draft.operationId != operationId)
        .toList(growable: false);
    if (next.length == previous.length) return;
    final generation = _generation;
    try {
      await _store.save(accountId, next);
      if (!_isCurrent(accountId, generation)) return;
      state = PaperImportDraftState(
        scopeFingerprint: state.scopeFingerprint,
        loading: false,
        drafts: List.unmodifiable(next),
      );
      _recordPendingAge(next);
    } on Object {
      if (_isCurrent(accountId, generation)) {
        state = PaperImportDraftState(
          scopeFingerprint: state.scopeFingerprint,
          loading: false,
          drafts: previous,
          errorMessage:
              'The unresolved Add Paper draft could not be removed locally.',
        );
      }
    }
  }

  Future<void> clearCurrent() async {
    final accountId = _accountId;
    if (accountId == null || !state.belongsTo(accountId)) return;
    final generation = _generation;
    try {
      await _store.clear(accountId);
      if (!_isCurrent(accountId, generation)) return;
      state = PaperImportDraftState(
        scopeFingerprint: state.scopeFingerprint,
        loading: false,
        drafts: const [],
      );
    } on Object {
      if (!_isCurrent(accountId, generation)) return;
      state = PaperImportDraftState(
        scopeFingerprint: state.scopeFingerprint,
        loading: false,
        drafts: state.drafts,
        errorMessage: 'Unresolved Add Paper drafts could not be cleared.',
      );
    }
  }

  bool _isCurrent(String accountId, int generation) =>
      mounted && _accountId == accountId && _generation == generation;

  void _recordPendingAge(
    List<PaperImportDraft> drafts, {
    bool unavailable = false,
  }) {
    if (_accountId == null || (!unavailable && drafts.isEmpty)) return;
    DateTime? oldest;
    for (final draft in drafts) {
      if (oldest == null || draft.createdAt.isBefore(oldest)) {
        oldest = draft.createdAt;
      }
    }
    emitTelemetry(_telemetry, PakPerkTelemetryEvent.pendingIntentAge, {
      'intent_kind': 'import',
      'age_bucket': telemetryDurationBucket(
        oldest == null ? null : _clock().toUtc().difference(oldest),
      ),
    });
  }

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
  }
}
