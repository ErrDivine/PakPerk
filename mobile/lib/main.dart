import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show appFlavor;

import 'app/application_bootstrap.dart';
import 'app/account_providers.dart';
import 'app/feature_flags.dart';
import 'app/library_providers.dart';
import 'app/comments_providers.dart';
import 'app/startup_controller.dart';
import 'core/content_policy.dart';
import 'core/providers.dart';
import 'core/telemetry/global_error_capture.dart';
import 'core/telemetry/telemetry.dart';

void main() {
  GlobalErrorCapture? errors;
  runZonedGuarded(
    () {
      final binding = WidgetsFlutterBinding.ensureInitialized();
      FlutterNativeSplashHandoff.preserve(binding);
      final buildConfig = AppBuildConfig.fromCompileTime();
      buildConfig.requireMatchingNativeFlavor(appFlavor);
      final exporter = createTelemetryExporter(buildConfig);
      final telemetry = RedactingTelemetrySink(exporter);
      errors = GlobalErrorCapture(telemetry: telemetry)..install();
      final bootstrapper = ApplicationStartupBootstrapper(
        fulltextPolicy: ClientFulltextPolicy.fromWire(
          buildConfig.fulltextPolicy,
        ),
      );
      final launchMode = startupLaunchModeForInitialRoute(
        binding.platformDispatcher.defaultRouteName,
      );

      runApp(
        ProviderScope(
          overrides: [
            appBuildConfigProvider.overrideWithValue(buildConfig),
            telemetryExporterProvider.overrideWithValue(exporter),
            startupLaunchModeProvider.overrideWithValue(launchMode),
            ...applicationStartupDataOverrides(bootstrapper),
            ...accountApplicationOverrides(bootstrapper),
            ...libraryApplicationOverrides(),
            ...commentsApplicationOverrides(),
          ],
          child: PakPerkBootstrapApp(bootstrapper: bootstrapper),
        ),
      );
    },
    (error, stack) {
      final capture = errors;
      if (capture != null) {
        capture.recordZoneErrorAndRethrow(error, stack);
      }
      // Bootstrap failed before the redacting capture could be installed.
      // Preserve the parent zone/OS fatal path instead of presenting/logging a
      // potentially sensitive raw exception and then swallowing it.
      Error.throwWithStackTrace(error, stack);
    },
  );
}
