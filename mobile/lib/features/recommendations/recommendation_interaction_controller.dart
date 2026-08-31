import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/reading_feed/reading_feed_models.dart';
import '../../core/recommendations/recommendation_interaction_api.dart';
import '../../core/recommendations/recommendation_interaction_models.dart';

typedef RecommendationOperationIdFactory = String Function();

@immutable
final class RecommendationInteractionCapabilities {
  const RecommendationInteractionCapabilities({
    this.explanations = false,
    this.feedback = false,
  });

  const RecommendationInteractionCapabilities.disabled()
    : explanations = false,
      feedback = false;

  const RecommendationInteractionCapabilities.all()
    : explanations = true,
      feedback = true;

  final bool explanations;
  final bool feedback;

  bool get any => explanations || feedback;

  @override
  bool operator ==(Object other) =>
      other is RecommendationInteractionCapabilities &&
      other.explanations == explanations &&
      other.feedback == feedback;

  @override
  int get hashCode => Object.hash(explanations, feedback);
}

/// Immutable provenance for one server-created recommendation item.
///
/// Construction requires a reading-feed item already proven to be discovery
/// content with no queue payload. A To Read item therefore cannot acquire
/// explanation or feedback controls by passing only a paper identity.
@immutable
final class RecommendationItemContext {
  const RecommendationItemContext._({
    required this.batchId,
    required this.paperId,
    required this.authEpoch,
    required this.accountGeneration,
  });

  factory RecommendationItemContext.forRecommendation({
    required ReadingFeedItem item,
    required String batchId,
    required String paperId,
    required int authEpoch,
    required int accountGeneration,
  }) {
    final recommendation = item.recommendation;
    if (!item.source.isPersonalizedRecommendation ||
        item.queue != null ||
        recommendation == null ||
        recommendation.mode != item.source.recommendationMode ||
        item.paper.paperId != paperId ||
        !isRecommendationUuid(batchId) ||
        !isRecommendationUuid(paperId) ||
        authEpoch < 0 ||
        accountGeneration < 0) {
      throw ArgumentError.value(
        item,
        'item',
        'Recommendation controls require matching server batch provenance.',
      );
    }
    return RecommendationItemContext._(
      batchId: batchId,
      paperId: paperId,
      authEpoch: authEpoch,
      accountGeneration: accountGeneration,
    );
  }

  final String batchId;
  final String paperId;
  final int authEpoch;
  final int accountGeneration;

  @override
  bool operator ==(Object other) =>
      other is RecommendationItemContext &&
      other.batchId == batchId &&
      other.paperId == paperId &&
      other.authEpoch == authEpoch &&
      other.accountGeneration == accountGeneration;

  @override
  int get hashCode =>
      Object.hash(batchId, paperId, authEpoch, accountGeneration);

  @override
  String toString() =>
      'RecommendationItemContext(batchId: <redacted>, paperId: <redacted>, '
      'authEpoch: $authEpoch, accountGeneration: $accountGeneration)';
}

enum RecommendationExplanationPhase {
  unavailable,
  idle,
  loading,
  ready,
  failed,
}

enum RecommendationFeedbackPhase {
  unavailable,
  idle,
  sending,
  succeeded,
  failed,
}

