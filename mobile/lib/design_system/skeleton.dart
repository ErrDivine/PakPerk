import 'package:flutter/material.dart';

/// Theme roles for cache-miss placeholders.
///
/// A skeleton is intentionally a theme extension instead of a one-off widget:
/// later cache surfaces can share accessible light/dark values without
/// introducing another palette or replacing valid stale content with loading
/// chrome.
@immutable
class PakPerkSkeletonTheme extends ThemeExtension<PakPerkSkeletonTheme> {
  const PakPerkSkeletonTheme({
    required this.base,
    required this.highlight,
  });

  static const light = PakPerkSkeletonTheme(
    base: Color(0xFFE5DFD3),
    highlight: Color(0xFFF2EEE5),
  );

  static const dark = PakPerkSkeletonTheme(
    base: Color(0xFF354139),
    highlight: Color(0xFF465249),
  );

  final Color base;
  final Color highlight;

  @override
  PakPerkSkeletonTheme copyWith({Color? base, Color? highlight}) {
    return PakPerkSkeletonTheme(
      base: base ?? this.base,
      highlight: highlight ?? this.highlight,
    );
  }

  @override
  PakPerkSkeletonTheme lerp(
    covariant ThemeExtension<PakPerkSkeletonTheme>? other,
    double t,
  ) {
    if (other is! PakPerkSkeletonTheme) return this;
    return PakPerkSkeletonTheme(
      base: Color.lerp(base, other.base, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
    );
  }
}
