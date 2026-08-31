import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/document/assistant_v2_api.dart';
import 'package:pakperk/core/models/assistant_v2.dart';

void main() {
  test('posts exact assistant v2 contract and decodes evidence', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final answer = await AssistantV2Api(dio).ask(
      paperId: _paperId,
      generation: 7,
      question: 'What changed?',
      scope: AssistantRequestScope.selection(
        blockId: _blockId,
        start: 2,
        end: 9,
      ),
      answerStyle: AssistantAnswerStyle.expert,
      expectedAuthEpoch: 4,
      threadId: _threadId,
    );
    final body = jsonDecode(adapter.body) as Map<String, dynamic>;
    expect(body, containsPair('generation', 7));
    expect(body['scope'], containsPair('kind', 'selection'));
    expect(body['answer_style'], 'expert');
    expect(body['thread_id'], _threadId);
    expect(answer.status, AssistantAnswerStatus.partial);
    expect(answer.responseId, _responseId);
    expect(answer.claims.single.evidence.single, isA<AssistantEvidence>());
    expect(answer.claims.single.evidence.single.start, 2);
    expect(answer.claims.single.evidence.single.end, 9);
    expect(answer.claims.single.evidence.single.pageStart, 3);
  });

  test('posts exact evidence feedback target and decodes receipt', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final api = AssistantV2Api(dio);
    final answer = await api.ask(
      paperId: _paperId,
      generation: 7,
      question: 'What changed?',
      scope: const AssistantRequestScope.paper(),
      answerStyle: AssistantAnswerStyle.concise,
      expectedAuthEpoch: 4,
    );

    final receipt = await api.feedback(
      paperId: _paperId,
      generation: 7,
      answer: answer,
      feedback: AssistantEvidenceFeedbackDraft(
        operationId: _operationId,
        type: AssistantEvidenceFeedbackType.evidenceDoesNotSupportClaim,
        claimIndex: 0,
        evidenceBlockId: _blockId,
        detail: 'The cited sentence says the opposite.',
      ),
      expectedAuthEpoch: 4,
    );

    expect(adapter.path, '/v1/papers/$_paperId/assistant/feedback');
    expect(jsonDecode(adapter.body), {
      'operation_id': _operationId,
      'paper_id': _paperId,
      'generation': 7,
      'thread_id': _threadId,
      'response_id': _responseId,
      'provenance_id': _provenanceId,
      'feedback_type': 'evidence_does_not_support_claim',
      'claim_index': 0,
      'evidence_block_id': _blockId,
      'detail': 'The cited sentence says the opposite.',
    });
    expect(receipt.feedbackId, _feedbackId);
    expect(receipt.status, AssistantEvidenceFeedbackReceiptStatus.stored);
  });

  test('rejects a stale answer generation before feedback transport', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final api = AssistantV2Api(dio);
    final answer = await api.ask(
      paperId: _paperId,
      generation: 7,
      question: 'What changed?',
      scope: const AssistantRequestScope.paper(),
      answerStyle: AssistantAnswerStyle.concise,
      expectedAuthEpoch: 4,
    );

    await expectLater(
      api.feedback(
        paperId: _paperId,
        generation: 8,
        answer: answer,
        feedback: AssistantEvidenceFeedbackDraft(
          operationId: _operationId,
          type: AssistantEvidenceFeedbackType.missingEvidence,
          claimIndex: null,
          evidenceBlockId: null,
          detail: null,
        ),
        expectedAuthEpoch: 4,
      ),
      throwsArgumentError,
    );
    expect(adapter.fetches, 1);
  });

  test(
    'rejects public answer models with invalid feedback identifiers',
    () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final answer = AssistantAnswer(
        threadId: 'not-a-thread-id',
        responseId: _responseId,
        generation: 7,
        answer: 'Answer',
        status: AssistantAnswerStatus.notFound,
        claims: const [],
        limitations: const [],
        provenanceId: _provenanceId,
        promptVersion: 'v2',
      );

      await expectLater(
        AssistantV2Api(dio).feedback(
          paperId: _paperId,
          generation: 7,
          answer: answer,
          feedback: AssistantEvidenceFeedbackDraft(
            operationId: _operationId,
            type: AssistantEvidenceFeedbackType.missingEvidence,
            claimIndex: null,
            evidenceBlockId: null,
            detail: null,
          ),
          expectedAuthEpoch: 4,
        ),
        throwsArgumentError,
      );
      expect(adapter.fetches, 0);
    },
  );

  test('rejects a feedback target outside the decoded answer', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final api = AssistantV2Api(dio);
    final answer = await api.ask(
      paperId: _paperId,
      generation: 7,
      question: 'What changed?',
      scope: const AssistantRequestScope.paper(),
      answerStyle: AssistantAnswerStyle.concise,
      expectedAuthEpoch: 4,
    );

    await expectLater(
      api.feedback(
        paperId: _paperId,
        generation: 7,
        answer: answer,
        feedback: AssistantEvidenceFeedbackDraft(
          operationId: _operationId,
          type: AssistantEvidenceFeedbackType.incorrectCitation,
          claimIndex: 1,
          evidenceBlockId: _blockId,
          detail: null,
        ),
        expectedAuthEpoch: 4,
      ),
      throwsArgumentError,
    );
    expect(adapter.fetches, 1);
  });

  test('rejects an invalid question before transport', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await expectLater(
      AssistantV2Api(dio).ask(
        paperId: _paperId,
        generation: 7,
        question: '${List.filled(501, 'x').join()}\u0000',
        scope: const AssistantRequestScope.paper(),
        answerStyle: AssistantAnswerStyle.concise,
        expectedAuthEpoch: 4,
      ),
      throwsArgumentError,
    );
    expect(adapter.fetches, 0);
  });

  test('rejects unknown trust semantics in the response', () async {
    final adapter = _Adapter(responseStatus: 'future_status');
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await expectLater(
      AssistantV2Api(dio).ask(
        paperId: _paperId,
        generation: 7,
        question: 'What changed?',
        scope: const AssistantRequestScope.paper(),
        answerStyle: AssistantAnswerStyle.concise,
        expectedAuthEpoch: 4,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_ASSISTANT_RESPONSE',
        ),
      ),
    );
  });

  test('accepts the fixed claim-free not-found abstention', () async {
    final adapter = _Adapter(
      responseStatus: 'not_found',
      responseAnswer: 'Not found in this paper.',
      includeClaim: false,
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    final answer = await AssistantV2Api(dio).ask(
      paperId: _paperId,
      generation: 7,
      question: 'What changed?',
      scope: const AssistantRequestScope.paper(),
      answerStyle: AssistantAnswerStyle.concise,
      expectedAuthEpoch: 4,
    );

    expect(answer.status, AssistantAnswerStatus.notFound);
    expect(answer.answer, 'Not found in this paper.');
    expect(answer.claims, isEmpty);
  });

  test('rejects extra answer prose without a claim record', () async {
    final adapter = _Adapter(
      responseAnswer: 'A claim\n\nThis extra statement is not claim-backed.',
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await expectLater(
      AssistantV2Api(dio).ask(
        paperId: _paperId,
        generation: 7,
        question: 'What changed?',
        scope: const AssistantRequestScope.paper(),
        answerStyle: AssistantAnswerStyle.concise,
        expectedAuthEpoch: 4,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_ASSISTANT_RESPONSE',
        ),
      ),
    );
  });

  test(
    'rejects an invented https link even when answer matches claim',
    () async {
      const linkedClaim =
          'A claim at https://invented.example/provider-authored-source.';
      final adapter = _Adapter(
        responseAnswer: linkedClaim,
        claimText: linkedClaim,
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      await expectLater(
        AssistantV2Api(dio).ask(
          paperId: _paperId,
          generation: 7,
          question: 'What changed?',
          scope: const AssistantRequestScope.paper(),
          answerStyle: AssistantAnswerStyle.concise,
          expectedAuthEpoch: 4,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_ASSISTANT_RESPONSE',
          ),
        ),
      );
    },
  );

  test('rejects provider-authored paper claims in limitations', () async {
    final adapter = _Adapter(
      responseLimitations: const [
        'The paper did not test this method in deployment.',
      ],
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    await expectLater(
      AssistantV2Api(dio).ask(
        paperId: _paperId,
        generation: 7,
        question: 'What changed?',
        scope: const AssistantRequestScope.paper(),
        answerStyle: AssistantAnswerStyle.concise,
        expectedAuthEpoch: 4,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_ASSISTANT_RESPONSE',
        ),
      ),
    );
  });
}

