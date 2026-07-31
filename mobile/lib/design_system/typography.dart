import 'package:flutter/material.dart';

abstract final class PakPerkTypography {
  static TextTheme textTheme(ColorScheme colors) => TextTheme(
        displaySmall: TextStyle(
          color: colors.onSurface,
          fontSize: 36,
          height: 1.08,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.8,
        ),
        headlineSmall: TextStyle(
          color: colors.onSurface,
          fontSize: 24,
          height: 1.18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.25,
        ),
        titleLarge: TextStyle(
          color: colors.onSurface,
          fontSize: 20,
          height: 1.25,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: colors.onSurface,
          fontSize: 17,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: colors.onSurface,
          fontSize: 17,
          height: 1.52,
        ),
        bodyMedium: TextStyle(
          color: colors.onSurface,
          fontSize: 14,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          color: colors.onSurface,
          fontSize: 14,
          height: 1.25,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: TextStyle(
          color: colors.primary,
          fontSize: 12,
          height: 1.3,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      );
}
