import 'package:flutter/widgets.dart';

/// One app-wide interpretation of the platform accessibility motion signals.
/// Direct-manipulation gestures remain available; callers use this to remove
/// decorative and programmatic travel.
bool platformPrefersReducedMotion(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return (media?.disableAnimations ?? false) ||
      (media?.accessibleNavigation ?? false);
}

abstract final class PakPerkMotion {
  static const Duration instant = Duration.zero;
  static const Duration crossFade = Duration(milliseconds: 140);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 280);
  static const Duration deepLinkOpening = Duration(milliseconds: 280);
  static const Duration coldOpening = Duration(milliseconds: 620);
  static const Duration maximumOpening = Duration(milliseconds: 700);

  static const Curve emphasized = Cubic(0.2, 0, 0, 1);
  static const Curve enter = Cubic(0, 0, 0.2, 1);
  static const Curve exit = Cubic(0.4, 0, 1, 1);
}
