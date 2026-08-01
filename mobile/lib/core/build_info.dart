/// Release identity shown by the app and checked against native/package
/// metadata by `scripts/generate_release_metadata.py`.
abstract final class PakPerkBuildInfo {
  static const versionName = '0.2.0';
  static const buildNumber = '2';
  static const displayVersion = '$versionName ($buildNumber)';
}
