import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/application_bootstrap.dart';
import 'app/account_providers.dart';
import 'app/feature_flags.dart';
import 'app/startup_controller.dart';
import 'core/content_policy.dart';
import 'core/providers.dart';

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplashHandoff.preserve(binding);
  final buildConfig = AppBuildConfig.fromCompileTime();
  final bootstrapper = ApplicationStartupBootstrapper(
    fulltextPolicy: ClientFulltextPolicy.fromWire(buildConfig.fulltextPolicy),
  );
  final launchMode = startupLaunchModeForInitialRoute(
    binding.platformDispatcher.defaultRouteName,
  );

  runApp(
    ProviderScope(
      overrides: [
        appBuildConfigProvider.overrideWithValue(buildConfig),
        startupLaunchModeProvider.overrideWithValue(launchMode),
        ...applicationStartupDataOverrides(bootstrapper),
        ...accountApplicationOverrides(bootstrapper),
      ],
      child: PakPerkBootstrapApp(bootstrapper: bootstrapper),
    ),
  );
}
