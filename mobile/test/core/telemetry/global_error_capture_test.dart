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
      'platform handler preserves previous result $previousResult',
      () async {
        final dispatcher = PlatformDispatcher.instance;
        final originalFlutterHandler = FlutterError.onError;
        final originalPlatformHandler = dispatcher.onError;
        Object? delegatedError;
        StackTrace? delegatedStack;
        dispatcher.onError = (error, stack) {
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
          final handled = dispatcher.onError!(
            FormatException(sentinel),
            StackTrace.fromString('/private/$sentinel'),
          );
          await Future<void>.delayed(Duration.zero);

          expect(handled, previousResult);
          expect(delegatedError, isA<TelemetryErrorCategory>());
          expect(delegatedError.toString(), contains('format'));
          expect(delegatedError.toString(), isNot(contains(sentinel)));
          expect(delegatedStack.toString(), isEmpty);
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
    'platform handler returns false when no previous handler exists',
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
        final handled = dispatcher.onError!(
          ArgumentError('private'),
          StackTrace.current,
        );
        await Future<void>.delayed(Duration.zero);

        expect(handled, isFalse);
        expect(telemetry.errors, hasLength(1));
      } finally {
        capture.dispose();
        FlutterError.onError = originalFlutterHandler;
        dispatcher.onError = originalPlatformHandler;
      }
    },
  );

  test('zone capture records once and rethrows the original failure', () async {
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

    expect(propagatedError, same(error));
    expect(propagatedStack.toString(), stack.toString());
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
