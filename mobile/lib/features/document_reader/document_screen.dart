import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/models/document_block.dart';
import '../../core/models/assistant_v2.dart';
import '../../core/models/annotation.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/models/reader_state.dart';
import '../../core/models/reading_checkpoint.dart';
import '../../core/models/semantic_span.dart';
import '../../core/document/visual_asset_repository.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../paper_reader/paper_processing_controller.dart';
import '../annotations/annotation_editor.dart';
import '../evidence/evidence_card_editor.dart';
import '../chat/assistant_v2_sheet.dart';
import '../paper_reader/reader_navigation_controller.dart';
import '../passport/paper_passport_card.dart';
import '../passport/passport_controller.dart';
import '../reader_modes/reader_mode.dart';
import '../reader_modes/reader_mode_controller.dart';
import '../semantic/definition_sheet.dart';
import '../semantic/facet_controller.dart';
import '../semantic/faceted_text.dart';
import '../research/research_controller.dart';
import '../research/research_tools_sheet.dart';
import '../visual_objects/document_object_navigator.dart';
import 'block_renderer.dart';
import 'document_controller.dart';
import 'inline_reference_sheet.dart';
import 'reader_interaction_state.dart';
import 'reader_progression.dart';
import 'section_outline_sheet.dart';
import 'source_evidence_sheet.dart';

typedef ReaderAssistantLauncher =
    Future<void> Function(AssistantRequestScope scope, String? initialQuestion);

