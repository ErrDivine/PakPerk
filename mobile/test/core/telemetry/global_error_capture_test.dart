import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/telemetry/global_error_capture.dart';
import 'package:pakperk/core/telemetry/otlp_http_telemetry_sink.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('global surfaces emit redacted sentinels once', () async {
    final dispatcher = PlatformDispatcher.instance;
    final originalFlutterHandler = FlutterError.onError;
    final originalPlatformHandler = dispatcher.onError;
    FlutterError.onError = (_) {};
    dispatcher.onError = (_, _) => true;

    final transport = _Transport();
    final sink = RedactingTelemetrySink(
      OtlpHttpTelemetrySink(
        endpoint: Uri.parse('https://telemetry.pakperk.app/v1/logs'),
        environment: 'production',
        transport: transport,
      ),
    );
    final capture = GlobalErrorCapture(
      telemetry: sink,
      preserveDebugPresentation: false,
    )..install();
    try {
      const sentinel = 'Bearer raw-token reader@example.test private-body';
      final error = StateError(sentinel);
      final stack = StackTrace.fromString('private/stack/$sentinel');

      FlutterError.onError!(
        FlutterErrorDetails(exception: error, stack: stack),
      );
      capture.recordZoneError(
        error,
        StackTrace.fromString('different wrapper for the same error'),
      );
      dispatcher.onError!(
        FormatException('second $sentinel'),
        StackTrace.fromString('second stack $sentinel'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transport.bodies, hasLength(2));
      expect(transport.bodies.join(), isNot(contains(sentinel)));
      expect(transport.bodies.join(), isNot(contains('private/stack')));
      expect(transport.bodies.first, contains('flutter_framework'));
      expect(transport.bodies.last, contains('platform_dispatcher'));
      expect(transport.bodies.first, contains('state'));
      expect(transport.bodies.last, contains('format'));
    } finally {
      capture.dispose();
      FlutterError.onError = originalFlutterHandler;
      dispatcher.onError = originalPlatformHandler;
    }
  });

  test(
    'Flutter handler delegates only redacted presentation details',
    () async {
      final dispatcher = PlatformDispatcher.instance;
      final originalFlutterHandler = FlutterError.onError;
      final originalPlatformHandler = dispatcher.onError;
      FlutterErrorDetails? delegated;
      FlutterError.onError = (details) => delegated = details;

      final telemetry = _RecordingTelemetry();
      final capture = GlobalErrorCapture(
        telemetry: RedactingTelemetrySink(telemetry),
      )..install();
      try {
        const sentinel = 'token=user-secret@example.test';
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: StateError(sentinel),
            stack: StackTrace.fromString('/private/$sentinel'),
            informationCollector: () sync* {
              yield ErrorDescription(sentinel);
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(delegated, isNotNull);
        expect(delegated!.exception, isA<TelemetryErrorCategory>());
        expect(delegated!.exception.toString(), contains('state'));
        expect(delegated!.exception.toString(), isNot(contains(sentinel)));
        expect(delegated!.stack.toString(), isEmpty);
        expect(delegated!.informationCollector, isNull);
        expect(telemetry.errors, hasLength(1));
      } finally {
        capture.dispose();
        FlutterError.onError = originalFlutterHandler;
        dispatcher.onError = originalPlatformHandler;
      }
    },
  );

  for (final previousResult in const <bool>[false, true]) {
    test(
      'platform handler preserves safe prior handling $previousResult',
      () async {
        final dispatcher = PlatformDispatcher.instance;
        final originalFlutterHandler = FlutterError.onError;
        final originalPlatformHandler = dispatcher.onError;
        Object? delegatedError;
        StackTrace? delegatedStack;
        var delegatedCalls = 0;
        dispatcher.onError = (error, stack) {
          delegatedCalls += 1;
          delegatedError = error;
          delegatedStack = stack;
          return previousResult;
        };

        final telemetry = _RecordingTelemetry();
        final capture = GlobalErrorCapture(
          telemetry: RedactingTelemetrySink(telemetry),
          preserveDebugPresentation: false,
        )..install();
        try {
          const sentinel = 'Bearer platform-secret';
          Object? forwardedFatal;
          StackTrace? forwardedStack;
          late bool handled;
          runZonedGuarded(
            () {
              handled = dispatcher.onError!(
                FormatException(sentinel),
                StackTrace.fromString('/private/$sentinel'),
              );
            },
            (error, stack) {
              forwardedFatal = error;
              forwardedStack = stack;
            },
          );
          await Future<void>.delayed(Duration.zero);

          // A false result cannot be returned for the original error because
          // Flutter would print its raw callback arguments. It is converted
          // into a separate, content-free uncaught failure instead.
          expect(handled, isTrue);
          expect(delegatedError, isA<TelemetryErrorCategory>());
          expect(delegatedError.toString(), contains('format'));
          expect(delegatedError.toString(), isNot(contains(sentinel)));
          expect(delegatedStack.toString(), isEmpty);
          if (previousResult) {
            expect(forwardedFatal, isNull);
          } else {
            expect(forwardedFatal, isA<TelemetryErrorCategory>());
            expect(forwardedFatal.toString(), isNot(contains(sentinel)));
            expect(forwardedStack.toString(), isEmpty);
            expect(
              dispatcher.onError!(forwardedFatal!, forwardedStack!),
              isFalse,
            );
          }
          expect(delegatedCalls, 1);
          expect(telemetry.errors, hasLength(1));
        } finally {
          capture.dispose();
          FlutterError.onError = originalFlutterHandler;
          dispatcher.onError = originalPlatformHandler;
        }
      },
    );
  }

  test(
    'platform handler replaces a raw unhandled error with a safe fatal error',
    () async {
      final dispatcher = PlatformDispatcher.instance;
      final originalFlutterHandler = FlutterError.onError;
      final originalPlatformHandler = dispatcher.onError;
      dispatcher.onError = null;

      final telemetry = _RecordingTelemetry();
      final capture = GlobalErrorCapture(
        telemetry: RedactingTelemetrySink(telemetry),
        preserveDebugPresentation: false,
      )..install();
      try {
        const sentinel = 'token=private-platform-value';
        Object? forwardedFatal;
        StackTrace? forwardedStack;
        late bool handled;
        runZonedGuarded(
          () {
            handled = dispatcher.onError!(
              ArgumentError(sentinel),
              StackTrace.fromString('/private/$sentinel'),
            );
          },
          (error, stack) {
            forwardedFatal = error;
            forwardedStack = stack;
          },
        );
        await Future<void>.delayed(Duration.zero);

        expect(handled, isTrue);
        expect(forwardedFatal, isA<TelemetryErrorCategory>());
        expect(forwardedFatal.toString(), contains('argument'));
        expect(forwardedFatal.toString(), isNot(contains(sentinel)));
        expect(forwardedStack.toString(), isEmpty);
        expect(dispatcher.onError!(forwardedFatal!, forwardedStack!), isFalse);
        expect(telemetry.errors, hasLength(1));
      } finally {
        capture.dispose();
        FlutterError.onError = originalFlutterHandler;
        dispatcher.onError = originalPlatformHandler;
      }
    },
  );

  test(
    'a failing prior platform handler cannot replace the safe fatal',
    () async {
      final dispatcher = PlatformDispatcher.instance;
      final originalFlutterHandler = FlutterError.onError;
      final originalPlatformHandler = dispatcher.onError;
      const sentinel = 'prior-handler-secret@example.test';
      dispatcher.onError = (_, _) => throw StateError(sentinel);

      final telemetry = _RecordingTelemetry();
      final capture = GlobalErrorCapture(
        telemetry: RedactingTelemetrySink(telemetry),
        preserveDebugPresentation: false,
      )..install();
      try {
        Object? forwardedFatal;
        StackTrace? forwardedStack;
        late bool handled;
        runZonedGuarded(
          () {
            handled = dispatcher.onError!(
              StateError('raw-platform-secret'),
              StackTrace.fromString('/private/raw-platform-secret'),
            );
          },
          (error, stack) {
            forwardedFatal = error;
            forwardedStack = stack;
          },
        );
        await Future<void>.delayed(Duration.zero);

        expect(handled, isTrue);
        expect(forwardedFatal, isA<TelemetryErrorCategory>());
        expect(forwardedFatal.toString(), isNot(contains(sentinel)));
        expect(forwardedStack.toString(), isEmpty);
        expect(dispatcher.onError!(forwardedFatal!, forwardedStack!), isFalse);
        expect(telemetry.errors, hasLength(1));
      } finally {
        capture.dispose();
        FlutterError.onError = originalFlutterHandler;
        dispatcher.onError = originalPlatformHandler;
      }
    },
  );

  test('invalid nominal category cannot reach the platform fallback', () async {
    final dispatcher = PlatformDispatcher.instance;
    final originalFlutterHandler = FlutterError.onError;
    final originalPlatformHandler = dispatcher.onError;
    dispatcher.onError = null;
    const sentinel = 'Bearer invalid-category-secret';
    final unsafeInput = TelemetryErrorCategory(sentinel);
    expect(unsafeInput.category, 'unexpected');

    final telemetry = _RecordingTelemetry();
    final capture = GlobalErrorCapture(
      telemetry: RedactingTelemetrySink(telemetry),
      preserveDebugPresentation: false,
    )..install();
    try {
      final handled = dispatcher.onError!(unsafeInput, StackTrace.empty);
      await Future<void>.delayed(Duration.zero);

      expect(handled, isFalse);
      expect(unsafeInput.toString(), isNot(contains(sentinel)));
      expect(telemetry.errors, isEmpty);
    } finally {
      capture.dispose();
      FlutterError.onError = originalFlutterHandler;
      dispatcher.onError = originalPlatformHandler;
    }
  });

  test('invalid nominal category cannot cross the zone boundary', () async {
    const sentinel = 'reader@example.test private-zone-category';
    final unsafeInput = TelemetryErrorCategory(sentinel);
    final telemetry = _RecordingTelemetry();
    final capture = GlobalErrorCapture(
      telemetry: RedactingTelemetrySink(telemetry),
    );
    Object? propagatedError;
    StackTrace? propagatedStack;

    runZonedGuarded(
      () => capture.recordZoneErrorAndRethrow(
        unsafeInput,
        StackTrace.fromString('/private/$sentinel'),
      ),
      (caught, caughtStack) {
        propagatedError = caught;
        propagatedStack = caughtStack;
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(propagatedError, isA<TelemetryErrorCategory>());
    expect((propagatedError! as TelemetryErrorCategory).category, 'unexpected');
    expect(propagatedError.toString(), isNot(contains(sentinel)));
    expect(propagatedStack.toString(), isEmpty);
    expect(telemetry.errors, hasLength(1));
  });

  test('zone capture records once and rethrows a safe fatal failure', () async {
    final telemetry = _RecordingTelemetry();
    final capture = GlobalErrorCapture(
      telemetry: RedactingTelemetrySink(telemetry),
    );
    final error = StateError('private-zone-message');
    final stack = StackTrace.fromString('/private/zone-stack');
    Object? propagatedError;
    StackTrace? propagatedStack;

    runZonedGuarded(() => capture.recordZoneErrorAndRethrow(error, stack), (
      caught,
      caughtStack,
    ) {
      propagatedError = caught;
      propagatedStack = caughtStack;
    });
    await Future<void>.delayed(Duration.zero);

    expect(propagatedError, isA<TelemetryErrorCategory>());
    expect(propagatedError.toString(), contains('state'));
    expect(propagatedError.toString(), isNot(contains('private-zone-message')));
    expect(propagatedStack.toString(), isEmpty);
    expect(telemetry.errors, hasLength(1));
    expect(telemetry.errors.single.error.toString(), contains('state'));
    expect(
      telemetry.errors.single.error.toString(),
      isNot(contains('private-zone-message')),
    );
  });
}

final class _Transport implements OtlpHttpTransport {
  final bodies = <String>[];

  @override
  Future<void> postJson(Uri endpoint, String body) async {
    bodies.add(body);
  }

  @override
  void close() {}
}

final class _RecordingTelemetry implements TelemetrySink {
  final errors = <_RecordedError>[];

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {
    errors.add(_RecordedError(error, stack, context));
  }

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {}
}

final class _RecordedError {
  const _RecordedError(this.error, this.stack, this.context);

  final Object error;
  final StackTrace stack;
  final Map<String, Object?> context;
}
