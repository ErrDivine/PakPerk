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

  test('create and edit serialize exact NFKC canonical bodies', () async {
    const paperId = '018f47a6-4b56-7f4c-8c7a-e2656e820021';
    const commentId = '018f47a6-4b56-7f4c-8c7a-e2656e820011';
    const requestId = '018f47a6-4b56-7f4c-8c7a-e2656e820041';
    final adapter = _CommentMutationAdapter(
      paperId: paperId,
      commentId: commentId,
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;
    final api = CommentsApi(dio);

    final created = await api.create(
      paperId: paperId,
      clientRequestId: requestId,
      body: '  Ａ create\r\n\r\n\r\nnext\tline  ',
      expectedAuthEpoch: 7,
    );
    final edited = await api.edit(
      commentId: commentId,
      body: '  \u212b edit\r\n\u1100\u1161\tline  ',
      expectedVersion: 1,
      expectedAuthEpoch: 7,
    );

    expect(created.body, 'A create\n\nnext line');
    expect(edited.body, '\u00c5 edit\n\uac00 line');
    expect(adapter.bodies, [
      {'client_request_id': requestId, 'body': 'A create\n\nnext line'},
      {'body': '\u00c5 edit\n\uac00 line', 'expected_version': 1},
    ]);
  });

  test('comment mutations reject invalid raw input before a request', () async {
    const paperId = '018f47a6-4b56-7f4c-8c7a-e2656e820021';
    const commentId = '018f47a6-4b56-7f4c-8c7a-e2656e820011';
    const requestId = '018f47a6-4b56-7f4c-8c7a-e2656e820041';
    final adapter = _CommentMutationAdapter(
      paperId: paperId,
      commentId: commentId,
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;
    final api = CommentsApi(dio);
    final invalidBodies = <String>[
      _repeat('x', commentMaximumRawCodeUnits + 1),
      'before${String.fromCharCode(0xd800)}',
      _repeat('\u0301', commentMaximumRawClusterScalars + 1),
    ];

    for (final body in invalidBodies) {
      await expectLater(
        api.create(
          paperId: paperId,
          clientRequestId: requestId,
          body: body,
          expectedAuthEpoch: 7,
        ),
        throwsArgumentError,
      );
      await expectLater(
        api.edit(
          commentId: commentId,
          body: body,
          expectedVersion: 1,
          expectedAuthEpoch: 7,
        ),
        throwsArgumentError,
      );
    }

    expect(adapter.calls, 0);
  });
}

final class _CommentMutationAdapter implements HttpClientAdapter {
  _CommentMutationAdapter({required this.paperId, required this.commentId});

  final String paperId;
  final String commentId;
  final List<Map<String, dynamic>> bodies = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final decoded = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    bodies.add(decoded);
    calls += 1;
    final isCreate = options.method == 'POST';
    if (isCreate) {
      expect(options.path, '/v1/papers/$paperId/comments');
    } else {
      expect(options.method, 'PATCH');
      expect(options.path, '/v1/comments/$commentId');
    }
    final updatedAt = isCreate
        ? '2026-07-30T10:00:00Z'
        : '2026-07-30T10:01:00Z';
    return ResponseBody.fromString(
      jsonEncode({
        'comment': {
          'id': commentId,
          'paper_id': paperId,
          'author': {
            'id': '018f47a6-4b56-7f4c-8c7a-e2656e820001',
            'handle': 'reader_one',
            'display_name': null,
            'status': 'active',
          },
          'body': decoded['body'],
          'status': 'published',
          'version': isCreate ? 1 : 2,
          'created_at': '2026-07-30T10:00:00Z',
          'updated_at': updatedAt,
          'edited_at': isCreate ? null : updatedAt,
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

String _repeat(String value, int count) => List.filled(count, value).join();
