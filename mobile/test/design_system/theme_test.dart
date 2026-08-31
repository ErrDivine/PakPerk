import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/design_system/colors.dart';
import 'package:pakperk/design_system/elevation.dart';
import 'package:pakperk/design_system/radii.dart';
import 'package:pakperk/design_system/sizes.dart';
import 'package:pakperk/design_system/skeleton.dart';
import 'package:pakperk/design_system/theme.dart';

void main() {
  test('type scale defines every semantic role with optical spacing', () {
    final light = PakPerkTheme.light();
    final dark = PakPerkTheme.dark();
    final lightText = light.textTheme;
    final styles = <TextStyle?>[
      lightText.displayLarge,
      lightText.displayMedium,
      lightText.displaySmall,
      lightText.headlineLarge,
      lightText.headlineMedium,
      lightText.headlineSmall,
      lightText.titleLarge,
      lightText.titleMedium,
      lightText.titleSmall,
      lightText.bodyLarge,
      lightText.bodyMedium,
      lightText.bodySmall,
      lightText.labelLarge,
      lightText.labelMedium,
      lightText.labelSmall,
    ];

    expect(styles, everyElement(isNotNull));
    expect(lightText.displayLarge?.fontSize, 40);
    expect(lightText.headlineMedium?.fontSize, 26);
    expect(lightText.titleSmall?.fontSize, 15);
    expect(lightText.bodySmall?.fontSize, 13);
    expect(lightText.labelMedium?.fontSize, 13);

    expect(lightText.displayLarge?.letterSpacing, lessThan(0));
    expect(lightText.headlineMedium?.letterSpacing, lessThan(0));
    expect(lightText.bodyLarge?.letterSpacing, 0);
    expect(lightText.bodySmall?.letterSpacing, greaterThan(0));
    expect(lightText.labelSmall?.letterSpacing, greaterThan(0));
    expect(
      lightText.displayLarge?.height,
      lessThan(lightText.bodyLarge!.height!),
    );
    expect(lightText.bodyLarge?.height, greaterThan(1.4));
    expect(
      lightText.labelSmall?.letterSpacing,
      lessThan(1),
      reason: 'small uppercase labels should remain compact and readable',
    );

    expect(lightText.bodyLarge?.color, light.colorScheme.onSurface);
    expect(lightText.bodySmall?.color, light.colorScheme.onSurfaceVariant);
    expect(dark.textTheme.bodyLarge?.color, dark.colorScheme.onSurface);
    expect(dark.textTheme.bodySmall?.color, dark.colorScheme.onSurfaceVariant);
  });

  test('light and dark themes expose readable semantic surfaces', () {
    final light = PakPerkTheme.light();
    final dark = PakPerkTheme.dark();

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.colorScheme.surface, isNot(dark.colorScheme.surface));
    expect(
      light.extension<PakPerkSemanticColors>(),
      PakPerkSemanticColors.light,
    );
    expect(dark.extension<PakPerkSemanticColors>(), PakPerkSemanticColors.dark);
    expect(light.extension<PakPerkSkeletonTheme>(), PakPerkSkeletonTheme.light);
    expect(dark.extension<PakPerkSkeletonTheme>(), PakPerkSkeletonTheme.dark);

    for (final theme in [light, dark]) {
      final scheme = theme.colorScheme;
      final semantic = theme.extension<PakPerkSemanticColors>()!;
      final schemePairs = <({String name, Color foreground, Color background})>[
        (
          name: 'surface text',
          foreground: scheme.onSurface,
          background: scheme.surface,
        ),
        (
          name: 'variant text',
          foreground: scheme.onSurfaceVariant,
          background: scheme.surfaceContainerHighest,
        ),
        (
          name: 'primary action',
          foreground: scheme.onPrimary,
          background: scheme.primary,
        ),
        (
          name: 'primary container',
          foreground: scheme.onPrimaryContainer,
          background: scheme.primaryContainer,
        ),
        (
          name: 'secondary action',
          foreground: scheme.onSecondary,
          background: scheme.secondary,
        ),
        (
          name: 'secondary container',
          foreground: scheme.onSecondaryContainer,
          background: scheme.secondaryContainer,
        ),
        (
          name: 'error action',
          foreground: scheme.onError,
          background: scheme.error,
        ),
        (
          name: 'error container',
          foreground: scheme.onErrorContainer,
          background: scheme.errorContainer,
        ),
        (
          name: 'inverse surface',
          foreground: scheme.onInverseSurface,
          background: scheme.inverseSurface,
        ),
      ];
      for (final pair in schemePairs) {
        expect(
          _contrastRatio(pair.foreground, pair.background),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness.name} ${pair.name}',
        );
      }

      final semanticForegrounds = <String, Color>{
        'ink': semantic.ink,
        'muted ink': semantic.mutedInk,
        'accent': semantic.accent,
        'warning': semantic.warning,
        'success': semantic.success,
        'processing': semantic.processing,
        'offline': semantic.offline,
        'moderation': semantic.moderation,
        'destructive': semantic.destructive,
      };
      for (final entry in semanticForegrounds.entries) {
        for (final surface in <String, Color>{
          'paper': semantic.paper,
          'raised paper': semantic.raisedPaper,
        }.entries) {
          expect(
            _contrastRatio(entry.value, surface.value),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness.name} ${entry.key} on ${surface.key}',
          );
        }
      }
      expect(
        _contrastRatio(semantic.ink, semantic.accentContainer),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness.name} accent container text',
      );
    }
  });

  test('interactive component themes retain 48 point target sizes', () {
    final theme = PakPerkTheme.light();
    final states = <WidgetState>{};

    for (final style in [
      theme.elevatedButtonTheme.style,
      theme.filledButtonTheme.style,
      theme.outlinedButtonTheme.style,
      theme.textButtonTheme.style,
    ]) {
      expect(
        style?.minimumSize?.resolve(states)?.height,
        greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
      );
    }
    expect(
      theme.iconButtonTheme.style?.minimumSize?.resolve(states),
      const Size.square(PakPerkSizes.minimumInteractive),
    );
    expect(
      theme.navigationBarTheme.height,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );
    expect(
      theme.listTileTheme.minTileHeight,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );
    expect(theme.navigationBarTheme.elevation, PakPerkElevation.flat);
    expect(theme.dialogTheme.elevation, PakPerkElevation.modal);
  });

  test('component chrome is calm, tactile, and color-scheme aware', () {
    final light = PakPerkTheme.light();
    final dark = PakPerkTheme.dark();
    final pressed = <WidgetState>{WidgetState.pressed};
    final hovered = <WidgetState>{WidgetState.hovered};
    final disabled = <WidgetState>{WidgetState.disabled};

    for (final theme in [light, dark]) {
      final semantic = theme.extension<PakPerkSemanticColors>()!;
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      final pressedOverlay = theme.textButtonTheme.style?.overlayColor?.resolve(
        pressed,
      );
      final hoveredOverlay = theme.textButtonTheme.style?.overlayColor?.resolve(
        hovered,
      );

      expect(theme.splashFactory, same(NoSplash.splashFactory));
      expect(theme.splashColor, Colors.transparent);
      expect(theme.highlightColor.a, greaterThan(0));
      expect(theme.highlightColor.a, lessThan(.2));
      expect(pressedOverlay, isNotNull);
      expect(pressedOverlay!.a, lessThan(.1));
      expect(hoveredOverlay, isNotNull);
      expect(hoveredOverlay!.a, lessThan(pressedOverlay.a));
      expect(
        theme.textButtonTheme.style?.overlayColor?.resolve(disabled),
        isNull,
      );

      expect(theme.appBarTheme.elevation, PakPerkElevation.flat);
      expect(theme.appBarTheme.scrolledUnderElevation, PakPerkElevation.flat);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
      expect(theme.appBarTheme.backgroundColor?.a, lessThan(1));
      expect(
        theme.appBarTheme.titleTextStyle?.fontSize,
        theme.textTheme.titleMedium?.fontSize,
      );
      expect(
        theme.appBarTheme.titleTextStyle?.fontWeight,
        theme.textTheme.titleMedium?.fontWeight,
      );
      expect(
        theme.appBarTheme.titleTextStyle?.color,
        theme.textTheme.titleMedium?.color,
      );

      expect(theme.cardTheme.color, semantic.raisedPaper);
      expect(theme.cardTheme.elevation, PakPerkElevation.flat);
      expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
      expect(cardShape.borderRadius, PakPerkRadii.card);
      expect(
        cardShape.side.color,
        theme.colorScheme.outlineVariant.withValues(
          alpha: theme.brightness == Brightness.dark ? .82 : .72,
        ),
      );

      expect(theme.navigationBarTheme.backgroundColor?.a, lessThan(1));
      expect(theme.navigationBarTheme.surfaceTintColor, Colors.transparent);
      expect(theme.navigationBarTheme.indicatorShape, isA<StadiumBorder>());
      expect(
        theme.navigationBarTheme.overlayColor?.resolve(pressed)?.a,
        lessThan(.1),
      );
      expect(theme.navigationRailTheme.elevation, PakPerkElevation.flat);
      expect(theme.navigationRailTheme.indicatorShape, isA<StadiumBorder>());

      expect(
        theme.listTileTheme.titleTextStyle?.fontSize,
        theme.textTheme.bodyLarge?.fontSize,
      );
      expect(
        theme.listTileTheme.subtitleTextStyle?.color,
        theme.colorScheme.onSurfaceVariant,
      );
      expect(theme.listTileTheme.enableFeedback, isTrue);
    }

    expect(
      light.appBarTheme.backgroundColor,
      isNot(dark.appBarTheme.backgroundColor),
    );
    expect(
      light.navigationBarTheme.backgroundColor,
      isNot(dark.navigationBarTheme.backgroundColor),
    );
  });

  test(
    'semantic status roles support dark mode, copying, and interpolation',
    () {
      const light = PakPerkSemanticColors.light;
      const dark = PakPerkSemanticColors.dark;

      expect(light.processing, isNot(light.warning));
      expect(light.moderation, isNot(light.processing));
      expect(light.destructive, PakPerkColors.error);
      expect(dark.processing, isNot(light.processing));
      expect(dark.moderation, isNot(light.moderation));
      expect(dark.destructive, PakPerkColors.darkError);

      const replacement = Colors.pink;
      expect(light.copyWith(processing: replacement).processing, replacement);
      final midpoint = light.lerp(dark, .5);
      expect(
        midpoint.processing,
        Color.lerp(light.processing, dark.processing, .5),
      );
      expect(
        midpoint.moderation,
        Color.lerp(light.moderation, dark.moderation, .5),
      );
      expect(
        midpoint.destructive,
        Color.lerp(light.destructive, dark.destructive, .5),
      );
    },
  );
}

double _contrastRatio(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}
