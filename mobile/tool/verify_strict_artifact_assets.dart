import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const _derivedSources = <String>{
  'assets/prepared_introductions.json',
  'assets/prepared_connections.json',
};

const _strictAppAssetAllowlist = <String>{
  'assets/brand/pakperk_mark.png',
  'assets/brand/pakperk_mark_dark.png',
  'assets/fallback_feed.json',
  'assets/legal/privacy.md',
  'assets/legal/terms.md',
  'assets/legal/community_guidelines.md',
  'assets/legal/support.md',
  'assets/legal/account_deletion.md',
  'assets/legal/open_source_licenses.md',
};

// These are the stock Flutter launcher PNGs that previously shipped in this
// repository, plus the two PNGs emitted from that catalog at the root of an
// iOS application bundle. Keep this denylist independent of the current
// Pakperk artwork so regenerating the approved icons cannot bless a default.
const _knownDefaultFlutterLauncherHashes = <String>{
  'c7c0c0189145e4e32a401c61c9bdc615754b0264e7afae24e834bb81049eaf81',
  '6a7c8f0d703e3682108f9662f813302236240d3f8f638bb391e32bfb96055fef',
  'e14aa40904929bf313fded22cf7e7ffcbf1d1aac4263b5ef1be8bfce650397aa',
  '4d470bf22d5c17d84edc5f82516d1ba8a1c09559cd761cefb792f86d9f52b540',
  '3c34e1f298d0c9ea3455d46db6b7759c8211a49e9ec6e44b635fc5c87dfb4180',
  '7770183009e914112de7d8ef1d235a6a30c5834424858e0d2f8253f6b8d31926',
  'cab10a0d391ec5bc09ef50ce49e8ad401cee7ef03707ec0923a222c5c2b3d212',
  'b9ad02cf6576a04d1b6806ac02a2431481b448dd0c2e505ce25842d1f7c4730b',
  'c6e6d3b215ae744a9c391f4c4d44157eff5e739d6ad6c39f9bfa5df66dddd267',
  '5dee24dc104ac76dc162e42ae0beb163d426bf365562ee28ba7b3ad368559a60',
  'a9b21eb6f4271385655a8771f76e29eef8c1107d7879cbcfc567e6619d1f716a',
  'e677d701ffe4af7bc2935098d6b3984cc9ab7ace573e6900955a5535b12410cf',
  '7c61c42fc7b657d9cf314d32a4ec458f0647c3aaf360be1b9377857266ec2499',
  '19be171481dc71a0b2803ebcd01dd8b0c5fd5778dee34c0a3cabc948c225f24e',
  '4209a49e44a92ec40a327d3455eb1b1c153ee83d75de1c2be0a12ab18b2ff9de',
  '836c918cb613249eba0483a6b02fa3df3c1c0a89a315ee4d3b88509b83c7ab73',
  '41c7d42f6e61f8fe7f30b1ffa2256aecbc9682be06d18c4a3062043e1a2e547c',
  '5d7e5bdf01b93802bc973345b3a78c038907147625035952a08a115a563b7f81',
};

