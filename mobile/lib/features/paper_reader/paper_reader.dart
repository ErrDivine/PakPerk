import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/discovery_providers.dart';
import '../../app/feature_flags.dart';
import '../../app/router.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/interactions/interaction_models.dart';
import '../../core/library/library_models.dart';
import '../../core/models/assistant_v2.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';
import '../../core/widgets/paper_stage_indicator.dart';
import '../../core/widgets/status_widgets.dart';
import '../../design_system/motion.dart';
import '../chat/chat_controller.dart';
import '../connections/connections_controller.dart';
import '../connections/connections_view.dart';
import '../document_reader/document_screen.dart';
import '../document_reader/reader_entry_context.dart';
import '../document_reader/reader_interaction_state.dart';
import '../introduction/introduction_controller.dart';
import '../introduction/introduction_view.dart';
import '../reader_modes/reader_mode_selector.dart';
import 'abstract_view.dart';
import 'paper_action_bar.dart';
import 'paper_processing_controller.dart';
import 'reader_navigation_controller.dart';

class PaperReader extends ConsumerStatefulWidget {
  const PaperReader({
    required this.paper,
    required this.readerKey,
    required this.isActive,
    this.onOpenLinkedPaper,
    this.onPreviousPaper,
    this.onNextPaper,
    this.contextualAction,
    this.saveSourceKind,
    this.interactionContext,
    this.entryContext = const ReaderEntryContext.external(),
    super.key,
  });

  final PaperSummary paper;
  final String readerKey;
  final bool isActive;
  final ValueChanged<PaperSummary>? onOpenLinkedPaper;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;
  final Widget? contextualAction;
  final LibrarySaveSourceKind? saveSourceKind;
  final PaperInteractionContext? interactionContext;
  final ReaderEntryContext entryContext;

  @override
  ConsumerState<PaperReader> createState() => _PaperReaderState();
}

class _PaperReaderState extends ConsumerState<PaperReader> {
  late final PageController _horizontalController;
  late final ScrollController _abstractController;
  late final ScrollController _introductionController;
  late final ScrollController _connectionsController;
  late final Map<PaperStage, double> _restorationTargets;
  final Map<PaperStage, bool> _scrollRestored = {
    PaperStage.abstractView: true,
    PaperStage.introduction: false,
    PaperStage.connections: false,
  };
  RequestCancellation? _routeRequests;
  final Set<PaperInteractionEventType> _recordedInteractions = {};
  String? _readerEntryTelemetrySignature;

