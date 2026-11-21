import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/ui.dart';
import 'product_survey_controller.dart';

class ProductSurveyScreen extends ConsumerStatefulWidget {
  const ProductSurveyScreen({super.key});

  @override
  ConsumerState<ProductSurveyScreen> createState() =>
      _ProductSurveyScreenState();
}

class _ProductSurveyScreenState extends ConsumerState<ProductSurveyScreen> {
  final _suggestions = TextEditingController();
  final _questionKeys = {for (final q in surveyQuestions) q.id: GlobalKey()};
  bool _showMissing = false;
  bool _initialized = false;
  late ProductSurveyController _survey;

  @override
  void initState() {
    super.initState();
    _survey = ref.read(productSurveyProvider);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _survey.ready;
    if (!mounted) return;
    _suggestions.text = _survey.suggestions;
    if (!_survey.completed) await _survey.choose('accept');
    if (mounted) setState(() => _initialized = true);
  }

  @override
  void dispose() {
    unawaited(_survey.flush());
    _suggestions.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final missing = _survey.firstUnanswered;
    if (missing != null) {
      setState(() => _showMissing = true);
      final target = _questionKeys[missing]?.currentContext;
      if (target != null) {
        await Scrollable.ensureVisible(
          target,
          alignment: .15,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 280),
        );
      }
      return;
    }
    await _survey.submit(Localizations.localeOf(context).languageCode);
  }

  @override
  Widget build(BuildContext context) {
    final survey = ref.watch(productSurveyProvider);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const UiText('Share your thoughts')),
      body: !_initialized
          ? const Center(child: CircularProgressIndicator())
          : survey.completed
          ? _ThankYou(onDone: () => Navigator.of(context).pop())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      UiText(
                        'How has it been?',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      const UiText(
                        'Eight quick questions about using PakPerk. Just go with how it feels to you.',
                      ),
                      const SizedBox(height: 12),
                      const UiText(
                        'No name or email needed. Your answers are sent only when you tap Submit.',
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value:
                                  survey.answeredCount / surveyQuestions.length,
                              borderRadius: BorderRadius.circular(8),
                              minHeight: 5,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${survey.answeredCount} / ${surveyQuestions.length}',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      for (
                        var index = 0;
                        index < surveyQuestions.length;
                        index++
                      ) ...[
                        _QuestionCard(
                          key: _questionKeys[surveyQuestions[index].id],
                          question: surveyQuestions[index],
                          index: index,
                          value: survey.answers[surveyQuestions[index].id],
                          answered: survey.answers.containsKey(
                            surveyQuestions[index].id,
                          ),
                          enabled: !survey.locked,
                          missing:
                              _showMissing &&
                              !survey.answers.containsKey(
                                surveyQuestions[index].id,
                              ),
                          onAnswer: (value) =>
                              survey.answer(surveyQuestions[index], value),
                        ),
                        const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 8),
                      UiText(
                        'Anything you would like to tell us? (Optional)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const ValueKey('survey-suggestions'),
                        controller: _suggestions,
                        enabled: !survey.locked,
                        minLines: 4,
                        maxLines: 8,
                        maxLength: 2000,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: uiString(
                            context,
                            'Something that felt awkward, something you wish we had — anything is welcome.',
                          ),
                          filled: true,
                          fillColor: colors.surfaceContainerLow,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        onChanged: survey.suggest,
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border(
                      top: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (survey.submitFailed) ...[
                            const UiText(
                              'Could not send yet. Your answers are kept here; please try again when you are online.',
                            ),
                            const SizedBox(height: 8),
                          ],
                          UiText(
                            survey.saveFailed
                                ? 'Could not save on this device. Please keep this page open and try again.'
                                : 'Your draft stays here if you leave.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: survey.saveFailed
                                      ? colors.error
                                      : colors.onSurfaceVariant,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            key: const ValueKey('survey-submit'),
                            onPressed: survey.sending ? null : _submit,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              child: survey.sending
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: colors.onPrimary,
                                      ),
                                    )
                                  : UiText(
                                      survey.submitFailed
                                          ? 'Try submitting again'
                                          : 'Submit',
                                    ),
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

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.index,
    required this.value,
    required this.answered,
    required this.enabled,
    required this.missing,
    required this.onAnswer,
    super.key,
  });
  final SurveyQuestion question;
  final int index;
  final int? value;
  final bool answered;
  final bool enabled;
  final bool missing;
  final ValueChanged<int?> onAnswer;
  static const labels = ['Excellent', 'Good', 'Pretty good', 'Average', 'Poor'];
  static const faces = [
    Icons.sentiment_very_satisfied_outlined,
    Icons.sentiment_satisfied_alt_outlined,
    Icons.sentiment_satisfied_outlined,
    Icons.sentiment_neutral_outlined,
    Icons.sentiment_dissatisfied_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: missing
              ? colors.error
              : colors.outlineVariant.withValues(alpha: .65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${index + 1}'.padLeft(2, '0'),
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.primary),
          ),
          const SizedBox(height: 8),
          UiText(
            question.text,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final vertical =
                  constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(14) > 19;
              final buttons = [
                for (var i = 0; i < labels.length; i++)
                  _rating(context, i, vertical),
              ];
              return vertical
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: buttons,
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final button in buttons) Expanded(child: button),
                      ],
                    );
            },
          ),
          if (question.canSkip)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: ValueKey('survey-${question.id}-skip'),
                onPressed: enabled ? () => onAnswer(null) : null,
                icon: Icon(
                  answered && value == null
                      ? Icons.check_circle_outline
                      : Icons.remove_circle_outline,
                  size: 17,
                ),
                label: const UiText('Haven’t tried this yet'),
                style: TextButton.styleFrom(
                  foregroundColor: answered && value == null
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
              ),
            ),
          if (missing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: UiText(
                question.canSkip
                    ? 'Choose one, or let us know you haven’t tried it yet.'
                    : 'Please choose the one that fits best.',
                style: TextStyle(color: colors.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rating(BuildContext context, int i, bool vertical) {
    final selected = answered && value == 5 - i;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: vertical ? 0 : 2,
        vertical: vertical ? 3 : 0,
      ),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey('survey-${question.id}-${5 - i}'),
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? () => onAnswer(5 - i) : null,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
              child: vertical
                  ? Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(
                          faces[i],
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        UiText(labels[i]),
                        if (selected) ...[
                          const Spacer(),
                          Icon(Icons.check, color: colors.primary),
                          const SizedBox(width: 12),
                        ],
                      ],
                    )
                  : Column(
                      children: [
                        Icon(
                          faces[i],
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 7),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: UiText(
                            labels[i],
                            maxLines: 1,
                            softWrap: false,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: selected
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThankYou extends StatelessWidget {
  const _ThankYou({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          UiText(
            'Thanks, we got it!',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const UiText(
            'Thanks for sharing a little of your time. Enjoy your next read.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: onDone,
            child: const UiText('Back to reading'),
          ),
        ],
      ),
    ),
  );
}