const _androidLauncherDensities = <String>{
  'mdpi',
  'hdpi',
  'xhdpi',
  'xxhdpi',
  'xxxhdpi',
};

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_strict_artifact_assets.dart <apk|aab|ipa|app>',
    );
    exitCode = 64;
    return;
  }

  final sourceHashes = <Digest>{};
  for (final path in _derivedSources) {
    final source = File(path);
    if (!source.existsSync()) {
      stderr.writeln('Required policy source is missing: $path');
      exitCode = 66;
      return;
    }
    sourceHashes.add(sha256.convert(await source.readAsBytes()));
  }
  final sourcePrivacyManifest = File('ios/Runner/PrivacyInfo.xcprivacy');
  if (!sourcePrivacyManifest.existsSync()) {
    stderr.writeln('Required iOS privacy manifest source is missing.');
    exitCode = 66;
    return;
  }
  final sourcePrivacyBytes = await sourcePrivacyManifest.readAsBytes();
  if (!RegExp(
    r'<key>NSPrivacyTracking</key>\s*<false\s*/>',
  ).hasMatch(utf8.decode(sourcePrivacyBytes))) {
    stderr.writeln('Source iOS privacy manifest must declare tracking false.');
    exitCode = 66;
    return;
  }

  final artifact = arguments.single;
  final entries = switch (FileSystemEntity.typeSync(artifact)) {
    FileSystemEntityType.file => await _zipEntries(File(artifact)),
    FileSystemEntityType.directory => await _directoryEntries(
      Directory(artifact),
    ),
    _ => <_ArtifactEntry>[],
  };
  if (entries.isEmpty) {
    stderr.writeln('Artifact does not exist or has no Flutter asset entries.');
    exitCode = 66;
    return;
  }

  final logicalAssets = <String>{};
  final violations = <String>[];
  for (final entry in entries) {
    final logicalName = _logicalFlutterAsset(entry.name);
    if (logicalName == null || !logicalName.startsWith('assets/')) continue;
    logicalAssets.add(logicalName);
    if (!_strictAppAssetAllowlist.contains(logicalName)) {
      violations.add('unexpected app asset: $logicalName');
    }
    if (_derivedSources.contains(logicalName)) {
      violations.add('prototype-derived asset path: $logicalName');
    }
    if (sourceHashes.contains(sha256.convert(entry.bytes))) {
      violations.add('prototype-derived asset content: $logicalName');
    }
  }

  _verifyNativeArtifactAssets(
    artifact,
    entries,
    sourcePrivacyBytes,
    violations,
  );

  if (!logicalAssets.contains('assets/fallback_feed.json')) {
    violations.add('required metadata fallback is absent');
  }
  final missingLegal = _strictAppAssetAllowlist.difference(logicalAssets);
  if (missingLegal.isNotEmpty) {
    violations.add(
      'required strict assets are absent: ${missingLegal.join(', ')}',
    );
  }
  if (violations.isNotEmpty) {
    for (final violation in violations.toSet()) {
      stderr.writeln(violation);
    }
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Strict app-asset, derived-content, launcher, and platform-manifest checks passed.',
  );
}

void _verifyNativeArtifactAssets(
  String artifact,
  List<_ArtifactEntry> entries,
  List<int> sourcePrivacyBytes,
  List<String> violations,
) {
  final nativeEntries = entries.where(
    (entry) => _isNativeLauncherEntry(entry.name),
  );
  for (final entry in nativeEntries) {
    final digest = sha256.convert(entry.bytes).toString();
    if (_knownDefaultFlutterLauncherHashes.contains(digest)) {
      violations.add('default Flutter launcher asset: ${entry.name}');
    }
  }

  final lowercaseArtifact = artifact.toLowerCase();
  if (lowercaseArtifact.endsWith('.apk') ||
      lowercaseArtifact.endsWith('.aab')) {
    _verifyAndroidLauncherAssets(entries, violations);
    return;
  }
  if (lowercaseArtifact.endsWith('.ipa') ||
      lowercaseArtifact.endsWith('.app')) {
    _verifyIosLauncherAssets(entries, violations);
    _verifyIosPrivacyManifest(entries, sourcePrivacyBytes, violations);
    return;
  }
  violations.add('unsupported strict artifact type: $artifact');
}

void _verifyIosPrivacyManifest(
  List<_ArtifactEntry> entries,
  List<int> sourcePrivacyBytes,
  List<String> violations,
) {
  final manifests = entries
      .where((entry) => _isIosAppPrivacyManifestEntry(entry.name))
      .toList();
  if (manifests.length != 1) {
    violations.add(
      'expected exactly one app-level iOS PrivacyInfo.xcprivacy; '
      'found ${manifests.length}',
    );
    return;
  }
  if (manifests.single.bytes.isEmpty) {
    violations.add('packaged iOS privacy manifest is empty');
    return;
  }
  if (sha256.convert(manifests.single.bytes) !=
      sha256.convert(sourcePrivacyBytes)) {
    violations.add('packaged iOS privacy manifest differs from source');
  }
}

