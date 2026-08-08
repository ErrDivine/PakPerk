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
  final Set<Object> _fatalReplacements = LinkedHashSet<Object>.identity();

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
      if (_fatalReplacements.remove(error)) {
        // The prior handler already declined the original occurrence. This is
        // the content-free replacement's engine pass; returning false here is
        // what preserves the fatal fallback without invoking that handler a
        // second time or exposing the original callback arguments.
        return false;
      }
      final safeError = _validatedCategory(error);
      final isAlreadySanitized =
          identical(error, safeError) && stack.toString().isEmpty;

      if (!isAlreadySanitized) {
        record(error, stack, source: GlobalErrorSource.platformDispatcher);
      }
      final previous = _previousPlatformHandler;
      if (isAlreadySanitized) {
        if (previous == null) return false;
        try {
          return previous(safeError, StackTrace.empty);
        } on Object {
          // A failing diagnostic callback must not replace the content-free
          // fatal signal with its own potentially sensitive exception.
          return false;
        }
      }

      if (previous != null) {
        try {
          if (previous(safeError, StackTrace.empty)) return true;
        } on Object {
          // Continue into the sanitized fatal path below.
        }
      }

      // Returning false for the original error would let the engine fallback
      // print its raw message and stack. Mark that occurrence handled, then
      // raise the bounded category on the same error zone. The zone guard
      // forwards it as an actually unhandled error; the second dispatcher
      // pass returns false only for that content-free object and empty stack.
      // This preserves honest fatal/crash semantics without leaking content.
      _remember(safeError);
      _rememberFatalReplacement(safeError);
      scheduleMicrotask(() {
        Error.throwWithStackTrace(safeError, StackTrace.empty);
      });
      return true;
    };
    FlutterError.onError = _installedFlutterHandler;
    _dispatcher.onError = _installedPlatformHandler;
  }

  void recordZoneError(Object error, StackTrace stack) {
    record(error, stack, source: GlobalErrorSource.zone);
  }

  /// Records one redacted category and then preserves the parent zone/OS fatal
  /// path using only the same bounded category and an empty stack.
  Never recordZoneErrorAndRethrow(Object error, StackTrace stack) {
    recordZoneError(error, stack);
    final safeError = _validatedCategory(error);
    Error.throwWithStackTrace(safeError, StackTrace.empty);
  }

  void record(
    Object error,
    StackTrace stack, {
    required GlobalErrorSource source,
  }) {
    // One uncaught object can traverse the framework, zone, and engine with
    // distinct StackTrace wrappers. Identity-based error deduplication avoids
    // double telemetry without merging separate exception instances.
    if (!_remember(error)) return;
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

  bool _remember(Object error) {
    if (!_recentErrors.add(error)) return false;
    if (_recentErrors.length > 32) _recentErrors.remove(_recentErrors.first);
    Timer(const Duration(seconds: 1), () {
      _recentErrors.remove(error);
    });
    return true;
  }

  void _rememberFatalReplacement(Object error) {
    _fatalReplacements.add(error);
    if (_fatalReplacements.length > 32) {
      _fatalReplacements.remove(_fatalReplacements.first);
    }
    Timer(const Duration(seconds: 1), () {
      _fatalReplacements.remove(error);
    });
  }

  TelemetryErrorCategory _validatedCategory(Object error) {
    final classified = RedactingTelemetrySink.classifyError(error);
    if (error case TelemetryErrorCategory(
      :final category,
    ) when category == classified.category) {
      return error;
    }
    return classified;
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
    _fatalReplacements.clear();
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
