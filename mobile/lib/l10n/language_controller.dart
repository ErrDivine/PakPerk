import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final languageControllerProvider =
    StateNotifierProvider<LanguageController, Locale>(
      (ref) => LanguageController(),
    );

class LanguageController extends StateNotifier<Locale> {
  LanguageController() : super(const Locale('en')) {
    _load();
  }
  bool _selected = false;
  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (mounted && !_selected) {
        state = Locale(
          preferences.getString('pakperk.language.v1') == 'zh' ? 'zh' : 'en',
        );
      }
    } catch (_) {
      // An unavailable preference store must not prevent public reading.
    }
  }

  void resetAfterLocalDataClear() {
    _selected = true;
    state = const Locale('en');
  }

  Future<void> select(String code) async {
    _selected = true;
    final previous = state;
    state = Locale(code);
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setString('pakperk.language.v1', code)) {
        throw StateError('Language preference was not saved');
      }
    } catch (_) {
      if (mounted) state = previous;
      rethrow;
    }
  }
}
