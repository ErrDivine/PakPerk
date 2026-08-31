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
    final isDark = brightness == Brightness.dark;
    final quietHighlight = scheme.onSurface.withValues(
      alpha: isDark ? .12 : .07,
    );
    final quietFocus = scheme.primary.withValues(alpha: isDark ? .16 : .1);
    final quietHover = scheme.primary.withValues(alpha: isDark ? .09 : .05);
    final primaryOverlay = _quietOverlay(scheme.primary);
    final chromeColor = semantic.raisedPaper.withValues(
      alpha: isDark ? .96 : .94,
    );
    final subtleOutline = scheme.outlineVariant.withValues(
      alpha: isDark ? .82 : .72,
    );
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
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: quietHighlight,
      focusColor: quietFocus,
      hoverColor: quietHover,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: AppBarThemeData(
        backgroundColor: chromeColor,
        foregroundColor: scheme.onSurface,
        elevation: PakPerkElevation.flat,
        scrolledUnderElevation: PakPerkElevation.flat,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        toolbarHeight: 56,
        titleTextStyle: textTheme.titleMedium,
        toolbarTextStyle: textTheme.bodyMedium,
        iconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        actionsIconTheme: IconThemeData(color: scheme.onSurface, size: 22),
        actionsPadding: const EdgeInsetsDirectional.only(end: 4),
      ),
      cardTheme: CardThemeData(
        color: semantic.raisedPaper,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: PakPerkElevation.flat,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: PakPerkRadii.card,
          side: BorderSide(color: subtleOutline),
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
        style:
            ElevatedButton.styleFrom(
              minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
              textStyle: textTheme.labelLarge,
              shape: const RoundedRectangleBorder(
                borderRadius: PakPerkRadii.input,
              ),
            ).copyWith(
              elevation: const WidgetStatePropertyAll(PakPerkElevation.flat),
              overlayColor: primaryOverlay,
              splashFactory: NoSplash.splashFactory,
            ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        ).copyWith(splashFactory: NoSplash.splashFactory),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              minimumSize: const Size(0, PakPerkSizes.minimumInteractive),
              textStyle: textTheme.labelLarge,
              side: BorderSide(color: scheme.outline.withValues(alpha: .84)),
              shape: const RoundedRectangleBorder(
                borderRadius: PakPerkRadii.input,
              ),
            ).copyWith(
              overlayColor: primaryOverlay,
              splashFactory: NoSplash.splashFactory,
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style:
            TextButton.styleFrom(
              minimumSize: const Size(
                PakPerkSizes.minimumInteractive,
                PakPerkSizes.minimumInteractive,
              ),
              textStyle: textTheme.labelLarge,
              shape: const RoundedRectangleBorder(
                borderRadius: PakPerkRadii.input,
              ),
            ).copyWith(
              overlayColor: primaryOverlay,
              splashFactory: NoSplash.splashFactory,
            ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size.square(PakPerkSizes.minimumInteractive),
          ),
          shape: const WidgetStatePropertyAll(CircleBorder()),
          overlayColor: primaryOverlay,
          splashFactory: NoSplash.splashFactory,
        ),
      ),
      listTileTheme: ListTileThemeData(
        minTileHeight: PakPerkSizes.minimumInteractive,
        minVerticalPadding: 8,
        minLeadingWidth: 24,
        horizontalTitleGap: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: const RoundedRectangleBorder(borderRadius: PakPerkRadii.input),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: .52),
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        leadingAndTrailingTextStyle: textTheme.labelMedium,
        enableFeedback: true,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: PakPerkSizes.navigationBarHeight,
        elevation: PakPerkElevation.flat,
        backgroundColor: chromeColor,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer.withValues(alpha: .82),
        indicatorShape: const StadiumBorder(),
        overlayColor: primaryOverlay,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            size: 24,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: 12,
            letterSpacing: .1,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: chromeColor,
        elevation: PakPerkElevation.flat,
        useIndicator: true,
        indicatorColor: scheme.primaryContainer.withValues(alpha: .82),
        indicatorShape: const StadiumBorder(),
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 24),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurfaceVariant,
          size: 24,
        ),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: semantic.raisedPaper,
        modalBackgroundColor: semantic.raisedPaper,
        surfaceTintColor: Colors.transparent,
        elevation: PakPerkElevation.modal,
        modalElevation: PakPerkElevation.modal,
        shadowColor: scheme.shadow,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: .42),
        dragHandleSize: const Size(36, 5),
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

  static WidgetStateProperty<Color?> _quietOverlay(Color color) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return null;
      if (states.contains(WidgetState.pressed)) {
        return color.withValues(alpha: .08);
      }
      if (states.contains(WidgetState.focused)) {
        return color.withValues(alpha: .07);
      }
      if (states.contains(WidgetState.hovered)) {
        return color.withValues(alpha: .04);
      }
      return null;
    });
  }
}
