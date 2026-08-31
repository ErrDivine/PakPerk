import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/document/assistant_v2_api.dart';
import '../../core/models/assistant_v2.dart';
import '../../design_system/sizes.dart';
import 'assistant_evidence_feedback.dart';

typedef AssistantEvidenceTarget = ({
  String blockId,
  int start,
  int end,
  int? pageStart,
});

final assistantEvidenceTargetProvider = StateProvider.autoDispose
    .family<AssistantEvidenceTarget?, String>((ref, readerKey) => null);

class AssistantV2Sheet extends ConsumerStatefulWidget {
  const AssistantV2Sheet({
    required this.paperId,
    required this.readerKey,
    required this.paperTitle,
    required this.generation,
    required this.scope,
    required this.enabled,
    required this.onClose,
    this.generationIsCurrent = true,
    this.initialQuestion,
    this.submitInitialQuestion = false,
    super.key,
  });
  final String paperId, readerKey, paperTitle;
  final int generation;
  final AssistantRequestScope scope;
  final bool enabled;
  final bool generationIsCurrent;
  final VoidCallback onClose;
  final String? initialQuestion;
  final bool submitInitialQuestion;

  @override
  ConsumerState<AssistantV2Sheet> createState() => _AssistantV2SheetState();
}

class _AssistantV2SheetState extends ConsumerState<AssistantV2Sheet> {
  late final TextEditingController _question;
  AssistantAnswer? _answer;
  bool _sending = false;
  String? _error;
  RequestCancellation? _request;
  RequestCancellation? _provenanceRequest;
  RequestCancellation? _feedbackRequest;
  AssistantEvidenceFeedbackDraft? _pendingFeedback;
  bool _feedbackFormVisible = false;
  bool _feedbackSending = false;
  bool _feedbackFailed = false;
  String? _feedbackStatus;
  late final ActiveLibraryScope? _openingScope;
  late AssistantRequestScope _activeScope;
  late List<AssistantRequestScope> _scopeChoices;
  AssistantAnswerStyle _answerStyle = AssistantAnswerStyle.concise;

  @override
  void initState() {
    super.initState();
    final initialQuestion = _normalizedQuestion(widget.initialQuestion);
    _question = TextEditingController(text: initialQuestion ?? '');
    _openingScope = ref.read(verifiedLibraryScopeProvider);
    _activeScope = widget.scope;
    _scopeChoices = _buildScopeChoices(widget.scope);
    if (widget.submitInitialQuestion && initialQuestion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _send();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AssistantV2Sheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generationIsCurrent && !widget.generationIsCurrent) {
      _request?.cancel('The paper document generation changed.');
      _provenanceRequest?.cancel('The paper document generation changed.');
      _resetFeedback('The paper document generation changed.');
      _answer = null;
      _sending = false;
      _error =
          'The prepared paper changed. Close and reopen Assistant for the current source.';
    }
  }

