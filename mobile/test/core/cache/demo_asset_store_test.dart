import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/cache/demo_asset_store.dart';

void main() {
  test('prototype-derived assets are declared only for the dev flavor', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in [
      'assets/prepared_introductions.json',
      'assets/prepared_connections.json',
    ]) {
      expect(
        pubspec,
        matches(
          RegExp(
            '- path: ${RegExp.escape(asset)}\\s+'
            'flavors:\\s+- dev',
          ),
        ),
        reason: '$asset must never enter strict staging/prod artifacts',
      );
    }
    expect(pubspec, contains('    - assets/fallback_feed.json'));
  });

  test('missing derived assets fail safely as unavailable content', () async {
    final store = BundleDemoContentStore(bundle: _MissingAssetBundle());

    expect(await store.loadIntroduction('paper-id'), isNull);
    expect(await store.loadConnections('paper-id'), isNull);
  });
}

final class _MissingAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future<ByteData>.error(FlutterError('Asset is intentionally absent.'));
}
