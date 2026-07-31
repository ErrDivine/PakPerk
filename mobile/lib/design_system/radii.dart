import 'package:flutter/widgets.dart';

abstract final class PakPerkRadii {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double pill = 999;

  static const card = BorderRadius.all(Radius.circular(md));
  static const input = BorderRadius.all(Radius.circular(sm));
  static const sheet = BorderRadius.vertical(top: Radius.circular(lg));
}
