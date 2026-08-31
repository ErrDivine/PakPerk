import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/library/library_models.dart';
import '../../core/paper_resolution/paper_input_classifier.dart';
import '../../core/paper_resolution/paper_resolution_api.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';

typedef PaperImportOperationIdFactory = String Function();

enum PaperImportPhase {
  unavailable,
  idle,
  ready,
  waitingForSearch,
  searching,
  choosingCandidate,
  importing,
  succeeded,
  failed,
}

enum PaperImportRetryAction { search, import }

enum PaperImportLifecyclePhase {
  importing,
  failed,
  succeeded,
  cancelled,
  closed,
}

/// The complete identity fence for account-owned paper-resolution work.
///
/// [accountGeneration] lets a caller invalidate work even if an account is
/// rebound without changing the current auth epoch. Raw account identity is
/// used only for equality and is deliberately redacted from diagnostics.
@immutable
final class PaperImportAccountScope {
  const PaperImportAccountScope({
    required this.accountId,
    required this.authEpoch,
    required this.accountGeneration,
  }) : assert(accountId != ''),
       assert(authEpoch >= 0),
       assert(accountGeneration >= 0);

  final String accountId;
  final int authEpoch;
  final int accountGeneration;

  @override
  bool operator ==(Object other) =>
      other is PaperImportAccountScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.accountGeneration == accountGeneration;

  @override
  int get hashCode => Object.hash(accountId, authEpoch, accountGeneration);

  @override
  String toString() =>
      'PaperImportAccountScope(accountId: <redacted>, '
      'authEpoch: $authEpoch, accountGeneration: $accountGeneration)';
}

@immutable
final class PaperImportFailure {
  const PaperImportFailure({
    required this.code,
    required this.title,
    required this.message,
    required this.retryable,
    this.retryAction,
  });

  final String code;
  final String title;
  final String message;
  final bool retryable;
  final PaperImportRetryAction? retryAction;
}

/// Ephemeral presentation state for one server import operation.
///
/// This object is never written to Drift or merged into the canonical library
/// projection. It exists only while the operation can still be retried with
/// its original idempotency key.
@immutable
final class PaperImportPlaceholder {
  const PaperImportPlaceholder({
    required this.operationId,
    required this.label,
    required this.source,
    required this.saveSourceKind,
  });

  final String operationId;
  final String label;
  final PaperImportSource source;
  final LibrarySaveSourceKind saveSourceKind;

  PaperImportSourceKind get sourceKind => source.kind;
}

/// A presentation-flow signal for pending-import authority and integration.
///
/// [succeeded] carries the server's canonical library result. Consumers should
/// apply that result directly rather than enqueueing a second save mutation.
/// [operationId] remains stable from the first importing event through every
/// retry and the eventual success or closure event.
@immutable
final class PaperImportLifecycleEvent {
  const PaperImportLifecycleEvent({
    required this.phase,
    required this.operationId,
    this.placeholder,
    this.failure,
    this.result,
  });

  final PaperImportLifecyclePhase phase;
  final String? operationId;
  final PaperImportPlaceholder? placeholder;
  final PaperImportFailure? failure;
  final PaperImportResult? result;

  bool get terminal => switch (phase) {
    PaperImportLifecyclePhase.importing => false,
    PaperImportLifecyclePhase.failed => !(failure?.retryable ?? false),
    PaperImportLifecyclePhase.succeeded ||
    PaperImportLifecyclePhase.cancelled ||
    PaperImportLifecyclePhase.closed => true,
  };
}

typedef PaperImportLifecycleCallback =
    void Function(PaperImportLifecycleEvent event);

@immutable
final class PaperImportState {
  const PaperImportState({
    required this.phase,
    this.input = '',
    this.classification,
    this.candidates = const <PaperSearchCandidate>[],
    this.selectedArxivId,
    this.failure,
    this.placeholder,
    this.result,
  });

  const PaperImportState.unavailable()
    : this(phase: PaperImportPhase.unavailable);

  const PaperImportState.idle() : this(phase: PaperImportPhase.idle);

  final PaperImportPhase phase;
  final String input;
  final ClassifiedPaperInput? classification;
  final List<PaperSearchCandidate> candidates;
  final String? selectedArxivId;
  final PaperImportFailure? failure;
  final PaperImportPlaceholder? placeholder;
  final PaperImportResult? result;

  bool get busy =>
      phase == PaperImportPhase.searching ||
      phase == PaperImportPhase.importing;

  bool get isTitle => classification?.kind == PaperInputKind.title;

