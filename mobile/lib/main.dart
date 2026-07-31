import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/feature_flags.dart';
import 'core/cache/local_store.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final buildConfig = AppBuildConfig.fromCompileTime();
  final store = await SharedPreferencesLocalStore.create();
  final sessionId = await store.getOrCreateSessionId();
  final restoration = await store.loadRestoration();

  runApp(
    ProviderScope(
      overrides: [
        appBuildConfigProvider.overrideWithValue(buildConfig),
        localStoreProvider.overrideWithValue(store),
        initialAnonymousSessionIdProvider.overrideWithValue(sessionId),
        initialRestorationProvider.overrideWithValue(restoration),
      ],
      child: const PakPerkApp(),
    ),
  );
}
