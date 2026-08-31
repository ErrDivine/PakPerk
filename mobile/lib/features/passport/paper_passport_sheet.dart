import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/paper_passport.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import 'passport_controller.dart';

typedef PassportFieldAction = FutureOr<void> Function(PassportField field);

Future<void> showPaperPassportSheet({
  required BuildContext context,
  required PaperPassport passport,
  required ValueChanged<PassportField> onInspectEvidence,
  ValueChanged<PassportField>? onAskAssistant,
  PassportFieldAction? onRemember,
  PassportControllerArgs? feedbackArgs,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  final reducedTransparency = platformPrefersReducedTransparency(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: reducedTransparency
        ? Theme.of(context).colorScheme.surface
        : null,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: .94,
      child: _PaperPassportSheet(
        passport: passport,
        onInspectEvidence: onInspectEvidence,
        onAskAssistant: onAskAssistant,
        onRemember: onRemember,
        feedbackArgs: feedbackArgs,
      ),
    ),
  );
}

class _PaperPassportSheet extends ConsumerStatefulWidget {
  const _PaperPassportSheet({
    required this.passport,
    required this.onInspectEvidence,
    required this.onAskAssistant,
    required this.onRemember,
    required this.feedbackArgs,
  });

  final PaperPassport passport;
  final ValueChanged<PassportField> onInspectEvidence;
  final ValueChanged<PassportField>? onAskAssistant;
  final PassportFieldAction? onRemember;
  final PassportControllerArgs? feedbackArgs;

  @override
  ConsumerState<_PaperPassportSheet> createState() =>
      _PaperPassportSheetState();
}

class _PaperPassportSheetState extends ConsumerState<_PaperPassportSheet> {
  String? _rememberingFieldId;
  String? _announcement;

