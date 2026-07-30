import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/introduction.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled fallback contains five prepared papers and one lazy paper',
    () async {
      final raw = await rootBundle.loadString('assets/fallback_feed.json');
      final feed = FeedPage.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );

      expect(feed.items, hasLength(6));
      expect(
        feed.items.map((paper) => paper.arxivBaseId),
        containsAll([
          '1706.03762',
          '1810.04805',
          '1907.11692',
          '1910.10683',
          '2005.11401',
          '2106.09685',
        ]),
      );
      expect(feed.items.first.abstractText.length, greaterThan(500));

      final lazy = feed.items.last;
      expect(lazy.arxivId, '2106.09685v2');
      expect(lazy.title, 'LoRA: Low-Rank Adaptation of Large Language Models');
      expect(lazy.authors, hasLength(8));
      expect(lazy.primaryCategory, 'cs.CL');
      expect(lazy.categories, ['cs.CL', 'cs.AI', 'cs.LG']);
      expect(lazy.capabilities.introduction, isFalse);
      expect(lazy.capabilities.chat, isFalse);
      expect(lazy.capabilities.connections, isFalse);

      final introductionRaw = await rootBundle.loadString(
        'assets/prepared_introductions.json',
      );
      final connectionRaw = await rootBundle.loadString(
        'assets/prepared_connections.json',
      );
      final introductions = Map<String, dynamic>.from(
        jsonDecode(introductionRaw) as Map,
      );
      final connections = Map<String, dynamic>.from(
        jsonDecode(connectionRaw) as Map,
      );
      const lazyPaperId = '21060968-5000-4000-8000-000000000006';
      expect(
        (introductions['papers'] as Map).containsKey(lazyPaperId),
        isFalse,
      );
      expect((connections['papers'] as Map).containsKey(lazyPaperId), isFalse);
    },
  );

  test('processing decoder accepts nested backend errors', () {
    final state = PaperProcessingState.fromJson({
      'paper_id': 'paper-1',
      'overall_state': 'failed',
      'stage': 'failed_retryable',
      'capabilities': {
        'metadata': true,
        'introduction': true,
        'chat': false,
        'connections': false,
      },
      'retryable': true,
      'updated_at': '2026-07-29T12:00:00Z',
      'last_error': {
        'category': 'model_temporary',
        'code': 'LLM_UNAVAILABLE',
        'message': 'Provider unavailable',
      },
    });

    expect(state.lastErrorCode, 'LLM_UNAVAILABLE');
    expect(state.lastErrorMessage, 'Provider unavailable');
    expect(state.capabilities.introduction, isTrue);
  });

  test('introduction decoder accepts nested detection details', () {
    final introduction = PaperIntroduction.fromJson({
      'paper_id': 'paper-1',
      'generation': 2,
      'heading': '1 Introduction',
      'paragraphs': [
        {
          'ordinal': 0,
          'text': 'Opening paragraph cites [1].',
          'heading': '1.1 Motivation',
          'citations': [
            {
              'start': 24,
              'end': 27,
              'marker': '[1]',
              'references': [
                {'paper_id': 'paper-2', 'title': 'Resolved paper'},
              ],
            },
          ],
        },
      ],
      'detection': {'confidence': .94, 'used_fallback': false},
      'original_pdf_url': 'https://arxiv.org/pdf/1706.03762',
    });

    expect(introduction.detectionConfidence, .94);
    expect(
      introduction.paragraphs.single.heading,
      '1.1 Motivation',
    );
    expect(introduction.paragraphs.single.citations.single.marker, '[1]');
    expect(
      introduction.paragraphs.single.citations.single.references.single.paperId,
      'paper-2',
    );

    final roundTrip = PaperIntroduction.fromJson(introduction.toJson());
    expect(roundTrip.paragraphs.single.heading, '1.1 Motivation');
    expect(roundTrip.paragraphs.single.citations.single.marker, '[1]');
  });

  test('chat decoder accepts bare and wrapped answers', () {
    final bare = ChatAnswer.fromJson({
      'answer_markdown': 'Bare answer',
      'insufficient_evidence': false,
      'evidence': const [],
      'suggested_follow_ups': const [],
    });
    final wrapped = ChatAnswer.fromJson({
      'thread_id': 'thread-7',
      'answer': {
        'answer_markdown': 'Wrapped answer',
        'insufficient_evidence': true,
        'evidence': [
          {
            'section_kind': 'result',
            'section_heading': '4 Results',
            'page_start': 8,
            'page_end': 8,
            'chunk_id': 'chunk-7',
          },
        ],
        'suggested_follow_ups': ['What baseline was used?'],
      },
    });

    expect(bare.answerMarkdown, 'Bare answer');
    expect(wrapped.answerMarkdown, 'Wrapped answer');
    expect(wrapped.threadId, 'thread-7');
    expect(wrapped.evidence.single.badgeLabel, '4 Results, p. 8');
  });
}
