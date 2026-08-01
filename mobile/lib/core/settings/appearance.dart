enum AppAppearance {
  system,
  light,
  dark;

  static AppAppearance fromWire(String? value) => switch (value) {
    'light' => AppAppearance.light,
    'dark' => AppAppearance.dark,
    _ => AppAppearance.system,
  };
}
