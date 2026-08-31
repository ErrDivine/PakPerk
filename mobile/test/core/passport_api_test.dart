import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/document/document_api.dart';
import 'package:pakperk/core/document/passport_api.dart';
import 'package:pakperk/core/models/paper_passport.dart';

import '../support/passport_fixtures.dart';

void main() {
  test('public Passport GET validates exact generation and version', () async {
    final adapter = _PassportAdapter();
    final passport = await PassportApi(_dio(adapter)).fetchPassport(
      paperId: passportPaperId,
      expectedVersionKey: '2601.00001v7',
      expectedGeneration: 7,
    );

    expect(passport.id, passportId);
    expect(
      adapter.requests.single.path,
      '/v1/papers/$passportPaperId/passport',
    );
    expect(adapter.requests.single.headers['Authorization'], isNull);
  });

  test('public Passport GET rejects a stale exact arXiv version', () async {
    final adapter = _PassportAdapter(versionLabel: 'v8');
    await expectLater(
      () => PassportApi(_dio(adapter)).fetchPassport(
        paperId: passportPaperId,
        expectedVersionKey: '2601.00001v7',
        expectedGeneration: 7,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_PASSPORT_RESPONSE',
        ),
      ),
    );
  });

  test(
    'document snapshot rejects a Passport for another exact version',
    () async {
      final adapter = _DocumentPassportAdapter();
      await expectLater(
        () => DocumentApi(_dio(adapter)).fetchSnapshot(
          paperId: passportPaperId,
          versionKey: '2601.00001v7',
          expectedGeneration: 7,
          expectedAuthEpoch: 9,
          includePassport: true,
          includeSemanticFacets: false,
          includeVisualObjects: false,
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'INVALID_DOCUMENT_RESPONSE',
          ),
        ),
      );
    },
  );

  test('authenticated feedback uses one idempotency operation', () async {
    final adapter = _PassportAdapter();
    final result = await PassportApi(_dio(adapter)).submitFeedback(
      paperId: passportPaperId,
      passportId: passportId,
      fieldId: validPassport().fields.first.id,
      feedbackType: PassportFeedbackType.wrongEvidence,
      detail: '  The cited block is unrelated.  ',
      operationId: passportOperationId,
      expectedAuthEpoch: 9,
      anonymousSessionId: null,
    );

    expect(result.evaluationId, passportEvaluationId);
    expect(result.replayed, isFalse);
    final request = adapter.requests.single;
    expect(request.headers['Idempotency-Key'], passportOperationId);
    expect(request.headers['X-Session-Id'], isNull);
    expect(request.extra['pakperk.expected_auth_epoch'], 9);
    expect((request.data as Map)['operation_id'], passportOperationId);
    expect((request.data as Map)['feedback_type'], 'wrong_evidence');
    expect((request.data as Map)['detail'], 'The cited block is unrelated.');
  });

  test('guest feedback binds a valid anonymous principal', () async {
    final adapter = _PassportAdapter(replayed: true);
    final result = await PassportApi(_dio(adapter)).submitFeedback(
      paperId: passportPaperId,
      passportId: passportId,
      fieldId: null,
      feedbackType: PassportFeedbackType.parserIssue,
      detail: null,
      operationId: passportOperationId,
      expectedAuthEpoch: null,
      anonymousSessionId: passportAnonymousSessionId,
    );

    expect(result.replayed, isTrue);
    expect(
      adapter.requests.single.headers['X-Session-Id'],
      passportAnonymousSessionId,
    );
    expect(
      adapter.requests.single.extra['pakperk.expected_auth_epoch'],
      isNull,
    );
  });

  test('feedback response and principal fail closed', () async {
    final malformed = _PassportAdapter(malformedFeedback: true);
    await expectLater(
      () => PassportApi(_dio(malformed)).submitFeedback(
        paperId: passportPaperId,
        passportId: passportId,
        fieldId: null,
        feedbackType: PassportFeedbackType.wrongField,
        detail: null,
        operationId: passportOperationId,
        expectedAuthEpoch: null,
        anonymousSessionId: passportAnonymousSessionId,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_PASSPORT_RESPONSE',
        ),
      ),
    );

    expect(
      () => PassportApi(_dio(_PassportAdapter())).submitFeedback(
        paperId: passportPaperId,
        passportId: passportId,
        fieldId: null,
        feedbackType: PassportFeedbackType.wrongField,
        detail: null,
        operationId: passportOperationId,
        expectedAuthEpoch: null,
        anonymousSessionId: null,
      ),
      throwsArgumentError,
    );
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

final class _PassportAdapter implements HttpClientAdapter {
  _PassportAdapter({
    this.versionLabel = 'v7',
    this.replayed = false,
    this.malformedFeedback = false,
  });

  final String versionLabel;
  final bool replayed;
  final bool malformedFeedback;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final isFeedback = options.path.endsWith('/feedback');
    final body = isFeedback
        ? malformedFeedback
              ? {'evaluation_id': 'not-a-uuid', 'replayed': 'false'}
              : {'evaluation_id': passportEvaluationId, 'replayed': replayed}
        : {
            'paper_id': passportPaperId,
            'generation': 7,
            'passport': validPassportJson(versionLabel: versionLabel),
          };
    return ResponseBody.fromString(
      jsonEncode(body),
      isFeedback ? 201 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _DocumentPassportAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final payload = switch (options.path.split('/').last) {
      'outline' => {
        'paper_id': passportPaperId,
        'generation': 7,
        'items': <Object?>[],
        'provenance': {'status': 'ready'},
      },
      'blocks' => {
        'paper_id': passportPaperId,
        'generation': 7,
        'items': <Object?>[],
        'next_cursor': null,
      },
      'passport' => {
        'paper_id': passportPaperId,
        'generation': 7,
        'passport': validPassportJson(versionLabel: 'v8'),
      },
      _ => throw StateError('Unexpected route ${options.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
