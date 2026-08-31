import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/api/transport_network_status.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/document/visual_asset_repository.dart';

void main() {
  test('responsive variant selection is closed at pixel-width boundaries', () {
    expect(visualAssetVariantForPixelWidth(480), VisualAssetVariant.small);
    expect(visualAssetVariantForPixelWidth(481), VisualAssetVariant.medium);
    expect(visualAssetVariantForPixelWidth(960), VisualAssetVariant.medium);
    expect(visualAssetVariantForPixelWidth(961), VisualAssetVariant.large);
    expect(
      visualAssetVariantForPixelWidth(double.nan),
      VisualAssetVariant.large,
    );
  });

  test('payload rejects a forged checksum and executable markup', () {
    final png = _payload(1);
    expect(
      () => VisualAssetPayload(
        bytes: png.bytes,
        contentType: png.contentType,
        checksum: List.filled(64, '0').join(),
      ),
      throwsFormatException,
    );
    final svg = Uint8List.fromList('<svg><script/></svg>'.codeUnits);
    expect(
      () => VisualAssetPayload(
        bytes: svg,
        contentType: 'image/svg+xml',
        checksum: sha256.convert(svg).toString(),
      ),
      throwsFormatException,
    );
  });

  test('payload rejects a compressed raster with hostile dimensions', () {
    final hostile = _pngHeader(width: 100000, height: 100000, suffix: 1);
    expect(
      () => VisualAssetPayload(
        bytes: hostile,
        contentType: 'image/png',
        checksum: sha256.convert(hostile).toString(),
      ),
      throwsFormatException,
    );
  });

  test('request rejects path-confusable identifiers', () {
    expect(
      () => VisualAssetRequest(
        accountId: _accountA,
        authEpoch: 2,
        paperId: '../paper',
        generation: 4,
        figureId: _figureA,
        revision: _revision,
        width: 1,
        height: 1,
      ),
      throwsArgumentError,
    );
  });

  test(
    'asset API accepts only the fenced checksum-bound raster response',
    () async {
      final payload = _payload(3);
      final adapter = _AssetAdapter(payload: payload);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      final received = await VisualAssetApi(dio).fetch(request: _request());

      expect(received.checksum, payload.checksum);
      expect(adapter.path, '/v1/papers/$_paper/figures/$_figureA/asset');
      expect(adapter.generation, 4);
      expect(adapter.revision, _revision);
      expect(adapter.variant, 'large');
    },
  );

  test('asset API selects and fences a responsive variant', () async {
    final payload = _payload(3);
    final adapter = _AssetAdapter(payload: payload);
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    final received = await VisualAssetApi(dio).fetch(
      request: _request(width: 2, height: 2, variant: VisualAssetVariant.small),
    );

    expect(received.width, 1);
    expect(adapter.variant, 'small');
    expect(
      _request(variant: VisualAssetVariant.small).cacheKey,
      isNot(_request(variant: VisualAssetVariant.large).cacheKey),
    );
    expect(
      _request(revision: _revision).cacheKey,
      isNot(_request(revision: _otherRevision).cacheKey),
    );
  });

  test(
    'asset API rejects forged checksums and oversized declarations',
    () async {
      final payload = _payload(3);
      for (final adapter in [
        _AssetAdapter(payload: payload, checksum: List.filled(64, '0').join()),
        _AssetAdapter(payload: payload, declaredLength: 8 * 1024 * 1024 + 1),
        _AssetAdapter(payload: payload, responseRevision: _otherRevision),
      ]) {
        final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
          ..httpClientAdapter = adapter;
        await expectLater(
          VisualAssetApi(dio).fetch(request: _request()),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INVALID_FIGURE_ASSET',
            ),
          ),
        );
      }
      await expectLater(
        VisualAssetApi(
          Dio(BaseOptions(baseUrl: 'https://api.example.test'))
            ..httpClientAdapter = _AssetAdapter(payload: payload),
        ).fetch(request: _request(width: 2)),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('file cache fences generations and account cleanup', () async {
    final root = await Directory.systemTemp.createTemp('pakperk-visual-cache-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final cache = FileVisualAssetCache(rootDirectory: () async => root);
    final first = _request(accountId: _accountA, generation: 4);
    final nextGeneration = _request(accountId: _accountA, generation: 5);
    final otherAccount = _request(accountId: _accountB, generation: 4);

    await cache.write(first, _payload(1));
    await cache.write(otherAccount, _payload(2));

    final cachePaths = await root
        .list(recursive: true, followLinks: false)
        .map((entity) => entity.path)
        .toList();
    expect(
      cachePaths.every(
        (path) =>
            !path.contains(_accountA) &&
            !path.contains(_paper) &&
            !path.contains(_figureA),
      ),
      isTrue,
    );

    expect((await cache.read(first))?.bytes, _payload(1).bytes);
    expect(await cache.read(nextGeneration), isNull);
    await cache.clearAccount(_accountA);
    expect(await cache.read(first), isNull);
    expect((await cache.read(otherAccount))?.bytes, _payload(2).bytes);
  });

  test('concurrent identical cache fills converge on one target', () async {
    final root = await Directory.systemTemp.createTemp('pakperk-visual-race-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final cache = FileVisualAssetCache(rootDirectory: () async => root);
    final request = _request();
    final payload = _payload(7);

    await Future.wait([
      cache.write(request, payload),
      cache.write(request, payload),
    ]);

    final assetFiles = await root
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.asset'))
        .toList();
    expect(assetFiles, hasLength(1));
    expect((await cache.read(request))?.checksum, payload.checksum);
  });

  test('LRU evicts old unpinned assets and preserves saved assets', () async {
    final root = await Directory.systemTemp.createTemp('pakperk-visual-lru-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final one = _payload(1);
    final two = _payload(2);
    final three = _payload(3);
    final cache = FileVisualAssetCache(
      rootDirectory: () async => root,
      budgetBytes: one.bytes.length + two.bytes.length,
      entryLimit: 2,
    );
    final saved = _request(figureId: _figureA);
    final old = _request(figureId: _figureB);
    final recent = _request(figureId: _figureC);

    await cache.write(saved, one);
    await cache.setPersistentPin(saved, VisualAssetPersistentPin.saved, true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await cache.write(old, two);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await cache.write(recent, three);

    expect(await cache.read(old), isNull);
    expect(await cache.read(saved), isNotNull);
    expect(await cache.read(recent), isNotNull);
  });

  test('hard ceiling evicts pinned assets by deterministic priority', () async {
    final root = await Directory.systemTemp.createTemp('pakperk-visual-hard-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final one = _payload(1);
    final two = _payload(2);
    final three = _payload(3);
    final cache = FileVisualAssetCache(
      rootDirectory: () async => root,
      budgetBytes: one.bytes.length + two.bytes.length,
      entryLimit: 2,
    );
    final saved = _request(figureId: _figureA);
    final evidence = _request(figureId: _figureB);
    final current = _request(figureId: _figureC);

    await cache.write(saved, one);
    await cache.setPersistentPin(saved, VisualAssetPersistentPin.saved, true);
    await cache.write(evidence, two);
    await cache.setPersistentPin(
      evidence,
      VisualAssetPersistentPin.evidence,
      true,
    );
    cache.retain(current);
    await cache.write(current, three);

    expect(await cache.read(saved), isNull);
    expect(await cache.read(evidence), isNotNull);
    expect(await cache.read(current), isNotNull);
    final files = await root
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.asset'))
        .cast<File>()
        .toList();
    var diskBytes = 0;
    for (final file in files) {
      diskBytes += await file.length();
    }
    expect(diskBytes, lessThanOrEqualTo(one.bytes.length + two.bytes.length));
  });

  test('paper unsave reconciles every cached generation pin', () async {
    final root = await Directory.systemTemp.createTemp('pakperk-visual-save-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final payload = _payload(1);
    final cache = FileVisualAssetCache(
      rootDirectory: () async => root,
      budgetBytes: payload.bytes.length * 2,
    );
    final first = _request(generation: 4, figureId: _figureA);
    final second = _request(generation: 5, figureId: _figureB);
    await cache.write(first, payload);
    await cache.write(second, _payload(2));
    await cache.setPersistentPin(first, VisualAssetPersistentPin.saved, true);
    await cache.setPersistentPin(second, VisualAssetPersistentPin.saved, true);

    await cache.setPaperSaved(
      VisualAssetPaperScope(
        accountId: _accountA,
        authEpoch: 2,
        paperId: _paper,
      ),
      false,
    );
    final savedMarkers = await root
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File && entity.path.endsWith('.saved.pin'))
        .toList();
    expect(savedMarkers, isEmpty);
    await cache.write(
      _request(paperId: _otherPaper, figureId: _figureC),
      _payload(3),
    );

    final remaining = [
      await cache.read(first),
      await cache.read(second),
    ].whereType<VisualAssetPayload>().length;
    expect(remaining, 1);
  });

  test(
    'prototype policy can use cache while strict policy fails closed',
    () async {
      final request = _request();
      final payload = _payload(9);
      final prototypeCache = _MemoryCache(payload);
      final prototypeNetwork = TransportNetworkStatus()..markOffline();
      addTearDown(prototypeNetwork.dispose);
      final prototype = VisualAssetRepository(
        remote: _FailingRemote(),
        cache: prototypeCache,
        networkStatus: prototypeNetwork,
        fulltextPolicy: ClientFulltextPolicy.prototype,
        accountWrites: AccountDataWriteBarrier(),
        accountScopeIsCurrent: (_, __) => true,
      );

      final lease = await prototype.acquire(request, saved: true);
      expect(lease.payload.bytes, payload.bytes);
      expect(prototypeCache.reads, 1);
      expect(prototypeCache.retained, isTrue);
      lease.release();
      expect(prototypeCache.retained, isFalse);

      final strictCache = _MemoryCache(payload);
      final strictNetwork = TransportNetworkStatus()..markOffline();
      addTearDown(strictNetwork.dispose);
      final strict = VisualAssetRepository(
        remote: _FailingRemote(),
        cache: strictCache,
        networkStatus: strictNetwork,
        fulltextPolicy: ClientFulltextPolicy.strict,
        accountWrites: AccountDataWriteBarrier(),
        accountScopeIsCurrent: (_, __) => true,
      );
      await expectLater(
        strict.acquire(request, saved: true),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'OFFLINE_FIGURE_ASSET_UNAVAILABLE',
          ),
        ),
      );
      expect(strictCache.reads, 0);
      expect(strictCache.pins, 0);
    },
  );

  test('account deletion fences a late remote cache write', () async {
    final request = _request();
    final remote = _DelayedRemote();
    final cache = _MemoryCache(null);
    final network = TransportNetworkStatus();
    final barrier = AccountDataWriteBarrier();
    var current = true;
    addTearDown(network.dispose);
    final repository = VisualAssetRepository(
      remote: remote,
      cache: cache,
      networkStatus: network,
      fulltextPolicy: ClientFulltextPolicy.prototype,
      accountWrites: barrier,
      accountScopeIsCurrent: (_, __) => current,
    );

    final acquire = repository.acquire(request, saved: false);
    await remote.started.future;
    current = false;
    await barrier.clear(
      accountId: request.accountId,
      invalidatedThroughEpoch: request.authEpoch,
      clearAccount: cache.clearAccount,
      clearAll: cache.clearAll,
    );
    remote.result.complete(_payload(5));

    await expectLater(
      acquire,
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'REQUEST_CANCELLED',
        ),
      ),
    );
    expect(cache.writes, 0);
    expect(cache.accountClears, 1);
  });
}

VisualAssetRequest _request({
  String accountId = _accountA,
  String paperId = _paper,
  int generation = 4,
  String figureId = _figureA,
  String revision = _revision,
  int width = 1,
  int height = 1,
  VisualAssetVariant variant = VisualAssetVariant.large,
}) => VisualAssetRequest(
  accountId: accountId,
  authEpoch: 2,
  paperId: paperId,
  generation: generation,
  figureId: figureId,
  revision: revision,
  width: width,
  height: height,
  variant: variant,
);

const _accountA = '11111111-1111-4111-8111-111111111111';
const _accountB = '22222222-2222-4222-8222-222222222222';
const _paper = '33333333-3333-4333-8333-333333333333';
const _otherPaper = '77777777-7777-4777-8777-777777777777';
const _figureA = '44444444-4444-4444-8444-444444444444';
const _figureB = '55555555-5555-4555-8555-555555555555';
const _figureC = '66666666-6666-4666-8666-666666666666';
const _revision =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherRevision =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

VisualAssetPayload _payload(int suffix) {
  final bytes = _pngHeader(width: 1, height: 1, suffix: suffix);
  return VisualAssetPayload(
    bytes: bytes,
    contentType: 'image/png',
    checksum: sha256.convert(bytes).toString(),
  );
}

Uint8List _pngHeader({
  required int width,
  required int height,
  required int suffix,
}) => Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  13,
  0x49,
  0x48,
  0x44,
  0x52,
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
  suffix,
]);

