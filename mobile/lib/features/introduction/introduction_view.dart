import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/models/introduction.dart';
import '../../core/models/paper.dart';
import '../../core/models/processing.dart';
import '../../core/providers.dart';
import '../../core/widgets/status_widgets.dart';
import '../chat/chat_controller.dart';
import '../paper_reader/abstract_view.dart';
import '../paper_reader/paper_processing_controller.dart';
import '../paper_reader/reader_navigation_controller.dart';
import 'introduction_controller.dart';

class IntroductionView extends ConsumerStatefulWidget {
  const IntroductionView({
    required this.paper,
    required this.readerKey,
    required this.scrollController,
    required this.processing,
    required this.capabilities,
    required this.onRetryPreparation,
    this.onOpenPaper,
    this.onPreviousPaper,
    this.onNextPaper,
    super.key,
  });

  final PaperSummary paper;
  final String readerKey;
  final ScrollController scrollController;
  final ProcessingUiState processing;
  final PaperCapabilities capabilities;
  final VoidCallback onRetryPreparation;
  final ValueChanged<String>? onOpenPaper;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

  @override
  ConsumerState<IntroductionView> createState() => _IntroductionViewState();
}

class _IntroductionViewState extends ConsumerState<IntroductionView> {
  final TextEditingController _composer = TextEditingController();
  bool _chatRouteOpen = false;
  bool _restoredChatScheduled = false;

  ChatControllerArgs get _chatArgs => ChatControllerArgs(
    paperId: widget.paper.paperId,
    readerKey: widget.readerKey,
  );

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final introduction = ref.watch(
      introductionControllerProvider(widget.paper.versionKey),
    );
    final navigation = ref.watch(
      readerNavigationStateProvider(widget.readerKey),
    );
    final chat = ref.watch(chatControllerProvider(_chatArgs));
    final repositoryOffline = ref.read(paperRepositoryProvider).isOffline;
    final networkOffline = ref
        .watch(networkOfflineProvider)
        .when(
          data: (value) => value,
          loading: () => widget.processing.offline || repositoryOffline,
          error: (_, __) => widget.processing.offline || repositoryOffline,
        );
    final offline = networkOffline || introduction.offline;
    final chatEnabled = widget.capabilities.chat && !offline;
    final processingState = widget.processing.processing;
    final chatFailed =
        processingState != null &&
        !widget.capabilities.chat &&
        widget.capabilities.introduction &&
        (processingState.stage == ProcessingStage.failedRetryable ||
            processingState.stage == ProcessingStage.failedTerminal) &&
        ((processingState.lastErrorCode ?? '').contains('LLM') ||
            (processingState.lastErrorCode ?? '').contains('MODEL'));