  PaperSearchCandidate? get selectedCandidate {
    final identity = selectedArxivId;
    if (identity == null) return null;
    for (final candidate in candidates) {
      if (candidate.arxivId == identity) return candidate;
    }
    return null;
  }

  bool get canSubmit => switch (phase) {
    PaperImportPhase.ready => classification?.isExact ?? false,
    PaperImportPhase.choosingCandidate => selectedCandidate != null,
    _ => false,
  };
}

/// Owns the complete add-paper request lifecycle without touching Drift.
///
/// Typing a valid title starts only a debounced search. Exact identifiers and
/// canonical arXiv URLs wait for an explicit submit and import immediately.
/// Title results must be explicitly selected before an import operation can
/// begin. Retrying that operation reuses the exact same UUID.
final class PaperImportController extends ChangeNotifier {
  PaperImportController({
    required PaperResolutionRemoteDataSource remote,
    required PaperImportAccountScope? scope,
    PaperInputClassifier classifier = const PaperInputClassifier(),
    PaperImportOperationIdFactory? operationId,
    this.searchLimit = 8,
    this.titleDebounce = defaultTitleDebounce,
    this.titleSearchEnabled = true,
    LibrarySaveSourceKind? initialSaveSourceKind,
  }) : assert(searchLimit >= 1 && searchLimit <= 10),
       _remote = remote,
       _classifier = classifier,
       _operationId = operationId ?? const Uuid().v7,
       _initialSaveSourceKind = initialSaveSourceKind,
       _scope = scope,
       _state = scope == null
           ? const PaperImportState.unavailable()
           : const PaperImportState.idle();

  static const Duration defaultTitleDebounce = Duration(milliseconds: 400);

  final PaperResolutionRemoteDataSource _remote;
  final PaperInputClassifier _classifier;
  final PaperImportOperationIdFactory _operationId;
  final int searchLimit;
  final Duration titleDebounce;
  final bool titleSearchEnabled;
  LibrarySaveSourceKind? _initialSaveSourceKind;

  PaperImportAccountScope? _scope;
  PaperImportState _state;
  Timer? _debounceTimer;
  RequestCancellation? _searchRequest;
  RequestCancellation? _importRequest;
  _PaperImportAttempt? _pendingAttempt;
  int _generation = 0;
  bool _disposed = false;

  PaperImportState get state => _state;
  PaperImportAccountScope? get scope => _scope;

  void updateScope(PaperImportAccountScope? next) {
    if (_scope == next) return;
    _scope = next;
    _invalidateRequests('The paper-import account scope changed.');
    _pendingAttempt = null;
    _publish(
      next == null
          ? const PaperImportState.unavailable()
          : const PaperImportState.idle(),
    );
  }

  void updateInput(String input) {
    if (_disposed || input == _state.input) return;
    _invalidateRequests('The paper-import input changed.');
    _pendingAttempt = null;
    if (_state.input.isNotEmpty && input != _state.input) {
      _initialSaveSourceKind = null;
    }
    if (_scope == null) {
      _publish(
        PaperImportState(phase: PaperImportPhase.unavailable, input: input),
      );
      return;
    }
    if (input.trim().isEmpty) {
      _publish(PaperImportState(phase: PaperImportPhase.idle, input: input));
      return;
    }

    late final ClassifiedPaperInput classification;
    try {
      classification = _classifier.classify(input);
    } on PaperInputException catch (error) {
      _publish(
        PaperImportState(
          phase: PaperImportPhase.failed,
          input: input,
          failure: PaperImportFailure(
            code: error.reason.name,
            title: 'Check this entry',
            message: error.message,
            retryable: false,
          ),
        ),
      );
      return;
    }

    if (classification.isExact) {
      _publish(
        PaperImportState(
          phase: PaperImportPhase.ready,
          input: input,
          classification: classification,
        ),
      );
      return;
    }

    if (!titleSearchEnabled) {
      _publish(
        PaperImportState(
          phase: PaperImportPhase.failed,
          input: input,
          classification: classification,
          failure: const PaperImportFailure(
            code: 'TITLE_SEARCH_UNAVAILABLE',
            title: 'Title search unavailable',
            message: 'Paste an arXiv link or ID to add this paper.',
            retryable: false,
          ),
        ),
      );
      return;
    }

    _publish(
      PaperImportState(
        phase: PaperImportPhase.waitingForSearch,
        input: input,
        classification: classification,
      ),
    );
    final generation = _generation;
    final requestScope = _scope!;
    _debounceTimer = Timer(titleDebounce, () {
      _debounceTimer = null;
      if (!_isCurrent(generation, requestScope) ||
          !_classificationIsCurrent(classification)) {
        return;
      }
      unawaited(_startSearch(classification));
    });
  }

