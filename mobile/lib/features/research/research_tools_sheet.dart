import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/annotation.dart';
import '../../core/models/evidence_card.dart';
import '../../core/models/research_memory.dart';
import '../../core/providers.dart';
import '../../core/research/research_api.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../evidence/evidence_card_editor.dart';
import '../memory/memory_review_screen.dart';
import '../version_diff/version_history_panel.dart';
import 'research_controller.dart';

Future<void> showResearchToolsSheet({
  required BuildContext context,
  required ResearchControllerArgs args,
  required ValueChanged<String> onRevealBlock,
  required ValueChanged<Annotation> onRequestManualReattach,
  required bool annotationsEnabled,
  required bool evidenceEnabled,
  required bool memoryEnabled,
  required bool versionDiffEnabled,
  VoidCallback? onOpenAllMemory,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    sheetAnimationStyle: platformPrefersReducedMotion(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _ResearchToolsSheet(
      args: args,
      onRevealBlock: onRevealBlock,
      onRequestManualReattach: onRequestManualReattach,
      annotationsEnabled: annotationsEnabled,
      evidenceEnabled: evidenceEnabled,
      memoryEnabled: memoryEnabled,
      versionDiffEnabled: versionDiffEnabled,
      onOpenAllMemory: onOpenAllMemory,
    ),
  );
}

class _ResearchToolsSheet extends ConsumerWidget {
  const _ResearchToolsSheet({
    required this.args,
    required this.onRevealBlock,
    required this.onRequestManualReattach,
    required this.annotationsEnabled,
    required this.evidenceEnabled,
    required this.memoryEnabled,
    required this.versionDiffEnabled,
    this.onOpenAllMemory,
  });

  final ResearchControllerArgs args;
  final ValueChanged<String> onRevealBlock;
  final ValueChanged<Annotation> onRequestManualReattach;
  final bool annotationsEnabled;
  final bool evidenceEnabled;
  final bool memoryEnabled;
  final bool versionDiffEnabled;
  final VoidCallback? onOpenAllMemory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(researchControllerProvider(args));
    final controller = ref.read(researchControllerProvider(args).notifier);
    final tabs = <({String label, IconData icon, Widget body})>[
      if (annotationsEnabled)
        (
          label: 'Notes',
          icon: Icons.border_color_outlined,
          body: _AnnotationsPanel(
            state: state,
            controller: controller,
            onRevealBlock: onRevealBlock,
            onRequestManualReattach: onRequestManualReattach,
          ),
        ),
      if (evidenceEnabled)
        (
          label: 'Evidence',
          icon: Icons.fact_check_outlined,
          body: _EvidencePanel(
            state: state,
            controller: controller,
            onRevealBlock: onRevealBlock,
          ),
        ),
      if (memoryEnabled)
        (
          label: 'Memory',
          icon: Icons.psychology_alt_outlined,
          body: _MemoryPanel(
            state: state,
            controller: controller,
            paperId: args.paperId,
            onRevealBlock: onRevealBlock,
            onOpenAllMemory: onOpenAllMemory,
          ),
        ),
      if (versionDiffEnabled)
        (
          label: 'Versions',
          icon: Icons.difference_outlined,
          body: VersionHistoryPanel(
            repository: controller.repository,
            scope: controller.scope,
            linkOpener: ref.watch(externalLinkOpenerProvider),
            annotations: state.annotations,
          ),
        ),
    ];
    if (tabs.isEmpty) return const SizedBox.shrink();
    return DefaultTabController(
      length: tabs.length,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .9,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Research tools',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (annotationsEnabled)
                        _SheetAction(
                          icon: Icons.download_outlined,
                          label: 'Import',
                          onPressed: () => _import(context, controller),
                        ),
                      _SheetAction(
                        icon: Icons.ios_share_outlined,
                        label: 'Export',
                        onPressed: () => _export(context, controller),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (state.offline)
              Semantics(
                liveRegion: true,
                child: Container(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  padding: const EdgeInsets.all(12),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_off_outlined),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Offline: edits are saved on this device and keep their operation IDs for later sync.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (state.errorMessage != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(state.errorMessage!),
                ),
              ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: const ListTile(
                leading: Icon(Icons.privacy_tip_outlined),
                title: Text('Private, account-scoped research data'),
                subtitle: Text(
                  'Sign-out and account deletion remove these local rows. This build does not claim the local SQLite database is encrypted; device access controls and OS file protection remain part of the threat boundary.',
                ),
              ),
            ),
            TabBar(
              isScrollable: true,
              tabs: [
                for (final tab in tabs)
                  Tab(icon: Icon(tab.icon), text: tab.label),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(children: [for (final tab in tabs) tab.body]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(
    BuildContext context,
    ResearchController controller,
  ) async {
    final format = await showModalBottomSheet<ResearchExportFormat>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      sheetAnimationStyle: platformPrefersReducedMotion(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Copy bounded export',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Exports include your research artifacts and citation metadata, not the complete paper text. Large exports are copied one complete part at a time; save each part before choosing Next part.',
            ),
            const SizedBox(height: 12),
            for (final value in ResearchExportFormat.values)
              _SheetAction(
                icon: value == ResearchExportFormat.markdown
                    ? Icons.text_snippet_outlined
                    : Icons.data_object,
                label: switch (value) {
                  ResearchExportFormat.json => 'Copy JSON',
                  ResearchExportFormat.markdown => 'Copy Markdown',
                  ResearchExportFormat.manifest => 'Copy export manifest',
                },
                onPressed: () => Navigator.of(context).pop(value),
              ),
          ],
        ),
      ),
    );
    if (format == null || !context.mounted) return;
    await _copyExportPart(context, controller, format);
  }

  Future<void> _copyExportPart(
    BuildContext context,
    ResearchController controller,
    ResearchExportFormat format, {
    String? cursor,
  }) async {
    try {
      final artifact = await controller.repository.exportResearch(
        scope: controller.scope,
        format: format,
        cursor: cursor,
      );
      final text = utf8.decode(artifact.bytes);
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      try {
        await HapticFeedback.lightImpact();
      } on Object {
        // Optional feedback only after the export is durably on the clipboard.
      }
      if (!context.mounted) return;
      final nextCursor = artifact.nextCursor;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            artifact.pageNumber == 1 && artifact.isComplete
                ? '${artifact.fileName} copied.'
                : artifact.isComplete
                ? '${artifact.fileName} part ${artifact.pageNumber} copied. Export complete.'
                : '${artifact.fileName} part ${artifact.pageNumber} copied.',
          ),
          action: nextCursor == null
              ? null
              : SnackBarAction(
                  label: 'Next part',
                  onPressed: () => unawaited(
                    _copyExportPart(
                      context,
                      controller,
                      format,
                      cursor: nextCursor,
                    ),
                  ),
                ),
        ),
      );
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The bounded export could not be copied.'),
        ),
      );
    }
  }

  Future<void> _import(
    BuildContext context,
    ResearchController controller,
  ) async {
    try {
      final clipboard = await Clipboard.getData('text/plain');
      final archive = clipboard?.text;
      if (archive == null || archive.trim().isEmpty) {
        throw const ApiException(
          code: 'EMPTY_ANNOTATION_IMPORT',
          message: 'Copy a Pakperk JSON research export before importing.',
          statusCode: 400,
        );
      }
      if (!context.mounted) return;
      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        sheetAnimationStyle: platformPrefersReducedMotion(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (context) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Import annotation archive?',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This sends only the annotation-bearing part of the copied Pakperk JSON export to your account, restoring annotations plus their exact conflict and re-anchor history. It does not send or import papers, Library state, evidence cards, memory, or assistant history. Matching IDs are skipped; any mismatch aborts the whole import.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SheetAction(
                      icon: Icons.close,
                      label: 'Cancel',
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                    _SheetAction(
                      icon: Icons.download_done_outlined,
                      label: 'Import',
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final result = await controller.repository.importAnnotationArchive(
        scope: controller.scope,
        encodedArchive: archive,
      );
      if (!context.mounted) return;
      try {
        await HapticFeedback.lightImpact();
      } on Object {
        // Optional feedback follows server acceptance, never clipboard read.
      }
      if (!context.mounted) return;
      final restored = result.importedAnnotations;
      final skipped = result.skippedAnnotations;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$restored annotations imported; $skipped existing annotations kept.',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The annotation archive could not be imported.'),
        ),
      );
    }
  }
}

