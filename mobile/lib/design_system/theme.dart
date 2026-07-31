import 'package:flutter/material.dart';

import 'colors.dart';
import 'elevation.dart';
import 'radii.dart';
import 'sizes.dart';
import 'skeleton.dart';
import 'typography.dart';

abstract final class PakPerkTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    scheme: const ColorScheme(
      brightness: Brightness.light,
      primary: PakPerkColors.moss,
      onPrimary: Colors.white,
      primaryContainer: PakPerkColors.mossSoft,
      onPrimaryContainer: PakPerkColors.ink,
      secondary: PakPerkColors.ochre,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFF2E1CA),
      onSecondaryContainer: Color(0xFF36220D),
      error: PakPerkColors.error,
      onError: Colors.white,
      errorContainer: Color(0xFFF9DAD6),
      onErrorContainer: Color(0xFF410006),
      surface: PakPerkColors.paper,
      onSurface: PakPerkColors.ink,
      surfaceContainerHighest: Color(0xFFEDE8DD),
      onSurfaceVariant: Color(0xFF465049),
      outline: PakPerkColors.outline,
      outlineVariant: Color(0xFFE5DFD3),
      shadow: Color(0x3317211B),
      scrim: Color(0x9917211B),
      inverseSurface: PakPerkColors.ink,
      onInverseSurface: PakPerkColors.paper,
      inversePrimary: Color(0xFFA8D5B7),
    ),
    semantic: PakPerkSemanticColors.light,
    skeleton: PakPerkSkeletonTheme.light,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    scheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: PakPerkColors.darkMoss,
      onPrimary: Color(0xFF103823),
      primaryContainer: PakPerkColors.darkMossSoft,
      onPrimaryContainer: Color(0xFFC3F1D0),
      secondary: PakPerkColors.darkOchre,
      onSecondary: Color(0xFF432B0E),
      secondaryContainer: Color(0xFF503A22),
      onSecondaryContainer: Color(0xFFFFDDB6),
      error: PakPerkColors.darkError,
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: Color(0xFFFFDAD6),
      surface: PakPerkColors.darkPaper,
      onSurface: PakPerkColors.darkInk,
      surfaceContainerHighest: Color(0xFF344139),
      onSurfaceVariant: PakPerkColors.darkInkMuted,
      outline: PakPerkColors.darkOutline,
      outlineVariant: Color(0xFF354139),
      shadow: Colors.black,
      scrim: Color(0xCC000000),
      inverseSurface: PakPerkColors.darkInk,
      onInverseSurface: PakPerkColors.ink,
      inversePrimary: PakPerkColors.moss,
    ),
    semantic: PakPerkSemanticColors.dark,
    skeleton: PakPerkSkeletonTheme.dark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
    required PakPerkSemanticColors semantic,
    required PakPerkSkeletonTheme skeleton,
  }) {
    final textTheme = PakPerkTypography.textTheme(scheme);
    final inputBorder = OutlineInputBorder(
      borderRadius: PakPerkRadii.input,
      borderSide: BorderSide(color: scheme.outline),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: semantic.paper,
      canvasColor: semantic.paper,
      textTheme: textTheme,
      extensions: [semantic, skeleton],
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      cardTheme: CardThemeData(
        color: semantic.raisedPaper,
        elevation: PakPerkElevation.flat,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: PakPerkRadii.card,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: semantic.raisedPaper,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      dividerColor: scheme.outlineVariant,
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(
            PakPerkSizes.minimumInteractive,
            PakPerkSizes.minimumInteractive,
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(
            Size.square(PakPerkSizes.minimumInteractive),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: PakPerkSizes.navigationBarHeight,
        elevation: PakPerkElevation.navigation,
        backgroundColor: semantic.raisedPaper,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: semantic.raisedPaper,
        modalBackgroundColor: semantic.raisedPaper,
        elevation: PakPerkElevation.modal,
        modalElevation: PakPerkElevation.modal,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.sheet),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceContainerHighest.withValues(alpha: .5),
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: semantic.raisedPaper,
        elevation: PakPerkElevation.modal,
        shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.card),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
    );
  }
}