class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({
    required this.paper,
    required this.readerKey,
    required this.scrollController,
    required this.processing,
    required this.active,
    required this.preparedAvailable,
    required this.includePassport,
    required this.includeSemanticFacets,
    required this.includeVisualObjects,
    required this.checkpointsEnabled,
    required this.annotationsEnabled,
    required this.evidenceCardsEnabled,
    required this.researchMemoryEnabled,
    required this.versionDiffEnabled,
    required this.onPrepare,
    required this.onOpenOriginal,
    required this.onOpenOriginalPage,
    this.onOpenAssistant,
    this.onOpenLibrary,
    this.onOpenMemoryReview,
    super.key,
  });

  final PaperSummary paper;
  final String readerKey;
  final ScrollController scrollController;
  final ProcessingUiState processing;
  final bool active;
  final bool preparedAvailable;
  final bool includePassport;
  final bool includeSemanticFacets;
  final bool includeVisualObjects;
  final bool checkpointsEnabled;
  final bool annotationsEnabled;
  final bool evidenceCardsEnabled;
  final bool researchMemoryEnabled;
  final bool versionDiffEnabled;
  final ValueChanged<PreparationTrigger> onPrepare;
  final ReaderAssistantLauncher? onOpenAssistant;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenMemoryReview;
  final VoidCallback onOpenOriginal;
  final ValueChanged<int?> onOpenOriginalPage;

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  final Map<String, GlobalKey> _blockKeys = {};
  final Map<String, String> _blockSectionNames = {};
  DocumentControllerArgs? _scheduledLoad;
  Timer? _highlightTimer;
  ResearchControllerArgs? _scheduledResearchLoad;
  Annotation? _pendingManualReattach;
  String? _endDocumentTelemetrySignature;
  String? _checkpointRestoreScope;
  String? _scheduledVisualObjectsLoadScope;
  String? _scheduledVisualAssetSavedState;
  ({String blockId, int start, int end})? _assistantEvidenceHighlight;
  String? _currentSectionName;
  bool _sectionProgressUpdateScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_scheduleSectionProgressUpdate);
  }

  @override
  void didUpdateWidget(covariant DocumentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_scheduleSectionProgressUpdate);
      widget.scrollController.addListener(_scheduleSectionProgressUpdate);
    }
    if (oldWidget.paper.versionKey != widget.paper.versionKey) {
      _currentSectionName = null;
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_scheduleSectionProgressUpdate);
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(verifiedLibraryScopeProvider);
    final generation = widget.processing.processing?.generation;
    final mode = ref.watch(readerDepthModeProvider(widget.readerKey));
    if (scope == null) {
      return _UnavailableDocument(
        icon: Icons.lock_outline,
        title: 'Verified account required',
        message:
            'Prepared document content is account-scoped. Finish signing in to load it.',
        onOpenOriginal: widget.onOpenOriginal,
      );
    }
    if (generation == null || generation <= 0 || !widget.preparedAvailable) {
      return _PreparationState(
        processing: widget.processing,
        onPrepare: widget.onPrepare,
        onOpenOriginal: widget.onOpenOriginal,
      );
    }
    ref.listen<AssistantEvidenceTarget?>(
      assistantEvidenceTargetProvider(widget.readerKey),
      (previous, next) {
        if (next == null || next == previous) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            _revealBlock(next.blockId, start: next.start, end: next.end),
          );
          ref
                  .read(
                    assistantEvidenceTargetProvider(widget.readerKey).notifier,
                  )
                  .state =
              null;
        });
      },
    );
    final args = DocumentControllerArgs(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      paperId: widget.paper.paperId,
      versionKey: widget.paper.arxivId,
      generation: generation,
      includePassport: widget.includePassport,
      includeSemanticFacets: widget.includeSemanticFacets,
      includeVisualObjects: widget.includeVisualObjects,
    );
    final document = ref.watch(documentControllerProvider(args));
    if (document.availability == DocumentAvailability.ready && widget.active) {
      _scheduleCheckpointRestore(args, document.checkpoint);
      _scheduleVisualObjectsLoad(args, document, mode);
    }
    final researchArgs = ResearchControllerArgs(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      paperId: widget.paper.paperId,
      versionKey: widget.paper.arxivId,
      generation: generation,
    );
    final researchEnabled =
        widget.annotationsEnabled ||
        widget.evidenceCardsEnabled ||
        widget.researchMemoryEnabled ||
        widget.versionDiffEnabled;
    if (researchEnabled &&
        widget.active &&
        _scheduledResearchLoad != researchArgs) {
      _scheduledResearchLoad = researchArgs;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !widget.active ||
            _scheduledResearchLoad != researchArgs) {
          return;
        }
        unawaited(
          ref.read(researchControllerProvider(researchArgs).notifier).load(),
        );
      });
    }
    if (widget.active && _scheduledLoad != args) {
      _scheduledLoad = args;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active || _scheduledLoad != args) return;
        unawaited(ref.read(documentControllerProvider(args).notifier).load());
      });
    }

    return switch (document.availability) {
      DocumentAvailability.idle ||
      DocumentAvailability.loading => const _DocumentLoading(),
      DocumentAvailability.offlineUnavailable => _UnavailableDocument(
        icon: Icons.cloud_off_outlined,
        title: 'Document unavailable offline',
        message:
            document.errorMessage ??
            'Reconnect to load this prepared document. The abstract and original source remain available.',
        onOpenOriginal: widget.onOpenOriginal,
      ),
      DocumentAvailability.unavailable => _UnavailableDocument(
        icon: Icons.article_outlined,
        title: 'Reliable extraction unavailable',
        message:
            document.errorMessage ??
            'No reconstructed section will be substituted for the Introduction.',
        onOpenOriginal: widget.onOpenOriginal,
      ),
      DocumentAvailability.failed => _UnavailableDocument(
        icon: Icons.error_outline,
        title: 'Document could not be loaded',
        message: document.errorMessage ?? 'The response could not be verified.',
        onRetry: () => ref
            .read(documentControllerProvider(args).notifier)
            .load(force: true),
        onOpenOriginal: widget.onOpenOriginal,
      ),
      DocumentAvailability.ready => _buildDocument(
        context,
        args,
        document,
        mode,
        researchEnabled ? researchArgs : null,
      ),
    };
  }

  Widget _buildDocument(
    BuildContext context,
    DocumentControllerArgs args,
    DocumentState state,
    ReaderDepthMode mode,
    ResearchControllerArgs? researchArgs,
  ) {
    final snapshot = state.snapshot!;
    final semanticDensity = snapshot.semanticFacetsIncluded
        ? ref.watch(semanticFacetDensityProvider(widget.readerKey))
        : SemanticDensity.off;
    final savedState = paperSavedStateProvider((
      accountId: args.accountId,
      authEpoch: args.authEpoch,
      paperId: args.paperId,
    ));
    final savedValue = ref.watch(savedState).value;
    final paperSaved = savedValue?.saved ?? false;
    if (savedValue != null) {
      final reconciliation =
          '${args.accountId}:${args.authEpoch}:${args.paperId}:$paperSaved';
      if (_scheduledVisualAssetSavedState != reconciliation) {
        _scheduledVisualAssetSavedState = reconciliation;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _scheduledVisualAssetSavedState != reconciliation) {
            return;
          }
          unawaited(_reconcileVisualAssetSavedState(args, paperSaved));
        });
      }
    }
    final allBlocks = snapshot.blocks;
    final visibleBlocks = visibleDocumentBlocksForMode(allBlocks, mode);
    final sectionTitles = documentSectionProgressTitles(
      outline: snapshot.outline,
      loadedBlocks: allBlocks,
    );
    _blockSectionNames
      ..clear()
      ..addEntries(
        visibleBlocks
            .where((block) => block.sectionPath.isNotEmpty)
            .map((block) => MapEntry(block.id, block.sectionPath.first.trim())),
      );
    if (widget.active && mode != ReaderDepthMode.skim) {
      _scheduleSectionProgressUpdate();
    }
    final blocksById = {for (final block in allBlocks) block.id: block};
    final interaction = ref.read(
      readerInteractionControllerProvider(widget.readerKey).notifier,
    );
    final documentScroll = NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis != Axis.vertical) return false;
        final extentAfter = notification.metrics.extentAfter;
        if (shouldLoadNextDocumentPage(
          mode: mode,
          active: widget.active,
          loadingMore: state.loadingMore,
          nextCursor: snapshot.nextCursor,
          extentAfter: extentAfter,
        )) {
          unawaited(
            ref.read(documentControllerProvider(args).notifier).loadNextPage(),
          );
        } else if (shouldRecordTrueDocumentEnd(
          mode: mode,
          active: widget.active,
          nextCursor: snapshot.nextCursor,
          extentAfter: extentAfter,
        )) {
          _recordEndOfDocument(snapshot);
        }
        return false;
      },
      child: CustomScrollView(
        key: ValueKey('document-${snapshot.paperId}-${snapshot.generation}'),
        controller: widget.scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: _DocumentControls(
              mode: mode,
              fromCache: state.fromCache,
              savingCheckpoint: state.savingCheckpoint,
              semanticDensity: snapshot.semanticFacetsIncluded
                  ? semanticDensity
                  : null,
              onSemanticDensityChanged: snapshot.semanticFacetsIncluded
                  ? (density) => ref
                        .read(semanticFacetControllerProvider(widget.readerKey))
                        .select(density)
                  : null,
              onOpenOutline: () => _openOutline(snapshot, interaction),
              onOpenAssistant: widget.onOpenAssistant == null
                  ? null
                  : () => _openAssistant(
                      interaction,
                      const AssistantRequestScope.paper(),
                    ),
              onSaveCheckpoint: widget.checkpointsEnabled
                  ? () => _saveCheckpoint(args, snapshot, mode)
                  : null,
              onOpenResearch: researchArgs == null
                  ? null
                  : () => _openResearchTools(researchArgs, interaction),
              onOpenOriginal: widget.onOpenOriginal,
            ),
          ),
          if (mode != ReaderDepthMode.skim && sectionTitles.isNotEmpty)
            SliverToBoxAdapter(
              child: ReaderSectionProgress(
                sections: sectionTitles,
                currentSection: _currentSectionName,
              ),
            ),
          if (widget.includePassport && snapshot.passport != null)
            SliverToBoxAdapter(
              child: PaperPassportCard(
                passport: snapshot.passport!,
                compact: mode == ReaderDepthMode.skim,
                feedbackArgs: PassportControllerArgs.authenticated(
                  accountId: args.accountId,
                  authEpoch: args.authEpoch,
                  paperId: args.paperId,
                  versionKey: args.versionKey,
                  generation: args.generation,
                  passportId: snapshot.passport!.id,
                  viewerScope: ref.watch(passportViewerScopeProvider),
                ),
                onRemember:
                    !widget.researchMemoryEnabled || researchArgs == null
                    ? null
                    : (field) => ref
                          .read(
                            researchControllerProvider(researchArgs).notifier,
                          )
                          .rememberPassportField(field),
                onInspectEvidence: (field) => _openEvidence(
                  title: field.key.replaceAll('_', ' '),
                  sourceIds: field.sourceBlockIds,
                  blocksById: blocksById,
                  status: field.status.wireValue,
                  interaction: interaction,
                ),
                onAskAssistant: widget.onOpenAssistant == null
                    ? null
                    : (field) => unawaited(
                        _askAboutPassportField(
                          interaction: interaction,
                          fieldKey: field.key,
                        ),
                      ),
              ),
            ),
          if (mode == ReaderDepthMode.inspect &&
              widget.includeVisualObjects &&
              snapshot.visualObjectsIncluded)
            SliverToBoxAdapter(
              child: DocumentObjectNavigator(
                figures: snapshot.figures,
                tables: snapshot.tables,
                equations: snapshot.equations,
                onInspect: (object) => _openObject(
                  object: object,
                  documentArgs: args,
                  paperSaved: paperSaved,
                  blocksById: blocksById,
                  interaction: interaction,
                  researchArgs: researchArgs,
                ),
              ),
            ),
          if (mode == ReaderDepthMode.inspect &&
              widget.includeVisualObjects &&
              !snapshot.visualObjectsIncluded)
            SliverToBoxAdapter(
              child: _VisualObjectsLoadState(
                loading: state.loadingVisualObjects,
                failed: state.visualObjectsFailed,
                onRetry: () {
                  _scheduledVisualObjectsLoadScope = null;
                  unawaited(
                    ref
                        .read(documentControllerProvider(args).notifier)
                        .loadVisualObjects(),
                  );
                },
              ),
            ),
          if (visibleBlocks.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No reliable document blocks are available. Open the original source to inspect this paper.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: visibleBlocks.length,
              itemBuilder: (context, index) {
                final block = visibleBlocks[index];
                final key = _blockKeys.putIfAbsent(block.id, GlobalKey.new);
                final exactHighlight = _assistantEvidenceHighlight;
                final highlightsThisBlock = exactHighlight?.blockId == block.id;
                final nextBlock = index + 1 < visibleBlocks.length
                    ? visibleBlocks[index + 1]
                    : null;
                final sectionBoundary =
                    mode != ReaderDepthMode.skim &&
                    nextBlock != null &&
                    isTopLevelSectionBoundary(block, nextBlock);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DocumentBlockRenderer(
                      key: key,
                      block: block,
                      terms: snapshot.terms,
                      semanticSpans: snapshot.semanticSpans
                          .where((span) => span.blockId == block.id)
                          .toList(growable: false),
                      semanticDensity: semanticDensity,
                      highlighted: state.highlightedBlockId == block.id,
                      highlightStart: highlightsThisBlock
                          ? exactHighlight!.start
                          : null,
                      highlightEnd: highlightsThisBlock
                          ? exactHighlight!.end
                          : null,
                      onSelectionChanged: (selection) => interaction.setActive(
                        ReaderInteractionKind.selection,
                        selection != null,
                      ),
                      onOpenTerm: (term) => unawaited(
                        _openDefinition(
                          term,
                          interaction,
                          contextBlockId: block.id,
                        ),
                      ),
                      onOpenReference: (reference) => unawaited(
                        _openInlineReference(
                          reference: reference,
                          block: block,
                          snapshot: snapshot,
                          documentArgs: args,
                          paperSaved: paperSaved,
                          blocksById: blocksById,
                          interaction: interaction,
                          researchArgs: researchArgs,
                        ),
                      ),
                      onHighlight:
                          !widget.annotationsEnabled || researchArgs == null
                          ? null
                          : (text) => _saveHighlight(
                              args: researchArgs,
                              block: block,
                              text: text,
                            ),
                      onAddNote:
                          !widget.annotationsEnabled || researchArgs == null
                          ? null
                          : (text) => _editAnnotation(
                              args: researchArgs,
                              block: block,
                              text: text,
                              kind: AnnotationKind.note,
                              interaction: interaction,
                            ),
                      onAskQuestion:
                          !widget.annotationsEnabled || researchArgs == null
                          ? null
                          : (text) => _editAnnotation(
                              args: researchArgs,
                              block: block,
                              text: text,
                              kind: AnnotationKind.question,
                              interaction: interaction,
                            ),
                      onAskAssistant: widget.onOpenAssistant == null
                          ? null
                          : (text) => unawaited(
                              _askAboutSelection(
                                interaction: interaction,
                                block: block,
                                selectedText: text,
                              ),
                            ),
                      onDefine: snapshot.semanticFacetsIncluded
                          ? (text) => unawaited(
                              _defineSelection(
                                selectedText: text,
                                blockId: block.id,
                                terms: snapshot.terms,
                                interaction: interaction,
                              ),
                            )
                          : null,
                      onSaveEvidence:
                          !widget.evidenceCardsEnabled || researchArgs == null
                          ? null
                          : (text) => _editEvidence(
                              args: researchArgs,
                              block: block,
                              text: text,
                              interaction: interaction,
                            ),
                      onReattach:
                          _pendingManualReattach == null || researchArgs == null
                          ? null
                          : (text) => _reattachHere(
                              args: researchArgs,
                              annotation: _pendingManualReattach!,
                              block: block,
                              text: text,
                            ),
                    ),
                    if (sectionBoundary)
                      _buildSectionStoppingPoint(
                        args: args,
                        snapshot: snapshot,
                        mode: mode,
                        current: block,
                        next: nextBlock,
                        interaction: interaction,
                      ),
                  ],
                );
              },
            ),
          if (mode == ReaderDepthMode.skim && visibleBlocks.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildSkimStoppingPoint(args, snapshot, interaction),
            )
          else if (snapshot.nextCursor == null && visibleBlocks.isNotEmpty)
            SliverToBoxAdapter(
              child: _buildDocumentEndStoppingPoint(
                args,
                snapshot,
                mode,
                interaction,
              ),
            )
          else if (snapshot.nextCursor != null)
            SliverToBoxAdapter(
              child: Semantics(
                liveRegion: state.loadingMore,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Center(
                      child: state.loadingMore
                          ? const CircularProgressIndicator.adaptive()
                          : const Text(
                              'Scroll to load more',
                              textAlign: TextAlign.center,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
    if (mode != ReaderDepthMode.read || widget.onOpenAssistant == null) {
      return documentScroll;
    }
    return Column(
      children: [
        Expanded(child: documentScroll),
        ReadAssistantComposer(
          key: ValueKey(
            'read-assistant-${args.accountId}-${args.authEpoch}-${args.paperId}-${args.generation}',
          ),
          enabled: widget.active,
          onCompositionChanged: (active) => interaction.setActive(
            ReaderInteractionKind.assistantComposer,
            widget.active && active,
          ),
          onSubmit: (question) => _submitReadAssistant(
            interaction: interaction,
            question: question,
          ),
        ),
      ],
    );
  }

  void _scheduleSectionProgressUpdate() {
    if (!mounted || !widget.active || _sectionProgressUpdateScheduled) return;
    _sectionProgressUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sectionProgressUpdateScheduled = false;
      if (!mounted || !widget.active) return;
      _updateSectionProgress();
    });
  }

  void _updateSectionProgress() {
    final threshold = MediaQuery.paddingOf(context).top + 160;
    String? beforeThreshold;
    var beforeDistance = double.infinity;
    String? afterThreshold;
    var afterDistance = double.infinity;
    for (final entry in _blockSectionNames.entries) {
      final renderObject = _blockKeys[entry.key]?.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      if (top <= threshold) {
        final distance = threshold - top;
        if (distance < beforeDistance) {
          beforeDistance = distance;
          beforeThreshold = entry.value;
        }
      } else {
        final distance = top - threshold;
        if (distance < afterDistance) {
          afterDistance = distance;
          afterThreshold = entry.value;
        }
      }
    }
    final next = beforeThreshold ?? afterThreshold;
    if (next != null && next != _currentSectionName) {
      setState(() => _currentSectionName = next);
    }
  }

  Widget _buildSkimStoppingPoint(
    DocumentControllerArgs args,
    DocumentSnapshot snapshot,
    ReaderInteractionController interaction,
  ) {
    return ReaderStoppingPoint(
      key: const ValueKey('skim-stopping-point'),
      semanticLabel: 'Skim stopping point',
      title: 'Skim ends here',
      message:
          'This compact preview stops deliberately. Continue when you want more depth; your Library state stays unchanged.',
      actions: [
        ReaderStoppingAction(
          label: 'Continue in Read',
          icon: Icons.menu_book_outlined,
          emphasized: true,
          onPressed: () => ref
              .read(readerModeControllerProvider(widget.readerKey))
              .select(ReaderDepthMode.read),
        ),
        ReaderStoppingAction(
          label: 'Inspect evidence',
          icon: Icons.fact_check_outlined,
          onPressed: () => ref
              .read(readerModeControllerProvider(widget.readerKey))
              .select(ReaderDepthMode.inspect),
        ),
        if (widget.onOpenAssistant != null)
          ReaderStoppingAction(
            label: 'Ask Assistant',
            icon: Icons.question_answer_outlined,
            onPressed: () => unawaited(
              _openAssistant(interaction, const AssistantRequestScope.paper()),
            ),
          ),
        if (widget.checkpointsEnabled)
          ReaderStoppingAction(
            label: 'Save checkpoint',
            icon: Icons.bookmark_add_outlined,
            onPressed: () =>
                _saveCheckpoint(args, snapshot, ReaderDepthMode.skim),
          ),
        if (widget.onOpenLibrary case final openLibrary?)
          ReaderStoppingAction(
            label: 'Open Library',
            icon: Icons.local_library_outlined,
            onPressed: openLibrary,
          ),
        ReaderStoppingAction(
          label: 'Original',
          icon: Icons.open_in_new,
          onPressed: widget.onOpenOriginal,
        ),
      ],
    );
  }

  Widget _buildSectionStoppingPoint({
    required DocumentControllerArgs args,
    required DocumentSnapshot snapshot,
    required ReaderDepthMode mode,
    required DocumentBlock current,
    required DocumentBlock next,
    required ReaderInteractionController interaction,
  }) {
    final currentSection = current.sectionPath.first.trim();
    final nextSection = next.sectionPath.first.trim();
    return ReaderStoppingPoint(
      key: ValueKey('section-stopping-point-${current.stableKey}'),
      semanticLabel: 'End of $currentSection. Next section: $nextSection',
      title: 'End of $currentSection',
      message:
          'Next: $nextSection. Pause here, save your place, or continue deliberately.',
      actions: [
        ReaderStoppingAction(
          label: 'Continue',
          icon: Icons.arrow_downward_rounded,
          emphasized: true,
          onPressed: () => _scrollToLoadedBlock(args, next.id, animated: true),
        ),
        if (widget.checkpointsEnabled)
          ReaderStoppingAction(
            label: 'Save checkpoint',
            icon: Icons.bookmark_add_outlined,
            onPressed: () => _saveCheckpoint(args, snapshot, mode),
          ),
        if (widget.onOpenAssistant != null)
          ReaderStoppingAction(
            label: 'Ask about section',
            icon: Icons.question_answer_outlined,
            onPressed: () => unawaited(
              _openAssistant(
                interaction,
                AssistantRequestScope.section(
                  kinds: [_assistantSectionKind(currentSection)],
                ),
              ),
            ),
          ),
        if (widget.onOpenLibrary case final openLibrary?)
          ReaderStoppingAction(
            label: 'Open Library',
            icon: Icons.local_library_outlined,
            onPressed: openLibrary,
          ),
        ReaderStoppingAction(
          label: 'Original',
          icon: Icons.open_in_new,
          onPressed: widget.onOpenOriginal,
        ),
      ],
    );
  }

  Widget _buildDocumentEndStoppingPoint(
    DocumentControllerArgs args,
    DocumentSnapshot snapshot,
    ReaderDepthMode mode,
    ReaderInteractionController interaction,
  ) {
    return ReaderStoppingPoint(
      key: const ValueKey('document-end-stopping-point'),
      semanticLabel: 'End of prepared document',
      title: 'A good place to stop',
      message:
          'You reached the end of this prepared document. Nothing was marked Reviewed or changed in your Library.',
      actions: [
        if (widget.checkpointsEnabled)
          ReaderStoppingAction(
            label: 'Save checkpoint',
            icon: Icons.bookmark_add_outlined,
            emphasized: true,
            onPressed: () => _saveCheckpoint(args, snapshot, mode),
          ),
        if (widget.onOpenAssistant != null)
          ReaderStoppingAction(
            label: 'Ask Assistant',
            icon: Icons.question_answer_outlined,
            onPressed: () => unawaited(
              _openAssistant(interaction, const AssistantRequestScope.paper()),
            ),
          ),
        if (widget.onOpenLibrary case final openLibrary?)
          ReaderStoppingAction(
            label: 'Open Library',
            icon: Icons.local_library_outlined,
            onPressed: openLibrary,
          ),
        ReaderStoppingAction(
          label: 'Original',
          icon: Icons.open_in_new,
          onPressed: widget.onOpenOriginal,
        ),
      ],
    );
  }

  Future<bool> _submitReadAssistant({
    required ReaderInteractionController interaction,
    required String question,
  }) async {
    if (!widget.active || normalizedAssistantQuestion(question) == null) {
      return false;
    }
    try {
      await _openAssistant(
        interaction,
        const AssistantRequestScope.paper(),
        initialQuestion: question,
      );
      return mounted;
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assistant could not be opened. Your draft remains.'),
          ),
        );
      }
      return false;
    }
  }

  void _recordEndOfDocument(DocumentSnapshot snapshot) {
    if (!widget.active) return;
    final signature = '${snapshot.paperId}|${snapshot.generation}';
    if (_endDocumentTelemetrySignature == signature) return;
    _endDocumentTelemetrySignature = signature;
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      PakPerkTelemetryEvent.endOfDocumentLibraryMutation,
      const {'mutation_attempted': false, 'explicit_user_action': false},
    );
  }

  AssistantSectionKind _assistantSectionKind(String sectionTitle) {
    final normalized = sectionTitle.trim().toLowerCase();
    if (normalized.contains('related work')) {
      return AssistantSectionKind.relatedWork;
    }
    if (normalized.contains('background')) {
      return AssistantSectionKind.background;
    }
    if (normalized.contains('method')) return AssistantSectionKind.method;
    if (normalized.contains('experiment')) {
      return AssistantSectionKind.experiment;
    }
    if (normalized.contains('result')) return AssistantSectionKind.result;
    if (normalized.contains('discussion')) {
      return AssistantSectionKind.discussion;
    }
    if (normalized.contains('limitation')) {
      return AssistantSectionKind.limitation;
    }
    if (normalized.contains('conclusion')) {
      return AssistantSectionKind.conclusion;
    }
    if (normalized.contains('appendix')) return AssistantSectionKind.appendix;
    if (normalized.contains('acknowledg')) {
      return AssistantSectionKind.acknowledgment;
    }
    if (normalized.contains('reference')) {
      return AssistantSectionKind.references;
    }
    if (normalized.contains('introduction')) {
      return AssistantSectionKind.introduction;
    }
    if (normalized.contains('abstract')) return AssistantSectionKind.abstract;
    return AssistantSectionKind.other;
  }

  void _scheduleVisualObjectsLoad(
    DocumentControllerArgs args,
    DocumentState state,
    ReaderDepthMode mode,
  ) {
    final snapshot = state.snapshot;
    if (!widget.active ||
        !widget.includeVisualObjects ||
        mode != ReaderDepthMode.inspect ||
        snapshot == null ||
        snapshot.visualObjectsIncluded ||
        state.loadingVisualObjects ||
        state.visualObjectsFailed) {
      return;
    }
    final scope = '${args.accountId}|${args.paperId}|${args.generation}';
    if (_scheduledVisualObjectsLoadScope == scope) return;
    _scheduledVisualObjectsLoadScope = scope;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      unawaited(
        ref.read(documentControllerProvider(args).notifier).loadVisualObjects(),
      );
    });
  }

  Future<void> _openOutline(
    DocumentSnapshot snapshot,
    ReaderInteractionController interaction,
  ) async {
    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    try {
      final blockId = await showSectionOutlineSheet(
        context: context,
        outline: snapshot.outline,
      );
      if (blockId != null && mounted) await _revealBlock(blockId);
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
  }

  Future<void> _openResearchTools(
    ResearchControllerArgs args,
    ReaderInteractionController interaction,
  ) async {
    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    try {
      await showResearchToolsSheet(
        context: context,
        args: args,
        annotationsEnabled: widget.annotationsEnabled,
        evidenceEnabled: widget.evidenceCardsEnabled,
        memoryEnabled: widget.researchMemoryEnabled,
        versionDiffEnabled: widget.versionDiffEnabled,
        onOpenAllMemory: widget.onOpenMemoryReview == null
            ? null
            : () {
                Navigator.of(context, rootNavigator: true).maybePop();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) widget.onOpenMemoryReview!();
                });
              },
        onRevealBlock: (blockId) {
          Navigator.of(context, rootNavigator: true).maybePop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_revealBlock(blockId));
          });
        },
        onRequestManualReattach: (annotation) {
          if (!mounted) return;
          setState(() => _pendingManualReattach = annotation);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Select the replacement source text, then choose Attach here.',
              ),
            ),
          );
        },
      );
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
  }

  Future<void> _saveHighlight({
    required ResearchControllerArgs args,
    required DocumentBlock block,
    required String text,
  }) => _commitResearchChange(
    () => ref
        .read(researchControllerProvider(args).notifier)
        .addHighlight(block: block, selectedText: text),
    'Highlight saved.',
  );

  Future<void> _editAnnotation({
    required ResearchControllerArgs args,
    required DocumentBlock block,
    required String text,
    required AnnotationKind kind,
    required ReaderInteractionController interaction,
  }) async {
    interaction.setActive(ReaderInteractionKind.noteEditor, true);
    try {
      final draft = await showAnnotationEditor(
        context: context,
        kind: kind,
        selectedText: text,
      );
      if (draft == null || !mounted) return;
      await _commitResearchChange(() {
        final controller = ref.read(researchControllerProvider(args).notifier);
        return kind == AnnotationKind.question
            ? controller.addQuestion(
                block: block,
                selectedText: text,
                body: draft.body,
              )
            : controller.addNote(
                block: block,
                selectedText: text,
                body: draft.body,
              );
      }, kind == AnnotationKind.question ? 'Question saved.' : 'Note saved.');
    } finally {
      interaction.setActive(ReaderInteractionKind.noteEditor, false);
    }
  }

  Future<void> _editEvidence({
    required ResearchControllerArgs args,
    required DocumentBlock block,
    required String text,
    required ReaderInteractionController interaction,
  }) async {
    interaction.setActive(ReaderInteractionKind.noteEditor, true);
    try {
      final draft = await showEvidenceCardEditor(
        context: context,
        selectedText: text,
      );
      if (draft == null || !mounted) return;
      await _commitResearchChange(
        () => ref
            .read(researchControllerProvider(args).notifier)
            .addEvidence(
              block: block,
              selectedText: text,
              title: draft.title,
              note: draft.note,
            ),
        'Evidence card saved.',
      );
    } finally {
      interaction.setActive(ReaderInteractionKind.noteEditor, false);
    }
  }

  Future<void> _reattachHere({
    required ResearchControllerArgs args,
    required Annotation annotation,
    required DocumentBlock block,
    required String text,
  }) async {
    await _commitResearchChange(
      () => ref
          .read(researchControllerProvider(args).notifier)
          .manualReattach(
            annotation: annotation,
            block: block,
            selectedText: text,
          ),
      'Annotation attached to the selected source.',
    );
    if (mounted) setState(() => _pendingManualReattach = null);
  }

  Future<void> _commitResearchChange(
    Future<Object?> Function() action,
    String confirmation,
  ) async {
    try {
      await action();
      if (!mounted) return;
      try {
        await HapticFeedback.lightImpact();
      } on Object {
        // Optional feedback only after the local durable commit.
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(confirmation)));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That research change could not be saved.'),
        ),
      );
    }
  }

  Future<void> _openDefinition(
    PaperTerm term,
    ReaderInteractionController interaction, {
    String? contextBlockId,
  }) async {
    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    String? sourceBlockId;
    try {
      sourceBlockId = await showDefinitionSheet(
        context: context,
        term: term,
        contextBlockId: contextBlockId,
      );
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
    if (sourceBlockId != null && mounted) {
      await _revealBlock(sourceBlockId);
    }
  }

  Future<void> _defineSelection({
    required String selectedText,
    required String blockId,
    required Iterable<PaperTerm> terms,
    required ReaderInteractionController interaction,
  }) async {
    final term = findUnambiguousPreparedTerm(
      selectedText: selectedText,
      blockId: blockId,
      terms: terms,
    );
    if (term != null) {
      await _openDefinition(term, interaction, contextBlockId: blockId);
      return;
    }
    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    try {
      await showUnavailableDefinitionSheet(
        context: context,
        selectedText: selectedText,
      );
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
  }

  Future<void> _openEvidence({
    required String title,
    required Iterable<String> sourceIds,
    required Map<String, DocumentBlock> blocksById,
    required String status,
    required ReaderInteractionController interaction,
    String? limitation,
  }) async {
    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    try {
      final boundedSourceIds = sourceIds
          .toSet()
          .take(128)
          .toList(growable: false);
      final blockId = await showSourceEvidenceSheet(
        context: context,
        title: title,
        sourceBlockIds: boundedSourceIds,
        blocksById: blocksById,
        loadSources: () => _loadSourceBlocks(boundedSourceIds),
        statusLabel: status,
        limitation: limitation,
      );
      if (blockId != null && mounted) await _revealBlock(blockId);
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
  }

  Future<List<DocumentBlock>> _loadSourceBlocks(List<String> sourceIds) async {
    final args = _scheduledLoad;
    if (args == null) return const [];
    final controller = ref.read(documentControllerProvider(args).notifier);
    for (final blockId in sourceIds) {
      await controller.ensureBlockLoaded(blockId);
      if (!mounted) return const [];
    }
    final blocks = ref.read(documentControllerProvider(args)).snapshot?.blocks;
    if (blocks == null) return const [];
    final blocksById = {for (final block in blocks) block.id: block};
    return sourceIds
        .map((id) => blocksById[id])
        .whereType<DocumentBlock>()
        .toList(growable: false);
  }

  Future<void> _openObject({
    required DocumentEvidenceObject object,
    required DocumentControllerArgs documentArgs,
    required bool paperSaved,
    required Map<String, DocumentBlock> blocksById,
    required ReaderInteractionController interaction,
    required ResearchControllerArgs? researchArgs,
  }) {
    final visualAssetVariant = visualAssetVariantForPixelWidth(
      MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context),
    );
    return showDocumentObjectSheet(
      context: context,
      object: object,
      interaction: interaction,
      onInspectSources: () {
        Navigator.of(context, rootNavigator: true).maybePop();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            _openEvidence(
              title: object.label,
              sourceIds: object.sourceBlockIds,
              blocksById: blocksById,
              status: object.status.name,
              limitation: object.limitation,
              interaction: interaction,
            ),
          );
        });
      },
      onInspectReference: (blockId) {
        Navigator.of(context, rootNavigator: true).maybePop();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_revealBlock(blockId));
        });
      },
      onOpenOriginal: () => widget.onOpenOriginalPage(object.page),
      loadFigureAsset:
          object is DocumentFigure &&
              object.assetRequestable &&
              object.assetRevision != null &&
              object.width != null &&
              object.height != null
          ? (cancellation) => ref
                .read(visualAssetRepositoryProvider)
                .acquire(
                  VisualAssetRequest(
                    accountId: documentArgs.accountId,
                    authEpoch: documentArgs.authEpoch,
                    paperId: documentArgs.paperId,
                    generation: documentArgs.generation,
                    figureId: object.id,
                    revision: object.assetRevision!,
                    width: object.width!,
                    height: object.height!,
                    variant: visualAssetVariant,
                  ),
                  saved: paperSaved,
                  cancellation: cancellation,
                )
          : null,
      onSaveEvidence: !widget.evidenceCardsEnabled || researchArgs == null
          ? null
          : () {
              Navigator.of(context, rootNavigator: true).maybePop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                unawaited(
                  _saveObjectEvidence(
                    args: researchArgs,
                    object: object,
                    interaction: interaction,
                  ),
                );
              });
            },
      onAskObject: widget.onOpenAssistant == null
          ? null
          : () {
              Navigator.of(context, rootNavigator: true).maybePop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                unawaited(_openAssistant(interaction, _assistantScope(object)));
              });
            },
    );
  }

  Future<void> _openInlineReference({
    required DocumentInlineSpan reference,
    required DocumentBlock block,
    required DocumentSnapshot snapshot,
    required DocumentControllerArgs documentArgs,
    required bool paperSaved,
    required Map<String, DocumentBlock> blocksById,
    required ReaderInteractionController interaction,
    required ResearchControllerArgs? researchArgs,
  }) async {
    final targetId = reference.targetId?.trim();
    final object = switch (reference.kind) {
      'figure_reference' =>
        snapshot.figures.where((value) => value.id == targetId).firstOrNull,
      'table_reference' =>
        snapshot.tables.where((value) => value.id == targetId).firstOrNull,
      'equation_reference' =>
        snapshot.equations.where((value) => value.id == targetId).firstOrNull,
      _ => null,
    };
    if (object != null) {
      await _openObject(
        object: object,
        documentArgs: documentArgs,
        paperSaved: paperSaved,
        blocksById: blocksById,
        interaction: interaction,
        researchArgs: researchArgs,
      );
      return;
    }

    interaction.setActive(ReaderInteractionKind.objectInspector, true);
    try {
      final openOriginal = await showInlineReferenceContextSheet(
        context: context,
        block: block,
        reference: reference,
      );
      if (openOriginal == true && mounted) {
        widget.onOpenOriginalPage(
          block.sourceLocator?.pageNumber ?? block.pageStart,
        );
      }
    } finally {
      interaction.setActive(ReaderInteractionKind.objectInspector, false);
    }
  }

  Future<void> _saveObjectEvidence({
    required ResearchControllerArgs args,
    required DocumentEvidenceObject object,
    required ReaderInteractionController interaction,
  }) async {
    interaction.setActive(ReaderInteractionKind.noteEditor, true);
    final visualAssetVariant = visualAssetVariantForPixelWidth(
      MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context),
    );
    try {
      final draft = await showEvidenceCardEditor(
        context: context,
        selectedText: object.caption ?? object.label,
        initialTitle: object.label,
      );
      if (draft == null || !mounted) return;
      await _commitResearchChange(() async {
        final result = await ref
            .read(researchControllerProvider(args).notifier)
            .addObjectEvidence(
              object: object,
              title: draft.title,
              note: draft.note,
            );
        if (object case DocumentFigure(assetRequestable: true)) {
          final revision = object.assetRevision;
          final width = object.width;
          final height = object.height;
          if (revision == null || width == null || height == null) {
            return result;
          }
          try {
            await ref
                .read(visualAssetRepositoryProvider)
                .pinAsEvidence(
                  VisualAssetRequest(
                    accountId: args.accountId,
                    authEpoch: args.authEpoch,
                    paperId: args.paperId,
                    generation: args.generation,
                    figureId: object.id,
                    revision: revision,
                    width: width,
                    height: height,
                    variant: visualAssetVariant,
                  ),
                );
          } on Object {
            // Evidence is already durable. A cache pin is best effort and
            // never changes the research-memory commit result.
          }
        }
        return result;
      }, 'Evidence card saved.');
    } finally {
      interaction.setActive(ReaderInteractionKind.noteEditor, false);
    }
  }

  Future<void> _reconcileVisualAssetSavedState(
    DocumentControllerArgs args,
    bool saved,
  ) async {
    try {
      await ref
          .read(visualAssetRepositoryProvider)
          .reconcilePaperSaved(
            VisualAssetPaperScope(
              accountId: args.accountId,
              authEpoch: args.authEpoch,
              paperId: args.paperId,
            ),
            saved: saved,
          );
    } on Object {
      // Saving is authoritative in Library. Cache priority reconciliation is
      // best effort and the hard disk ceiling still applies if it is delayed.
    }
  }

  Future<void> _askAboutSelection({
    required ReaderInteractionController interaction,
    required DocumentBlock block,
    required String selectedText,
  }) async {
    final exact = selectedText.trim();
    final codeUnitStart = exact.isEmpty ? -1 : block.text.indexOf(exact);
    final repeated =
        codeUnitStart >= 0 && block.text.lastIndexOf(exact) != codeUnitStart;
    if (codeUnitStart < 0 || repeated) {
      _showAssistantScopeUnavailable(
        repeated
            ? 'Select a unique passage so its exact source range can be verified.'
            : 'That selected passage could not be verified in this source block.',
      );
      return;
    }
    final start = block.text.substring(0, codeUnitStart).runes.length;
    final end = start + exact.runes.length;
    try {
      await _openAssistant(
        interaction,
        AssistantRequestScope.selection(
          blockId: block.id,
          start: start,
          end: end,
        ),
      );
    } on ArgumentError {
      _showAssistantScopeUnavailable(
        'That selected passage does not have a valid Assistant source identifier.',
      );
    }
  }

  Future<void> _askAboutPassportField({
    required ReaderInteractionController interaction,
    required String fieldKey,
  }) async {
    try {
      await _openAssistant(
        interaction,
        AssistantRequestScope.passportField(fieldKey),
      );
    } on ArgumentError {
      _showAssistantScopeUnavailable(
        'That Passport field cannot be used as an Assistant evidence scope.',
      );
    }
  }

  void _showAssistantScopeUnavailable(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  AssistantRequestScope _assistantScope(DocumentEvidenceObject object) =>
      AssistantRequestScope.object(
        kind: switch (object) {
          DocumentFigure() => AssistantScopeKind.figure,
          DocumentTable() => AssistantScopeKind.table,
          DocumentEquation() => AssistantScopeKind.equation,
          _ => throw StateError('Unsupported assistant object scope.'),
        },
        objectId: object.id,
      );

  Future<void> _openAssistant(
    ReaderInteractionController interaction,
    AssistantRequestScope scope, {
    String? initialQuestion,
  }) async {
    final open = widget.onOpenAssistant;
    if (open == null) return;
    interaction.setActive(ReaderInteractionKind.assistantComposer, true);
    try {
      await open(scope, initialQuestion);
    } finally {
      interaction.setActive(ReaderInteractionKind.assistantComposer, false);
    }
  }

  Future<void> _saveCheckpoint(
    DocumentControllerArgs args,
    DocumentSnapshot snapshot,
    ReaderDepthMode mode,
  ) async {
    final position = widget.scrollController.hasClients
        ? widget.scrollController.position
        : null;
    final fraction = position == null || position.maxScrollExtent <= 0
        ? 0.0
        : (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
    final highlighted = ref
        .read(documentControllerProvider(args))
        .highlightedBlockId;
    final blockId =
        highlighted ??
        _nearestVisibleBlockId(snapshot.blocks) ??
        snapshot.blocks.firstOrNull?.id;
    final saved = await ref
        .read(documentControllerProvider(args).notifier)
        .saveCheckpoint(
          mode: mode,
          stage: PaperStage.introduction,
          blockId: blockId,
          scrollFraction: fraction,
        );
    if (!mounted || !saved) return;
    ref
        .read(paperReaderNavigationControllerProvider(widget.readerKey))
        .setCheckpointPosition(blockId: blockId, scrollFraction: fraction);
    try {
      await HapticFeedback.lightImpact();
    } on Object {
      // Haptics are optional and occur only after the durable local commit.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reading checkpoint saved.')));
  }

  Future<void> _revealBlock(String blockId, {int? start, int? end}) async {
    ref
        .read(readerModeControllerProvider(widget.readerKey))
        .select(ReaderDepthMode.inspect);
    final args = _scheduledLoad;
    if (args == null) return;
    final controller = ref.read(documentControllerProvider(args).notifier);
    final available = await controller.ensureBlockLoaded(blockId);
    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That exact source passage is not available in the loaded document.',
          ),
        ),
      );
      return;
    }
    final exactRangeRequested = start != null || end != null;
    final targetBlock = ref
        .read(documentControllerProvider(args))
        .snapshot
        ?.blocks
        .where((block) => block.id == blockId)
        .firstOrNull;
    final exactRangeIsValid =
        start != null &&
        end != null &&
        targetBlock != null &&
        start >= 0 &&
        end > start &&
        end <= targetBlock.text.runes.length;
    if (exactRangeRequested && !exactRangeIsValid) {
      _highlightTimer?.cancel();
      controller.highlightBlock(null);
      if (_assistantEvidenceHighlight != null) {
        setState(() => _assistantEvidenceHighlight = null);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That exact source range is invalid for the current document generation.',
          ),
        ),
      );
      return;
    }
    _highlightTimer?.cancel();
    final exactHighlight = exactRangeIsValid
        ? (blockId: blockId, start: start, end: end)
        : null;
    if (_assistantEvidenceHighlight != exactHighlight) {
      setState(() => _assistantEvidenceHighlight = exactHighlight);
    }
    controller.highlightBlock(blockId);
    await _scrollToLoadedBlock(args, blockId, animated: true);
    if (!mounted) return;
    _highlightTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        if (_assistantEvidenceHighlight == exactHighlight &&
            exactHighlight != null) {
          setState(() => _assistantEvidenceHighlight = null);
        }
        ref
            .read(documentControllerProvider(args).notifier)
            .highlightBlock(null);
      }
    });
  }

  void _scheduleCheckpointRestore(
    DocumentControllerArgs args,
    ReadingCheckpoint? checkpoint,
  ) {
    final scope =
        '${args.accountId}|${args.authEpoch}|${args.paperId}|'
        '${args.versionKey}|${args.generation}';
    if (_checkpointRestoreScope == scope) return;
    _checkpointRestoreScope = scope;
    if (checkpoint == null || checkpoint.stage != PaperStage.introduction) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_checkpointScopeIsCurrent(args)) return;
      unawaited(_restoreRemoteCheckpoint(args, checkpoint));
    });
  }

  Future<void> _restoreRemoteCheckpoint(
    DocumentControllerArgs args,
    ReadingCheckpoint checkpoint,
  ) async {
    if (!_checkpointScopeIsCurrent(args)) return;
    final local = ref.read(readerNavigationStateProvider(widget.readerKey));
    if (!shouldApplyRemoteReaderCheckpoint(local)) return;
    ref
        .read(readerModeControllerProvider(widget.readerKey))
        .select(checkpoint.mode);
    ref
        .read(paperReaderNavigationControllerProvider(widget.readerKey))
        .setCheckpointPosition(
          blockId: checkpoint.blockId,
          scrollFraction: checkpoint.scrollFraction,
        );
    final blockId = checkpoint.blockId;
    if (blockId != null) {
      final available = await ref
          .read(documentControllerProvider(args).notifier)
          .ensureBlockLoaded(blockId);
      if (!_checkpointScopeIsCurrent(args) || !available) return;
      await _scrollToLoadedBlock(args, blockId, animated: false);
      return;
    }
    final fraction = checkpoint.scrollFraction;
    await WidgetsBinding.instance.endOfFrame;
    if (!_checkpointScopeIsCurrent(args) ||
        fraction == null ||
        !widget.scrollController.hasClients) {
      return;
    }
    final position = widget.scrollController.position;
    widget.scrollController.jumpTo(position.maxScrollExtent * fraction);
  }

  bool _checkpointScopeIsCurrent(DocumentControllerArgs args) {
    if (!mounted || !widget.active) return false;
    final scope = ref.read(verifiedLibraryScopeProvider);
    final generation = ref
        .read(paperProcessingControllerProvider(widget.paper.versionKey))
        .processing
        ?.generation;
    return scope?.accountId == args.accountId &&
        scope?.authEpoch == args.authEpoch &&
        widget.paper.paperId == args.paperId &&
        widget.paper.arxivId == args.versionKey &&
        generation == args.generation;
  }

  String? _nearestVisibleBlockId(List<DocumentBlock> blocks) {
    if (!widget.scrollController.hasClients) return null;
    final viewportTop = MediaQuery.paddingOf(context).top + 8;
    String? nearest;
    var nearestDistance = double.infinity;
    for (final block in blocks) {
      final blockContext = _blockKeys[block.id]?.currentContext;
      final renderBox = blockContext?.findRenderObject();
      if (renderBox is! RenderBox || !renderBox.attached) continue;
      final top = renderBox.localToGlobal(Offset.zero).dy;
      final bottom = top + renderBox.size.height;
      if (bottom < viewportTop) continue;
      final distance = (top - viewportTop).abs();
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = block.id;
      }
    }
    return nearest;
  }

  Future<void> _scrollToLoadedBlock(
    DocumentControllerArgs args,
    String blockId, {
    required bool animated,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    var blockContext = _blockKeys[blockId]?.currentContext;
    if (blockContext == null && widget.scrollController.hasClients) {
      final snapshot = ref.read(documentControllerProvider(args)).snapshot;
      final index = snapshot?.blocks.indexWhere((block) => block.id == blockId);
      if (index != null && index >= 0 && snapshot!.blocks.isNotEmpty) {
        final position = widget.scrollController.position;
        final target =
            position.maxScrollExtent * index / snapshot.blocks.length;
        if (!animated || platformPrefersReducedMotion(context)) {
          widget.scrollController.jumpTo(target);
        } else {
          await widget.scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutQuart,
          );
        }
        await WidgetsBinding.instance.endOfFrame;
        blockContext = _blockKeys[blockId]?.currentContext;
      }
    }
    if (blockContext != null && blockContext.mounted) {
      await Scrollable.ensureVisible(
        blockContext,
        duration: !animated || platformPrefersReducedMotion(blockContext)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        curve: Curves.easeOutQuart,
        alignment: .18,
      );
    }
  }
}