  @override
  void dispose() {
    _request?.cancel('Assistant sheet closed.');
    _provenanceRequest?.cancel('Assistant sheet closed.');
    _feedbackRequest?.cancel('Assistant sheet closed.');
    _question.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _question.text.trim();
    if (!_questionIsValid) {
      setState(
        () => _error =
            'Enter a question of at most 500 Unicode characters without null characters.',
      );
      return;
    }
    final scope = ref.read(verifiedLibraryScopeProvider);
    if (!widget.enabled ||
        !widget.generationIsCurrent ||
        scope == null ||
        scope != _openingScope) {
      setState(
        () => _error = !widget.generationIsCurrent
            ? 'The prepared paper changed. Close and reopen Assistant for the current source.'
            : scope != _openingScope
            ? 'The active account changed. Close and reopen Assistant.'
            : 'A new answer needs a connection and an active account.',
      );
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final request = RequestCancellation();
    _request?.cancel('A newer assistant request replaced this one.');
    _request = request;
    try {
      final answer = await AssistantV2Api(ref.read(pakPerkDioProvider)).ask(
        paperId: widget.paperId,
        generation: widget.generation,
        question: text,
        scope: _activeScope,
        answerStyle: _answerStyle,
        expectedAuthEpoch: scope.authEpoch,
        threadId: _answer?.threadId,
        cancellation: request,
      );
      final current = ref.read(verifiedLibraryScopeProvider);
      if (mounted &&
          !request.isCancelled &&
          current == scope &&
          widget.generationIsCurrent) {
        setState(() {
          _resetFeedback('A newer Assistant answer replaced this report.');
          _answer = answer;
        });
      }
    } catch (_) {
      if (mounted &&
          !request.isCancelled &&
          ref.read(verifiedLibraryScopeProvider) == scope) {
        setState(
          () => _error =
              'Assistant v2 could not answer. Nothing was sent to legacy chat.',
        );
      }
    } finally {
      if (identical(_request, request)) {
        _request = null;
        if (mounted) setState(() => _sending = false);
      }
    }
  }

  bool get _questionIsValid => _normalizedQuestion(_question.text) != null;

  void _resetFeedback(String reason) {
    _feedbackRequest?.cancel(reason);
    _feedbackRequest = null;
    _pendingFeedback = null;
    _feedbackFormVisible = false;
    _feedbackSending = false;
    _feedbackFailed = false;
    _feedbackStatus = null;
  }

  void _beginFeedback() {
    setState(() {
      _pendingFeedback = null;
      _feedbackFailed = false;
      _feedbackStatus = null;
      _feedbackFormVisible = true;
    });
  }

  void _submitFeedback(
    AssistantAnswer answer,
    AssistantEvidenceFeedbackSelection selection,
  ) {
    final draft = AssistantEvidenceFeedbackDraft(
      operationId: const Uuid().v7(),
      type: selection.type,
      claimIndex: selection.claimIndex,
      evidenceBlockId: selection.evidenceBlockId,
      detail: selection.detail,
    );
    _sendFeedback(answer, draft);
  }

  Future<void> _sendFeedback(
    AssistantAnswer answer,
    AssistantEvidenceFeedbackDraft feedback,
  ) async {
    final scope = ref.read(verifiedLibraryScopeProvider);
    if (!widget.enabled ||
        !widget.generationIsCurrent ||
        scope == null ||
        scope != _openingScope ||
        _answer?.responseId != answer.responseId) {
      setState(() {
        _feedbackFailed = true;
        _feedbackStatus = !widget.generationIsCurrent
            ? 'The prepared paper changed before this evidence report could be sent.'
            : scope != _openingScope
            ? 'The active account changed before this evidence report could be sent.'
            : 'This answer is no longer current. Ask again before reporting its evidence.';
      });
      return;
    }

    final request = RequestCancellation();
    _feedbackRequest?.cancel('A newer evidence report replaced this one.');
    _feedbackRequest = request;
    setState(() {
      _pendingFeedback = feedback;
      _feedbackSending = true;
      _feedbackFailed = false;
      _feedbackStatus = 'Sending evidence report…';
    });
    try {
      await AssistantV2Api(ref.read(pakPerkDioProvider)).feedback(
        paperId: widget.paperId,
        generation: widget.generation,
        answer: answer,
        feedback: feedback,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      final currentScope = ref.read(verifiedLibraryScopeProvider);
      if (!mounted ||
          request.isCancelled ||
          currentScope != scope ||
          !widget.generationIsCurrent ||
          _answer?.responseId != answer.responseId) {
        return;
      }
      setState(() {
        _pendingFeedback = null;
        _feedbackFormVisible = false;
        _feedbackFailed = false;
        _feedbackStatus = 'Evidence issue saved.';
      });
      try {
        await HapticFeedback.lightImpact();
      } on Object {
        // The saved state is authoritative when haptics are unavailable.
      }
    } on Object {
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope ||
          !widget.generationIsCurrent ||
          _answer?.responseId != answer.responseId) {
        return;
      }
      setState(() {
        _feedbackFormVisible = false;
        _feedbackFailed = true;
        _feedbackStatus =
            'The evidence report could not be saved. Retry uses the same report ID.';
      });
    } finally {
      if (identical(_feedbackRequest, request)) {
        _feedbackRequest = null;
        if (mounted) setState(() => _feedbackSending = false);
      }
    }
  }

  List<AssistantRequestScope> _buildScopeChoices(
    AssistantRequestScope contextual,
  ) {
    final values = <AssistantRequestScope>[contextual];
    if (contextual.kind != AssistantScopeKind.paper) {
      values.add(const AssistantRequestScope.paper());
    }
    for (final kind in AssistantSectionKind.values) {
      if (contextual.kind == AssistantScopeKind.section &&
          contextual.sectionKinds.length == 1 &&
          contextual.sectionKinds.single == kind) {
        continue;
      }
      values.add(AssistantRequestScope.section(kinds: [kind]));
    }
    return List.unmodifiable(values);
  }

  Future<void> _inspectProvenance(AssistantAnswer answer) async {
    final scope = ref.read(verifiedLibraryScopeProvider);
    if (!widget.generationIsCurrent ||
        scope == null ||
        scope != _openingScope) {
      return;
    }
    final request = RequestCancellation();
    _provenanceRequest?.cancel('A newer provenance request replaced this one.');
    _provenanceRequest = request;
    try {
      final provenance = await AssistantV2Api(ref.read(pakPerkDioProvider))
          .provenance(
            provenanceId: answer.provenanceId,
            expectedAuthEpoch: scope.authEpoch,
            cancellation: request,
          );
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Answer provenance'),
          content: Text(
            'Generation ${provenance.generation}\n'
            '${provenance.activityType}\n'
            '${provenance.modelId ?? 'Model not reported'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on Object {
      if (!mounted || request.isCancelled) return;
      setState(() => _error = 'Answer provenance could not be loaded.');
    } finally {
      if (identical(_provenanceRequest, request)) {
        _provenanceRequest = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentScope = ref.watch(verifiedLibraryScopeProvider);
    final scopeIsCurrent =
        widget.generationIsCurrent && currentScope == _openingScope;
    ref.listen<ActiveLibraryScope?>(verifiedLibraryScopeProvider, (_, next) {
      if (next == _openingScope) return;
      _request?.cancel('The active Assistant account changed.');
      _provenanceRequest?.cancel('The active Assistant account changed.');
      if (!mounted) return;
      setState(() {
        _resetFeedback('The active Assistant account changed.');
        _answer = null;
        _sending = false;
        _error = 'The active account changed. Close and reopen Assistant.';
      });
    });
    final answer = scopeIsCurrent ? _answer : null;
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Ask about ${widget.paperTitle}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onClose,
                      tooltip: 'Close assistant',
                      constraints: const BoxConstraints(
                        minWidth: PakPerkSizes.minimumInteractive,
                        minHeight: PakPerkSizes.minimumInteractive,
                      ),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Semantics(
                  label: 'Active assistant evidence scope',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: DropdownButtonFormField<AssistantRequestScope>(
                      key: ValueKey(
                        'assistant-scope-${_scopeToken(_activeScope)}',
                      ),
                      initialValue: _activeScope,
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: 'Evidence scope',
                        helperText:
                            'The answer can use evidence only from this scope.',
                      ),
                      items: [
                        for (final scope in _scopeChoices)
                          DropdownMenuItem(
                            value: scope,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: PakPerkSizes.minimumInteractive,
                              ),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(scope.displayLabel),
                              ),
                            ),
                          ),
                      ],
                      onChanged: _sending || _feedbackSending
                          ? null
                          : (scope) {
                              if (scope != null) {
                                setState(() {
                                  _resetFeedback(
                                    'The Assistant evidence scope changed.',
                                  );
                                  _activeScope = scope;
                                  _answer = null;
                                });
                              }
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: 'Assistant answer style',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: DropdownButtonFormField<AssistantAnswerStyle>(
                      key: ValueKey(
                        'assistant-style-${_answerStyle.wireValue}',
                      ),
                      initialValue: _answerStyle,
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: 'Answer style',
                        helperText:
                            'Changes explanation depth, not the evidence scope.',
                      ),
                      items: [
                        for (final style in AssistantAnswerStyle.values)
                          DropdownMenuItem(
                            value: style,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: PakPerkSizes.minimumInteractive,
                              ),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(style.displayLabel),
                              ),
                            ),
                          ),
                      ],
                      onChanged: _sending || _feedbackSending
                          ? null
                          : (style) {
                              if (style != null) {
                                setState(() => _answerStyle = style);
                              }
                            },
                    ),
                  ),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(error)),
                ],
                if (answer != null) ...[
                  const SizedBox(height: 20),
                  Semantics(
                    container: true,
                    label:
                        'Assistant answer status: ${_statusLabel(answer.status)}',
                    child: Text(
                      _statusLabel(answer.status),
                      key: const ValueKey('assistant-answer-status'),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (answer.status == AssistantAnswerStatus.notFound)
                    SelectableText(
                      answer.answer,
                      key: const ValueKey('assistant-not-found-answer'),
                    ),
                  for (final (claimIndex, claim) in answer.claims.indexed) ...[
                    const SizedBox(height: 16),
                    SelectableText(
                      claim.text,
                      key: ValueKey('assistant-claim-text-$claimIndex'),
                    ),
                    const SizedBox(height: 8),
                    Semantics(
                      container: true,
                      label: 'Claim support: ${_supportLabel(claim.support)}',
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Chip(
                          key: ValueKey(
                            'assistant-claim-${claim.support.name}',
                          ),
                          avatar: Icon(
                            claim.support == AssistantClaimSupport.direct
                                ? Icons.fact_check_outlined
                                : Icons.psychology_alt_outlined,
                            size: 18,
                          ),
                          label: Text(_supportLabel(claim.support)),
                        ),
                      ),
                    ),
                    for (final evidence in claim.evidence)
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: PakPerkSizes.minimumInteractive,
                        ),
                        child: TextButton.icon(
                          onPressed: () {
                            ref
                                .read(
                                  assistantEvidenceTargetProvider(
                                    widget.readerKey,
                                  ).notifier,
                                )
                                .state = (
                              blockId: evidence.blockId,
                              start: evidence.start,
                              end: evidence.end,
                              pageStart: evidence.pageStart,
                            );
                            widget.onClose();
                          },
                          icon: const Icon(Icons.find_in_page),
                          label: Text(
                            'Open exact source${evidence.pageStart == null ? '' : ' · page ${evidence.pageStart}'}',
                          ),
                        ),
                      ),
                  ],
                  if (answer.limitations.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Semantics(
                      header: true,
                      child: Text(
                        'Answer coverage',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Semantics(
                      container: true,
                      label: 'Answer coverage notice',
                      child: Column(
                        key: const ValueKey('assistant-limitations'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final limitation in answer.limitations)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const ExcludeSemantics(child: Text('•  ')),
                                  Expanded(child: Text(limitation)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Semantics(
                    header: true,
                    child: Text(
                      'Evidence correctness',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'If a citation is missing, misplaced, or does not support a claim, report that exact issue.',
                  ),
                  if (_feedbackStatus case final status?) ...[
                    const SizedBox(height: 8),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        status,
                        key: const ValueKey('assistant-feedback-status'),
                      ),
                    ),
                  ],
                  if (_feedbackFormVisible) ...[
                    const SizedBox(height: 12),
                    AssistantEvidenceFeedbackForm(
                      key: ValueKey(
                        'assistant-feedback-form-${answer.responseId}',
                      ),
                      answer: answer,
                      enabled: widget.enabled && scopeIsCurrent && !_sending,
                      sending: _feedbackSending,
                      onSubmit: (selection) =>
                          _submitFeedback(answer, selection),
                      onCancel: () {
                        if (_feedbackSending) return;
                        setState(() => _feedbackFormVisible = false);
                      },
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: PakPerkSizes.minimumInteractive,
                      ),
                      child: OutlinedButton.icon(
                        key: const ValueKey('assistant-feedback-open'),
                        onPressed:
                            widget.enabled &&
                                scopeIsCurrent &&
                                !_sending &&
                                !_feedbackSending
                            ? _beginFeedback
                            : null,
                        icon: const Icon(Icons.report_outlined),
                        label: const Text('Report evidence issue'),
                      ),
                    ),
                    if (_feedbackFailed && _pendingFeedback != null) ...[
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: PakPerkSizes.minimumInteractive,
                        ),
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('assistant-feedback-retry'),
                          onPressed:
                              widget.enabled &&
                                  scopeIsCurrent &&
                                  !_sending &&
                                  !_feedbackSending
                              ? () => _sendFeedback(answer, _pendingFeedback!)
                              : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry evidence report'),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: TextButton(
                      onPressed: () => _inspectProvenance(answer),
                      child: const Text('Inspect provenance'),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
          Material(
            key: const ValueKey('assistant-pinned-composer'),
            color: Theme.of(context).colorScheme.surface,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _question,
                      enabled:
                          widget.enabled &&
                          scopeIsCurrent &&
                          !_sending &&
                          !_feedbackSending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) {
                        if (_questionIsValid &&
                            !_sending &&
                            !_feedbackSending) {
                          _send();
                        }
                      },
                      onChanged: (_) => setState(() => _error = null),
                      decoration: InputDecoration(
                        labelText: 'Question',
                        hintText: 'Ask about this evidence scope',
                        helperText:
                            '${_question.text.trim().runes.length}/500 characters',
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: PakPerkSizes.minimumInteractive,
                      ),
                      child: FilledButton(
                        onPressed:
                            widget.enabled &&
                                scopeIsCurrent &&
                                !_sending &&
                                !_feedbackSending &&
                                _questionIsValid
                            ? _send
                            : null,
                        child: Text(_sending ? 'Asking…' : 'Ask'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _scopeToken(AssistantRequestScope scope) => [
  scope.kind.wireValue,
  ...scope.sectionKinds.map((value) => value.wireValue),
  ...scope.objectIds,
  if (scope.selection case final value?)
    '${value.blockId}:${value.start}:${value.end}',
  if (scope.passportField case final value?) value,
].join('-');

String? _normalizedQuestion(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.runes.length > 500 ||
      normalized.contains('\u0000')) {
    return null;
  }
  return normalized;
}

String _supportLabel(AssistantClaimSupport support) => switch (support) {
  AssistantClaimSupport.direct => 'Direct',
  AssistantClaimSupport.inferred => 'Inferred',
};

String _statusLabel(AssistantAnswerStatus status) => switch (status) {
  AssistantAnswerStatus.supported => 'Supported',
  AssistantAnswerStatus.partial => 'Partially supported',
  AssistantAnswerStatus.notFound => 'Not found',
};
