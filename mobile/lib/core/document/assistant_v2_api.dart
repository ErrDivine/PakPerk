import 'package:dio/dio.dart';
import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../models/assistant_v2.dart';

final class AssistantV2Api {
  const AssistantV2Api(this._dio);
  final Dio _dio;

  Future<AssistantAnswer> ask({
    required String paperId,
    required int generation,
    required String question,
    required AssistantRequestScope scope,
    required AssistantAnswerStyle answerStyle,
    required int expectedAuthEpoch,
    String? threadId,
    RequestCancellation? cancellation,
  }) async {
    final normalizedQuestion = question.trim();
    if (!isValidAssistantUuid(paperId) ||
        generation <= 0 ||
        generation > _signed32Maximum ||
        expectedAuthEpoch < 0 ||
        normalizedQuestion.isEmpty ||
        normalizedQuestion.runes.length > 500 ||
        normalizedQuestion.contains('\u0000') ||
        (threadId != null && !isValidAssistantUuid(threadId))) {
      throw ArgumentError('Invalid assistant request.');
    }
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/$paperId/assistant',
        data: {
          'paper_id': paperId,
          'generation': generation,
          'question': normalizedQuestion,
          'scope': scope.toJson(),
          'answer_style': answerStyle.wireValue,
          'thread_id': threadId,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.never,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      final answer = AssistantAnswer.fromJson(_responseMap(response.data));
      if (answer.generation != generation ||
          (threadId != null && answer.threadId != threadId)) {
        throw const FormatException('Stale assistant response scope.');
      }
      return answer;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidAssistantResponse;
    }
  }

  Future<AssistantProvenance> provenance({
    required String provenanceId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    if (!isValidAssistantUuid(provenanceId) || expectedAuthEpoch < 0) {
      throw ArgumentError('Invalid assistant provenance request.');
    }
    try {
      final response = await _dio.get<Object?>(
        '/v1/assistant/provenance/$provenanceId',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      final provenance = AssistantProvenance.fromJson(
        _responseMap(response.data),
      );
      if (provenance.id != provenanceId) {
        throw const FormatException('Assistant provenance scope mismatch.');
      }
      return provenance;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidAssistantResponse;
    }
  }

  Future<AssistantEvidenceFeedbackReceipt> feedback({
    required String paperId,
    required int generation,
    required AssistantAnswer answer,
    required AssistantEvidenceFeedbackDraft feedback,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) async {
    if (!isValidAssistantUuid(paperId) ||
        generation <= 0 ||
        generation > _signed32Maximum ||
        expectedAuthEpoch < 0 ||
        answer.generation != generation ||
        !isValidAssistantUuid(answer.threadId) ||
        !isValidAssistantUuid(answer.responseId) ||
        !isValidAssistantUuid(answer.provenanceId) ||
        !_feedbackTargetsAnswer(answer, feedback)) {
      throw ArgumentError('Invalid assistant feedback request.');
    }
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/$paperId/assistant/feedback',
        data: {
          'operation_id': feedback.operationId,
          'paper_id': paperId,
          'generation': generation,
          'thread_id': answer.threadId,
          'response_id': answer.responseId,
          'provenance_id': answer.provenanceId,
          'feedback_type': feedback.type.wireValue,
          'claim_index': feedback.claimIndex,
          'evidence_block_id': feedback.evidenceBlockId,
          'detail': feedback.detail,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.never,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
        cancelToken: cancellation?.dioToken,
      );
      return AssistantEvidenceFeedbackReceipt.fromJson(
        _responseMap(response.data),
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidAssistantResponse;
    }
  }
}

bool _feedbackTargetsAnswer(
  AssistantAnswer answer,
  AssistantEvidenceFeedbackDraft feedback,
) {
  final claimIndex = feedback.claimIndex;
  if (!feedback.type.requiresClaim) {
    return claimIndex == null && feedback.evidenceBlockId == null;
  }
  if (claimIndex == null || claimIndex >= answer.claims.length) return false;
  if (!feedback.type.requiresEvidenceBlock) {
    return feedback.evidenceBlockId == null;
  }
  final evidenceBlockId = feedback.evidenceBlockId;
  return evidenceBlockId != null &&
      answer.claims[claimIndex].evidence.any(
        (evidence) => evidence.blockId == evidenceBlockId,
      );
}

Map<String, dynamic> _responseMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid assistant response envelope.');
  }
  return Map<String, dynamic>.from(value);
}

const _signed32Maximum = 0x7fffffff;
const _invalidAssistantResponse = ApiException(
  code: 'INVALID_ASSISTANT_RESPONSE',
  message: 'The Assistant service returned invalid data.',
  retryable: true,
  statusCode: 502,
);
