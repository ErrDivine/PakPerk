import 'package:flutter/material.dart';

import '../design_system/theme.dart';

export '../design_system/colors.dart';
export '../design_system/elevation.dart';
export '../design_system/motion.dart';
export '../design_system/radii.dart';
export '../design_system/sizes.dart';
export '../design_system/spacing.dart';
export '../design_system/theme.dart';
export '../design_system/typography.dart';

/// Compatibility entrypoint for existing callers while the application moves
/// to [PakPerkTheme.light] and [PakPerkTheme.dark].
ThemeData buildPakPerkTheme() => PakPerkTheme.light();

ThemeData buildPakPerkDarkTheme() => PakPerkTheme.dark();
