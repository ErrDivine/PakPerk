import 'package:flutter/material.dart';

import '../../core/models/assistant_v2.dart';
import '../../design_system/sizes.dart';

typedef AssistantEvidenceFeedbackSelection = ({
  AssistantEvidenceFeedbackType type,
  int? claimIndex,
  String? evidenceBlockId,
  String? detail,
});

/// Collects a narrowly scoped report about answer evidence.
///
/// This deliberately does not expose generic positive/negative sentiment.
/// Every submission names an evidence failure category and, where required,
/// an exact persisted claim and source block.
class AssistantEvidenceFeedbackForm extends StatefulWidget {
  const AssistantEvidenceFeedbackForm({
    required this.answer,
    required this.enabled,
    required this.sending,
    required this.onSubmit,
    required this.onCancel,
    super.key,
  });

  final AssistantAnswer answer;
  final bool enabled;
  final bool sending;
  final ValueChanged<AssistantEvidenceFeedbackSelection> onSubmit;
  final VoidCallback onCancel;

  @override
  State<AssistantEvidenceFeedbackForm> createState() =>
      _AssistantEvidenceFeedbackFormState();
}

class _AssistantEvidenceFeedbackFormState
    extends State<AssistantEvidenceFeedbackForm> {
  late AssistantEvidenceFeedbackType _type;
  int? _claimIndex;
  String? _evidenceBlockId;
  late final TextEditingController _detail;

  @override
  void initState() {
    super.initState();
    _detail = TextEditingController();
    _type = widget.answer.claims.isEmpty
        ? AssistantEvidenceFeedbackType.missingEvidence
        : AssistantEvidenceFeedbackType.incorrectCitation;
    _alignTargetToType();
  }

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Iterable<AssistantEvidenceFeedbackType> get _availableTypes =>
      widget.answer.claims.isEmpty
      ? const [AssistantEvidenceFeedbackType.missingEvidence]
      : AssistantEvidenceFeedbackType.values;

  List<AssistantEvidence> get _selectedEvidence {
    final index = _claimIndex;
    if (index == null || index < 0 || index >= widget.answer.claims.length) {
      return const [];
    }
    return widget.answer.claims[index].evidence;
  }

  List<AssistantEvidence> get _distinctSelectedEvidence {
    final seen = <String>{};
    return [
      for (final evidence in _selectedEvidence)
        if (seen.add(evidence.blockId)) evidence,
    ];
  }

  void _alignTargetToType() {
    if (!_type.requiresClaim) {
      _claimIndex = null;
      _evidenceBlockId = null;
      return;
    }
    if (_claimIndex == null || _claimIndex! >= widget.answer.claims.length) {
      _claimIndex = widget.answer.claims.isEmpty ? null : 0;
    }
    if (!_type.requiresEvidenceBlock) {
      _evidenceBlockId = null;
      return;
    }
    final candidates = _distinctSelectedEvidence;
    if (!candidates.any((value) => value.blockId == _evidenceBlockId)) {
      _evidenceBlockId = candidates.isEmpty ? null : candidates.first.blockId;
    }
  }

  bool get _detailIsValid {
    final value = _detail.text;
    return !value.contains('\u0000') && value.trim().runes.length <= 1000;
  }

  bool get _canSubmit =>
      widget.enabled &&
      !widget.sending &&
      _detailIsValid &&
      (!_type.requiresClaim || _claimIndex != null) &&
      (!_type.requiresEvidenceBlock || _evidenceBlockId != null);

  void _submit() {
    if (!_canSubmit) return;
    final detail = _detail.text.trim();
    widget.onSubmit((
      type: _type,
      claimIndex: _claimIndex,
      evidenceBlockId: _evidenceBlockId,
      detail: detail.isEmpty ? null : detail,
    ));
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Evidence correctness report',
    child: Card(
      key: const ValueKey('assistant-evidence-feedback-form'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Report an evidence issue',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose what is wrong with the citations or support for this answer.',
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: DropdownButtonFormField<AssistantEvidenceFeedbackType>(
                key: ValueKey('assistant-feedback-type-${_type.wireValue}'),
                initialValue: _type,
                isExpanded: true,
                itemHeight: null,
                decoration: const InputDecoration(labelText: 'Evidence issue'),
                items: [
                  for (final type in _availableTypes)
                    DropdownMenuItem(
                      value: type,
                      child: Text(type.displayLabel),
                    ),
                ],
                onChanged: !widget.enabled || widget.sending
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _type = value;
                          _alignTargetToType();
                        });
                      },
              ),
            ),
            if (_type.requiresClaim) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: DropdownButtonFormField<int>(
                  key: ValueKey('assistant-feedback-claim-$_claimIndex'),
                  initialValue: _claimIndex,
                  isExpanded: true,
                  itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Claim'),
                  items: [
                    for (
                      var index = 0;
                      index < widget.answer.claims.length;
                      index++
                    )
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          'Claim ${index + 1}: ${widget.answer.claims[index].text}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: !widget.enabled || widget.sending
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _claimIndex = value;
                            _evidenceBlockId = null;
                            _alignTargetToType();
                          });
                        },
                ),
              ),
            ],
            if (_type.requiresEvidenceBlock) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'assistant-feedback-evidence-$_evidenceBlockId',
                  ),
                  initialValue: _evidenceBlockId,
                  isExpanded: true,
                  itemHeight: null,
                  decoration: const InputDecoration(labelText: 'Citation'),
                  items: [
                    for (
                      var index = 0;
                      index < _distinctSelectedEvidence.length;
                      index++
                    )
                      DropdownMenuItem(
                        value: _distinctSelectedEvidence[index].blockId,
                        child: Text(
                          _evidenceLabel(
                            _distinctSelectedEvidence[index],
                            index,
                          ),
                        ),
                      ),
                  ],
                  onChanged: !widget.enabled || widget.sending
                      ? null
                      : (value) => setState(() => _evidenceBlockId = value),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('assistant-feedback-detail'),
              controller: _detail,
              enabled: widget.enabled && !widget.sending,
              minLines: 2,
              maxLines: 5,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Private detail (optional)',
                helperText:
                    'Stored with this account report to help review the evidence.',
              ),
            ),
            if (!_detailIsValid)
              Semantics(
                liveRegion: true,
                child: const Text(
                  'Detail must be at most 1,000 characters and cannot contain null characters.',
                ),
              ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: FilledButton.icon(
                key: const ValueKey('assistant-feedback-submit'),
                onPressed: _canSubmit ? _submit : null,
                icon: widget.sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.report_outlined),
                label: Text(
                  widget.sending ? 'Sending report…' : 'Send evidence report',
                ),
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: TextButton(
                onPressed: widget.sending ? null : widget.onCancel,
                child: const Text('Cancel report'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _evidenceLabel(AssistantEvidence evidence, int index) {
  final context = [
    if (evidence.pageStart case final page?) 'page $page',
    if (evidence.section case final section?) section,
  ].join(' · ');
  return 'Citation ${index + 1}${context.isEmpty ? '' : ' · $context'}';
}