  @override
  void initState() {
    super.initState();
    final navigation = ref.read(
      readerNavigationStateProvider(widget.readerKey),
    );
    _horizontalController = PageController(
      initialPage: navigation.stageIndex.clamp(0, 2),
    );
    _restorationTargets = {
      for (final stage in PaperStage.values) stage: navigation.offsetFor(stage),
    };
    _abstractController = ScrollController(
      initialScrollOffset: _restorationTargets[PaperStage.abstractView] ?? 0,
      keepScrollOffset: false,
    );
    _introductionController = ScrollController(keepScrollOffset: false);
    _connectionsController = ScrollController(keepScrollOffset: false);
    _bindScroll(_abstractController, PaperStage.abstractView);
    _bindScroll(_introductionController, PaperStage.introduction);
    _bindScroll(_connectionsController, PaperStage.connections);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activateStage(navigation.stageIndex.clamp(0, 2));
    });
  }

  @override
  void didUpdateWidget(covariant PaperReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final paperChanged = oldWidget.paper.versionKey != widget.paper.versionKey;
    if (paperChanged) {
      _cancelRouteRequests();
      ref
          .read(
            paperProcessingControllerProvider(
              oldWidget.paper.versionKey,
            ).notifier,
          )
          .setVisible(false);
      _recordedInteractions.clear();
      _readerEntryTelemetrySignature = null;
    }
    if (oldWidget.entryContext.source != widget.entryContext.source ||
        paperChanged ||
        oldWidget.entryContext.queueMembership !=
            widget.entryContext.queueMembership) {
      _readerEntryTelemetrySignature = null;
      if (widget.isActive) _recordReaderEntryContext();
    }
    if (paperChanged || oldWidget.isActive != widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!widget.isActive) {
          _cancelRouteRequests();
          ref
              .read(
                paperProcessingControllerProvider(
                  widget.paper.versionKey,
                ).notifier,
              )
              .setVisible(false);
        } else {
          final stage = ref
              .read(readerNavigationStateProvider(widget.readerKey))
              .stageIndex;
          _activateStage(stage);
        }
      });
    }
  }

  @override
  void dispose() {
    _cancelRouteRequests();
    _horizontalController.dispose();
    _abstractController.dispose();
    _introductionController.dispose();
    _connectionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = ref.watch(
      readerNavigationStateProvider(widget.readerKey),
    );
    final processing = ref.watch(
      paperProcessingControllerProvider(widget.paper.versionKey),
    );
    final connections = ref.watch(
      connectionsControllerProvider(widget.paper.versionKey),
    );
    final capabilities =
        processing.processing?.capabilities ?? widget.paper.capabilities;
    final features = ref.watch(featureFlagsProvider);
    final enrichmentRequest = _enrichmentRequestFor(features);
    if (processing.enrichmentRequest != enrichmentRequest) {
      final paperKey = widget.paper.versionKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.paper.versionKey != paperKey) return;
        ref
            .read(paperProcessingControllerProvider(paperKey).notifier)
            .setEnrichmentRequest(enrichmentRequest);
      });
    }
    final readerInteraction = ref.watch(
      readerInteractionControllerProvider(widget.readerKey),
    );
    final repositoryOffline = ref.read(paperRepositoryProvider).isOffline;
    final offline = ref
        .watch(networkOfflineProvider)
        .when(
          data: (value) => value,
          loading: () => processing.offline || repositoryOffline,
          error: (_, __) => processing.offline || repositoryOffline,
        );

    ref.listen<ProcessingUiState>(
      paperProcessingControllerProvider(widget.paper.versionKey),
      (previous, next) {
        final previousGeneration = previous?.processing?.generation;
        final nextGeneration = next.processing?.generation;
        if (nextGeneration != null && previousGeneration != nextGeneration) {
          ref
              .read(
                introductionControllerProvider(
                  widget.paper.versionKey,
                ).notifier,
              )
              .acceptGeneration(nextGeneration);
          ref
              .read(
                connectionsControllerProvider(widget.paper.versionKey).notifier,
              )
              .acceptGeneration(nextGeneration);
          final chatProvider = chatControllerProvider(
            ChatControllerArgs(
              paperId: widget.paper.paperId,
              readerKey: widget.readerKey,
            ),
          );
          // Do not instantiate chat merely because processing loaded. If its
          // composer/route is already alive, constrain or invalidate that
          // controller before it can display a stale transcript.
          if (ref.exists(chatProvider)) {
            ref.read(chatProvider.notifier).acceptGeneration(nextGeneration);
          }
        }
        final nextCapabilities = next.processing?.capabilities;
        if (nextCapabilities?.introduction == true) {
          unawaited(
            ref
                .read(
                  introductionControllerProvider(
                    widget.paper.versionKey,
                  ).notifier,
                )
                .load(),
          );
        }
        if (nextCapabilities?.connections == true) {
          unawaited(
            ref
                .read(
                  connectionsControllerProvider(
                    widget.paper.versionKey,
                  ).notifier,
                )
                .load(),
          );
          if (previous?.processing?.capabilities.connections != true) {
            // Introduction is published before reference resolution. Refresh
            // once at that capability boundary so newly resolved markers
            // become tappable without losing progressive rendering.
            unawaited(
              ref
                  .read(
                    introductionControllerProvider(
                      widget.paper.versionKey,
                    ).notifier,
                  )
                  .load(force: true),
            );
          }
        }
      },
    );
    ref.listen<IntroductionState>(
      introductionControllerProvider(widget.paper.versionKey),
      (_, next) {
        if (next.value != null ||
            (!next.loading && next.errorMessage != null)) {
          _restoreScroll(PaperStage.introduction);
        }
      },
    );
    ref.listen<ConnectionsState>(
      connectionsControllerProvider(widget.paper.versionKey),
      (_, next) {
        if (next.value != null ||
            (!next.loading && next.errorMessage != null)) {
          _restoreScroll(PaperStage.connections);
        }
      },
    );

    final introductionState = ref.watch(
      introductionControllerProvider(widget.paper.versionKey),
    );
    if (introductionState.value != null) {
      _restoreScroll(PaperStage.introduction);
    }
    if (connections.value != null) {
      _restoreScroll(PaperStage.connections);
    }

    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (offline) const OfflineBanner(),
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PaperStageIndicator(
                    currentStage: PaperStage.fromIndex(navigation.stageIndex),
                    pageController: _horizontalController,
                    onSelected: _goToStage,
                    enabled: readerInteraction.canNavigateStages,
                  ),
                  if (features.deepReader) ...[
                    _ReaderEntryBadge(entryContext: widget.entryContext),
                    ReaderModeSelector(readerKey: widget.readerKey),
                  ],
                  if (features.library ||
                      features.comments ||
                      widget.contextualAction != null)
                    PaperActionBar(
                      paper: widget.paper,
                      contextualAction: widget.contextualAction,
                      saveSourceKind: widget.saveSourceKind,
                      interactionContext: widget.interactionContext,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (features.deepReader &&
                navigation.stageIndex != PaperStage.abstractView.index &&
                capabilities.introduction &&
                processing.enrichmentMessage != null)
              _ReaderEnrichmentNotice(
                message: processing.enrichmentMessage!,
                unavailable:
                    processing.enrichmentStatus ==
                    ProcessingEnrichmentStatus.unavailable,
              ),
            Expanded(
              child: PageView(
                key: ValueKey('paper-reader-${widget.readerKey}'),
                controller: _horizontalController,
                physics: readerInteraction.canDragPager
                    ? const PageScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                onPageChanged: _activateStage,
                children: [
                  AbstractView(
                    paper: widget.paper,
                    scrollController: _abstractController,
                    onStageRequested: _goToStage,
                    passportGeneration: processing.processing?.generation,
                    paperPassportReady: capabilities.paperPassport,
                    active:
                        widget.isActive &&
                        navigation.stageIndex == PaperStage.abstractView.index,
                    onPreviousPaper: readerInteraction.canNavigateVertically
                        ? widget.onPreviousPaper
                        : null,
                    onNextPaper: readerInteraction.canNavigateVertically
                        ? widget.onNextPaper
                        : null,
                  ),
                  if (features.deepReader)
                    DocumentScreen(
                      paper: widget.paper,
                      readerKey: widget.readerKey,
                      scrollController: _introductionController,
                      processing: processing,
                      active:
                          widget.isActive &&
                          navigation.stageIndex ==
                              PaperStage.introduction.index,
                      preparedAvailable: capabilities.introduction,
                      includePassport:
                          features.paperPassport && capabilities.paperPassport,
                      includeSemanticFacets:
                          features.semanticFacets &&
                          capabilities.semanticFacets &&
                          capabilities.terms,
                      includeVisualObjects:
                          features.documentVisualObjects &&
                          capabilities.visualObjects,
                      checkpointsEnabled: features.readingCheckpoints,
                      annotationsEnabled: features.annotations,
                      evidenceCardsEnabled: features.evidenceCards,
                      researchMemoryEnabled: features.researchMemory,
                      versionDiffEnabled: features.versionDiff,
                      onPrepare: _prepareWithTrigger,
                      onOpenAssistant: capabilities.chat
                          ? (scope, initialQuestion) => _openAssistant(
                              capabilities.chat && !offline,
                              scope,
                              initialQuestion: initialQuestion,
                            )
                          : null,
                      onOpenLibrary: features.library
                          ? () => context.go(PakPerkRoutes.library)
                          : null,
                      onOpenMemoryReview: features.researchMemory
                          ? _openMemoryReview
                          : null,
                      onOpenOriginal: _openOriginal,
                      onOpenOriginalPage: _openOriginalPage,
                    )
                  else
                    IntroductionView(
                      paper: widget.paper,
                      readerKey: widget.readerKey,
                      scrollController: _introductionController,
                      processing: processing,
                      capabilities: capabilities,
                      onOpenPaper: _openPaper,
                      onRetryPreparation: () => ref
                          .read(
                            paperProcessingControllerProvider(
                              widget.paper.versionKey,
                            ).notifier,
                          )
                          .prepare(
                            retry: true,
                            trigger: PreparationTrigger.explicitPrepare,
                          ),
                      onPreviousPaper: readerInteraction.canNavigateVertically
                          ? widget.onPreviousPaper
                          : null,
                      onNextPaper: readerInteraction.canNavigateVertically
                          ? widget.onNextPaper
                          : null,
                    ),
                  ConnectionsView(
                    paper: widget.paper,
                    scrollController: _connectionsController,
                    state: connections,
                    processing: processing,
                    capabilities: capabilities,
                    onOpenPaper: _openPaper,
                    onRetryPreparation: () => ref
                        .read(
                          paperProcessingControllerProvider(
                            widget.paper.versionKey,
                          ).notifier,
                        )
                        .prepare(
                          retry: true,
                          trigger: PreparationTrigger.explicitPrepare,
                        ),
                    onRetryConnections: () => ref
                        .read(
                          connectionsControllerProvider(
                            widget.paper.versionKey,
                          ).notifier,
                        )
                        .load(force: true),
                    onPreviousPaper: readerInteraction.canNavigateVertically
                        ? widget.onPreviousPaper
                        : null,
                    onNextPaper: readerInteraction.canNavigateVertically
                        ? widget.onNextPaper
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _bindScroll(ScrollController controller, PaperStage stage) {
    controller.addListener(() {
      if (!_scrollRestored[stage]!) return;
      ref
          .read(paperReaderNavigationControllerProvider(widget.readerKey))
          .setScrollOffset(stage, controller.offset);
    });
  }

  void _restoreScroll(PaperStage stage) {
    if (_scrollRestored[stage] == true) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrollRestored[stage] == true) return;
      final controller = switch (stage) {
        PaperStage.abstractView => _abstractController,
        PaperStage.introduction => _introductionController,
        PaperStage.connections => _connectionsController,
      };
      if (!controller.hasClients) return;
      final target = _restorationTargets[stage] ?? 0;
      final position = controller.position;
      controller.jumpTo(target.clamp(0, position.maxScrollExtent).toDouble());
      _scrollRestored[stage] = true;
    });
  }

  void _goToStage(PaperStage stage) {
    if (!ref
        .read(readerInteractionControllerProvider(widget.readerKey))
        .canNavigateStages) {
      return;
    }
    if (platformPrefersReducedMotion(context)) {
      _horizontalController.jumpToPage(stage.index);
      return;
    }
    _horizontalController.animateToPage(
      stage.index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _activateStage(int rawIndex) async {
    if (!mounted) return;
    _recordReaderEntryContext();
    final index = rawIndex.clamp(0, 2);
    final navigation = ref.read(
      paperReaderNavigationControllerProvider(widget.readerKey),
    );
    navigation.setStage(index);
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      PakPerkTelemetryEvent.paperStageCommitted,
      {
        'stage': switch (index) {
          0 => 'abstract',
          1 => 'introduction',
          _ => 'connections',
        },
      },
    );
    final processing = ref.read(
      paperProcessingControllerProvider(widget.paper.versionKey).notifier,
    );
    processing.setEnrichmentRequest(
      _enrichmentRequestFor(ref.read(featureFlagsProvider)),
    );
    if (!widget.isActive) {
      processing.setVisible(false);
      return;
    }
    final eventType = switch (index) {
      0 => PaperInteractionEventType.abstractOpened,
      1 => PaperInteractionEventType.introductionCommitted,
      _ => PaperInteractionEventType.connectionsOpened,
    };
    if (_recordedInteractions.add(eventType)) {
      final interaction = widget.interactionContext;
      ref
          .read(interactionEventBatcherProvider)
          .record(
            eventType: eventType,
            paperId: widget.paper.paperId,
            feedMode: interaction?.feedMode,
            batchId: interaction?.batchId,
            position: interaction?.position,
          );
    }
    if (index == PaperStage.abstractView.index) {
      processing.setVisible(false);
      return;
    }

    if (index == PaperStage.introduction.index) {
      if (navigation.commitPreparationIntent(index)) {
        processing.setVisible(true);
        await processing.prepare(
          trigger: PreparationTrigger.introductionTransition,
        );
      } else {
        processing.setVisible(false);
        await processing.recoverCommittedIntent();
        if (!_stillActiveStage(index)) return;
        processing.setVisible(true);
      }
      if (!mounted) return;
      final capabilities =
          ref
              .read(paperProcessingControllerProvider(widget.paper.versionKey))
              .processing
              ?.capabilities ??
          widget.paper.capabilities;
      if (capabilities.introduction) {
        await ref
            .read(
              introductionControllerProvider(widget.paper.versionKey).notifier,
            )
            .load();
      }
    } else if (index == PaperStage.connections.index) {
      final restoredNavigation = ref.read(
        readerNavigationStateProvider(widget.readerKey),
      );
      if (restoredNavigation.prepareRequested) {
        processing.setVisible(false);
        await processing.recoverCommittedIntent();
        if (!_stillActiveStage(index)) return;
      }
      processing.setVisible(true);
      final capabilities =
          ref
              .read(paperProcessingControllerProvider(widget.paper.versionKey))
              .processing
              ?.capabilities ??
          widget.paper.capabilities;
      if (capabilities.connections) {
        await ref
            .read(
              connectionsControllerProvider(widget.paper.versionKey).notifier,
            )
            .load();
      }
    }
  }

  void _recordReaderEntryContext() {
    if (!widget.isActive) return;
    final entry = widget.entryContext;
    final signature =
        '${widget.paper.versionKey}|${entry.source.wireValue}|'
        '${entry.queueMembership.wireValue}';
    if (_readerEntryTelemetrySignature == signature) return;
    _readerEntryTelemetrySignature = signature;
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      PakPerkTelemetryEvent.readerEntryContext,
      {
        'source': entry.source.wireValue,
        'queue_membership': entry.queueMembership.wireValue,
      },
    );
  }

  bool _stillActiveStage(int stageIndex) {
    if (!mounted || !widget.isActive) return false;
    return ref
            .read(readerNavigationStateProvider(widget.readerKey))
            .stageIndex ==
        stageIndex;
  }

  Future<void> _openPaper(String paperId) async {
    _captureOffsets();
    try {
      final result = await ref
          .read(paperRepositoryProvider)
          .getPaper(paperId, cancellation: _activeRouteRequests);
      if (!mounted) return;
      final onOpenLinkedPaper = widget.onOpenLinkedPaper;
      if (onOpenLinkedPaper != null) {
        onOpenLinkedPaper(result.value);
      } else {
        ref
            .read(appRestorationControllerProvider.notifier)
            .pushPaper(
              result.value,
              entryContext: ReaderEntryContext.connection(
                originReaderKey: widget.readerKey,
              ),
            );
      }
      final interaction = widget.interactionContext;
      ref
          .read(interactionEventBatcherProvider)
          .record(
            eventType: PaperInteractionEventType.openedConnection,
            paperId: widget.paper.paperId,
            feedMode: interaction?.feedMode,
            batchId: interaction?.batchId,
            position: interaction?.position,
          );
    } on ApiException catch (error) {
      if (error.cancelled) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.isOffline
                ? 'This paper is not cached. Reconnect to open its abstract.'
                : error.message,
          ),
        ),
      );
    }
  }

  RequestCancellation get _activeRouteRequests {
    final current = _routeRequests;
    if (current != null && !current.isCancelled) return current;
    return _routeRequests = RequestCancellation();
  }

  void _cancelRouteRequests() {
    _routeRequests?.cancel('The paper reader is no longer active.');
    _routeRequests = null;
  }

  void _captureOffsets() {
    final navigation = ref.read(
      paperReaderNavigationControllerProvider(widget.readerKey),
    );
    for (final entry in [
      (PaperStage.abstractView, _abstractController),
      (PaperStage.introduction, _introductionController),
      (PaperStage.connections, _connectionsController),
    ]) {
      if (entry.$2.hasClients) {
        navigation.setScrollOffset(entry.$1, entry.$2.offset);
      }
    }
  }

  void _prepareWithTrigger(PreparationTrigger trigger) {
    final current = ref.read(
      paperProcessingControllerProvider(widget.paper.versionKey),
    );
    final failed = switch (current.processing?.stage) {
      ProcessingStage.failedRetryable || ProcessingStage.failedTerminal => true,
      _ => false,
    };
    unawaited(
      ref
          .read(
            paperProcessingControllerProvider(widget.paper.versionKey).notifier,
          )
          .prepare(retry: failed, trigger: trigger),
    );
  }

  Future<void> _openAssistant(
    bool enabled,
    AssistantRequestScope scope, {
    String? initialQuestion,
  }) async {
    final interaction = ref.read(
      readerInteractionControllerProvider(widget.readerKey).notifier,
    );
    interaction.setActive(ReaderInteractionKind.assistantComposer, true);
    try {
      await openPaperChat(
        context,
        PaperChatRouteData(
          paperId: widget.paper.paperId,
          readerKey: widget.readerKey,
          paperTitle: widget.paper.title,
          chatEnabled: enabled,
          paperVersionKey: widget.paper.versionKey,
          generation: ref
              .read(paperProcessingControllerProvider(widget.paper.versionKey))
              .processing
              ?.generation,
          assistantScope: scope,
          initialQuestion: initialQuestion,
          submitInitialQuestion: initialQuestion != null,
        ),
      );
    } finally {
      interaction.setActive(ReaderInteractionKind.assistantComposer, false);
    }
  }

  void _openMemoryReview() {
    _captureOffsets();
    unawaited(
      context.push<void>(
        PakPerkRoutes.youMemory,
        extra: MemoryReviewRouteData(originReaderKey: widget.readerKey),
      ),
    );
  }

  Future<void> _openOriginal() => _openOriginalPage(null);

  Future<void> _openOriginalPage(int? page) async {
    final uri = widget.paper.canonicalPdfUri;
    final targetedUri = uri == null || page == null
        ? uri
        : uri.replace(fragment: 'page=$page');
    final opened =
        targetedUri != null &&
        await ref.read(externalLinkOpenerProvider).open(targetedUri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the original PDF.')),
      );
    }
  }
}

