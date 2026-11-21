import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/features/product_survey/product_survey_controller.dart';

void main() {
  test(
    'counts foreground usage across launches; snooze and refusal persist',
    () async {
      var now = DateTime(2026, 11, 21);
      var elapsed = Duration.zero;
      String? saved;
      ProductSurveyController create() => ProductSurveyController(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
        send: (_) async {},
        now: () => now,
        elapsed: () => elapsed,
      );
      var survey = create();
      await survey.ready;
      survey.setForeground(true);
      elapsed += const Duration(minutes: 10);
      survey.setForeground(false);
      await survey.flush();
      elapsed += const Duration(hours: 1);
      expect(survey.invitationDue, isFalse);
      survey.dispose();
      survey = create();
      await survey.ready;
      survey.setForeground(true);
      elapsed += const Duration(minutes: 4, seconds: 59);
      expect(survey.invitationDue, isFalse);
      elapsed += const Duration(seconds: 1);
      expect(survey.invitationDue, isTrue);
      await survey.choose('later');
      now = now.add(const Duration(minutes: 14, seconds: 59));
      expect(survey.invitationDue, isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(survey.invitationDue, isTrue);
      await survey.choose('refuse');
      survey.dispose();
      survey = create();
      await survey.ready;
      survey.setForeground(true);
      now = now.add(const Duration(days: 1));
      expect(survey.invitationDue, isFalse);
      survey.dispose();
    },
  );

  test(
    'draft survives restart and failed submission retries the same response ID',
    () async {
      String? saved;
      final sent = <Map<String, dynamic>>[];
      ProductSurveyController create() => ProductSurveyController(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
        send: (payload) async {
          sent.add(payload);
          if (sent.length == 1) throw StateError('offline');
        },
      );
      var survey = create();
      await survey.ready;
      for (final q in surveyQuestions) {
        survey.answer(q, q.canSkip ? null : 5);
      }
      survey.suggest('希望更顺手');
      await survey.flush();
      survey.dispose();
      survey = create();
      await survey.ready;
      expect(survey.suggestions, '希望更顺手');
      expect(survey.answeredCount, 8);
      expect(await survey.submit('zh'), isFalse);
      expect(survey.locked, isTrue);
      survey.dispose();
      survey = create();
      await survey.ready;
      expect(await survey.submit('en'), isTrue);
      expect(sent[0], equals(sent[1]));
      expect(survey.completed, isTrue);
      expect(jsonDecode(saved!)['status'], 'completed');
      survey.dispose();
    },
  );
}
