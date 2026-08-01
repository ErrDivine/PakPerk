import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/design_system/colors.dart';
import 'package:pakperk/design_system/elevation.dart';
import 'package:pakperk/design_system/sizes.dart';
import 'package:pakperk/design_system/skeleton.dart';
import 'package:pakperk/design_system/theme.dart';

void main() {
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

  test('interactive component themes retain Material target sizes', () {
    final theme = PakPerkTheme.light();
    final states = <WidgetState>{};

    expect(
      theme.filledButtonTheme.style?.minimumSize?.resolve(states)?.height,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );
    expect(
      theme.iconButtonTheme.style?.minimumSize?.resolve(states),
      const Size.square(PakPerkSizes.minimumInteractive),
    );
    expect(
      theme.navigationBarTheme.height,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );
    expect(theme.navigationBarTheme.elevation, PakPerkElevation.navigation);
    expect(theme.dialogTheme.elevation, PakPerkElevation.modal);
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