  void clear() => updateInput('');

  Future<void> searchNow() async {
    final classification = _state.classification;
    if (!titleSearchEnabled ||
        classification == null ||
        classification.kind != PaperInputKind.title) {
      return;
    }
    await _startSearch(classification);
  }

  void selectCandidate(PaperSearchCandidate candidate) {
    if (_disposed || _state.busy || !_state.candidates.contains(candidate)) {
      return;
    }
    if (_state.selectedArxivId == candidate.arxivId &&
        _state.phase == PaperImportPhase.choosingCandidate) {
      return;
    }
    _pendingAttempt = null;
    _publish(
      PaperImportState(
        phase: PaperImportPhase.choosingCandidate,
        input: _state.input,
        classification: _state.classification,
        candidates: _state.candidates,
        selectedArxivId: candidate.arxivId,
      ),
    );
  }

  Future<PaperImportResult?> submit() async {
    final classification = _state.classification;
    if (classification == null || _scope == null) return null;
    if (classification.isExact) {
      final identifier = classification.identifier!;
      return _startImport(
        source: PaperImportSource.fromClassification(classification),
        saveSourceKind:
            _initialSaveSourceKind ??
            PaperImportSource.fromClassification(
              classification,
            ).directSaveSourceKind,
        label: identifier.queryId,
      );
    }
    final selected = _state.selectedCandidate;
    if (selected == null) return null;
    return _startImport(
      source: selected.importSource,
      saveSourceKind: LibrarySaveSourceKind.titleSearch,
      label: selected.title,
    );
  }

  Future<PaperImportResult?> retry() async {
    final failure = _state.failure;
    if (failure == null || !failure.retryable) return null;
    switch (failure.retryAction) {
      case PaperImportRetryAction.search:
        await searchNow();
        return null;
      case PaperImportRetryAction.import:
        final attempt = _pendingAttempt;
        if (attempt == null) return null;
        return _performImport(attempt);
      case null:
        return null;
    }
  }

