import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/models/reader_state.dart';
import '../../core/providers.dart';
import '../../core/telemetry/telemetry.dart';
import '../../core/widgets/paper_stage_indicator.dart';
import '../../core/widgets/status_widgets.dart';
import '../../design_system/motion.dart';
import '../chat/chat_controller.dart';
import '../comments/paper_comments_control.dart';
import '../connections/connections_controller.dart';
import '../connections/connections_view.dart';
import '../introduction/introduction_controller.dart';
import '../introduction/introduction_view.dart';
import '../library/paper_save_control.dart';
import 'abstract_view.dart';
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
    super.key,
  });

  final PaperSummary paper;
  final String readerKey;
  final bool isActive;
  final ValueChanged<PaperSummary>? onOpenLinkedPaper;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

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
    if (oldWidget.isActive != widget.isActive) {
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
            PaperStageIndicator(
              currentStage: PaperStage.fromIndex(navigation.stageIndex),
              onSelected: _goToStage,
            ),
            const Divider(height: 1),
            if (ref.watch(featureFlagsProvider).library) ...[
              PaperSaveControl(paper: widget.paper),
              const Divider(height: 1),
            ],
            if (ref.watch(featureFlagsProvider).comments) ...[
              PaperCommentsControl(paper: widget.paper),
              const Divider(height: 1),
            ],
            Expanded(
              child: PageView(
                key: ValueKey('paper-reader-${widget.readerKey}'),
                controller: _horizontalController,
                onPageChanged: _activateStage,
                children: [
                  AbstractView(
                    paper: widget.paper,
                    scrollController: _abstractController,
                    onStageRequested: _goToStage,
                    onPreviousPaper: widget.onPreviousPaper,
                    onNextPaper: widget.onNextPaper,
                  ),
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
                        .prepare(retry: true),
                    onPreviousPaper: widget.onPreviousPaper,
                    onNextPaper: widget.onNextPaper,
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
                        .prepare(retry: true),
                    onRetryConnections: () => ref
                        .read(
                          connectionsControllerProvider(
                            widget.paper.versionKey,
                          ).notifier,
                        )
                        .load(force: true),
                    onPreviousPaper: widget.onPreviousPaper,
                    onNextPaper: widget.onNextPaper,
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
    if (!widget.isActive) {
      processing.setVisible(false);
      return;
    }
    if (index == PaperStage.abstractView.index) {
      processing.setVisible(false);
      return;
    }

    if (index == PaperStage.introduction.index) {
      if (navigation.commitPreparationIntent(index)) {
        processing.setVisible(true);
        await processing.prepare();
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
            .pushPaper(result.value);
      }
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
}