    if (navigation.chatSheetOpen &&
        !_chatRouteOpen &&
        !_restoredChatScheduled) {
      _restoredChatScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openChat(chatEnabled));
      });
    }

    return Column(
      children: [
        Expanded(
          child: _IntroductionContent(
            paper: widget.paper,
            scrollController: widget.scrollController,
            state: introduction,
            processing: widget.processing,
            capabilities: widget.capabilities,
            offline: offline,
            onRetryPreparation: widget.onRetryPreparation,
            onRetryIntroduction: () => ref
                .read(
                  introductionControllerProvider(
                    widget.paper.versionKey,
                  ).notifier,
                )
                .load(force: true),
            onOpenPdf: _openPdf,
            onOpenCitation: _openCitation,
            onStarterQuestion: chatEnabled
                ? (question) => _ask(question, chatEnabled)
                : null,
            onPreviousPaper: widget.onPreviousPaper,
            onNextPaper: widget.onNextPaper,
          ),
        ),
        _PersistentChatComposer(
          controller: _composer,
          enabled: chatEnabled && !chat.restoring && !chat.sending,
          hintText: offline
              ? 'Offline — reconnect to ask a question'
              : chatFailed
              ? 'Paper chat is temporarily unavailable'
              : widget.capabilities.chat
              ? 'Ask about methods, results, or limitations…'
              : 'Indexing later sections…',
          onSend: () => _sendComposer(chatEnabled),
          onOpen: () => unawaited(_openChat(chatEnabled)),
        ),
      ],
    );
  }

  Future<void> _openPdf() async {
    final uri = widget.paper.canonicalPdfUri;
    final opened =
        uri != null && await ref.read(externalLinkOpenerProvider).open(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the original PDF.')),
      );
    }
  }

  Future<void> _openCitation(IntroductionCitation citation) async {
    final references = citation.references
        .where((reference) => reference.paperId.trim().isNotEmpty)
        .toList(growable: false);
    if (references.isEmpty || widget.onOpenPaper == null) return;
    if (references.length == 1) {
      widget.onOpenPaper!(references.single.paperId);
      return;
    }
    final selected = await showModalBottomSheet<IntroductionCitationReference>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Open cited paper')),
            for (final reference in references)
              ListTile(
                title: Text(reference.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, reference),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      widget.onOpenPaper!(selected.paperId);
    }
  }

  void _sendComposer(bool chatEnabled) {
    final value = _composer.text.trim();
    if (value.isEmpty) {
      unawaited(_openChat(chatEnabled));
      return;
    }
    _composer.clear();
    _ask(value, chatEnabled);
  }

  Future<void> _openChat(bool chatEnabled) async {
    if (_chatRouteOpen || !mounted) return;
    setState(() => _chatRouteOpen = true);
    try {
      await openPaperChat(
        context,
        PaperChatRouteData(
          paperId: widget.paper.paperId,
          readerKey: widget.readerKey,
          paperTitle: widget.paper.title,
          chatEnabled: chatEnabled,
        ),
      );
    } finally {
      if (mounted) setState(() => _chatRouteOpen = false);
    }
  }

  void _ask(String question, bool chatEnabled) {
    unawaited(_openChat(chatEnabled));
    unawaited(
      ref.read(chatControllerProvider(_chatArgs).notifier).send(question),
    );
  }
}

class _IntroductionContent extends StatelessWidget {
  const _IntroductionContent({
    required this.paper,
    required this.scrollController,
    required this.state,
    required this.processing,
    required this.capabilities,
    required this.offline,
    required this.onRetryPreparation,
    required this.onRetryIntroduction,
    required this.onOpenPdf,
    required this.onOpenCitation,
    required this.onStarterQuestion,
    this.onPreviousPaper,
    this.onNextPaper,
  });

  final PaperSummary paper;
  final ScrollController scrollController;
  final IntroductionState state;
  final ProcessingUiState processing;
  final PaperCapabilities capabilities;
  final bool offline;
  final VoidCallback onRetryPreparation;
  final VoidCallback onRetryIntroduction;
  final VoidCallback onOpenPdf;
  final ValueChanged<IntroductionCitation> onOpenCitation;
  final ValueChanged<String>? onStarterQuestion;
  final VoidCallback? onPreviousPaper;
  final VoidCallback? onNextPaper;

  static const starterQuestions = [
    'What method does this paper use?',
    'What is the main result?',
    'What limitations do the authors mention?',
  ];

