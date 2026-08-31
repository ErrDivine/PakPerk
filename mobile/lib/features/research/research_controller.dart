import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/cache/drift_local_store.dart';
import '../../core/database/research_cache_dao.dart';
import '../../core/models/annotation.dart';
import '../../core/models/document_block.dart';
import '../../core/models/evidence_card.dart';
import '../../core/models/paper.dart';
import '../../core/models/paper_passport.dart';
import '../../core/models/research_memory.dart';
import '../../core/providers.dart';
import '../../core/research/research_api.dart';
import '../../core/research/research_repository.dart';
import '../paper_reader/paper_processing_controller.dart';

final researchRemoteDataSourceProvider = Provider<ResearchRemoteDataSource>(
  (ref) => ResearchApi(ref.watch(pakPerkDioProvider)),
);

final researchDataSourceProvider = Provider<ResearchRepository>((ref) {
  final store = ref.watch(localStoreProvider);
  if (store is! DriftLocalStore) {
    throw StateError('Research memory requires the Drift local store.');
  }
  return ResearchRepository(
    remote: ref.watch(researchRemoteDataSourceProvider),
    cache: ResearchCacheDao(store.database),
    networkStatus: ref.watch(transportNetworkStatusProvider),
    accountWrites: ref.watch(accountDataWriteBarrierProvider),
    telemetry: ref.watch(telemetrySinkProvider),
  );
});

final class ResearchControllerArgs {
  const ResearchControllerArgs({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
    required this.versionKey,
    required this.generation,
  });

  final String accountId;
  final int authEpoch;
  final String paperId;
  final String versionKey;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is ResearchControllerArgs &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.paperId == paperId &&
      other.versionKey == versionKey &&
      other.generation == generation;

  @override
  int get hashCode =>
      Object.hash(accountId, authEpoch, paperId, versionKey, generation);
}

final class ResearchState {
  const ResearchState({
    this.annotations = const [],
    this.evidenceCards = const [],
    this.memoryItems = const [],
    this.conflicts = const [],
    this.loading = false,
    this.syncing = false,
    this.offline = false,
    this.errorMessage,
  });

  final List<Annotation> annotations;
  final List<EvidenceCard> evidenceCards;
  final List<MemoryItem> memoryItems;
  final List<AnnotationConflict> conflicts;
  final bool loading;
  final bool syncing;
  final bool offline;
  final String? errorMessage;

  List<Annotation> get anchorsNeedingReview => annotations
      .where((annotation) => annotation.needsAnchorReview)
      .toList(growable: false);