  Future<void> _startSearch(ClassifiedPaperInput classification) async {
    final requestScope = _scope;
    if (requestScope == null || !_classificationIsCurrent(classification)) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchRequest?.cancel('A newer title search replaced this one.');
    _importRequest?.cancel('A title search replaced the active import.');
    _pendingAttempt = null;
    final request = RequestCancellation();
    _searchRequest = request;
    final generation = ++_generation;
    _publish(
      PaperImportState(
        phase: PaperImportPhase.searching,
        input: _state.input,
        classification: classification,
      ),
    );
    try {
      final result = await _remote.searchByTitle(
        query: classification.normalizedValue,
        limit: searchLimit,
        expectedAuthEpoch: requestScope.authEpoch,
        cancellation: request,
      );
      if (!_isCurrent(generation, requestScope) ||
          !_classificationIsCurrent(classification)) {
        return;
      }
      _publish(
        PaperImportState(
          phase: PaperImportPhase.choosingCandidate,
          input: _state.input,
          classification: classification,
          candidates: List<PaperSearchCandidate>.unmodifiable(
            result.candidates,
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!_isCurrent(generation, requestScope) || error.cancelled) return;
      _publish(
        _failureState(
          action: PaperImportRetryAction.search,
          error: error,
          title: 'Couldn’t search arXiv',
        ),
      );
    } on Object {
      if (!_isCurrent(generation, requestScope)) return;
      _publish(
        _unexpectedFailureState(
          action: PaperImportRetryAction.search,
          title: 'Couldn’t search arXiv',
        ),
      );
    } finally {
      if (identical(_searchRequest, request)) _searchRequest = null;
    }
  }

  Future<PaperImportResult?> _startImport({
    required PaperImportSource source,
    required LibrarySaveSourceKind saveSourceKind,
    required String label,
  }) {
    final identity =
        '${source.kind.wireValue}\u0000${source.value}'
        '\u0000${saveSourceKind.wireValue}';
    final existing = _pendingAttempt;
    final attempt = existing != null && existing.identity == identity
        ? existing
        : _PaperImportAttempt(
            identity: identity,
            operationId: _operationId().toLowerCase(),
            source: source,
            saveSourceKind: saveSourceKind,
            label: label,
          );
    _pendingAttempt = attempt;
    return _performImport(attempt);
  }

  Future<PaperImportResult?> _performImport(_PaperImportAttempt attempt) async {
    final requestScope = _scope;
    if (requestScope == null || _pendingAttempt != attempt) return null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchRequest?.cancel('The selected paper is being imported.');
    _importRequest?.cancel('A newer import attempt replaced this one.');
    final request = RequestCancellation();
    _importRequest = request;
    final generation = ++_generation;
    final placeholder = PaperImportPlaceholder(
      operationId: attempt.operationId,
      label: attempt.label,
      source: attempt.source,
      saveSourceKind: attempt.saveSourceKind,
    );
    _publish(
      PaperImportState(
        phase: PaperImportPhase.importing,
        input: _state.input,
        classification: _state.classification,
        candidates: _state.candidates,
        selectedArxivId: _state.selectedArxivId,
        placeholder: placeholder,
      ),
    );
    try {
      final result = await _remote.importPaper(
        source: attempt.source,
        operationId: attempt.operationId,
        saveSourceKind: attempt.saveSourceKind,
        expectedAuthEpoch: requestScope.authEpoch,
        cancellation: request,
      );
      if (!_isCurrent(generation, requestScope) || _pendingAttempt != attempt) {
        return null;
      }
      if (result.item.lastOperationId != attempt.operationId) {
        throw StateError('Paper import operation identity changed.');
      }
      _publish(
        PaperImportState(
          phase: PaperImportPhase.succeeded,
          input: _state.input,
          classification: _state.classification,
          candidates: _state.candidates,
          selectedArxivId: _state.selectedArxivId,
          result: result,
        ),
      );
      return result;
    } on ApiException catch (error) {
      if (!_isCurrent(generation, requestScope) || error.cancelled) return null;
      _publish(
        _failureState(
          action: PaperImportRetryAction.import,
          error: error,
          title: 'Couldn’t add this paper',
          placeholder: placeholder,
        ),
      );
      return null;
    } on Object {
      if (!_isCurrent(generation, requestScope)) return null;
      _publish(
        _unexpectedFailureState(
          action: PaperImportRetryAction.import,
          title: 'Couldn’t add this paper',
          placeholder: placeholder,
        ),
      );
      return null;
    } finally {
      if (identical(_importRequest, request)) _importRequest = null;
    }
  }

  PaperImportState _failureState({
    required PaperImportRetryAction action,
    required ApiException error,
    required String title,
    PaperImportPlaceholder? placeholder,
  }) => PaperImportState(
    phase: PaperImportPhase.failed,
    input: _state.input,
    classification: _state.classification,
    candidates: _state.candidates,
    selectedArxivId: _state.selectedArxivId,
    failure: PaperImportFailure(
      code: error.code,
      title: title,
      message: error.message,
      retryable: error.retryable,
      retryAction: action,
    ),
    placeholder: placeholder,
  );

  PaperImportState _unexpectedFailureState({
    required PaperImportRetryAction action,
    required String title,
    PaperImportPlaceholder? placeholder,
  }) => PaperImportState(
    phase: PaperImportPhase.failed,
    input: _state.input,
    classification: _state.classification,
    candidates: _state.candidates,
    selectedArxivId: _state.selectedArxivId,
    failure: PaperImportFailure(
      code: action == PaperImportRetryAction.search
          ? 'PAPER_SEARCH_UNAVAILABLE'
          : 'PAPER_IMPORT_UNAVAILABLE',
      title: title,
      message: action == PaperImportRetryAction.search
          ? 'Paper search is temporarily unavailable.'
          : 'This paper could not be added right now.',
      retryable: true,
      retryAction: action,
    ),
    placeholder: placeholder,
  );

  bool _classificationIsCurrent(ClassifiedPaperInput classification) {
    final current = _state.classification;
    return current != null &&
        current.kind == classification.kind &&
        current.normalizedValue == classification.normalizedValue;
  }

  bool _isCurrent(int generation, PaperImportAccountScope requestScope) =>
      !_disposed && generation == _generation && _scope == requestScope;

  void _invalidateRequests(String reason) {
    _generation += 1;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _searchRequest?.cancel(reason);
    _searchRequest = null;
    _importRequest?.cancel(reason);
    _importRequest = null;
  }

  void _publish(PaperImportState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateRequests('The add-paper flow was closed.');
    super.dispose();
  }
}

final class _PaperImportAttempt {
  const _PaperImportAttempt({
    required this.identity,
    required this.operationId,
    required this.source,
    required this.saveSourceKind,
    required this.label,
  });

  final String identity;
  final String operationId;
  final PaperImportSource source;
  final LibrarySaveSourceKind saveSourceKind;
  final String label;
}