PaperTerm? findUnambiguousPreparedTerm({
  required String selectedText,
  required String blockId,
  required Iterable<PaperTerm> terms,
}) {
  final normalizedSelection = _normalizeDefinitionMatch(selectedText);
  if (normalizedSelection.isEmpty || normalizedSelection.runes.length > 512) {
    return null;
  }
  final matches = terms
      .where((term) {
        if (term.definitions.isEmpty ||
            !term.occurrences.any((value) => value.blockId == blockId)) {
          return false;
        }
        return _normalizeDefinitionMatch(term.displayTerm) ==
                normalizedSelection ||
            _normalizeDefinitionMatch(term.normalizedTerm) ==
                normalizedSelection;
      })
      .take(2)
      .toList(growable: false);
  return matches.length == 1 ? matches.single : null;
}

String _normalizeDefinitionMatch(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool shouldApplyRemoteReaderCheckpoint(ReaderNavigationState local) =>
    local.introductionOffset <= 0 &&
    local.checkpointBlockId == null &&
    local.checkpointScrollFraction == null &&
    local.depthMode == ReaderDepthMode.skim;

class _DocumentControls extends StatelessWidget {
  const _DocumentControls({
    required this.mode,
    required this.fromCache,
    required this.savingCheckpoint,
    required this.semanticDensity,
    required this.onSemanticDensityChanged,
    required this.onOpenOutline,
    required this.onOpenAssistant,
    required this.onSaveCheckpoint,
    required this.onOpenResearch,
    required this.onOpenOriginal,
  });

  final ReaderDepthMode mode;
  final bool fromCache;
  final bool savingCheckpoint;
  final SemanticDensity? semanticDensity;
  final ValueChanged<SemanticDensity>? onSemanticDensityChanged;
  final VoidCallback onOpenOutline;
  final VoidCallback? onOpenAssistant;
  final VoidCallback? onSaveCheckpoint;
  final VoidCallback? onOpenResearch;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${mode.label} · ${fromCache ? 'available offline' : 'current generation'}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ReaderAction(
                icon: Icons.toc_outlined,
                label: 'Outline',
                onPressed: onOpenOutline,
              ),
              if (onOpenAssistant != null)
                _ReaderAction(
                  icon: Icons.question_answer_outlined,
                  label: 'Assistant',
                  onPressed: onOpenAssistant!,
                ),
              if (onSaveCheckpoint != null)
                _ReaderAction(
                  icon: Icons.bookmark_add_outlined,
                  label: savingCheckpoint ? 'Saving…' : 'Checkpoint',
                  onPressed: savingCheckpoint ? null : onSaveCheckpoint,
                ),
              if (onOpenResearch != null)
                _ReaderAction(
                  icon: Icons.science_outlined,
                  label: 'Research',
                  onPressed: onOpenResearch,
                ),
              _ReaderAction(
                icon: Icons.open_in_new,
                label: 'Original',
                onPressed: onOpenOriginal,
              ),
            ],
          ),
          if (semanticDensity != null && onSemanticDensityChanged != null) ...[
            const SizedBox(height: 12),
            SemanticDensitySelector(
              selected: semanticDensity!,
              onSelected: onSemanticDensityChanged!,
            ),
          ],
        ],
      ),
    );
  }
}

