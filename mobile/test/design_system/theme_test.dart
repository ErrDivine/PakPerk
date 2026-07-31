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
      expect(
        _contrastRatio(theme.colorScheme.onSurface, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(theme.colorScheme.onPrimary, theme.colorScheme.primary),
        greaterThanOrEqualTo(4.5),
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
