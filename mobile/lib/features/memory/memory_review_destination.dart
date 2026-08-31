import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/models/paper.dart';
import '../../core/models/research_memory.dart';
import '../../core/providers.dart';
import '../../design_system/spacing.dart';
import 'memory_controller.dart';
import 'memory_review_screen.dart';

typedef OpenMemorySource = void Function(PaperSummary paper, MemoryItem item);

final class MemoryReviewDestination extends ConsumerStatefulWidget {
  const MemoryReviewDestination({required this.onOpenSource, super.key});

  final OpenMemorySource onOpenSource;

  @override
  ConsumerState<MemoryReviewDestination> createState() =>
      _MemoryReviewDestinationState();
}

final class _MemoryReviewDestinationState
    extends ConsumerState<MemoryReviewDestination> {
  MemoryReviewScope? _loadedScope;
  RequestCancellation? _paperRequest;
  String? _openingItemId;
  String? _openErrorMessage;

  @override
  void dispose() {
    _paperRequest?.cancel('The memory review closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.researchMemory),
    );
    if (!enabled) {
      return const _UnavailableMemoryReview(
        message: 'Research memory is not enabled in this build.',
      );
    }
    final scope = ref.watch(verifiedLibraryScopeProvider);
    if (scope == null) {
      _paperRequest?.cancel('The verified account changed.');
      return const _UnavailableMemoryReview(
        message: 'Finish signing in to review private research memory.',
      );
    }
    final state = ref.watch(memoryReviewControllerProvider(scope));
    final controller = ref.read(memoryReviewControllerProvider(scope).notifier);
    if (_loadedScope != scope) {
      _loadedScope = scope;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(verifiedLibraryScopeProvider) != scope) {
          return;
        }
        unawaited(controller.load());
      });
    }
    return MemoryReviewScreen(
      state: state,
      now: DateTime.now(),
      openingItemId: _openingItemId,
      openErrorMessage: _openErrorMessage,
      onRefresh: () => unawaited(controller.load()),
      onOpenSource: (item) => unawaited(_openSource(scope, item)),
      onReviewed: (item, nextReviewAt) =>
          unawaited(controller.markReviewed(item, nextReviewAt: nextReviewAt)),
      onSnooze: (item, nextReviewAt) =>
          unawaited(controller.snooze(item, nextReviewAt: nextReviewAt)),
      onRetire: (item) => unawaited(controller.retire(item)),
    );
  }

  Future<void> _openSource(MemoryReviewScope scope, MemoryItem item) async {
    if (_openingItemId != null ||
        ref.read(verifiedLibraryScopeProvider) != scope) {
      return;
    }
    final current = ref
        .read(memoryReviewControllerProvider(scope))
        .items
        .where((value) => value.id == item.id)
        .firstOrNull;
    if (current == null ||
        current.paperId != item.paperId ||
        current.generation != item.generation ||
        !current.isReviewable) {
      setState(() {
        _openErrorMessage =
            'This memory item changed. Refresh before opening its source.';
      });
      return;
    }
    _paperRequest?.cancel('A different memory source was opened.');
    final request = RequestCancellation();
    _paperRequest = request;
    setState(() {
      _openingItemId = item.id;
      _openErrorMessage = null;
    });
    try {
      final result = await ref
          .read(paperRepositoryProvider)
          .getPaper(item.paperId, cancellation: request);
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope) {
        return;
      }
      final latest = ref
          .read(memoryReviewControllerProvider(scope))
          .items
          .where((value) => value.id == item.id)
          .firstOrNull;
      if (latest == null ||
          latest.paperId != item.paperId ||
          latest.generation != item.generation ||
          !latest.isReviewable) {
        setState(() {
          _openingItemId = null;
          _openErrorMessage =
              'This memory item changed while its source was opening.';
        });
        return;
      }
      setState(() => _openingItemId = null);
      widget.onOpenSource(result.value, latest);
    } on ApiException catch (error) {
      if (!mounted || error.cancelled || request.isCancelled) return;
      setState(() {
        _openingItemId = null;
        _openErrorMessage = error.isOffline
            ? 'This source paper is not cached. Reconnect and try again.'
            : error.message;
      });
    } on Object {
      if (!mounted || request.isCancelled) return;
      setState(() {
        _openingItemId = null;
        _openErrorMessage = 'The source paper could not be opened.';
      });
    }
  }
}

final class _UnavailableMemoryReview extends StatelessWidget {
  const _UnavailableMemoryReview({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Research memory')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(PakPerkSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: PakPerkSpacing.md),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
