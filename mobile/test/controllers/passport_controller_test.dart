import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/document/passport_api.dart';
import 'package:pakperk/core/models/paper_passport.dart';
import 'package:pakperk/features/passport/passport_controller.dart';

import '../support/passport_fixtures.dart';

void main() {
  test(
    'abstract loader ignores a response after its viewer scope changes',
    () async {
      var current = true;
      final remote = _DeferredPassportRead();
      final controller = AbstractPassportController(
        args: const AbstractPassportArgs(
          paperId: passportPaperId,
          versionKey: '2601.00001v7',
          generation: 7,
          viewerScope: 'viewer-1',
        ),
        source: remote,
        scopeIsCurrent: () => current,
      );
      addTearDown(controller.dispose);

      final flight = controller.load();
      expect(controller.state.phase, AbstractPassportPhase.loading);
      current = false;
      remote.completer.complete(validPassport());
      await flight;

      expect(controller.state.passport, isNull);
      expect(controller.state.phase, AbstractPassportPhase.loading);
    },
  );

  test('abstract loader cancels the transport when disposed', () async {
    final remote = _DeferredPassportRead();
    final controller = AbstractPassportController(
      args: const AbstractPassportArgs(
        paperId: passportPaperId,
        versionKey: '2601.00001v7',
        generation: 7,
        viewerScope: 'viewer-1',
      ),
      source: remote,
      scopeIsCurrent: () => true,
    );

    unawaited(controller.load());
    await Future<void>.delayed(Duration.zero);
    final cancellation = remote.cancellation;
    expect(cancellation, isNotNull);
    controller.dispose();
    expect(cancellation!.isCancelled, isTrue);
    remote.completer.complete(validPassport());
  });

  test('feedback retry reuses the exact failed operation id', () async {
    final remote = _FeedbackRemote(failFirst: true);
    final controller = PassportController(
      args: const PassportControllerArgs.anonymous(
        anonymousSessionId: passportAnonymousSessionId,
        paperId: passportPaperId,
        versionKey: '2601.00001v7',
        generation: 7,
        passportId: passportId,
        viewerScope: 'viewer-1',
      ),
      source: remote,
      scopeIsCurrent: () => true,
      operationId: () => passportOperationId,
    );
    addTearDown(controller.dispose);
    final field = validPassport().fields.first;

    await controller.submit(
      field: field,
      feedbackType: PassportFeedbackType.wrongEvidence,
      detail: 'Wrong source',
    );
    expect(controller.state.phase, PassportFeedbackPhase.failed);
    await controller.submit(
      field: field,
      feedbackType: PassportFeedbackType.wrongEvidence,
      detail: 'Wrong source',
    );

    expect(remote.operationIds, [passportOperationId, passportOperationId]);
    expect(controller.state.phase, PassportFeedbackPhase.succeeded);
    expect(controller.state.receipt?.evaluationId, passportEvaluationId);
  });

  test(
    'feedback drops a successful late response after scope invalidation',
    () async {
      var current = true;
      final remote = _DeferredFeedbackRemote();
      final controller = PassportController(
        args: const PassportControllerArgs.anonymous(
          anonymousSessionId: passportAnonymousSessionId,
          paperId: passportPaperId,
          versionKey: '2601.00001v7',
          generation: 7,
          passportId: passportId,
          viewerScope: 'viewer-1',
        ),
        source: remote,
        scopeIsCurrent: () => current,
        operationId: () => passportOperationId,
      );
      addTearDown(controller.dispose);

      final flight = controller.submit(
        field: validPassport().fields.first,
        feedbackType: PassportFeedbackType.wrongField,
        detail: null,
      );
      current = false;
      remote.completer.complete(
        const PassportFeedbackReceipt(
          evaluationId: passportEvaluationId,
          replayed: false,
        ),
      );
      await flight;

      expect(controller.state.receipt, isNull);
      expect(controller.state.phase, PassportFeedbackPhase.submitting);
    },
  );

  test(
    'feedback rejects hand-built unverified fields before transport',
    () async {
      final remote = _FeedbackRemote();
      final controller = PassportController(
        args: const PassportControllerArgs.anonymous(
          anonymousSessionId: passportAnonymousSessionId,
          paperId: passportPaperId,
          versionKey: '2601.00001v7',
          generation: 7,
          passportId: passportId,
          viewerScope: 'viewer-1',
        ),
        source: remote,
        scopeIsCurrent: () => true,
        operationId: () => passportOperationId,
      );
      addTearDown(controller.dispose);

      await expectLater(
        () => controller.submit(
          field: PassportField(
            key: 'main_result',
            status: PassportFieldStatus.supported,
            value: 'Unverified',
            sourceBlockIds: const [passportPaperId],
          ),
          feedbackType: PassportFeedbackType.wrongField,
          detail: null,
        ),
        throwsStateError,
      );
      expect(remote.operationIds, isEmpty);
    },
  );
}

final class _DeferredPassportRead implements PassportReadRemoteDataSource {
  final Completer<PaperPassport> completer = Completer<PaperPassport>();
  RequestCancellation? cancellation;

  @override
  Future<PaperPassport> fetchPassport({
    required String paperId,
    required String expectedVersionKey,
    required int expectedGeneration,
    RequestCancellation? cancellation,
  }) {
    this.cancellation = cancellation;
    return completer.future;
  }
}

final class _FeedbackRemote implements PassportFeedbackRemoteDataSource {
  _FeedbackRemote({this.failFirst = false});

  final bool failFirst;
  final List<String> operationIds = [];

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
    operationIds.add(operationId);
    if (failFirst && operationIds.length == 1) {
      throw const ApiException(
        code: 'TEMPORARY',
        message: 'Temporary failure',
        retryable: true,
      );
    }
    return const PassportFeedbackReceipt(
      evaluationId: passportEvaluationId,
      replayed: false,
    );
  }
}

final class _DeferredFeedbackRemote
    implements PassportFeedbackRemoteDataSource {
  final Completer<PassportFeedbackReceipt> completer =
      Completer<PassportFeedbackReceipt>();

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
  }) => completer.future;
}