ProcessingEnrichmentRequest _enrichmentRequestFor(FeatureFlags features) =>
    ProcessingEnrichmentRequest(
      visualObjects: features.deepReader && features.documentVisualObjects,
      terms: features.deepReader && features.semanticFacets,
      semanticFacets: features.deepReader && features.semanticFacets,
      paperPassport: features.deepReader && features.paperPassport,
    );

class _ReaderEnrichmentNotice extends StatelessWidget {
  const _ReaderEnrichmentNotice({
    required this.message,
    required this.unavailable,
  });

  final String message;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('reader-enrichment-status'),
          width: double.infinity,
          color: unavailable
              ? colors.surfaceContainerHighest
              : colors.secondaryContainer,
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                unavailable ? Icons.info_outline : Icons.hourglass_top_rounded,
                size: 18,
                color: unavailable
                    ? colors.onSurfaceVariant
                    : colors.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unavailable
                        ? colors.onSurfaceVariant
                        : colors.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderEntryBadge extends StatelessWidget {
  const _ReaderEntryBadge({required this.entryContext});

  final ReaderEntryContext entryContext;

  @override
  Widget build(BuildContext context) {
    final inQueue =
        entryContext.queueMembership == ReaderQueueMembership.inToRead;
    final fromMemory = entryContext.source == ReaderEntrySource.memory;
    final label = fromMemory
        ? 'Opened from Research memory · Library unchanged'
        : inQueue
        ? 'In To Read'
        : 'Outside To Read';
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Semantics(
          label: fromMemory
              ? 'Opened from Research memory. Library and To Read state unchanged.'
              : inQueue
              ? 'In To Read'
              : 'Outside the active To Read queue',
          child: Chip(
            avatar: Icon(
              fromMemory
                  ? Icons.psychology_alt_outlined
                  : inQueue
                  ? Icons.playlist_add_check
                  : Icons.call_split_outlined,
              size: 18,
            ),
            label: Text(label),
          ),
        ),
      ),
    );
  }
}
