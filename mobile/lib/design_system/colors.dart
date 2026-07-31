import 'package:flutter/material.dart';

/// The small set of brand colors that may also be used outside a [ThemeData].
///
/// Prefer [ColorScheme] or [PakPerkSemanticColors] inside widgets. Keeping the
/// brand palette separate from semantic roles prevents a light-theme color
/// from accidentally leaking into dark mode.
abstract final class PakPerkColors {
  static const ink = Color(0xFF17211B);
  static const paper = Color(0xFFF7F4EC);
  static const paperRaised = Color(0xFFFFFCF5);
  static const moss = Color(0xFF315C47);
  static const mossSoft = Color(0xFFDCE9DF);
  static const ochre = Color(0xFF9B6427);
  static const outline = Color(0xFFD4CEC0);
  static const error = Color(0xFF9B2C2C);

  static const darkPaper = Color(0xFF17211B);
  static const darkPaperRaised = Color(0xFF202C25);
  static const darkInk = Color(0xFFF0F5F1);
  static const darkInkMuted = Color(0xFFBBC7BF);
  static const darkMoss = Color(0xFFA8D5B7);
  static const darkMossSoft = Color(0xFF294336);
  static const darkOchre = Color(0xFFE7AC66);
  static const darkOutline = Color(0xFF536158);
  static const darkError = Color(0xFFFFB4AB);
}

@immutable
class PakPerkSemanticColors extends ThemeExtension<PakPerkSemanticColors> {
  const PakPerkSemanticColors({
    required this.paper,
    required this.raisedPaper,
    required this.ink,
    required this.mutedInk,
    required this.accent,
    required this.accentContainer,
    required this.warning,
    required this.success,
    required this.processing,
    required this.offline,
    required this.moderation,
    required this.destructive,
  });

  static const light = PakPerkSemanticColors(
    paper: PakPerkColors.paper,
    raisedPaper: PakPerkColors.paperRaised,
    ink: PakPerkColors.ink,
    mutedInk: Color(0xFF59635C),
    accent: PakPerkColors.ochre,
    accentContainer: Color(0xFFF2E1CA),
    warning: PakPerkColors.ochre,
    success: PakPerkColors.moss,
    processing: Color(0xFF365F73),
    offline: Color(0xFF665F55),
    moderation: Color(0xFF74527D),
    destructive: PakPerkColors.error,
  );

  static const dark = PakPerkSemanticColors(
    paper: PakPerkColors.darkPaper,
    raisedPaper: PakPerkColors.darkPaperRaised,
    ink: PakPerkColors.darkInk,
    mutedInk: PakPerkColors.darkInkMuted,
    accent: PakPerkColors.darkOchre,
    accentContainer: Color(0xFF503A22),
    warning: PakPerkColors.darkOchre,
    success: PakPerkColors.darkMoss,
    processing: Color(0xFF9CCBE0),
    offline: Color(0xFFC9C1B5),
    moderation: Color(0xFFDDBBE5),
    destructive: PakPerkColors.darkError,
  );

  final Color paper;
  final Color raisedPaper;
  final Color ink;
  final Color mutedInk;
  final Color accent;
  final Color accentContainer;
  final Color warning;
  final Color success;
  final Color processing;
  final Color offline;
  final Color moderation;
  final Color destructive;

  @override
  PakPerkSemanticColors copyWith({
    Color? paper,
    Color? raisedPaper,
    Color? ink,
    Color? mutedInk,
    Color? accent,
    Color? accentContainer,
    Color? warning,
    Color? success,
    Color? processing,
    Color? offline,
    Color? moderation,
    Color? destructive,
  }) {
    return PakPerkSemanticColors(
      paper: paper ?? this.paper,
      raisedPaper: raisedPaper ?? this.raisedPaper,
      ink: ink ?? this.ink,
      mutedInk: mutedInk ?? this.mutedInk,
      accent: accent ?? this.accent,
      accentContainer: accentContainer ?? this.accentContainer,
      warning: warning ?? this.warning,
      success: success ?? this.success,
      processing: processing ?? this.processing,
      offline: offline ?? this.offline,
      moderation: moderation ?? this.moderation,
      destructive: destructive ?? this.destructive,
    );
  }

  @override
  PakPerkSemanticColors lerp(
    covariant ThemeExtension<PakPerkSemanticColors>? other,
    double t,
  ) {
    if (other is! PakPerkSemanticColors) return this;
    return PakPerkSemanticColors(
      paper: Color.lerp(paper, other.paper, t)!,
      raisedPaper: Color.lerp(raisedPaper, other.raisedPaper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      mutedInk: Color.lerp(mutedInk, other.mutedInk, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentContainer: Color.lerp(accentContainer, other.accentContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      processing: Color.lerp(processing, other.processing, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      moderation: Color.lerp(moderation, other.moderation, t)!,
      destructive: Color.lerp(destructive, other.destructive, t)!,
    );
  }
}

extension PakPerkThemeColors on BuildContext {
  PakPerkSemanticColors get pakPerkColors =>
      Theme.of(this).extension<PakPerkSemanticColors>()!;
}
