import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultLauncherHashesByPath = <String, String>{
  'android/app/src/main/res/mipmap-mdpi/ic_launcher.png':
      'c7c0c0189145e4e32a401c61c9bdc615754b0264e7afae24e834bb81049eaf81',
  'android/app/src/main/res/mipmap-hdpi/ic_launcher.png':
      '6a7c8f0d703e3682108f9662f813302236240d3f8f638bb391e32bfb96055fef',
  'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png':
      'e14aa40904929bf313fded22cf7e7ffcbf1d1aac4263b5ef1be8bfce650397aa',
  'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png':
      '4d470bf22d5c17d84edc5f82516d1ba8a1c09559cd761cefb792f86d9f52b540',
  'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png':
      '3c34e1f298d0c9ea3455d46db6b7759c8211a49e9ec6e44b635fc5c87dfb4180',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png':
      '7770183009e914112de7d8ef1d235a6a30c5834424858e0d2f8253f6b8d31926',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png':
      'cab10a0d391ec5bc09ef50ce49e8ad401cee7ef03707ec0923a222c5c2b3d212',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png':
      'b9ad02cf6576a04d1b6806ac02a2431481b448dd0c2e505ce25842d1f7c4730b',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png':
      'c6e6d3b215ae744a9c391f4c4d44157eff5e739d6ad6c39f9bfa5df66dddd267',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png':
      '5dee24dc104ac76dc162e42ae0beb163d426bf365562ee28ba7b3ad368559a60',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png':
      'a9b21eb6f4271385655a8771f76e29eef8c1107d7879cbcfc567e6619d1f716a',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png':
      'e677d701ffe4af7bc2935098d6b3984cc9ab7ace573e6900955a5535b12410cf',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png':
      'b9ad02cf6576a04d1b6806ac02a2431481b448dd0c2e505ce25842d1f7c4730b',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png':
      '7c61c42fc7b657d9cf314d32a4ec458f0647c3aaf360be1b9377857266ec2499',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png':
      '19be171481dc71a0b2803ebcd01dd8b0c5fd5778dee34c0a3cabc948c225f24e',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png':
      '19be171481dc71a0b2803ebcd01dd8b0c5fd5778dee34c0a3cabc948c225f24e',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png':
      '4209a49e44a92ec40a327d3455eb1b1c153ee83d75de1c2be0a12ab18b2ff9de',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png':
      '836c918cb613249eba0483a6b02fa3df3c1c0a89a315ee4d3b88509b83c7ab73',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png':
      '41c7d42f6e61f8fe7f30b1ffa2256aecbc9682be06d18c4a3062043e1a2e547c',
  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png':
      '5d7e5bdf01b93802bc973345b3a78c038907147625035952a08a115a563b7f81',
};

void main() {
  test('Android pins the supported and Play submission API levels', () {
    final gradle = _source('android/app/build.gradle.kts');

    expect(gradle, contains('compileSdk = 36'));
    expect(gradle, contains('ndkVersion = "28.2.13676358"'));
    expect(gradle, contains('minSdk = 24'));
    expect(gradle, contains('targetSdk = 36'));
    expect(gradle, isNot(contains('compileSdk = flutter.compileSdkVersion')));
    expect(gradle, isNot(contains('minSdk = flutter.minSdkVersion')));
    expect(gradle, isNot(contains('targetSdk = flutter.targetSdkVersion')));
  });

  test(
    'Android declares legacy, round, adaptive, and monochrome launchers',
    () {
      final manifest = _source('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(
        manifest,
        contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      );

      for (final density in const <String>[
        'mdpi',
        'hdpi',
        'xhdpi',
        'xxhdpi',
        'xxxhdpi',
      ]) {
        _expectNonDefaultPng(
          'android/app/src/main/res/mipmap-$density/ic_launcher.png',
        );
        _expectNonDefaultPng(
          'android/app/src/main/res/mipmap-$density/ic_launcher_round.png',
        );
      }

      for (final name in const <String>['ic_launcher', 'ic_launcher_round']) {
        final adaptive = _source(
          'android/app/src/main/res/mipmap-anydpi-v26/$name.xml',
        );
        expect(adaptive, contains('<adaptive-icon'));
        expect(adaptive, contains('@color/pakperk_launcher_background'));
        expect(adaptive, contains('@drawable/ic_launcher_foreground'));

        final themed = _source(
          'android/app/src/main/res/mipmap-anydpi-v33/$name.xml',
        );
        expect(themed, contains('<adaptive-icon'));
        expect(themed, contains('@drawable/ic_launcher_monochrome'));
      }

      expect(
        _source('android/app/src/main/res/drawable/ic_launcher_foreground.xml'),
        contains('<vector'),
      );
      expect(
        _source('android/app/src/main/res/drawable/ic_launcher_monochrome.xml'),
        contains('<vector'),
      );
    },
  );

  test('iOS AppIcon catalog is complete, opaque, and not Flutter default', () {
    const catalog = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents = jsonDecode(_source('$catalog/Contents.json'));
    final images = (contents as Map<String, Object?>)['images'];
    expect(images, isA<List<Object?>>());

    var marketingIcons = 0;
    for (final rawImage in images! as List<Object?>) {
      final image = rawImage! as Map<String, Object?>;
      final filename = image['filename'] as String?;
      expect(filename, isNotNull, reason: 'Every AppIcon slot must be filled.');
      final relativePath = '$catalog/$filename';
      _expectNonDefaultPng(relativePath);

      final size = double.parse((image['size']! as String).split('x').first);
      final scale = int.parse((image['scale']! as String).replaceAll('x', ''));
      final bytes = File(relativePath).readAsBytesSync();
      final dimensions = _pngDimensions(bytes);
      final expectedPixels = (size * scale).round();
      expect(dimensions, (expectedPixels, expectedPixels));

      if (image['idiom'] == 'ios-marketing') {
        marketingIcons += 1;
        expect(expectedPixels, 1024);
        expect(
          _pngColorType(bytes),
          2,
          reason: 'The App Store marketing icon must be opaque RGB.',
        );
      }
    }
    expect(marketingIcons, 1);
  });

  test('iOS configurations use the supported App Store deployment floor', () {
    final project = _source('ios/Runner.xcodeproj/project.pbxproj');
    final targets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);',
    ).allMatches(project).map((match) => match.group(1)).toList();

    expect(targets, isNotEmpty);
    expect(
      targets,
      everyElement('15.0'),
      reason:
          'Xcode 26 supports iOS 15 or later as the App Store upload range.',
    );
    expect(project, isNot(contains('IPHONEOS_DEPLOYMENT_TARGET = 13.0;')));
  });
}

String _source(String path) => File(path).readAsStringSync();

void _expectNonDefaultPng(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'Missing launcher source: $path');
  final digest = sha256.convert(file.readAsBytesSync()).toString();
  expect(
    _defaultLauncherHashesByPath.values,
    isNot(contains(digest)),
    reason: '$path still contains the stock Flutter launcher artwork.',
  );
}

(int, int) _pngDimensions(Uint8List bytes) {
  expect(bytes.length, greaterThanOrEqualTo(26));
  expect(bytes.sublist(1, 4), <int>[0x50, 0x4e, 0x47]);
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

int _pngColorType(Uint8List bytes) => bytes[25];