@immutable
final class RecommendationInteractionFailure {
  const RecommendationInteractionFailure({
    required this.code,
    required this.title,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String title;
  final String message;
  final bool retryable;
}

@immutable
final class RecommendationInteractionState {
  const RecommendationInteractionState({
    required this.explanationPhase,
    required this.feedbackPhase,
    this.explanations = const [],
    this.explanationFailure,
    this.feedbackFailure,
    this.feedbackSelection,
    this.feedbackResult,
    this.feedbackOperationId,
  });

  final RecommendationExplanationPhase explanationPhase;
  final RecommendationFeedbackPhase feedbackPhase;
  final List<RecommendationExplanation> explanations;
  final RecommendationInteractionFailure? explanationFailure;
  final RecommendationInteractionFailure? feedbackFailure;
  final RecommendationFeedbackSelection? feedbackSelection;
  final RecommendationFeedbackResult? feedbackResult;
  final String? feedbackOperationId;

  RecommendationInteractionState copyWith({
    RecommendationExplanationPhase? explanationPhase,
    RecommendationFeedbackPhase? feedbackPhase,
    List<RecommendationExplanation>? explanations,
    RecommendationInteractionFailure? explanationFailure,
    bool clearExplanationFailure = false,
    RecommendationInteractionFailure? feedbackFailure,
    bool clearFeedbackFailure = false,
    RecommendationFeedbackSelection? feedbackSelection,
    bool clearFeedbackSelection = false,
    RecommendationFeedbackResult? feedbackResult,
    bool clearFeedbackResult = false,
    String? feedbackOperationId,
    bool clearFeedbackOperationId = false,
  }) => RecommendationInteractionState(
    explanationPhase: explanationPhase ?? this.explanationPhase,
    feedbackPhase: feedbackPhase ?? this.feedbackPhase,
    explanations: explanations ?? this.explanations,
    explanationFailure: clearExplanationFailure
        ? null
        : explanationFailure ?? this.explanationFailure,
    feedbackFailure: clearFeedbackFailure
        ? null
        : feedbackFailure ?? this.feedbackFailure,
    feedbackSelection: clearFeedbackSelection
        ? null
        : feedbackSelection ?? this.feedbackSelection,
    feedbackResult: clearFeedbackResult
        ? null
        : feedbackResult ?? this.feedbackResult,
    feedbackOperationId: clearFeedbackOperationId
        ? null
        : feedbackOperationId ?? this.feedbackOperationId,
  );

  @override
  String toString() =>
      'RecommendationInteractionState(explanationPhase: '
      '${explanationPhase.name}, explanations: ${explanations.length}, '
      'feedbackPhase: ${feedbackPhase.name}, feedbackOperationId: <redacted>)';
}

/// Owns only ephemeral explanation and explicit-feedback task state.
///
/// Explanations are private `no-store` responses and are discarded when the
/// item/account scope changes or this controller closes. Feedback retries keep
/// the same operation UUID until the server accepts or terminally rejects it.
final class RecommendationInteractionController extends ChangeNotifier {
  RecommendationInteractionController({
    required RecommendationInteractionRemoteDataSource remote,
    RecommendationItemContext? context,
    RecommendationInteractionCapabilities capabilities =
        const RecommendationInteractionCapabilities.disabled(),
    RecommendationOperationIdFactory? operationId,
  }) : _remote = remote,
       _context = context,
       _capabilities = capabilities,
       _operationId = operationId ?? const Uuid().v7,
       _state = _initialState(context, capabilities);

  final RecommendationInteractionRemoteDataSource _remote;
  final RecommendationOperationIdFactory _operationId;

  RecommendationItemContext? _context;
  RecommendationInteractionCapabilities _capabilities;
  RecommendationInteractionState _state;
  RequestCancellation? _explanationRequest;
  RequestCancellation? _feedbackRequest;
  _FeedbackAttempt? _feedbackAttempt;
  int _identityGeneration = 0;
  int _explanationGeneration = 0;
  int _feedbackGeneration = 0;
  bool _disposed = false;

  RecommendationItemContext? get context => _context;
  RecommendationInteractionCapabilities get capabilities => _capabilities;
  RecommendationInteractionState get state => _state;
  bool get controlsAvailable => _context != null && _capabilities.any;

  void updateContext(RecommendationItemContext? next) {
    if (_context == next) return;
    _context = next;
    _reset('The recommendation item scope changed.');
  }

  void updateCapabilities(RecommendationInteractionCapabilities next) {
    if (_capabilities == next) return;
    _capabilities = next;
    _reset('Recommendation interactions changed availability.');
  }

  Future<void> loadExplanation() async {
    final taskContext = _context;
    if (_disposed ||
        taskContext == null ||
        !_capabilities.explanations ||
        _state.explanationPhase == RecommendationExplanationPhase.loading) {
      return;
    }
    _explanationRequest?.cancel('A newer explanation request replaced it.');
    final cancellation = RequestCancellation();
    _explanationRequest = cancellation;
    final identityGeneration = _identityGeneration;
    final generation = ++_explanationGeneration;
    _publish(
      _state.copyWith(
        explanationPhase: RecommendationExplanationPhase.loading,
        explanations: const [],
        clearExplanationFailure: true,
      ),
    );
    try {
      final result = await _remote.explanation(
        batchId: taskContext.batchId,
        paperId: taskContext.paperId,
        expectedAuthEpoch: taskContext.authEpoch,
        cancellation: cancellation,
      );
      if (!_explanationIsCurrent(taskContext, identityGeneration, generation)) {
        return;
      }
      _publish(
        _state.copyWith(
          explanationPhase: RecommendationExplanationPhase.ready,
          explanations: result.explanations,
          clearExplanationFailure: true,
        ),
      );
    } on ApiException catch (error) {
      if (!_explanationIsCurrent(taskContext, identityGeneration, generation) ||
          error.cancelled) {
        return;
      }
      _publish(
        _state.copyWith(
          explanationPhase: RecommendationExplanationPhase.failed,
          explanationFailure: _failure(
            error,
            title: 'Couldn’t load this explanation',
          ),
        ),
      );
    } on Object {
      if (!_explanationIsCurrent(taskContext, identityGeneration, generation)) {
        return;
      }
      _publish(
        _state.copyWith(
          explanationPhase: RecommendationExplanationPhase.failed,
          explanationFailure: _unexpectedFailure(
            'Couldn’t load this explanation',
          ),
        ),
      );
    } finally {
      if (identical(_explanationRequest, cancellation)) {
        _explanationRequest = null;
      }
    }
  }

  Future<void> submitFeedback(RecommendationFeedbackSelection selection) async {
    final taskContext = _context;
    if (_disposed ||
        taskContext == null ||
        !_capabilities.feedback ||
        _state.feedbackPhase == RecommendationFeedbackPhase.sending) {
      return;
    }
    final operationId = _operationId().toLowerCase();
    if (!isRecommendationUuid(operationId)) {
      _feedbackAttempt = null;
      _publish(
        _state.copyWith(
          feedbackPhase: RecommendationFeedbackPhase.failed,
          feedbackSelection: selection,
          feedbackFailure: const RecommendationInteractionFailure(
            code: 'INVALID_OPERATION_ID',
            title: 'Couldn’t send feedback',
            message: 'Feedback could not be started safely.',
            retryable: false,
          ),
          clearFeedbackResult: true,
          clearFeedbackOperationId: true,
        ),
      );
      return;
    }
    final attempt = _FeedbackAttempt(
      context: taskContext,
      selection: selection,
      operationId: operationId,
    );
    _feedbackAttempt = attempt;
    await _sendFeedback(attempt);
  }

  Future<void> retryFeedback() async {
    final attempt = _feedbackAttempt;
    if (_disposed ||
        attempt == null ||
        !(_state.feedbackFailure?.retryable ?? false) ||
        _context != attempt.context ||
        !_capabilities.feedback) {
      return;
    }
    await _sendFeedback(attempt);
  }

  Future<void> _sendFeedback(_FeedbackAttempt attempt) async {
    _feedbackRequest?.cancel('A newer feedback request replaced it.');
    final cancellation = RequestCancellation();
    _feedbackRequest = cancellation;
    final identityGeneration = _identityGeneration;
    final generation = ++_feedbackGeneration;
    _publish(
      _state.copyWith(
        feedbackPhase: RecommendationFeedbackPhase.sending,
        feedbackSelection: attempt.selection,
        feedbackOperationId: attempt.operationId,
        clearFeedbackFailure: true,
        clearFeedbackResult: true,
      ),
    );
    try {
      final result = await _remote.submitFeedback(
        batchId: attempt.context.batchId,
        paperId: attempt.context.paperId,
        selection: attempt.selection,
        operationId: attempt.operationId,
        expectedAuthEpoch: attempt.context.authEpoch,
        cancellation: cancellation,
      );
      if (!_feedbackIsCurrent(attempt, identityGeneration, generation)) return;
      _feedbackAttempt = null;
      _publish(
        _state.copyWith(
          feedbackPhase: RecommendationFeedbackPhase.succeeded,
          feedbackResult: result,
          clearFeedbackFailure: true,
        ),
      );
    } on ApiException catch (error) {
      if (!_feedbackIsCurrent(attempt, identityGeneration, generation) ||
          error.cancelled) {
        return;
      }
      final failure = _failure(error, title: 'Couldn’t send feedback');
      if (!failure.retryable) _feedbackAttempt = null;
      _publish(
        _state.copyWith(
          feedbackPhase: RecommendationFeedbackPhase.failed,
          feedbackFailure: failure,
          clearFeedbackResult: true,
        ),
      );
    } on Object {
      if (!_feedbackIsCurrent(attempt, identityGeneration, generation)) return;
      _publish(
        _state.copyWith(
          feedbackPhase: RecommendationFeedbackPhase.failed,
          feedbackFailure: _unexpectedFailure('Couldn’t send feedback'),
          clearFeedbackResult: true,
        ),
      );
    } finally {
      if (identical(_feedbackRequest, cancellation)) {
        _feedbackRequest = null;
      }
    }
  }

  bool _explanationIsCurrent(
    RecommendationItemContext taskContext,
    int identityGeneration,
    int requestGeneration,
  ) =>
      !_disposed &&
      _context == taskContext &&
      _identityGeneration == identityGeneration &&
      _explanationGeneration == requestGeneration;

  bool _feedbackIsCurrent(
    _FeedbackAttempt attempt,
    int identityGeneration,
    int requestGeneration,
  ) =>
      !_disposed &&
      _context == attempt.context &&
      _identityGeneration == identityGeneration &&
      _feedbackGeneration == requestGeneration;

  void _reset(String reason) {
    _identityGeneration += 1;
    _explanationGeneration += 1;
    _feedbackGeneration += 1;
    _explanationRequest?.cancel(reason);
    _feedbackRequest?.cancel(reason);
    _explanationRequest = null;
    _feedbackRequest = null;
    _feedbackAttempt = null;
    _publish(_initialState(_context, _capabilities));
  }

  void _publish(RecommendationInteractionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _identityGeneration += 1;
    _explanationRequest?.cancel('The recommendation interaction closed.');
    _feedbackRequest?.cancel('The recommendation interaction closed.');
    _explanationRequest = null;
    _feedbackRequest = null;
    _feedbackAttempt = null;
    _state = _initialState(
      null,
      const RecommendationInteractionCapabilities.disabled(),
    );
    super.dispose();
  }
}

RecommendationInteractionState _initialState(
  RecommendationItemContext? context,
  RecommendationInteractionCapabilities capabilities,
) => RecommendationInteractionState(
  explanationPhase: context != null && capabilities.explanations
      ? RecommendationExplanationPhase.idle
      : RecommendationExplanationPhase.unavailable,
  feedbackPhase: context != null && capabilities.feedback
      ? RecommendationFeedbackPhase.idle
      : RecommendationFeedbackPhase.unavailable,
);

RecommendationInteractionFailure _failure(
  ApiException error, {
  required String title,
}) => RecommendationInteractionFailure(
  code: _safeCode(error.code),
  title: title,
  message: switch (error.code) {
    'RECOMMENDATION_ITEM_NOT_FOUND' =>
      'This recommendation is no longer available.',
    'FEATURE_DISABLED' => 'Recommendation interactions are not enabled.',
    'UNAUTHENTICATED' ||
    'TOKEN_EXPIRED' => 'Sign in again before using recommendation controls.',
    'IDEMPOTENCY_CONFLICT' =>
      'This feedback operation could not be replayed safely.',
    _ => 'Recommendation interactions are temporarily unavailable.',
  },
  retryable: error.retryable,
);

RecommendationInteractionFailure _unexpectedFailure(String title) =>
    RecommendationInteractionFailure(
      code: 'RECOMMENDATION_SERVICE_UNAVAILABLE',
      title: title,
      message: 'Recommendation interactions are temporarily unavailable.',
      retryable: true,
    );

String _safeCode(String value) =>
    RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value)
    ? value
    : 'RECOMMENDATION_SERVICE_UNAVAILABLE';

final class _FeedbackAttempt {
  const _FeedbackAttempt({
    required this.context,
    required this.selection,
    required this.operationId,
  });

  final RecommendationItemContext context;
  final RecommendationFeedbackSelection selection;
  final String operationId;
}