  ResearchState copyWith({
    List<Annotation>? annotations,
    List<EvidenceCard>? evidenceCards,
    List<MemoryItem>? memoryItems,
    List<AnnotationConflict>? conflicts,
    bool? loading,
    bool? syncing,
    bool? offline,
    String? errorMessage,
    bool clearError = false,
  }) => ResearchState(
    annotations: annotations ?? this.annotations,
    evidenceCards: evidenceCards ?? this.evidenceCards,
    memoryItems: memoryItems ?? this.memoryItems,
    conflicts: conflicts ?? this.conflicts,
    loading: loading ?? this.loading,
    syncing: syncing ?? this.syncing,
    offline: offline ?? this.offline,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final researchControllerProvider = StateNotifierProvider.autoDispose
    .family<ResearchController, ResearchState, ResearchControllerArgs>((
      ref,
      args,
    ) {
      final source = ref.watch(researchDataSourceProvider);
      return ResearchController(
        args: args,
        source: source,
        scopeIsCurrent: () {
          final verified = ref.read(verifiedLibraryScopeProvider);
          final generation = ref
              .read(
                paperProcessingControllerProvider(
                  PaperVersionKey(
                    paperId: args.paperId,
                    arxivId: args.versionKey,
                  ),
                ),
              )
              .processing
              ?.generation;
          return verified?.accountId == args.accountId &&
              verified?.authEpoch == args.authEpoch &&
              generation == args.generation;
        },
      );
    });

final class ResearchController extends StateNotifier<ResearchState> {
  ResearchController({
    required this.args,
    required ResearchRepository source,
    required ResearchScopeFence scopeIsCurrent,
  }) : _source = source,
       _scope = ResearchRequestScope(
         accountId: args.accountId,
         authEpoch: args.authEpoch,
         paperId: args.paperId,
         generation: args.generation,
         isCurrent: scopeIsCurrent,
       ),
       super(ResearchState(offline: source.isOffline)) {
    _subscriptions.add(
      source.watchAnnotations(_scope).listen((items) {
        if (mounted && _scope.isCurrent()) {
          state = state.copyWith(annotations: items);
        }
      }),
    );
    _subscriptions.add(
      source.watchEvidenceCards(_scope).listen((items) {
        if (mounted && _scope.isCurrent()) {
          state = state.copyWith(evidenceCards: items);
        }
      }),
    );
    _subscriptions.add(
      source.watchMemoryReview(args.accountId).listen((items) {
        if (mounted && _scope.isCurrent()) {
          state = state.copyWith(memoryItems: items);
        }
      }),
    );
    _subscriptions.add(
      source.watchConflicts(_scope).listen((items) {
        if (mounted && _scope.isCurrent()) {
          state = state.copyWith(conflicts: items);
        }
      }),
    );
  }

  final ResearchControllerArgs args;
  final ResearchRepository _source;
  final ResearchRequestScope _scope;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<void>? _loadFlight;

  Future<void> load({bool force = false}) {
    final active = _loadFlight;
    if (active != null) return active;
    late final Future<void> flight;
    flight = _load(force: force).whenComplete(() {
      if (identical(_loadFlight, flight)) _loadFlight = null;
    });
    _loadFlight = flight;
    return flight;
  }

  Future<void> _load({required bool force}) async {
    if (!_scope.isCurrent()) return;
    state = state.copyWith(
      loading: true,
      syncing: !_source.isOffline,
      offline: _source.isOffline,
      clearError: true,
    );
    try {
      await _source.restoreAndSync(_scope);
      if (!_scope.isCurrent()) return;
      if (!_source.isOffline) {
        await Future.wait<void>([
          _source.refreshPaperResearch(_scope),
          _source.refreshMemory(_scope),
        ]);
      }
      if (!mounted || !_scope.isCurrent()) return;
      state = state.copyWith(
        loading: false,
        syncing: false,
        offline: _source.isOffline,
        clearError: true,
      );
    } on ApiException catch (error) {
      if (error.cancelled || !mounted || !_scope.isCurrent()) return;
      state = state.copyWith(
        loading: false,
        syncing: false,
        offline: error.isOffline || _source.isOffline,
        errorMessage: error.isOffline
            ? 'Offline changes remain on this device and will sync when connected.'
            : error.message,
      );
    } on Object {
      if (!mounted || !_scope.isCurrent()) return;
      state = state.copyWith(
        loading: false,
        syncing: false,
        errorMessage: 'Research changes could not be verified.',
      );
    }
  }

  Future<Annotation> addHighlight({
    required DocumentBlock block,
    required String selectedText,
  }) => _source.createAnnotation(
    scope: _scope,
    blockId: block.id,
    kind: AnnotationKind.highlight,
    colorRole: AnnotationColorRole.yellow,
    selector: selectorForBlock(block, selectedText),
    sectionHint: block.sectionPath,
    pageHint: block.pageStart,
  );

  Future<Annotation> addNote({
    required DocumentBlock block,
    required String selectedText,
    required String body,
  }) => _source.createAnnotation(
    scope: _scope,
    blockId: block.id,
    kind: AnnotationKind.note,
    body: body,
    colorRole: AnnotationColorRole.blue,
    selector: selectorForBlock(block, selectedText),
    sectionHint: block.sectionPath,
    pageHint: block.pageStart,
  );

  Future<Annotation> addQuestion({
    required DocumentBlock block,
    required String selectedText,
    required String body,
  }) => _source.createAnnotation(
    scope: _scope,
    blockId: block.id,
    kind: AnnotationKind.question,
    body: body,
    colorRole: AnnotationColorRole.purple,
    selector: selectorForBlock(block, selectedText),
    sectionHint: block.sectionPath,
    pageHint: block.pageStart,
  );

  Future<EvidenceCard> addEvidence({
    required DocumentBlock block,
    required String selectedText,
    required String title,
    String? note,
  }) => _source.createEvidenceCard(
    scope: _scope,
    title: title,
    claimOrQuestion: selectedText,
    userNote: note,
    sourceBlockIds: [block.id],
  );

  Future<EvidenceCard> addObjectEvidence({
    required DocumentEvidenceObject object,
    required String title,
    String? note,
  }) {
    final figureIds = object is DocumentFigure ? [object.id] : const <String>[];
    final tableIds = object is DocumentTable ? [object.id] : const <String>[];
    if (object.sourceBlockIds.isEmpty &&
        figureIds.isEmpty &&
        tableIds.isEmpty) {
      throw StateError('The object has no exact source anchor.');
    }
    return _source.createEvidenceCard(
      scope: _scope,
      title: title,
      claimOrQuestion: object.caption ?? object.label,
      userNote: note,
      sourceBlockIds: object.sourceBlockIds,
      figureIds: figureIds,
      tableIds: tableIds,
    );
  }

  Future<MemoryItem> rememberAnnotation(Annotation annotation) {
    if (annotation.needsAnchorReview) {
      return _source.createMemoryItem(
        scope: _scope,
        sourceType: MemorySourceType.annotation,
        sourceId: annotation.id,
        promptText: 'Revisit this saved annotation after the paper changed.',
        answerText: annotation.body ?? annotation.selector?.exact,
      );
    }
    final isQuestion = annotation.kind == AnnotationKind.question;
    return _source.createMemoryItem(
      scope: _scope,
      sourceType: isQuestion
          ? MemorySourceType.userQuestion
          : MemorySourceType.annotation,
      sourceId: annotation.id,
      promptText: isQuestion ? annotation.body : annotation.selector?.exact,
      answerText: isQuestion ? annotation.selector?.exact : annotation.body,
    );
  }

  Future<MemoryItem> rememberEvidence(EvidenceCard card) {
    if (card.verificationStatus != EvidenceVerificationStatus.userReviewed) {
      throw StateError('Review this evidence card before remembering it.');
    }
    return _source.createMemoryItem(
      scope: _scope,
      sourceType: MemorySourceType.evidenceCard,
      sourceId: card.id,
      promptText: card.claimOrQuestion ?? card.title,
      answerText: card.userNote,
    );
  }

  Future<MemoryItem> rememberPassportField(PassportField field) {
    final answer = field.displayValue?.trim();
    final supportedStatus =
        field.status == PassportFieldStatus.supported ||
        field.status == PassportFieldStatus.inferred;
    if (!field.serverValidated ||
        !field.isRememberable ||
        !supportedStatus ||
        !_researchSourceUuid.hasMatch(field.id) ||
        answer == null ||
        answer.isEmpty) {
      throw StateError(
        'Only server-validated supported or inferred Passport fields can be remembered.',
      );
    }
    return _source.createMemoryItem(
      scope: _scope,
      sourceType: MemorySourceType.passportField,
      sourceId: field.id,
      promptText:
          'What does the paper say about ${field.displayLabel.toLowerCase()}?',
      answerText: answer,
    );
  }

  Future<void> reanchor(Annotation annotation) =>
      _source.requestReanchor(scope: _scope, annotation: annotation);

  Future<Annotation> manualReattach({
    required Annotation annotation,
    required DocumentBlock block,
    required String selectedText,
  }) => _source.manualReattach(
    scope: _scope,
    annotation: annotation,
    blockId: block.id,
    selector: selectorForBlock(block, selectedText),
  );

  Future<Annotation> mergeConflict({
    required Annotation annotation,
    required AnnotationConflict conflict,
    required String? mergedBody,
  }) => _source.mergeConflict(
    scope: _scope,
    annotation: annotation,
    conflict: conflict,
    mergedBody: mergedBody,
  );

  Future<MemoryItem> reviewMemory({
    required MemoryItem item,
    required MemoryStatus status,
    DateTime? nextReviewAt,
  }) => _source.reviewMemoryItem(
    scope: _scope,
    item: item,
    status: status,
    nextReviewAt: nextReviewAt,
  );

  ResearchRepository get repository => _source;
  ResearchRequestScope get scope => _scope;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

TextQuotePositionSelector selectorForBlock(
  DocumentBlock block,
  String selectedText,
) {
  final exact = selectedText.trim();
  if (exact.isEmpty) throw ArgumentError.value(selectedText, 'selectedText');
  final codeUnitStart = block.text.indexOf(exact);
  if (codeUnitStart < 0) return TextQuotePositionSelector(exact: exact);
  // SelectionArea currently exposes selected text but not the selected range.
  // When a quote repeats, omit a guessed position so the server can retain the
  // exact quote without falsely claiming that the first occurrence was tapped.
  if (block.text.indexOf(exact, codeUnitStart + exact.length) >= 0) {
    return TextQuotePositionSelector(exact: exact);
  }
  final textScalars = block.text.runes.toList(growable: false);
  final start = block.text.substring(0, codeUnitStart).runes.length;
  final end = start + exact.runes.length;
  final prefixStart = (start - 64).clamp(0, start).toInt();
  final suffixEnd = (end + 64).clamp(end, textScalars.length).toInt();
  final prefix = String.fromCharCodes(textScalars.sublist(prefixStart, start));
  final suffix = String.fromCharCodes(textScalars.sublist(end, suffixEnd));
  return TextQuotePositionSelector(
    exact: exact,
    prefix: prefix.isEmpty ? null : prefix,
    suffix: suffix.isEmpty ? null : suffix,
    start: start,
    end: end,
  );
}

final _researchSourceUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