void _verifyAndroidLauncherAssets(
  List<_ArtifactEntry> entries,
  List<String> violations,
) {
  final names = entries.map((entry) => _normalizedPath(entry.name)).toSet();
  for (final density in _androidLauncherDensities) {
    for (final basename in const <String>[
      'ic_launcher.png',
      'ic_launcher_round.png',
    ]) {
      final present =
          _hasAndroidResource(names, 'mipmap-$density', basename) ||
          _hasAndroidResource(names, 'mipmap-$density-v4', basename);
      if (!present) {
        violations.add('missing Android $density launcher asset: $basename');
      }
    }
  }

  const requiredResources = <(String, String)>[
    ('mipmap-anydpi-v26', 'ic_launcher.xml'),
    ('mipmap-anydpi-v26', 'ic_launcher_round.xml'),
    ('mipmap-anydpi-v33', 'ic_launcher.xml'),
    ('mipmap-anydpi-v33', 'ic_launcher_round.xml'),
    ('drawable', 'ic_launcher_foreground.xml'),
    ('drawable', 'ic_launcher_monochrome.xml'),
  ];
  for (final (folder, basename) in requiredResources) {
    if (!_hasAndroidResource(names, folder, basename)) {
      violations.add('missing Android launcher resource: $folder/$basename');
    }
  }
}

bool _hasAndroidResource(Set<String> names, String folder, String basename) {
  final suffix = 'res/$folder/$basename';
  return names.any((name) => name == suffix || name.endsWith('/$suffix'));
}

void _verifyIosLauncherAssets(
  List<_ArtifactEntry> entries,
  List<String> violations,
) {
  final basenames = entries
      .where((entry) => _isIosLauncherEntry(entry.name))
      .map((entry) => _basename(entry.name))
      .toSet();
  for (final required in const <String>{
    'AppIcon60x60@2x.png',
    'AppIcon76x76@2x~ipad.png',
  }) {
    if (!basenames.contains(required)) {
      violations.add('missing packaged iOS launcher asset: $required');
    }
  }
}

Future<List<_ArtifactEntry>> _zipEntries(File artifact) async {
  try {
    final archive = ZipDecoder().decodeBytes(await artifact.readAsBytes());
    return [
      for (final file in archive)
        if (file.isFile && _isInspectedArtifactEntry(file.name))
          _ArtifactEntry(file.name, file.readBytes() ?? const []),
    ];
  } on Object catch (error) {
    stderr.writeln('Could not inspect ${artifact.path}: $error');
    return const [];
  }
}

Future<List<_ArtifactEntry>> _directoryEntries(Directory artifact) async {
  final entries = <_ArtifactEntry>[];
  await for (final entity in artifact.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !_isInspectedArtifactEntry(entity.path)) continue;
    entries.add(_ArtifactEntry(entity.path, await entity.readAsBytes()));
  }
  return entries;
}

bool _isInspectedArtifactEntry(String rawName) =>
    _logicalFlutterAsset(rawName) != null ||
    _isNativeLauncherEntry(rawName) ||
    _isIosAppPrivacyManifestEntry(rawName);

bool _isNativeLauncherEntry(String rawName) =>
    _isAndroidLauncherEntry(rawName) || _isIosLauncherEntry(rawName);

bool _isAndroidLauncherEntry(String rawName) {
  final normalized = _normalizedPath(rawName);
  final basename = _basename(normalized);
  return normalized.contains('/res/') || normalized.startsWith('res/')
      ? basename.startsWith('ic_launcher') &&
            (basename.endsWith('.png') ||
                basename.endsWith('.webp') ||
                basename.endsWith('.xml'))
      : false;
}

bool _isIosLauncherEntry(String rawName) {
  final basename = _basename(rawName);
  return basename.startsWith('AppIcon') && basename.endsWith('.png');
}

bool _isIosAppPrivacyManifestEntry(String rawName) => RegExp(
  r'(?:^|/)[^/]+\.app/PrivacyInfo\.xcprivacy$',
).hasMatch(_normalizedPath(rawName));

String _normalizedPath(String rawName) => rawName.replaceAll('\\', '/');

String _basename(String rawName) {
  final normalized = _normalizedPath(rawName);
  final separator = normalized.lastIndexOf('/');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

String? _logicalFlutterAsset(String rawName) {
  final normalized = rawName.replaceAll('\\', '/');
  const marker = 'flutter_assets/';
  final markerIndex = normalized.indexOf(marker);
  if (markerIndex < 0) return null;
  return normalized.substring(markerIndex + marker.length);
}

final class _ArtifactEntry {
  const _ArtifactEntry(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}
