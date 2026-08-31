import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/reading_feed/reading_feed_models.dart';
import '../../core/recommendations/recommendation_interaction_api.dart';
import 'recommendation_explanation_sheet.dart';
import 'recommendation_interaction_controller.dart';

/// Owns the ephemeral interaction task for one visibly rendered server batch
/// recommendation. Invalid, legacy, queue, disabled, or incomplete provenance
/// renders no control and cannot issue a request.
class RecommendationFeedControl extends StatefulWidget {
  const RecommendationFeedControl({
    required this.item,
    required this.batchId,
    required this.authEpoch,
    required this.accountGeneration,
    required this.enabled,
    required this.remote,
    super.key,
  });

  final ReadingFeedItem item;
  final String? batchId;
  final int authEpoch;
  final int accountGeneration;
  final bool enabled;
  final RecommendationInteractionRemoteDataSource remote;

  @override
  State<RecommendationFeedControl> createState() =>
      _RecommendationFeedControlState();
}

class _RecommendationFeedControlState extends State<RecommendationFeedControl> {
  late RecommendationInteractionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(RecommendationFeedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.remote, widget.remote)) {
      _controller.dispose();
      _controller = _buildController();
      return;
    }
    _controller
      ..updateContext(_context)
      ..updateCapabilities(_capabilities);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  RecommendationInteractionController _buildController() =>
      RecommendationInteractionController(
        remote: widget.remote,
        context: _context,
        capabilities: _capabilities,
      );

  RecommendationItemContext? get _context {
    final batchId = widget.batchId;
    if (batchId == null) return null;
    try {
      return RecommendationItemContext.forRecommendation(
        item: widget.item,
        batchId: batchId,
        paperId: widget.item.paper.paperId,
        authEpoch: widget.authEpoch,
        accountGeneration: widget.accountGeneration,
      );
    } on ArgumentError {
      return null;
    }
  }

  RecommendationInteractionCapabilities get _capabilities {
    final recommendation = widget.item.recommendation;
    if (!widget.enabled || _context == null || recommendation == null) {
      return const RecommendationInteractionCapabilities.disabled();
    }
    return RecommendationInteractionCapabilities(
      explanations: recommendation.explanationAvailable,
      feedback: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (!_controller.controlsAvailable) return const SizedBox.shrink();
        final reasonLabel = widget.item.recommendation!.reasonLabel;
        return Semantics(
          container: true,
          excludeSemantics: true,
          button: true,
          label: 'Recommendation details. $reasonLabel',
          child: Tooltip(
            message: 'Why this paper? $reasonLabel',
            excludeFromSemantics: true,
            child: InkWell(
              key: const ValueKey('recommendation-feed-control'),
              onTap: () => unawaited(
                showRecommendationExplanationSheet(
                  context: context,
                  controller: _controller,
                  paperTitle: widget.item.paper.title,
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_awesome_outlined, size: 22),
                      SizedBox(height: 4),
                      Text(
                        'Why',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