class _AnnotationsPanel extends StatelessWidget {
  const _AnnotationsPanel({
    required this.state,
    required this.controller,
    required this.onRevealBlock,
    required this.onRequestManualReattach,
  });

  final ResearchState state;
  final ResearchController controller;
  final ValueChanged<String> onRevealBlock;
  final ValueChanged<Annotation> onRequestManualReattach;

  @override
  Widget build(BuildContext context) {
    if (state.annotations.isEmpty && state.conflicts.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.border_color_outlined,
        title: 'No annotations yet',
        message:
            'Select source text to highlight it, add a note, or save a question.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        if (state.conflicts.isNotEmpty) ...[
          Text('Merge review', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final conflict in state.conflicts)
            Card(
              child: ListTile(
                minVerticalPadding: 12,
                leading: const Icon(Icons.call_merge_outlined),
                title: const Text('Note changed on two devices'),
                subtitle: const Text(
                  'Both bodies are preserved. Choose or edit a merged result.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _reviewConflict(context, conflict),
              ),
            ),
          const SizedBox(height: 12),
        ],
        for (final annotation in state.annotations)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_annotationIcon(annotation)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          annotation.kind.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      _SyncLabel(state: annotation.syncState),
                    ],
                  ),
                  if (annotation.selector?.exact case final quote?) ...[
                    const SizedBox(height: 6),
                    Text(
                      '“$quote”',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (annotation.body case final body?) ...[
                    const SizedBox(height: 6),
                    Text(body),
                  ],
                  if (annotation.needsAnchorReview) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_outlined),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            annotation.anchorStatus ==
                                    AnnotationAnchorStatus.orphaned
                                ? 'Original quote not found in this generation.'
                                : 'Possible source match needs your review.',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (annotation.blockId != null)
                        _SheetAction(
                          icon: Icons.my_location_outlined,
                          label: 'Exact source',
                          onPressed: () => onRevealBlock(annotation.blockId!),
                        ),
                      if (annotation.needsAnchorReview) ...[
                        _SheetAction(
                          icon: Icons.refresh,
                          label: 'Re-run anchor',
                          onPressed: () => _commit(
                            context,
                            () => controller.reanchor(annotation),
                            'Anchor review queued.',
                          ),
                        ),
                        _SheetAction(
                          icon: Icons.link,
                          label: 'Attach manually',
                          onPressed: () {
                            onRequestManualReattach(annotation);
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                      _SheetAction(
                        icon: Icons.psychology_alt_outlined,
                        label: 'Remember',
                        onPressed: () => _commit(
                          context,
                          () => controller.rememberAnnotation(annotation),
                          'Added to research memory.',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _reviewConflict(
    BuildContext context,
    AnnotationConflict conflict,
  ) async {
    final annotation = state.annotations
        .where((value) => value.id == conflict.annotationId)
        .firstOrNull;
    if (annotation == null) return;
    final merged = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      sheetAnimationStyle: platformPrefersReducedMotion(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => _ConflictMergeEditor(conflict: conflict),
    );
    if (!context.mounted || merged == null) return;
    await _commit(
      context,
      () => controller.mergeConflict(
        annotation: annotation,
        conflict: conflict,
        mergedBody: merged,
      ),
      'Merge saved and pending server confirmation.',
    );
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({
    required this.state,
    required this.controller,
    required this.onRevealBlock,
  });

  final ResearchState state;
  final ResearchController controller;
  final ValueChanged<String> onRevealBlock;

  @override
  Widget build(BuildContext context) {
    if (state.evidenceCards.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.fact_check_outlined,
        title: 'No evidence cards yet',
        message: 'Select an exact source passage and choose Evidence.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: state.evidenceCards.length,
      itemBuilder: (context, index) {
        final card = state.evidenceCards[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.fact_check_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        card.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    _SyncLabel(state: card.syncState),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Verification: ${_verificationLabel(card.verificationStatus)}',
                ),
                if (card.claimOrQuestion case final claim?) ...[
                  const SizedBox(height: 6),
                  Text(claim, maxLines: 5, overflow: TextOverflow.ellipsis),
                ],
                if (card.userNote case final note?) ...[
                  const SizedBox(height: 6),
                  Text(note),
                ],
                if (card.verificationStatus !=
                    EvidenceVerificationStatus.userReviewed) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Review this card before adding it to research memory.',
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (card.sourceBlockIds.firstOrNull case final blockId?)
                      _SheetAction(
                        icon: Icons.my_location_outlined,
                        label: 'Exact source',
                        onPressed: () => onRevealBlock(blockId),
                      ),
                    _SheetAction(
                      icon:
                          card.verificationStatus ==
                              EvidenceVerificationStatus.userReviewed
                          ? Icons.edit_outlined
                          : Icons.fact_check_outlined,
                      label:
                          card.verificationStatus ==
                              EvidenceVerificationStatus.userReviewed
                          ? 'Edit'
                          : 'Review first',
                      onPressed: () => _edit(context, card),
                    ),
                    if (card.verificationStatus ==
                        EvidenceVerificationStatus.userReviewed)
                      _SheetAction(
                        icon: Icons.psychology_alt_outlined,
                        label: 'Remember',
                        onPressed: () => _commit(
                          context,
                          () => controller.rememberEvidence(card),
                          'Added to research memory.',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, EvidenceCard card) async {
    final draft = await showEvidenceCardEditor(
      context: context,
      selectedText: card.claimOrQuestion ?? card.title,
      initialTitle: card.title,
      initialNote: card.userNote,
    );
    if (draft == null || !context.mounted) return;
    await _commit(
      context,
      () => controller.repository.updateEvidenceCard(
        scope: controller.scope,
        card: card,
        title: draft.title,
        claimOrQuestion: card.claimOrQuestion,
        userNote: draft.note,
        verificationStatus: EvidenceVerificationStatus.userReviewed,
      ),
      'Evidence card updated.',
    );
  }
}

class _MemoryPanel extends StatelessWidget {
  const _MemoryPanel({
    required this.state,
    required this.controller,
    required this.paperId,
    required this.onRevealBlock,
    required this.onOpenAllMemory,
  });

  final ResearchState state;
  final ResearchController controller;
  final String paperId;
  final ValueChanged<String> onRevealBlock;
  final VoidCallback? onOpenAllMemory;

  @override
  Widget build(BuildContext context) {
    final items = state.memoryItems
        .where((item) => item.paperId == paperId)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onOpenAllMemory != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _SheetAction(
              icon: Icons.view_list_outlined,
              label: 'Review due memory across papers',
              onPressed: onOpenAllMemory,
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? const _EmptyPanel(
                  icon: Icons.psychology_alt_outlined,
                  title: 'No memory items for this paper',
                  message:
                      'Only artifacts you explicitly choose are added here.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final blockId = _memoryBlockId(item, state);
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.psychology_alt_outlined),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    item.promptText ??
                                        'Saved research artifact',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                _SyncLabel(state: item.syncState),
                              ],
                            ),
                            if (item.answerText case final answer?) ...[
                              const SizedBox(height: 6),
                              Text(answer),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              'Status: ${item.status.name} · reviewed ${item.reviewCount} times',
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (blockId != null)
                                  _SheetAction(
                                    icon: Icons.my_location_outlined,
                                    label: 'Open source in this paper',
                                    onPressed: () => onRevealBlock(blockId),
                                  ),
                                _SheetAction(
                                  icon: Icons.check_circle_outline,
                                  label: 'Reviewed',
                                  onPressed: () => _scheduleReview(
                                    context,
                                    item,
                                    title: 'Schedule after review',
                                    confirmation:
                                        'Review recorded with your next review time.',
                                  ),
                                ),
                                _SheetAction(
                                  icon: Icons.snooze,
                                  label: 'Snooze',
                                  onPressed: () => _scheduleReview(
                                    context,
                                    item,
                                    title: 'Snooze until',
                                    confirmation:
                                        'Memory item snoozed until your chosen time.',
                                  ),
                                ),
                                _SheetAction(
                                  icon: Icons.archive_outlined,
                                  label: 'Retire',
                                  onPressed: () => _commit(
                                    context,
                                    () => controller.reviewMemory(
                                      item: item,
                                      status: MemoryStatus.retired,
                                    ),
                                    'Memory item retired.',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _scheduleReview(
    BuildContext context,
    MemoryItem item, {
    required String title,
    required String confirmation,
  }) async {
    final nextReviewAt = await showMemoryReviewSchedulePicker(
      context: context,
      title: title,
      now: DateTime.now(),
    );
    if (nextReviewAt == null || !context.mounted) return;
    await _commit(
      context,
      () => controller.reviewMemory(
        item: item,
        // The API permits a next_review_at only on a snoozed item. Recording
        // the review still increments review_count server-side.
        status: MemoryStatus.snoozed,
        nextReviewAt: nextReviewAt,
      ),
      confirmation,
    );
  }
}

class _ConflictMergeEditor extends StatefulWidget {
  const _ConflictMergeEditor({required this.conflict});

  final AnnotationConflict conflict;

  @override
  State<_ConflictMergeEditor> createState() => _ConflictMergeEditorState();
}

class _ConflictMergeEditorState extends State<_ConflictMergeEditor> {
  late final TextEditingController _merged;

  @override
  void initState() {
    super.initState();
    _merged = TextEditingController(text: widget.conflict.attemptedBody);
  }

  @override
  void dispose() {
    _merged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      20 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Merge note', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _BodyVersion(
            label: 'This device',
            body: widget.conflict.attemptedBody,
          ),
          _BodyVersion(
            label: 'Server version',
            body: widget.conflict.serverBody,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _merged,
            minLines: 4,
            maxLines: 10,
            maxLength: 32000,
            decoration: const InputDecoration(
              labelText: 'Merged note',
              border: OutlineInputBorder(),
            ),
          ),
          _SheetAction(
            icon: Icons.call_merge,
            label: 'Save merged note',
            onPressed: () => Navigator.of(context).pop(_merged.text.trim()),
          ),
        ],
      ),
    ),
  );
}

class _BodyVersion extends StatelessWidget {
  const _BodyVersion({required this.label, required this.body});

  final String label;
  final String? body;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(body?.isNotEmpty == true ? body! : 'Empty note'),
        ],
      ),
    ),
  );
}

class _SyncLabel extends StatelessWidget {
  const _SyncLabel({required this.state});

  final ResearchSyncState state;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Sync status ${state.name}',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(switch (state) {
          ResearchSyncState.clean => Icons.cloud_done_outlined,
          ResearchSyncState.pending => Icons.cloud_upload_outlined,
          ResearchSyncState.conflict => Icons.call_merge_outlined,
          ResearchSyncState.failed => Icons.cloud_off_outlined,
        }, size: 18),
        const SizedBox(width: 4),
        Text(state.name),
      ],
    ),
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
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

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

Future<void> _commit(
  BuildContext context,
  Future<Object?> Function() action,
  String confirmation,
) async {
  try {
    await action();
    if (!context.mounted) return;
    try {
      await HapticFeedback.lightImpact();
    } on Object {
      // Haptics are optional and only follow the local durable commit.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(confirmation)));
  } on ApiException catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.message)));
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('That research change could not be saved.')),
    );
  }
}

IconData _annotationIcon(Annotation annotation) => switch (annotation.kind) {
  AnnotationKind.highlight => Icons.border_color_outlined,
  AnnotationKind.note => Icons.note_outlined,
  AnnotationKind.question => Icons.help_outline,
  AnnotationKind.evidence => Icons.fact_check_outlined,
};

String _verificationLabel(EvidenceVerificationStatus status) =>
    switch (status) {
      EvidenceVerificationStatus.userSelected => 'user selected',
      EvidenceVerificationStatus.userReviewed => 'user reviewed',
      EvidenceVerificationStatus.superseded => 'superseded',
    };

String? _memoryBlockId(MemoryItem item, ResearchState state) {
  if (item.sourceType == MemorySourceType.annotation) {
    return state.annotations
        .where((value) => value.id == item.sourceId)
        .firstOrNull
        ?.blockId;
  }
  if (item.sourceType == MemorySourceType.evidenceCard) {
    return state.evidenceCards
        .where((value) => value.id == item.sourceId)
        .firstOrNull
        ?.sourceBlockIds
        .firstOrNull;
  }
  return null;
}
