import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../models/paper_passport.dart';

final class PassportFeedbackReceipt {
  const PassportFeedbackReceipt({
    required this.evaluationId,
    required this.replayed,
  });

  final String evaluationId;
  final bool replayed;
}

abstract interface class PassportReadRemoteDataSource {
  Future<PaperPassport> fetchPassport({
    required String paperId,
    required String expectedVersionKey,
    required int expectedGeneration,
    RequestCancellation? cancellation,
  });
}

abstract interface class PassportFeedbackRemoteDataSource {
  Future<PassportFeedbackReceipt> submitFeedback({
    required String paperId,
    required String passportId,
    required String? fieldId,
    required PassportFeedbackType feedbackType,
    required String? detail,
    required String operationId,
    required int? expectedAuthEpoch,
    required String? anonymousSessionId,
    RequestCancellation? cancellation,
  });
}

final class PassportApi
    implements PassportReadRemoteDataSource, PassportFeedbackRemoteDataSource {
  const PassportApi(this._dio);

  final Dio _dio;

  @override
  Future<PaperPassport> fetchPassport({
    required String paperId,
    required String expectedVersionKey,
    required int expectedGeneration,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuid(paperId, 'paperId');
    if (expectedGeneration <= 0) {
      throw ArgumentError.value(expectedGeneration, 'expectedGeneration');
    }
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/$safePaperId/passport',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.optional,
          retry: AuthRetryPolicy.safe,
        ),
        cancelToken: cancellation?.dioToken,
      );
      if (response.statusCode != 200) {
        throw const FormatException('Unexpected Passport response status.');
      }
      final envelope = _map(response.data);
      final responsePaperId = _responseUuid(envelope['paper_id'], 'paper_id');
      final responseGeneration = _positiveResponseInteger(
        envelope['generation'],
        'generation',
      );
      final rawPassport = envelope['passport'];
      if (rawPassport is! Map) {
        throw const FormatException('Missing Passport artifact.');
      }
      final passport = PaperPassport.fromJson(
        Map<String, dynamic>.from(rawPassport),
      );
      if (responsePaperId != safePaperId ||
          responseGeneration != expectedGeneration ||
          passport.paperId != safePaperId ||
          passport.generation != expectedGeneration ||
          !passportVersionMatchesVersionKey(passport, expectedVersionKey) ||
          !passport.isDisplayable) {
        throw const FormatException('Stale or unavailable Passport artifact.');
      }
      return passport;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<PassportFeedbackReceipt> submitFeedback({
    required String paperId,
    required String passportId,
    required String? fieldId,
    required PassportFeedbackType feedbackType,
    required String? detail,
    required String operationId,
    required int? expectedAuthEpoch,
    required String? anonymousSessionId,
    RequestCancellation? cancellation,
  }) async {
    final safePaperId = _uuid(paperId, 'paperId');
    final safePassportId = _uuid(passportId, 'passportId');
    final safeOperationId = _uuid(operationId, 'operationId');
    final safeFieldId = fieldId == null ? null : _uuid(fieldId, 'fieldId');
    if (expectedAuthEpoch != null && expectedAuthEpoch < 0) {
      throw ArgumentError.value(expectedAuthEpoch, 'expectedAuthEpoch');
    }
    final safeSessionId = anonymousSessionId == null
        ? null
        : _uuid(anonymousSessionId, 'anonymousSessionId');
    if ((expectedAuthEpoch == null) == (safeSessionId == null)) {
      throw ArgumentError(
        'Passport feedback requires exactly one authenticated or anonymous principal.',
      );
    }
    final safeDetail = normalizePassportFeedbackDetail(detail);
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/$safePaperId/passport/feedback',
        data: {
          'operation_id': safeOperationId,
          'passport_id': safePassportId,
          'field_id': safeFieldId,
          'feedback_type': feedbackType.wireValue,
          'detail': safeDetail,
        },
        options: pakPerkRequestOptions(
          auth: expectedAuthEpoch == null
              ? RequestAuthPolicy.optional
              : RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {
            'Idempotency-Key': safeOperationId,
            if (safeSessionId != null) 'X-Session-Id': safeSessionId,
          },
        ),
        cancelToken: cancellation?.dioToken,
      );
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw const FormatException('Unexpected Passport feedback status.');
      }
      final json = _map(response.data);
      final replayed = json['replayed'];
      if (replayed is! bool) {
        throw const FormatException('Invalid Passport feedback replay state.');
      }
      return PassportFeedbackReceipt(
        evaluationId: _responseUuid(json['evaluation_id'], 'evaluation_id'),
        replayed: replayed,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

String? normalizePassportFeedbackDetail(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final normalized = value.trim();
  if (normalized.contains('\u0000') ||
      normalized.runes.length > passportFeedbackMaximumScalars) {
    throw ArgumentError.value(value, 'detail');
  }
  return normalized;
}

String _uuid(String value, String field) {
  final normalized = value.trim().toLowerCase();
  if (!isValidPassportUuid(normalized)) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _responseUuid(Object? value, String field) {
  if (value is! String || !isValidPassportUuid(value)) {
    throw FormatException('Invalid Passport $field.');
  }
  return value.toLowerCase();
}

int _positiveResponseInteger(Object? value, String field) {
  if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
    throw FormatException('Invalid Passport $field.');
  }
  final result = value.toInt();
  if (result <= 0 || result > 0x7fffffff) {
    throw FormatException('Invalid Passport $field.');
  }
  return result;
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Invalid Passport feedback envelope.');
}

const _invalidResponse = ApiException(
  code: 'INVALID_PASSPORT_RESPONSE',
  message: 'The Passport service returned invalid data.',
  retryable: true,
  statusCode: 502,
);