  @override
  Widget build(BuildContext context) {
    final passport = widget.passport;
    return Semantics(
      container: true,
      label: 'Full Paper Passport for ${passport.versionLabel}',
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            automaticallyImplyLeading: false,
            title: const Text('Paper Passport'),
            actions: [
              IconButton(
                constraints: const BoxConstraints(
                  minWidth: PakPerkSizes.minimumInteractive,
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: 'Close Paper Passport',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${passport.versionLabel} · ${_passportStatus(passport.status)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'A source-linked reading aid generated from the prepared full paper. Inferences are labeled separately from author-stated evidence.',
                  ),
                  if (_announcement != null) ...[
                    const SizedBox(height: 10),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _announcement!,
                        key: const ValueKey('passport-live-feedback'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  _PassportInformationPanel(passport: passport),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: passport.fields.length,
            itemBuilder: (context, index) {
              final field = passport.fields[index];
              final canRemember =
                  widget.onRemember != null && field.isRememberable;
              return _PassportFieldPanel(
                field: field,
                remembering: _rememberingFieldId == field.id,
                onInspectEvidence: field.hasEvidence
                    ? () => _leaveFor(() => widget.onInspectEvidence(field))
                    : null,
                onAskAssistant: widget.onAskAssistant == null
                    ? null
                    : () => _leaveFor(() => widget.onAskAssistant!(field)),
                onRemember: canRemember ? () => _remember(field) : null,
                onReport:
                    widget.feedbackArgs == null ||
                        !passport.serverValidated ||
                        !field.serverValidated
                    ? null
                    : () => showPassportFeedbackComposer(
                        context: context,
                        args: widget.feedbackArgs!,
                        field: field,
                      ),
              );
            },
          ),
          if (widget.feedbackArgs != null && passport.serverValidated)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: OutlinedButton.icon(
                  key: const ValueKey('passport-report-general'),
                  style: _minimumButtonStyle(),
                  onPressed: () => showPassportFeedbackComposer(
                    context: context,
                    args: widget.feedbackArgs!,
                    field: null,
                    initialType: PassportFeedbackType.parserIssue,
                  ),
                  icon: const Icon(Icons.report_outlined),
                  label: const Text('Report a Passport issue'),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  void _leaveFor(VoidCallback action) {
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
  }

  Future<void> _remember(PassportField field) async {
    final action = widget.onRemember;
    if (action == null ||
        !field.isRememberable ||
        _rememberingFieldId != null) {
      return;
    }
    setState(() {
      _rememberingFieldId = field.id;
      _announcement = 'Saving ${field.displayLabel} to Memory…';
    });
    try {
      await action(field);
      if (!mounted) return;
      setState(() {
        _rememberingFieldId = null;
        _announcement = '${field.displayLabel} saved to Memory.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${field.displayLabel} saved to Memory.')),
      );
      unawaited(_committedSuccessHaptic());
    } on Object {
      if (!mounted) return;
      setState(() {
        _rememberingFieldId = null;
        _announcement = '${field.displayLabel} could not be saved to Memory.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${field.displayLabel} could not be saved to Memory.'),
        ),
      );
    }
  }

  Future<void> _committedSuccessHaptic() async {
    try {
      await HapticFeedback.lightImpact();
    } on Object {
      // Haptics are optional and occur only after the durable commit.
    }
  }
}

class _PassportFieldPanel extends StatelessWidget {
  const _PassportFieldPanel({
    required this.field,
    required this.remembering,
    required this.onInspectEvidence,
    required this.onAskAssistant,
    required this.onRemember,
    required this.onReport,
  });

  final PassportField field;
  final bool remembering;
  final VoidCallback? onInspectEvidence;
  final VoidCallback? onAskAssistant;
  final VoidCallback? onRemember;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label:
          '${field.displayLabel}. ${_fieldStatus(field.status)}. ${_authorshipLabel(field.status)}.',
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(field.displayLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Badge(label: _fieldStatus(field.status)),
                  _Badge(label: _authorshipLabel(field.status)),
                  _Badge(label: _sourceCoverage(field)),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                field.displayValue ?? _unavailableExplanation(field.status),
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onInspectEvidence != null)
                    OutlinedButton.icon(
                      key: ValueKey('passport-evidence-${field.key}'),
                      style: _minimumButtonStyle(),
                      onPressed: onInspectEvidence,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Exact evidence'),
                    ),
                  if (onAskAssistant != null)
                    OutlinedButton.icon(
                      key: ValueKey('passport-assistant-${field.key}'),
                      style: _minimumButtonStyle(),
                      onPressed: onAskAssistant,
                      icon: const Icon(Icons.question_answer_outlined),
                      label: const Text('Ask'),
                    ),
                  if (onRemember != null)
                    FilledButton.tonalIcon(
                      key: ValueKey('passport-remember-${field.key}'),
                      style: _minimumButtonStyle(),
                      onPressed: remembering ? null : onRemember,
                      icon: remembering
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.bookmark_add_outlined),
                      label: Text(remembering ? 'Saving…' : 'Remember'),
                    ),
                  if (onReport != null)
                    TextButton.icon(
                      key: ValueKey('passport-report-${field.key}'),
                      style: _minimumButtonStyle(),
                      onPressed: onReport,
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Correction'),
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

class _PassportInformationPanel extends StatelessWidget {
  const _PassportInformationPanel({required this.passport});

  final PaperPassport passport;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ExpansionTile(
      key: const ValueKey('passport-information-panel'),
      minTileHeight: PakPerkSizes.minimumInteractive,
      leading: const Icon(Icons.info_outline),
      title: const Text('Generation details'),
      subtitle: Text(
        'Generated ${_formatTimestamp(context, passport.createdAt)}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InformationRow(label: 'Paper version', value: passport.versionLabel),
        _InformationRow(label: 'Schema', value: passport.schemaVersion),
        _InformationRow(label: 'Parser', value: passport.parserId),
        _InformationRow(
          label: 'Model',
          value: passport.modelId ?? 'No model recorded',
        ),
        _InformationRow(
          label: 'Prompt',
          value: passport.promptVersion ?? 'No prompt recorded',
        ),
        _InformationRow(
          label: 'Last updated',
          value: _formatTimestamp(context, passport.updatedAt),
        ),
        _InformationRow(
          label: 'Provenance record',
          value: passport.provenanceId,
          selectable: true,
        ),
      ],
    ),
  );
}

class _InformationRow extends StatelessWidget {
  const _InformationRow({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 2),
        if (selectable) SelectableText(value) else Text(value),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelMedium),
  );
}

Future<void> showPassportFeedbackComposer({
  required BuildContext context,
  required PassportControllerArgs args,
  required PassportField? field,
  PassportFeedbackType initialType = PassportFeedbackType.wrongField,
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (context) => _PassportFeedbackComposer(
      args: args,
      field: field,
      initialType: initialType,
    ),
  );
}

class _PassportFeedbackComposer extends ConsumerStatefulWidget {
  const _PassportFeedbackComposer({
    required this.args,
    required this.field,
    required this.initialType,
  });

  final PassportControllerArgs args;
  final PassportField? field;
  final PassportFeedbackType initialType;

  @override
  ConsumerState<_PassportFeedbackComposer> createState() =>
      _PassportFeedbackComposerState();
}

class _PassportFeedbackComposerState
    extends ConsumerState<_PassportFeedbackComposer> {
  late PassportFeedbackType _type = widget.initialType;
  final TextEditingController _detail = TextEditingController();
  String? _hapticReceipt;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = passportControllerProvider(widget.args);
    final feedback = ref.watch(provider);
    ref.listen<PassportFeedbackState>(provider, (previous, next) {
      final receipt = next.receipt;
      if (next.phase != PassportFeedbackPhase.succeeded ||
          receipt == null ||
          _hapticReceipt == receipt.evaluationId) {
        return;
      }
      _hapticReceipt = receipt.evaluationId;
      unawaited(_successHaptic());
    });
    final scalarCount = _detail.text.runes.length;
    final detailInvalid =
        _detail.text.contains('\u0000') ||
        scalarCount > passportFeedbackMaximumScalars;
    return Semantics(
      container: true,
      label: widget.field == null
          ? 'Report a Paper Passport issue'
          : 'Report a correction for ${widget.field!.displayLabel}',
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.field == null
                    ? 'Report a Passport issue'
                    : 'Correct ${widget.field!.displayLabel}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              const Text(
                'Feedback creates a private evaluation record for review. It does not directly rewrite the shared Passport.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<PassportFeedbackType>(
                key: const ValueKey('passport-feedback-type'),
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Issue type'),
                items: PassportFeedbackType.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.displayLabel),
                      ),
                    )
                    .toList(growable: false),
                onChanged: feedback.isSubmitting
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _type = value);
                        ref.read(provider.notifier).clearStatus();
                      },
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('passport-feedback-detail'),
                controller: _detail,
                enabled: !feedback.isSubmitting,
                minLines: 3,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Details (optional)',
                  alignLabelWithHint: true,
                  helperText: detailInvalid
                      ? 'Use at most $passportFeedbackMaximumScalars characters and remove unsupported null characters.'
                      : '$scalarCount of $passportFeedbackMaximumScalars characters',
                  errorText: detailInvalid
                      ? 'Details are too long or invalid.'
                      : null,
                ),
                onChanged: (_) {
                  setState(() {});
                  ref.read(provider.notifier).clearStatus();
                },
              ),
              if (feedback.message != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    feedback.message!,
                    key: const ValueKey('passport-feedback-announcement'),
                    style: TextStyle(
                      color: feedback.phase == PassportFeedbackPhase.failed
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (feedback.phase == PassportFeedbackPhase.succeeded)
                FilledButton(
                  key: const ValueKey('passport-feedback-done'),
                  style: _minimumButtonStyle(),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('passport-feedback-submit'),
                  style: _minimumButtonStyle(),
                  onPressed: feedback.isSubmitting || detailInvalid
                      ? null
                      : () => ref
                            .read(provider.notifier)
                            .submit(
                              field: widget.field,
                              feedbackType: _type,
                              detail: _detail.text,
                            ),
                  icon: feedback.isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.send_outlined),
                  label: Text(
                    feedback.phase == PassportFeedbackPhase.failed
                        ? 'Try again'
                        : feedback.isSubmitting
                        ? 'Sending…'
                        : 'Send correction',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _successHaptic() async {
    try {
      await HapticFeedback.lightImpact();
    } on Object {
      // Optional feedback only after the server commits the evaluation.
    }
  }
}

ButtonStyle _minimumButtonStyle() => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(
    Size(PakPerkSizes.minimumInteractive, PakPerkSizes.minimumInteractive),
  ),
);

String _passportStatus(PassportStatus status) => switch (status) {
  PassportStatus.draft => 'Draft',
  PassportStatus.ready => 'Ready',
  PassportStatus.partial => 'Partial',
  PassportStatus.failed => 'Failed',
};

String _fieldStatus(PassportFieldStatus status) => switch (status) {
  PassportFieldStatus.supported => 'Supported',
  PassportFieldStatus.inferred => 'Inferred',
  PassportFieldStatus.notFound => 'Not found',
  PassportFieldStatus.notApplicable => 'Not applicable',
  PassportFieldStatus.conflicting => 'Conflicting evidence',
};

String _authorshipLabel(PassportFieldStatus status) => switch (status) {
  PassportFieldStatus.supported => 'Author-stated',
  PassportFieldStatus.inferred => 'Pakperk-derived',
  PassportFieldStatus.conflicting => 'Author statements conflict',
  PassportFieldStatus.notFound ||
  PassportFieldStatus.notApplicable => 'Unavailable',
};

String _sourceCoverage(PassportField field) {
  final count = field.sourceBlockIds.length;
  return switch (count) {
    0 => 'No source coverage',
    1 => '1 source block',
    _ => '$count source blocks',
  };
}

String _unavailableExplanation(PassportFieldStatus status) => switch (status) {
  PassportFieldStatus.notFound =>
    'No reliable evidence was found in the available document.',
  PassportFieldStatus.notApplicable =>
    'This field does not apply to this kind of paper.',
  PassportFieldStatus.conflicting =>
    'The prepared source contains materially conflicting statements.',
  PassportFieldStatus.supported ||
  PassportFieldStatus.inferred => 'The generated value is unavailable.',
};

String _formatTimestamp(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} at '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}
