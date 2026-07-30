import 'package:flutter/material.dart';

abstract final class PakPerkColors {
  static const ink = Color(0xFF17211B);
  static const paper = Color(0xFFF7F4EC);
  static const paperRaised = Color(0xFFFFFCF5);
  static const moss = Color(0xFF315C47);
  static const mossSoft = Color(0xFFDCE9DF);
  static const ochre = Color(0xFF9B6427);
  static const outline = Color(0xFFD4CEC0);
  static const error = Color(0xFF9B2C2C);
}

ThemeData buildPakPerkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: PakPerkColors.moss,
    brightness: Brightness.light,
    surface: PakPerkColors.paper,
    error: PakPerkColors.error,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: PakPerkColors.paper,
    canvasColor: PakPerkColors.paper,
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        color: PakPerkColors.ink,
        fontSize: 24,
        height: 1.18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      ),
      titleMedium: TextStyle(
        color: PakPerkColors.ink,
        fontSize: 17,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(
        color: PakPerkColors.ink,
        fontSize: 17,
        height: 1.52,
      ),
      bodyMedium: TextStyle(
        color: PakPerkColors.ink,
        fontSize: 14,
        height: 1.4,
      ),
      labelSmall: TextStyle(
        color: PakPerkColors.moss,
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    ),
    cardTheme: const CardThemeData(
      color: PakPerkColors.paperRaised,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: PakPerkColors.outline),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: PakPerkColors.paperRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: PakPerkColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: PakPerkColors.outline),
      ),
    ),
    dividerColor: PakPerkColors.outline,
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: PakPerkColors.moss,
    ),
  );
}
