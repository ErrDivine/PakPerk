import 'paper.dart';

enum ProcessingStage {
  notRequested('not_requested'),
  queued('queued'),
  fetchingLicense('fetching_license'),
  fetchingPdf('fetching_pdf'),
  parsingPdf('parsing_pdf'),
  introductionReady('introduction_ready'),
  indexingChat('indexing_chat'),
  resolvingReferences('resolving_references'),
  ready('ready'),
  failedRetryable('failed_retryable'),
  failedTerminal('failed_terminal');

  const ProcessingStage(this.wireValue);
  final String wireValue;

  static ProcessingStage fromWire(Object? value) {
    final wire = value?.toString() ?? 'not_requested';
    return ProcessingStage.values.firstWhere(
      (stage) => stage.wireValue == wire,
      orElse: () => ProcessingStage.notRequested,
    );
  }
}

class PaperProcessingState {
  const PaperProcessingState({
    required this.paperId,
    required this.overallState,
    required this.stage,
    required this.capabilities,
    required this.retryable,
    required this.updatedAt,
    this.lastErrorCode,
    this.lastErrorMessage,
  });

  final String paperId;
  final String overallState;
  final ProcessingStage stage;
  final PaperCapabilities capabilities;
  final bool retryable;
  final DateTime updatedAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;

  bool get stopsPolling =>
      stage == ProcessingStage.ready ||
      stage == ProcessingStage.failedRetryable ||
      stage == ProcessingStage.failedTerminal ||
      capabilities.allReady;

  factory PaperProcessingState.fromJson(Map<String, dynamic> json) {
    final capabilityJson = json['capabilities'];
    final nestedError = json['last_error'];
    final error = nestedError is Map
        ? Map<String, dynamic>.from(nestedError)
        : const <String, dynamic>{};
    return PaperProcessingState(
      paperId: (json['paper_id'] ?? '').toString(),
      overallState:
          (json['overall_state'] ?? json['state'] ?? 'processing').toString(),
      stage: ProcessingStage.fromWire(json['stage']),
      capabilities: PaperCapabilities.fromJson(
        capabilityJson is Map
            ? Map<String, dynamic>.from(capabilityJson)
            : const {},
      ),
      retryable: json['retryable'] as bool? ?? false,
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastErrorCode:
          (json['last_error_code'] ?? json['error_code'] ?? error['code'])
              ?.toString(),
      lastErrorMessage: (json['last_error_message'] ??
              json['error_message'] ??
              error['message'])
          ?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'paper_id': paperId,
        'overall_state': overallState,
        'stage': stage.wireValue,
        'capabilities': capabilities.toJson(),
        'retryable': retryable,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        if (lastErrorCode != null) 'last_error_code': lastErrorCode,
        if (lastErrorMessage != null) 'last_error_message': lastErrorMessage,
      };
}

String processingStageMessage(ProcessingStage stage, {String? errorMessage}) {
  switch (stage) {
    case ProcessingStage.notRequested:
      return 'Open Introduction to prepare this paper.';
    case ProcessingStage.queued:
    case ProcessingStage.fetchingLicense:
    case ProcessingStage.fetchingPdf:
      return 'Preparing the paper…';
    case ProcessingStage.parsingPdf:
      return 'Reading the PDF structure…';
    case ProcessingStage.introductionReady:
    case ProcessingStage.indexingChat:
      return 'Introduction ready. Indexing later sections for chat…';
    case ProcessingStage.resolvingReferences:
      return 'Introduction and chat ready. Resolving references…';
    case ProcessingStage.ready:
      return 'Introduction, chat, and connections are ready.';
    case ProcessingStage.failedRetryable:
      return errorMessage?.trim().isNotEmpty == true
          ? errorMessage!
          : 'Preparation paused after a temporary problem.';
    case ProcessingStage.failedTerminal:
      return errorMessage?.trim().isNotEmpty == true
          ? errorMessage!
          : 'We could not reliably prepare this paper.';
  }
}
