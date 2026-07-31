import 'package:flutter/animation.dart';

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
