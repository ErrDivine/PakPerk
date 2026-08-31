import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/processing.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/paper_reader/paper_processing_controller.dart';

import '../support/fakes.dart';

void main() {
  const requestedEnrichments = ProcessingEnrichmentRequest(
    visualObjects: true,
    terms: true,
    semanticFacets: true,
    paperPassport: true,
  );

  test(
    'keeps polling after core ready until late enrichments arrive',
    () async {
      final scheduler = _ManualPollScheduler();
      final source = _ProcessingSource(_coreReady());
      final controller = PaperProcessingController(
        paperId: samplePaper.paperId,
        repository: source,
        timerFactory: scheduler.schedule,
      );
      addTearDown(controller.dispose);

      controller.setEnrichmentRequest(requestedEnrichments);
      controller.setVisible(true);
      await _flushAsyncWork();

      expect(source.processingCalls, 1);
      expect(controller.state.processing?.capabilities.introduction, isTrue);
      expect(
        controller.state.enrichmentStatus,
        ProcessingEnrichmentStatus.waiting,
      );
      expect(scheduler.hasActiveTimer, isTrue);

      source.processing = _allEnrichmentsReady();
      await scheduler.fireNext();

      expect(source.processingCalls, 2);
      expect(
        controller.state.enrichmentStatus,
        ProcessingEnrichmentStatus.ready,
      );
      expect(controller.state.processing?.capabilities.paperPassport, isTrue);
      expect(scheduler.hasActiveTimer, isFalse);
      expect(source.prepareCalls, 0);
    },
  );

  test('disabled enrichments do not extend core-ready polling', () async {
    final scheduler = _ManualPollScheduler();
    final source = _ProcessingSource(_coreReady());
    final controller = PaperProcessingController(
      paperId: samplePaper.paperId,
      repository: source,
      timerFactory: scheduler.schedule,
    );
    addTearDown(controller.dispose);

    controller.setEnrichmentRequest(const ProcessingEnrichmentRequest());
    controller.setVisible(true);
    await _flushAsyncWork();

    expect(source.processingCalls, 1);
    expect(
      controller.state.enrichmentStatus,
      ProcessingEnrichmentStatus.disabled,
    );
    expect(scheduler.hasActiveTimer, isFalse);
    expect(source.prepareCalls, 0);
  });

  test('enrichment polling stops at the finite attempt budget', () async {
    final scheduler = _ManualPollScheduler();
    final source = _ProcessingSource(_coreReady());
    final controller = PaperProcessingController(
      paperId: samplePaper.paperId,
      repository: source,
      pollPolicy: const ProcessingPollPolicy(
        maximumEnrichmentAttempts: 2,
        maximumEnrichmentDuration: Duration(minutes: 5),
      ),
      timerFactory: scheduler.schedule,
    );
    addTearDown(controller.dispose);

    controller.setEnrichmentRequest(requestedEnrichments);
    controller.setVisible(true);
    await _flushAsyncWork();
    await scheduler.fireNext();
    await scheduler.fireNext();

    expect(source.processingCalls, 3);
    expect(
      controller.state.enrichmentStatus,
      ProcessingEnrichmentStatus.unavailable,
    );
    expect(controller.state.processing?.capabilities.introduction, isTrue);
    expect(controller.state.enrichmentMessage, contains('text remains'));
    expect(scheduler.hasActiveTimer, isFalse);
    expect(source.prepareCalls, 0);
  });

  test('enrichment polling also stops at the elapsed deadline', () async {
    final scheduler = _ManualPollScheduler();
    var now = DateTime.utc(2026, 8, 31, 12);
    final source = _ProcessingSource(_coreReady());
    final controller = PaperProcessingController(
      paperId: samplePaper.paperId,
      repository: source,
      pollPolicy: const ProcessingPollPolicy(
        maximumEnrichmentAttempts: 100,
        maximumEnrichmentDuration: Duration(minutes: 1),
      ),
      now: () => now,
      timerFactory: scheduler.schedule,
    );
    addTearDown(controller.dispose);

    controller.setEnrichmentRequest(requestedEnrichments);
    controller.setVisible(true);
    await _flushAsyncWork();
    await scheduler.fireNext();
    now = now.add(const Duration(minutes: 1));
    await scheduler.fireNext();

    expect(source.processingCalls, 2);
    expect(
      controller.state.enrichmentStatus,
      ProcessingEnrichmentStatus.unavailable,
    );
    expect(scheduler.hasActiveTimer, isFalse);
    expect(source.prepareCalls, 0);
  });

  test('hiding the reader cancels and fences an in-flight poll', () async {
    final scheduler = _ManualPollScheduler();
    final source = _DelayedProcessingSource();
    final controller = PaperProcessingController(
      paperId: samplePaper.paperId,
      repository: source,
      timerFactory: scheduler.schedule,
    );
    addTearDown(controller.dispose);

    controller.setEnrichmentRequest(requestedEnrichments);
    controller.setVisible(true);
    await _flushAsyncWork();
    expect(source.processingCalls, 1);

    controller.setVisible(false);
    expect(source.lastProcessingCancellation?.isCancelled, isTrue);

    source.pending.complete(
      RepositoryValue(
        value: _allEnrichmentsReady(),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await _flushAsyncWork();

    expect(controller.state.visible, isFalse);
    expect(controller.state.processing, isNull);
    expect(scheduler.hasActiveTimer, isFalse);
    expect(source.prepareCalls, 0);
  });
}

PaperProcessingState _coreReady() => PaperProcessingState(
  paperId: samplePaper.paperId,
  overallState: 'ready',
  stage: ProcessingStage.ready,
  capabilities: const PaperCapabilities(
    introduction: true,
    chat: true,
    connections: true,
  ),
  retryable: false,
  updatedAt: DateTime.utc(2026, 8, 31),
);

PaperProcessingState _allEnrichmentsReady() => PaperProcessingState(
  paperId: samplePaper.paperId,
  overallState: 'ready',
  stage: ProcessingStage.ready,
  capabilities: const PaperCapabilities(
    introduction: true,
    chat: true,
    connections: true,
    visualObjects: true,
    terms: true,
    semanticFacets: true,
    paperPassport: true,
  ),
  retryable: false,
  updatedAt: DateTime.utc(2026, 8, 31, 0, 1),
);

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ProcessingSource extends FakePaperDataSource {
  _ProcessingSource(PaperProcessingState processing)
    : super(processing: processing);

  @override
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) async {
    processingCalls += 1;
    lastProcessingCancellation = cancellation;
    return RepositoryValue(
      value: processing!,
      origin: DataOrigin.network,
      offline: false,
    );
  }
}

final class _DelayedProcessingSource extends FakePaperDataSource {
  final pending = Completer<RepositoryValue<PaperProcessingState>>();

  @override
  Future<RepositoryValue<PaperProcessingState>> getProcessing(
    String paperId, {
    RequestCancellation? cancellation,
  }) {
    processingCalls += 1;
    lastProcessingCancellation = cancellation;
    return pending.future;
  }
}

final class _ManualPollScheduler {
  final List<_ManualTimer> _timers = [];

  Timer schedule(Duration _, void Function() callback) {
    final timer = _ManualTimer(callback);
    _timers.add(timer);
    return timer;
  }

  bool get hasActiveTimer => _timers.any((timer) => timer.isActive);

  Future<void> fireNext() async {
    final timer = _timers.firstWhere((candidate) => candidate.isActive);
    timer.fire();
    await _flushAsyncWork();
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  var _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() {
    _active = false;
  }
}
