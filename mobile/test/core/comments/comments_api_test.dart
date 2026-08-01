import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/auth_interceptor.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/comments/comments_api.dart';

void main() {
  test(
    'report has one protected 401 replay and accepts canonical duplicate',
    () async {
      const commentId = '018f47a6-4b56-7f4c-8c7a-e2656e820011';
      final tokens = _TokenSource();
      final adapter = _ReportAdapter(commentId);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        AuthInterceptor(
          dio: dio,
          apiBaseUri: Uri.parse('https://api.pakperk.app'),
          tokenSource: tokens,
        ),
      );

      final receipt = await CommentsApi(dio).report(
        commentId: commentId,
        reason: CommentReportReason.harassment,
        detail: null,
        expectedAuthEpoch: 7,
      );

      expect(receipt.reason, CommentReportReason.spam);
      expect(tokens.refreshCalls, 1);
      expect(adapter.authorization, ['Bearer access-one', 'Bearer access-two']);
      expect(adapter.idempotencyKeys, hasLength(2));
      expect(adapter.idempotencyKeys.first, adapter.idempotencyKeys.last);
      expect(adapter.bodies, hasLength(2));
      expect(jsonDecode(adapter.bodies.first), {
        'reason': 'harassment',
        'detail': null,
      });
      expect(adapter.bodies.last, adapter.bodies.first);
    },
  );

  test(
    'user report has one protected replay and validates target identity',
    () async {
      const userId = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
      final tokens = _TokenSource();
      final adapter = _UserReportAdapter(userId);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        AuthInterceptor(
          dio: dio,
          apiBaseUri: Uri.parse('https://api.pakperk.app'),
          tokenSource: tokens,
        ),
      );

      final receipt = await CommentsApi(dio).reportUser(
        userId: userId,
        reason: CommentReportReason.impersonation,
        detail: '  Profile context  ',
        expectedAuthEpoch: 7,
      );

      expect(receipt.reportedUserId, userId);
      expect(receipt.reason, CommentReportReason.spam);
      expect(tokens.refreshCalls, 1);
      expect(adapter.idempotencyKeys, hasLength(2));
      expect(adapter.idempotencyKeys.first, adapter.idempotencyKeys.last);
      expect(jsonDecode(adapter.bodies.first), {
        'reason': 'impersonation',
        'detail': 'Profile context',
      });
      expect(adapter.bodies.last, adapter.bodies.first);
    },
  );
}

final class _TokenSource implements AuthTokenSource {
  var token = 'access-one';
  var refreshCalls = 0;

  @override
  bool isCurrentEpoch(int expectedAuthEpoch) => expectedAuthEpoch == 7;

  @override
  Future<String?> accessTokenForRequest({int? expectedAuthEpoch}) async {
    expect(expectedAuthEpoch, 7);
    return token;
  }

  @override
  Future<String?> refreshAfterUnauthorized({
    required String rejectedAccessToken,
    int? expectedAuthEpoch,
  }) async {
    expect(expectedAuthEpoch, 7);
    expect(rejectedAccessToken, 'access-one');
    refreshCalls += 1;
    return token = 'access-two';
  }
}

final class _ReportAdapter implements HttpClientAdapter {
  _ReportAdapter(this.commentId);

  final String commentId;
  final List<String?> authorization = [];
  final List<String?> idempotencyKeys = [];
  final List<String> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'POST');
    expect(options.path, '/v1/comments/$commentId/reports');
    authorization.add(options.headers['Authorization'] as String?);
    idempotencyKeys.add(options.headers['Idempotency-Key'] as String?);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    if (authorization.length == 1) {
      return ResponseBody.fromString(
        jsonEncode(const {'error': 'unauthorized'}),
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'report': {
          'id': '018f47a6-4b56-7f4c-8c7a-e2656e820031',
          'comment_id': commentId,
          // A duplicate reporter/comment pair returns the first canonical
          // reason, which may differ from this retry's submitted reason.
          'reason': 'spam',
          'status': 'open',
          'created_at': '2026-07-30T10:00:00Z',
        },
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

final class _UserReportAdapter implements HttpClientAdapter {
  _UserReportAdapter(this.userId);

  final String userId;
  final List<String?> idempotencyKeys = [];
  final List<String> bodies = [];
  var calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'POST');
    expect(options.path, '/v1/users/$userId/reports');
    idempotencyKeys.add(options.headers['Idempotency-Key'] as String?);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    calls += 1;
    if (calls == 1) {
      return ResponseBody.fromString(
        jsonEncode(const {'error': 'unauthorized'}),
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'report': {
          'id': '018f47a6-4b56-7f4c-8c7a-e2656e820032',
          'reported_user_id': userId,
          'reason': 'spam',
          'status': 'open',
          'created_at': '2026-07-30T10:00:00Z',
        },
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