const _paperId = '11111111-1111-4111-8111-111111111111';
const _threadId = '22222222-2222-4222-8222-222222222222';
const _responseId = '55555555-5555-4555-8555-555555555555';
const _provenanceId = '33333333-3333-4333-8333-333333333333';
const _blockId = '44444444-4444-4444-8444-444444444444';
const _operationId = '66666666-6666-4666-8666-666666666666';
const _feedbackId = '77777777-7777-4777-8777-777777777777';

final class _Adapter implements HttpClientAdapter {
  _Adapter({
    this.responseStatus = 'partial',
    this.responseAnswer = 'A claim',
    this.claimText = 'A claim',
    this.includeClaim = true,
    this.responseLimitations,
  });

  final String responseStatus;
  final String responseAnswer;
  final String claimText;
  final bool includeClaim;
  final List<String>? responseLimitations;
  String body = '';
  String path = '';
  int fetches = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetches += 1;
    path = options.path;
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    body = utf8.decode(bytes);
    if (options.path.endsWith('/assistant/feedback')) {
      return ResponseBody.fromString(
        jsonEncode({'feedback_id': _feedbackId, 'status': 'stored'}),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'thread_id': _threadId,
        'response_id': _responseId,
        'generation': 7,
        'answer': responseAnswer,
        'status': responseStatus,
        'claims': [
          if (includeClaim)
            {
              'text': claimText,
              'support': 'direct',
              'evidence': [
                {
                  'block_id': _blockId,
                  'start': 2,
                  'end': 9,
                  'page_start': 3,
                  'section': 'Methods',
                },
              ],
            },
        ],
        'limitations':
            responseLimitations ??
            (responseStatus == 'partial'
                ? const [
                    'Only claim-backed portions of the requested answer are shown.',
                  ]
                : const []),
        'provenance_id': _provenanceId,
        'model_id': 'model',
        'prompt_version': 'v2',
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
