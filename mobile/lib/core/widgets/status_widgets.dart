import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/processing.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Offline. Showing cached paper data.',
      child: Container(
        width: double.infinity,
        color: PakPerkColors.ochre,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: const Text(
          'OFFLINE · Showing cached paper data',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: .5,
          ),
        ),
      ),
    );
  }
}

class BundledDemoNotice extends StatelessWidget {
  const BundledDemoNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          'Bundled demo content. Offline sample content, not a live parsed result.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'BUNDLED DEMO · Offline sample content',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Packaged with the app for demonstration; '
                    'this is not a live parsed result.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProcessingStatusCard extends StatelessWidget {
  const ProcessingStatusCard({
    required this.processing,
    this.fallbackMessage,
    this.busy = false,
    this.offline = false,
    this.onRetry,
    super.key,
  });

  final PaperProcessingState? processing;
  final String? fallbackMessage;
  final bool busy;
  final bool offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final state = processing;
    final message = offline && state == null
        ? 'You’re offline. Connect to prepare uncached paper content.'
        : fallbackMessage ??
              (state == null
                  ? 'Preparing the paper…'
                  : processingStageMessage(
                      state.stage,
                      errorMessage: state.lastErrorMessage,
                    ));
    final failed =
        state?.stage == ProcessingStage.failedRetryable ||
        state?.stage == ProcessingStage.failedTerminal;
    final showProgress =
        busy || (state != null && !state.stopsPolling && !offline);

    return Semantics(
      liveRegion: true,
      label: message,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showProgress)
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 14),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    failed ? Icons.error_outline : Icons.info_outline,
                    color: failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message),
                    if (onRetry != null && (failed || offline)) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: busy ? null : onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message),
            if (action != null) ...[const SizedBox(height: 10), action!],
          ],
        ),
      ),
    );
  }
}
