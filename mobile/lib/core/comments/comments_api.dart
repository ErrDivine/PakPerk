import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'comment_models.dart';

abstract interface class CommentsRemoteDataSource {
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  });

  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  });

  Future<PaperComment> edit({
    required String commentId,
    required String body,
    required int expectedVersion,
    required int expectedAuthEpoch,
  });

  Future<void> delete({
    required String commentId,
    required int expectedAuthEpoch,
  });

  Future<CommentReportReceipt> report({
    required String commentId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  });

  Future<UserReportReceipt> reportUser({
    required String userId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  });

  Future<BlockedUser> block({
    required String userId,
    required int expectedAuthEpoch,
  });

  Future<void> unblock({
    required String userId,
    required int expectedAuthEpoch,
  });

  Future<BlockedUserPage> listBlockedUsers({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  });

  Future<CommentPage> listMyComments({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  });
}

final class CommentsApi implements CommentsRemoteDataSource {
  const CommentsApi(this._dio);

  final Dio _dio;

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    _validateUuid(paperId, 'paperId');
    _validateList(cursor: cursor, limit: limit);
    if (expectedAuthEpoch != null) _validateEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.get<Object?>(
        '/v1/papers/${Uri.encodeComponent(paperId)}/comments',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
        options: pakPerkRequestOptions(
          auth: expectedAuthEpoch == null
              ? RequestAuthPolicy.none
              : RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      return CommentPage.fromJson(_map(response.data));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  }) async {
    _validateUuid(paperId, 'paperId');
    _validateUuid(clientRequestId, 'clientRequestId');
    _validateEpoch(expectedAuthEpoch);
    _validateBody(body);
    try {
      final response = await _dio.post<Object?>(
        '/v1/papers/${Uri.encodeComponent(paperId)}/comments',
        data: {'client_request_id': clientRequestId, 'body': body},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          // The body is canonical authority. Mirroring the UUID in this
          // generic retry header lets AuthInterceptor safely replay one 401.
          headers: {'Idempotency-Key': clientRequestId},
        ),
      );
      final comment = _commentEnvelope(response.data);
      if (comment.paperId != paperId) throw const FormatException();
      return comment;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<PaperComment> edit({
    required String commentId,
    required String body,
    required int expectedVersion,
    required int expectedAuthEpoch,
  }) async {
    _validateUuid(commentId, 'commentId');
    _validateEpoch(expectedAuthEpoch);
    _validateBody(body);
    if (expectedVersion < 1) throw ArgumentError.value(expectedVersion);
    try {
      final response = await _dio.patch<Object?>(
        '/v1/comments/${Uri.encodeComponent(commentId)}',
        data: {'body': body, 'expected_version': expectedVersion},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {'If-Match': '"comment-version-$expectedVersion"'},
        ),
      );
      final comment = _commentEnvelope(response.data);
      if (comment.id != commentId || comment.version <= expectedVersion) {
        throw const FormatException();
      }
      return comment;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<void> delete({
    required String commentId,
    required int expectedAuthEpoch,
  }) => _emptyMutation(
    method: 'DELETE',
    path: '/v1/comments/${_uuidPath(commentId, 'commentId')}',
    expectedAuthEpoch: expectedAuthEpoch,
  );

  @override
  Future<CommentReportReceipt> report({
    required String commentId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  }) async {
    _validateUuid(commentId, 'commentId');
    _validateEpoch(expectedAuthEpoch);
    final normalizedDetail = _normalizeReportDetail(detail);
    try {
      final response = await _dio.post<Object?>(
        '/v1/comments/${Uri.encodeComponent(commentId)}/reports',
        data: {'reason': reason.wireValue, 'detail': normalizedDetail},
        options: _repeatSafeOptions(expectedAuthEpoch),
      );
      final root = _map(response.data);
      _expectKeys(root, const {'report'});
      final raw = root['report'];
      if (raw is! Map) throw const FormatException();
      final report = CommentReportReceipt.fromJson(
        Map<String, dynamic>.from(raw),
      );
      // Reporter/comment uniqueness wins across retries. A later retry with a
      // different reason returns the first canonical report by design.
      if (report.commentId != commentId) {
        throw const FormatException();
      }
      return report;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<UserReportReceipt> reportUser({
    required String userId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  }) async {
    _validateUuid(userId, 'userId');
    _validateEpoch(expectedAuthEpoch);
    final normalizedDetail = _normalizeReportDetail(detail);
    try {
      final response = await _dio.post<Object?>(
        '/v1/users/${Uri.encodeComponent(userId)}/reports',
        data: {'reason': reason.wireValue, 'detail': normalizedDetail},
        options: _repeatSafeOptions(expectedAuthEpoch),
      );
      final root = _map(response.data);
      _expectKeys(root, const {'report'});
      final raw = root['report'];
      if (raw is! Map) throw const FormatException();
      final report = UserReportReceipt.fromJson(Map<String, dynamic>.from(raw));
      // Reporter/target uniqueness returns the first canonical reason on a
      // retry, while the target identity must always match this request.
      if (report.reportedUserId != userId) throw const FormatException();
      return report;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<BlockedUser> block({
    required String userId,
    required int expectedAuthEpoch,
  }) async {
    _validateUuid(userId, 'userId');
    _validateEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.put<Object?>(
        '/v1/me/blocked-users/${Uri.encodeComponent(userId)}',
        options: _repeatSafeOptions(expectedAuthEpoch),
      );
      final root = _map(response.data);
      _expectKeys(root, const {'blocked_user'});
      final raw = root['blocked_user'];
      if (raw is! Map) throw const FormatException();
      final block = BlockedUser.fromJson(Map<String, dynamic>.from(raw));
      if (block.user.id != userId) throw const FormatException();
      return block;
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<void> unblock({
    required String userId,
    required int expectedAuthEpoch,
  }) => _emptyMutation(
    method: 'DELETE',
    path: '/v1/me/blocked-users/${_uuidPath(userId, 'userId')}',
    expectedAuthEpoch: expectedAuthEpoch,
  );

  @override
  Future<BlockedUserPage> listBlockedUsers({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async {
    _validateEpoch(expectedAuthEpoch);
    _validateList(cursor: cursor, limit: limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/me/blocked-users',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      return BlockedUserPage.fromJson(_map(response.data));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  @override
  Future<CommentPage> listMyComments({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    _validateEpoch(expectedAuthEpoch);
    _validateList(cursor: cursor, limit: limit);
    try {
      final response = await _dio.get<Object?>(
        '/v1/me/comments',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      return CommentPage.fromJson(_map(response.data));
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<void> _emptyMutation({
    required String method,
    required String path,
    required int expectedAuthEpoch,
  }) async {
    _validateEpoch(expectedAuthEpoch);
    try {
      final response = await _dio.request<Object?>(
        path,
        options: _repeatSafeOptions(expectedAuthEpoch).copyWith(method: method),
      );
      _expectNoContent(response);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw _invalidResponse;
    }
  }
}

PaperComment _commentEnvelope(Object? value) {
  final root = _map(value);
  _expectKeys(root, const {'comment'});
  final raw = root['comment'];
  if (raw is! Map) throw const FormatException();
  return PaperComment.fromJson(Map<String, dynamic>.from(raw));
}

Options _repeatSafeOptions(int expectedAuthEpoch) => pakPerkRequestOptions(
  auth: RequestAuthPolicy.required,
  retry: AuthRetryPolicy.idempotencyProtected,
  expectedAuthEpoch: expectedAuthEpoch,
  headers: {'Idempotency-Key': const Uuid().v7()},
);

void _expectNoContent(Response<Object?> response) {
  if (response.statusCode != 204 || response.data != null) {
    throw const FormatException('Expected an empty response.');
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected JSON object.');
}

void _expectKeys(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length ||
      json.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Unexpected response fields.');
  }
}

void _validateBody(String body) {
  final issue = validateCommentBody(body);
  if (issue != null) throw ArgumentError.value(body.length, 'body', issue);
}

String? _normalizeReportDetail(String? detail) {
  final normalized = detail?.trim();
  if (normalized != null &&
      (normalized.isEmpty ||
          normalized.runes.length > 500 ||
          utf8.encode(normalized).length > 2000 ||
          normalized.runes.any((rune) => rune < 0x20))) {
    throw ArgumentError.value(detail, 'detail', 'Invalid report detail.');
  }
  return normalized;
}

void _validateList({required String? cursor, required int limit}) {
  if (limit < 1 || limit > 100) {
    throw ArgumentError.value(limit, 'limit', 'Must be 1-100.');
  }
  if (cursor != null &&
      (cursor.isEmpty ||
          cursor.length > 512 ||
          cursor.runes.any((rune) => rune < 0x21 || rune > 0x7e))) {
    throw ArgumentError.value(cursor, 'cursor', 'Invalid opaque cursor.');
  }
}

void _validateEpoch(int epoch) {
  if (epoch < 0) throw ArgumentError.value(epoch, 'expectedAuthEpoch');
}

String _uuidPath(String value, String name) {
  _validateUuid(value, name);
  return Uri.encodeComponent(value);
}

void _validateUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Must be a canonical UUID.');
  }
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The comments service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