final class _FailingRemote implements VisualAssetRemoteDataSource {
  @override
  Future<VisualAssetPayload> fetch({
    required VisualAssetRequest request,
    RequestCancellation? cancellation,
  }) => throw StateError('remote should not be called');
}

final class _DelayedRemote implements VisualAssetRemoteDataSource {
  final Completer<void> started = Completer<void>();
  final Completer<VisualAssetPayload> result = Completer<VisualAssetPayload>();

  @override
  Future<VisualAssetPayload> fetch({
    required VisualAssetRequest request,
    RequestCancellation? cancellation,
  }) {
    started.complete();
    return result.future;
  }
}

final class _AssetAdapter implements HttpClientAdapter {
  _AssetAdapter({
    required this.payload,
    this.checksum,
    this.declaredLength,
    this.responseRevision,
  });

  final VisualAssetPayload payload;
  final String? checksum;
  final int? declaredLength;
  final String? responseRevision;
  String? path;
  int? generation;
  String? revision;
  String? variant;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.path;
    generation = options.queryParameters['generation'] as int?;
    revision = options.queryParameters['revision'] as String?;
    variant = options.queryParameters['variant'] as String?;
    return ResponseBody.fromBytes(
      payload.bytes,
      200,
      headers: {
        Headers.contentTypeHeader: [payload.contentType],
        Headers.contentLengthHeader: [
          '${declaredLength ?? payload.bytes.length}',
        ],
        'x-pakperk-document-generation': ['$generation'],
        'x-pakperk-image-width': ['${payload.width}'],
        'x-pakperk-image-height': ['${payload.height}'],
        'x-pakperk-image-variant': ['$variant'],
        'x-pakperk-image-revision': [responseRevision ?? '$revision'],
        'x-content-sha256': [checksum ?? payload.checksum],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _MemoryCache implements VisualAssetCache {
  _MemoryCache(this.payload);

  final VisualAssetPayload? payload;
  int reads = 0;
  int pins = 0;
  int writes = 0;
  int accountClears = 0;
  bool retained = false;

  @override
  Future<void> clearAccount(String accountId) async {
    accountClears++;
  }

  @override
  Future<void> clearAll() async {}

  @override
  Future<VisualAssetPayload?> read(VisualAssetRequest request) async {
    reads++;
    return payload;
  }

  @override
  void release(VisualAssetRequest request) => retained = false;

  @override
  void retain(VisualAssetRequest request) => retained = true;

  @override
  Future<void> setPersistentPin(
    VisualAssetRequest request,
    VisualAssetPersistentPin pin,
    bool enabled,
  ) async {
    pins++;
  }

  @override
  Future<void> setPaperSaved(VisualAssetPaperScope scope, bool saved) async {}

  @override
  Future<void> write(
    VisualAssetRequest request,
    VisualAssetPayload payload,
  ) async {
    writes++;
  }
}
