import 'dart:math' as math;

import '../api/api_exception.dart';

typedef RetryJitterSource = double Function();

final class OutboxRetryPolicy {
  OutboxRetryPolicy({
    this.baseDelay = const Duration(seconds: 4),
    this.maximumDelay = const Duration(hours: 1),
    this.jitterFraction = 0.25,
    RetryJitterSource? jitter,
  }) : _jitter = jitter ?? math.Random.secure().nextDouble {
    if (baseDelay <= Duration.zero ||
        maximumDelay < baseDelay ||
        jitterFraction < 0 ||
        jitterFraction > 1) {
      throw ArgumentError('Invalid outbox retry policy.');
    }
  }

  final Duration baseDelay;
  final Duration maximumDelay;
  final double jitterFraction;
  final RetryJitterSource _jitter;

  bool shouldRetry(ApiException error) =>
      error.retryable ||
      error.isOffline ||
      error.statusCode == 429 ||
      (error.statusCode != null && error.statusCode! >= 500);

  Duration delayFor({required int completedAttempts, Duration? retryAfter}) {
    if (completedAttempts < 0) {
      throw ArgumentError.value(
        completedAttempts,
        'completedAttempts',
        'Must not be negative.',
      );
    }
    final exponent = math.min(completedAttempts, 20);
    final scaled = baseDelay.inMicroseconds * (1 << exponent);
    final minimumJitterMicros = jitterFraction == 0
        ? 0
        : const Duration(seconds: 1).inMicroseconds;
    final capBase = jitterFraction == 0
        ? maximumDelay.inMicroseconds
        : ((maximumDelay.inMicroseconds - minimumJitterMicros) /
                  (1 + jitterFraction))
              .floor();
    final boundedBase = math.min(scaled, capBase);
    final sample = _jitter().clamp(0.0, 1.0);
    final sampledJitter = (boundedBase * jitterFraction * sample).round();
    final jitterRoom = maximumDelay.inMicroseconds - boundedBase;
    final positiveJitter = jitterFraction > 0 && jitterRoom > 0
        ? math.min(jitterRoom, minimumJitterMicros + sampledJitter)
        : 0;
    final localDelay = Duration(
      microseconds: math.min(
        boundedBase + positiveJitter,
        maximumDelay.inMicroseconds,
      ),
    );
    final retryAfterMicros = retryAfter?.inMicroseconds;
    if (retryAfterMicros != null && retryAfterMicros > 0) {
      return retryAfter! > localDelay ? retryAfter : localDelay;
    }
    return localDelay;
  }
}
