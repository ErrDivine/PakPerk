import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/paper_passport.dart';
import '../../design_system/sizes.dart';
import 'paper_passport_sheet.dart';
import 'passport_controller.dart';

class PaperPassportCard extends StatelessWidget {
  const PaperPassportCard({
    required this.passport,
    required this.compact,
    required this.onInspectEvidence,
    this.onAskAssistant,
    this.onRemember,
    this.feedbackArgs,
    super.key,
  });

  final PaperPassport passport;
  final bool compact;
  final ValueChanged<PassportField> onInspectEvidence;
  final ValueChanged<PassportField>? onAskAssistant;
  final PassportFieldAction? onRemember;
  final PassportControllerArgs? feedbackArgs;

  @override
  Widget build(BuildContext context) {
    final visible = _compactFields(passport.fields);
    return Card(
      key: const ValueKey('paper-passport-compact-card'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Semantics(
        container: true,
        label: 'Generated Paper Passport for ${passport.versionLabel}',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Paper Passport',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Generated from the prepared full paper · '
                '${passport.versionLabel} · ${_passportStatus(passport.status)}',
              ),
              const SizedBox(height: 12),
              if (visible.isEmpty)
                const Text('No supported Passport fields are available.')
              else
                for (final (index, field) in visible.indexed) ...[
                  if (index > 0) const Divider(height: 24),
                  _CompactPassportField(
                    field: field,
                    compact: compact,
                    onInspectEvidence: field.hasEvidence
                        ? () => onInspectEvidence(field)
                        : null,
                    onAskAssistant: onAskAssistant == null
                        ? null
                        : () => onAskAssistant!(field),
                  ),
                ],
              if (passport.serverValidated) ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  key: const ValueKey('paper-passport-open-full'),
                  style: ButtonStyle(
                    minimumSize: const WidgetStatePropertyAll(
                      Size(
                        PakPerkSizes.minimumInteractive,
                        PakPerkSizes.minimumInteractive,
                      ),
                    ),
                  ),
                  onPressed: () => unawaited(
                    showPaperPassportSheet(
                      context: context,
                      passport: passport,
                      onInspectEvidence: onInspectEvidence,
                      onAskAssistant: onAskAssistant,
                      onRemember: onRemember,
                      feedbackArgs: feedbackArgs,
                    ),
                  ),
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('View full Passport'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactPassportField extends StatelessWidget {
  const _CompactPassportField({
    required this.field,
    required this.compact,
    required this.onInspectEvidence,
    required this.onAskAssistant,
  });

  final PassportField field;
  final bool compact;
  final VoidCallback? onInspectEvidence;
  final VoidCallback? onAskAssistant;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label:
        '${field.displayLabel}. ${_fieldStatus(field.status)}. ${_authorship(field.status)}.',
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: PakPerkSizes.minimumInteractive,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            field.displayLabel,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 3),
          Text(
            '${_fieldStatus(field.status)} · ${_authorship(field.status)} · '
            '${_coverage(field.sourceBlockIds.length)}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          Text(
            field.displayValue ?? _fieldStatus(field.status),
            maxLines: compact ? 3 : 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (onInspectEvidence != null || onAskAssistant != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onInspectEvidence != null)
                  IconButton.outlined(
                    constraints: const BoxConstraints(
                      minWidth: PakPerkSizes.minimumInteractive,
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    onPressed: onInspectEvidence,
                    tooltip: 'Show evidence for ${field.displayLabel}',
                    icon: const Icon(Icons.fact_check_outlined),
                  ),
                if (onAskAssistant != null)
                  IconButton.outlined(
                    constraints: const BoxConstraints(
                      minWidth: PakPerkSizes.minimumInteractive,
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    onPressed: onAskAssistant,
                    tooltip: 'Ask about ${field.displayLabel}',
                    icon: const Icon(Icons.question_answer_outlined),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

List<PassportField> _compactFields(List<PassportField> fields) {
  const preferred = ['contribution', 'method', 'main_result', 'limitations'];
  final byKey = {for (final field in fields) field.key: field};
  final result = <PassportField>[];
  for (final key in preferred) {
    final field = byKey[key];
    if (field != null && field.isGenerated) result.add(field);
  }
  if (result.isEmpty) {
    result.addAll(fields.where((field) => field.isGenerated).take(4));
  }
  return result.take(4).toList(growable: false);
}

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

String _authorship(PassportFieldStatus status) => switch (status) {
  PassportFieldStatus.supported => 'Author-stated',
  PassportFieldStatus.inferred => 'Pakperk-derived',
  PassportFieldStatus.conflicting => 'Author statements conflict',
  PassportFieldStatus.notFound ||
  PassportFieldStatus.notApplicable => 'Unavailable',
};

String _coverage(int count) => switch (count) {
  0 => 'No source coverage',
  1 => '1 source block',
  _ => '$count source blocks',
};