  @override
  Widget build(BuildContext context) {
    final introduction = state.value;
    return CustomScrollView(
      key: const PageStorageKey('introduction-scroll'),
      controller: scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          sliver: SliverList.list(
            children: [
              Text(
                paper.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              Text(
                'INTRODUCTION',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 10),
              if (introduction != null) ...[
                if (state.bundledDemo) ...[
                  const BundledDemoNotice(),
                  const SizedBox(height: 14),
                ],
                Semantics(
                  header: true,
                  child: Text(
                    introduction.heading,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 14),
                for (final paragraph in introduction.paragraphs) ...[
                  if (paragraph.heading?.trim().isNotEmpty == true) ...[
                    Semantics(
                      key: ValueKey(
                        'introduction-subheading-${paragraph.ordinal}',
                      ),
                      header: true,
                      child: Text(
                        paragraph.heading!,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 7),
                  ],
                  IntroductionParagraphText(
                    paragraph: paragraph,
                    onOpenCitation: onOpenCitation,
                  ),
                  const SizedBox(height: 16),
                ],
                if (!capabilities.allReady) ...[
                  const SizedBox(height: 4),
                  ProcessingStatusCard(
                    processing: processing.processing,
                    busy: processing.requestInFlight,
                    offline: offline,
                    onRetry: processing.processing?.retryable == true || offline
                        ? onRetryPreparation
                        : null,
                  ),
                ],
              ] else if (state.errorMessage != null) ...[
                EmptyStateCard(
                  title: 'Introduction unavailable',
                  message:
                      processing.processing?.stage ==
                          ProcessingStage.failedTerminal
                      ? 'We could not reliably extract this paper’s introduction.'
                      : state.errorMessage!,
                  action: Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: onRetryIntroduction,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                      TextButton.icon(
                        onPressed: onOpenPdf,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open original PDF'),
                      ),
                    ],
                  ),
                ),
              ] else
                ProcessingStatusCard(
                  processing: processing.processing,
                  busy: state.loading || processing.requestInFlight,
                  offline: offline,
                  fallbackMessage:
                      processing.processing?.stage ==
                          ProcessingStage.failedTerminal
                      ? 'We could not reliably extract this paper’s introduction.'
                      : state.notReady
                      ? 'The introduction is still being prepared.'
                      : null,
                  onRetry:
                      offline ||
                          processing.processing?.stage ==
                              ProcessingStage.failedRetryable
                      ? onRetryPreparation
                      : null,
                ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onOpenPdf,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open original PDF on arXiv'),
              ),
              if (capabilities.chat && onStarterQuestion != null) ...[
                const SizedBox(height: 26),
                Text(
                  'ASK THE PAPER',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final question in starterQuestions)
                      ActionChip(
                        label: Text(question),
                        onPressed: () => onStarterQuestion!(question),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 28),
              PaperBoundaryActions(
                onPrevious: onPreviousPaper,
                onNext: onNextPaper,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class IntroductionParagraphText extends StatelessWidget {
  const IntroductionParagraphText({
    required this.paragraph,
    required this.onOpenCitation,
    super.key,
  });

  final IntroductionParagraph paragraph;
  final ValueChanged<IntroductionCitation> onOpenCitation;

  @override
  Widget build(BuildContext context) {
    final characters = paragraph.text.runes.toList(growable: false);
    final citations = [...paragraph.citations]
      ..sort((left, right) => left.start.compareTo(right.start));
    final bodyStyle = Theme.of(context).textTheme.bodyLarge;
    final linkStyle = bodyStyle?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: Theme.of(context).colorScheme.primary,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    var renderedCitationIndex = 0;
    for (final citation in citations) {
      if (citation.start < cursor ||
          citation.end <= citation.start ||
          citation.end > characters.length ||
          !citation.isNavigable) {
        continue;
      }
      final marker = String.fromCharCodes(
        characters.sublist(citation.start, citation.end),
      );
      if (marker != citation.marker) continue;
      if (citation.start > cursor) {
        spans.add(
          TextSpan(
            text: String.fromCharCodes(
              characters.sublist(cursor, citation.start),
            ),
          ),
        );
      }
      final citationIndex = renderedCitationIndex++;
      final titles = citation.references
          .map((reference) => reference.title)
          .join(', ');
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Semantics(
            link: true,
            label: '${citation.marker}, citation to $titles',
            child: InkWell(
              key: ValueKey(
                'citation-marker-${paragraph.ordinal}-$citationIndex',
              ),
              onTap: () => onOpenCitation(citation),
              child: Text(citation.marker, style: linkStyle),
            ),
          ),
        ),
      );
      cursor = citation.end;
    }
    if (cursor < characters.length) {
      spans.add(
        TextSpan(text: String.fromCharCodes(characters.sublist(cursor))),
      );
    }
    return SelectionArea(
      child: Text.rich(
        TextSpan(style: bodyStyle, children: spans),
        key: ValueKey('introduction-paragraph-${paragraph.ordinal}'),
      ),
    );
  }
}

class _PersistentChatComposer extends StatelessWidget {
  const _PersistentChatComposer({
    required this.controller,
    required this.enabled,
    required this.hintText,
    required this.onSend,
    required this.onOpen,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hintText;
  final VoidCallback onSend;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      child: SafeArea(
        top: false,
        bottom: false,
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 3,
                maxLength: 500,
                onTap: enabled ? onOpen : null,
                textInputAction: TextInputAction.send,
                onSubmitted: enabled ? (_) => onSend() : null,
                decoration: InputDecoration(
                  hintText: hintText,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: enabled ? 'Send question' : hintText,
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
