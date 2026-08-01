import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cache/local_store.dart';
import '../core/providers.dart';
import '../core/settings/appearance.dart';

final initialAppearanceProvider = Provider<AppAppearance>(
  (ref) => AppAppearance.system,
);

final appearanceControllerProvider =
    StateNotifierProvider<AppearanceController, AppAppearance>((ref) {
      return AppearanceController(
        store: ref.watch(localStoreProvider),
        initial: ref.watch(initialAppearanceProvider),
      );
    });

final class AppearanceController extends StateNotifier<AppAppearance> {
  AppearanceController({
    required LocalStore store,
    required AppAppearance initial,
  }) : _store = store,
       super(initial);

  final LocalStore _store;

  Future<void> setAppearance(AppAppearance value) async {
    if (value == state) return;
    final previous = state;
    state = value;
    try {
      await _store.saveAppearance(value);
    } on Object {
      if (mounted && state == value) state = previous;
      rethrow;
    }
  }

  Future<void> resetAfterLocalDataClear() async {
    state = AppAppearance.system;
    await _store.saveAppearance(AppAppearance.system);
  }
}

extension AppAppearanceThemeMode on AppAppearance {
  ThemeMode get themeMode => switch (this) {
    AppAppearance.system => ThemeMode.system,
    AppAppearance.light => ThemeMode.light,
    AppAppearance.dark => ThemeMode.dark,
  };

  String get label => switch (this) {
    AppAppearance.system => 'Use device setting',
    AppAppearance.light => 'Light',
    AppAppearance.dark => 'Dark',
  };
}
