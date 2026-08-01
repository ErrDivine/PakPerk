import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'telemetry.dart';

enum GlobalErrorSource {
  flutterFramework('flutter_framework'),
  platformDispatcher('platform_dispatcher'),
  zone('zone');

  const GlobalErrorSource(this.wireValue);

  final String wireValue;
}

/// Installs the three Flutter/Dart global failure surfaces onto one redacted
/// telemetry sink and deduplicates the same error crossing two surfaces.
final class GlobalErrorCapture {
  GlobalErrorCapture({
    required TelemetrySink telemetry,
    PlatformDispatcher? dispatcher,
    this.preserveDebugPresentation = true,
  }) : _telemetry = telemetry,
       _dispatcher = dispatcher ?? PlatformDispatcher.instance;

  final TelemetrySink _telemetry;
  final PlatformDispatcher _dispatcher;
  final bool preserveDebugPresentation;
  final Set<Object> _recentErrors = LinkedHashSet<Object>.identity();

  FlutterExceptionHandler? _previousFlutterHandler;
  ErrorCallback? _previousPlatformHandler;
  FlutterExceptionHandler? _installedFlutterHandler;
  ErrorCallback? _installedPlatformHandler;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutterHandler = FlutterError.onError;
    _previousPlatformHandler = _dispatcher.onError;

    _installedFlutterHandler = (details) {
      record(
        details.exception,
        details.stack ?? StackTrace.empty,
        source: GlobalErrorSource.flutterFramework,
      );
      // Preserve Flutter's existing presentation/reporting contract in
      // production, but never hand a raw exception, stack, or information
      // collector to a logging/crash handler. Fatal framework policy remains
      // owned by that previously installed handler.
      if (!kDebugMode || preserveDebugPresentation) {
        (_previousFlutterHandler ?? FlutterError.presentError)(
          _redactedFlutterDetails(details),
        );
      }
    };
    _installedPlatformHandler = (error, stack) {
      record(error, stack, source: GlobalErrorSource.platformDispatcher);
      final previous = _previousPlatformHandler;
      if (previous == null) {
        // False lets Flutter's engine/OS retain its normal uncaught-error and
        // crash semantics. The callback has already emitted one redacted
        // telemetry category; returning true here would silently swallow the
        // fatal error and make crash-free evidence dishonest.
        return false;
      }
      // A prior handler keeps ownership of handled/unhandled semantics, while
      // receiving only the same bounded category allowed into telemetry.
      return previous(
        RedactingTelemetrySink.classifyError(error),
        StackTrace.empty,
      );
    };
    FlutterError.onError = _installedFlutterHandler;
    _dispatcher.onError = _installedPlatformHandler;
  }

  void recordZoneError(Object error, StackTrace stack) {
    record(error, stack, source: GlobalErrorSource.zone);
  }

  /// Records one redacted category and then preserves the parent zone/OS fatal
  /// path. The original error never enters Pakperk telemetry, but rethrowing it
  /// is necessary for platform crash diagnostics and process integrity.
  Never recordZoneErrorAndRethrow(Object error, StackTrace stack) {
    recordZoneError(error, stack);
    Error.throwWithStackTrace(error, stack);
  }

  void record(
    Object error,
    StackTrace stack, {
    required GlobalErrorSource source,
  }) {
    // One uncaught object can traverse the framework, zone, and engine with
    // distinct StackTrace wrappers. Identity-based error deduplication avoids
    // double telemetry without merging separate exception instances.
    if (!_recentErrors.add(error)) return;
    if (_recentErrors.length > 32) _recentErrors.remove(_recentErrors.first);
    Timer(const Duration(seconds: 1), () {
      _recentErrors.remove(error);
    });
    unawaited(
      _telemetry
          .error(
            error,
            stack,
            context: {
              'component': 'application',
              'operation': source.wireValue,
            },
          )
          .catchError((Object _) {}),
    );
  }

  void dispose() {
    if (!_installed) return;
    if (identical(FlutterError.onError, _installedFlutterHandler)) {
      FlutterError.onError = _previousFlutterHandler;
    }
    if (identical(_dispatcher.onError, _installedPlatformHandler)) {
      _dispatcher.onError = _previousPlatformHandler;
    }
    _recentErrors.clear();
    _installed = false;
  }

  FlutterErrorDetails _redactedFlutterDetails(FlutterErrorDetails details) =>
      FlutterErrorDetails(
        exception: RedactingTelemetrySink.classifyError(details.exception),
        stack: StackTrace.empty,
        library: 'Pakperk',
        context: ErrorDescription('while handling an application failure'),
        silent: details.silent,
      );
}