class _ReaderAction extends StatelessWidget {
  const _ReaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: PakPerkSizes.minimumInteractive,
      ),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _VisualObjectsLoadState extends StatelessWidget {
  const _VisualObjectsLoadState({
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final label = failed
        ? 'Figure, table, and equation details could not be loaded.'
        : loading
        ? 'Loading figure, table, and equation details.'
        : 'Figure, table, and equation details load only in Inspect.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Card(
        child: Semantics(
          container: true,
          liveRegion: loading || failed,
          label: label,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Icon(
                    failed ? Icons.warning_amber_rounded : Icons.image_outlined,
                  ),
                const SizedBox(width: 12),
                Expanded(child: Text(label)),
                if (failed) ...[
                  const SizedBox(width: 8),
                  _ReaderAction(
                    icon: Icons.refresh,
                    label: 'Retry',
                    onPressed: onRetry,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DocumentLoading extends StatelessWidget {
  const _DocumentLoading();

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: 'Loading prepared document',
      child: const CircularProgressIndicator(),
    ),
  );
}

class _PreparationState extends StatelessWidget {
  const _PreparationState({
    required this.processing,
    required this.onPrepare,
    required this.onOpenOriginal,
  });

  final ProcessingUiState processing;
  final ValueChanged<PreparationTrigger> onPrepare;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final inFlight = processing.requestInFlight;
    return _UnavailableDocument(
      icon: Icons.auto_stories_outlined,
      title: inFlight ? 'Preparing document' : 'Document is not prepared',
      message: inFlight
          ? 'Preparation runs once for this committed reader action.'
          : 'Prepare the full document explicitly, or open the original source.',
      onRetry: inFlight
          ? null
          : () => onPrepare(PreparationTrigger.explicitPrepare),
      retryLabel: 'Prepare document',
      secondaryAction: inFlight
          ? null
          : () => onPrepare(PreparationTrigger.inspectEvidence),
      secondaryLabel: 'Inspect evidence',
      onOpenOriginal: onOpenOriginal,
    );
  }
}

class _UnavailableDocument extends StatelessWidget {
  const _UnavailableDocument({
    required this.icon,
    required this.title,
    required this.message,
    required this.onOpenOriginal,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.secondaryAction,
    this.secondaryLabel,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onOpenOriginal;
  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? secondaryAction;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44),
              const SizedBox(height: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onRetry != null)
                    _ReaderAction(
                      icon: Icons.refresh,
                      label: retryLabel,
                      onPressed: onRetry,
                    ),
                  if (secondaryAction != null && secondaryLabel != null)
                    _ReaderAction(
                      icon: Icons.fact_check_outlined,
                      label: secondaryLabel!,
                      onPressed: secondaryAction,
                    ),
                  _ReaderAction(
                    icon: Icons.open_in_new,
                    label: 'Open original',
                    onPressed: onOpenOriginal,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
