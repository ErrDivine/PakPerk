import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import '../api/transport_network_status.dart';
import '../account/account_data_write_barrier.dart';
import '../content_policy.dart';
import '../telemetry/telemetry.dart';
import 'visual_asset_limits.dart';

const _visualAssetCacheBudgetBytes = 64 * 1024 * 1024;
const _visualAssetCacheEntryLimit = 2048;
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

enum VisualAssetVariant { small, medium, large }

VisualAssetVariant visualAssetVariantForPixelWidth(double pixelWidth) {
  if (!pixelWidth.isFinite || pixelWidth <= 0) {
    return VisualAssetVariant.large;
  }
  if (pixelWidth <= 480) return VisualAssetVariant.small;
  if (pixelWidth <= 960) return VisualAssetVariant.medium;
  return VisualAssetVariant.large;
}

final class VisualAssetRequest {
  VisualAssetRequest({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
    required this.generation,
    required this.figureId,
    required this.revision,
    required this.width,
    required this.height,
    this.variant = VisualAssetVariant.large,
  }) {
    if (!_uuidPattern.hasMatch(accountId) ||
        !_uuidPattern.hasMatch(paperId) ||
        !_uuidPattern.hasMatch(figureId) ||
        !_sha256Pattern.hasMatch(revision) ||
        authEpoch < 0 ||
        generation <= 0 ||
        !validVisualAssetDimensions(width, height)) {
      throw ArgumentError('Invalid visual asset scope.');
    }
  }

  final String accountId;
  final int authEpoch;
  final String paperId;
  final int generation;
  final String figureId;
  final String revision;
  final int width;
  final int height;
  final VisualAssetVariant variant;

  String get accountKey => _hexSha256(utf8.encode(accountId));
  String get paperKey => _hexSha256(utf8.encode('$accountId\u0000$paperId'));
  String get cacheKey => _hexSha256(
    utf8.encode(
      '$accountId\u0000$authEpoch\u0000$paperId\u0000$generation\u0000$figureId\u0000$revision\u0000${variant.name}',
    ),
  );
}

final class VisualAssetPayload {
  factory VisualAssetPayload({
    required Uint8List bytes,
    required String contentType,
    required String checksum,
  }) {
    final immutableBytes = Uint8List.fromList(bytes);
    final dimensions = _rasterDimensions(immutableBytes, contentType);
    if (immutableBytes.isEmpty ||
        immutableBytes.length > maximumVisualAssetBytes ||
        !_supportedRasterType(contentType) ||
        !_sha256Pattern.hasMatch(checksum) ||
        _hexSha256(immutableBytes) != checksum ||
        dimensions == null ||
        !validVisualAssetDimensions(dimensions.width, dimensions.height)) {
      throw const FormatException('Invalid visual derivative.');
    }
    return VisualAssetPayload._(
      bytes: immutableBytes,
      contentType: contentType,
      checksum: checksum,
      width: dimensions.width,
      height: dimensions.height,
    );
  }

  const VisualAssetPayload._({
    required this.bytes,
    required this.contentType,
    required this.checksum,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String contentType;
  final String checksum;
  final int width;
  final int height;
}

final class VisualAssetPaperScope {
  VisualAssetPaperScope({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
  }) {
    if (!_uuidPattern.hasMatch(accountId) ||
        !_uuidPattern.hasMatch(paperId) ||
        authEpoch < 0) {
      throw ArgumentError('Invalid visual asset paper scope.');
    }
  }

  final String accountId;
  final int authEpoch;
  final String paperId;

  String get accountKey => _hexSha256(utf8.encode(accountId));
  String get paperKey => _hexSha256(utf8.encode('$accountId\u0000$paperId'));
}

final class VisualAssetLease {
  VisualAssetLease(this.payload, void Function() release) : _release = release;

  final VisualAssetPayload payload;
  void Function()? _release;

  void release() {
    final release = _release;
    _release = null;
    release?.call();
  }
}

enum VisualAssetPersistentPin { saved, evidence }

abstract interface class VisualAssetRemoteDataSource {
  Future<VisualAssetPayload> fetch({
    required VisualAssetRequest request,
    RequestCancellation? cancellation,
  });
}

abstract interface class VisualAssetCache {
  void retain(VisualAssetRequest request);
  void release(VisualAssetRequest request);

  Future<VisualAssetPayload?> read(VisualAssetRequest request);

  Future<void> write(VisualAssetRequest request, VisualAssetPayload payload);

  Future<void> setPersistentPin(
    VisualAssetRequest request,
    VisualAssetPersistentPin pin,
    bool enabled,
  );

  Future<void> setPaperSaved(VisualAssetPaperScope scope, bool saved);

  Future<void> clearAccount(String accountId);
  Future<void> clearAll();
}

final class VisualAssetApi implements VisualAssetRemoteDataSource {
  const VisualAssetApi(this._dio);

  final Dio _dio;

  @override
  Future<VisualAssetPayload> fetch({
    required VisualAssetRequest request,
    RequestCancellation? cancellation,
  }) async {
    final cancelToken = cancellation?.dioToken ?? CancelToken();
    try {
      final response = await _dio.get<ResponseBody>(
        '/v1/papers/${request.paperId}/figures/${request.figureId}/asset',
        queryParameters: {
          'generation': request.generation,
          'revision': request.revision,
          'variant': request.variant.name,
        },
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: request.authEpoch,
          responseType: ResponseType.stream,
          strictRawResponseStream: true,
          validateStatus: (status) => status == 200,
        ),
        cancelToken: cancelToken,
      );
      return await _readBoundedAsset(
        response,
        request: request,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw const ApiException(
        code: 'INVALID_FIGURE_ASSET',
        message: 'The figure derivative failed safety validation.',
        retryable: true,
        statusCode: 502,
      );
    }
  }
}

final class FileVisualAssetCache implements VisualAssetCache {
  FileVisualAssetCache({
    required Future<Directory> Function() rootDirectory,
    this.telemetry = const NoopTelemetrySink(),
    int budgetBytes = _visualAssetCacheBudgetBytes,
    int entryLimit = _visualAssetCacheEntryLimit,
    int maximumAssetBytes = maximumVisualAssetBytes,
  }) : _rootDirectory = rootDirectory,
       _budgetBytes = budgetBytes,
       _entryLimit = entryLimit,
       _maximumAssetBytes = maximumAssetBytes {
    if (budgetBytes <= 0 || entryLimit <= 0 || maximumAssetBytes <= 0) {
      throw ArgumentError('Visual asset cache bounds must be positive.');
    }
  }

  final Future<Directory> Function() _rootDirectory;
  final TelemetrySink telemetry;
  final int _budgetBytes;
  final int _entryLimit;
  final int _maximumAssetBytes;
  final Set<String> _runtimePins = <String>{};
  final Map<String, String> _runtimePinAccounts = <String, String>{};
  Future<void> _mutationTail = Future<void>.value();

  @override
  void retain(VisualAssetRequest request) {
    _runtimePins.add(request.cacheKey);
    _runtimePinAccounts[request.cacheKey] = request.accountKey;
  }

  @override
  void release(VisualAssetRequest request) {
    _runtimePins.remove(request.cacheKey);
    _runtimePinAccounts.remove(request.cacheKey);
  }

  @override
  Future<VisualAssetPayload?> read(VisualAssetRequest request) =>
      _mutate(() async {
        final directory = await _scopeDirectory(request);
        if (!await directory.exists()) return null;
        final candidates = <File>[];
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.asset')) {
            candidates.add(entity);
          }
        }
        candidates.sort((left, right) {
          final leftTime = left.lastModifiedSync();
          final rightTime = right.lastModifiedSync();
          return rightTime.compareTo(leftTime);
        });
        for (final file in candidates) {
          try {
            final expectedChecksum = _assetChecksumFromPath(file.path);
            final bytes = await _readBoundedFile(file, _maximumAssetBytes);
            final contentType = _rasterContentType(bytes);
            if (contentType == null || _hexSha256(bytes) != expectedChecksum) {
              await _removeScope(file.parent);
              continue;
            }
            final payload = VisualAssetPayload(
              bytes: bytes,
              contentType: contentType,
              checksum: expectedChecksum,
            );
            if (!_payloadMatchesRequest(payload, request)) {
              await _removeScope(file.parent);
              continue;
            }
            await file.setLastModified(DateTime.now().toUtc());
            return payload;
          } on FileSystemException {
            continue;
          } on FormatException {
            await _removeScope(file.parent);
          }
        }
        return null;
      });

  @override
  Future<void> write(VisualAssetRequest request, VisualAssetPayload payload) =>
      _mutate(() async {
        if (payload.bytes.length > _maximumAssetBytes) {
          throw const FormatException('Visual derivative exceeds cache limit.');
        }
        if (!_payloadMatchesRequest(payload, request)) {
          throw const FormatException(
            'Visual derivative dimensions do not match metadata.',
          );
        }
        final directory = await _scopeDirectory(request);
        await directory.create(recursive: true);
        await _writeScopeIdentity(directory, request.paperKey);
        final target = File('${directory.path}/${payload.checksum}.asset');
        if (!await target.exists()) {
          final temporary = File(
            '${directory.path}/.${payload.checksum}.${const Uuid().v4()}.tmp',
          );
          try {
            await temporary.writeAsBytes(payload.bytes, flush: true);
            if (await target.exists()) {
              await temporary.delete();
            } else {
              try {
                await temporary.rename(target.path);
              } on FileSystemException {
                // Another request for the same checksum may win between the
                // existence check and rename. Its target is byte-identical by
                // construction, so that race is a successful cache fill.
                if (!await target.exists()) rethrow;
              }
            }
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
        }
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File &&
              entity.path.endsWith('.asset') &&
              entity.path != target.path) {
            await entity.delete();
          }
        }
        final cacheSize = await _enforceBudget();
        emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheSize, {
          'bytes': cacheSize.clamp(0, 1073741824),
        });
      });

  @override
  Future<void> setPersistentPin(
    VisualAssetRequest request,
    VisualAssetPersistentPin pin,
    bool enabled,
  ) => _mutate(() async {
    final directory = await _scopeDirectory(request);
    final marker = File('${directory.path}/.${pin.name}.pin');
    if (enabled) {
      if (!await _containsAsset(directory)) return;
      await directory.create(recursive: true);
      await _writeScopeIdentity(directory, request.paperKey);
      if (!await marker.exists()) await marker.writeAsBytes(const []);
    } else if (await marker.exists()) {
      await marker.delete();
      if (!await _containsAsset(directory)) await _removeScope(directory);
    }
  });

  @override
  Future<void> setPaperSaved(VisualAssetPaperScope scope, bool saved) =>
      _mutate(() async {
        final root = await _rootDirectory();
        final account = Directory('${root.path}/${scope.accountKey}');
        if (!await account.exists()) return;
        await for (final entity in account.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final identity = File('${entity.path}/.paper-${scope.paperKey}');
          if (!await identity.exists()) continue;
          if (!await _containsAsset(entity)) {
            await _removeScope(entity);
            continue;
          }
          final marker = File(
            '${entity.path}/.${VisualAssetPersistentPin.saved.name}.pin',
          );
          if (saved) {
            if (!await marker.exists()) await marker.writeAsBytes(const []);
          } else if (await marker.exists()) {
            await marker.delete();
          }
        }
      });

  @override
  Future<void> clearAccount(String accountId) => _mutate(() async {
    final root = await _rootDirectory();
    final accountKey = _hexSha256(utf8.encode(accountId));
    final directory = Directory('${root.path}/$accountKey');
    _runtimePinAccounts.removeWhere((cacheKey, value) {
      if (value != accountKey) return false;
      _runtimePins.remove(cacheKey);
      return true;
    });
    if (!await directory.exists()) return;
    final count = await _assetCount(directory);
    await directory.delete(recursive: true);
    emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
      'reason': 'account_cleanup',
      'count': count,
    });
  });

  @override
  Future<void> clearAll() => _mutate(() async {
    final root = await _rootDirectory();
    _runtimePins.clear();
    _runtimePinAccounts.clear();
    if (!await root.exists()) return;
    final count = await _assetCount(root);
    await root.delete(recursive: true);
    if (count > 0) {
      emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
        'reason': 'account_cleanup',
        'count': count,
      });
    }
  });

  Future<Directory> _scopeDirectory(VisualAssetRequest request) async {
    final root = await _rootDirectory();
    return Directory('${root.path}/${request.accountKey}/${request.cacheKey}');
  }

  Future<int> _enforceBudget() async {
    final root = await _rootDirectory();
    if (!await root.exists()) return 0;
    final entries = <_CacheFile>[];
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.asset')) continue;
      final stat = await entity.stat();
      total += stat.size;
      final scopeDirectory = entity.parent;
      final scopeKey = scopeDirectory.path.split(Platform.pathSeparator).last;
      final savedPin = await File(
        '${scopeDirectory.path}/.${VisualAssetPersistentPin.saved.name}.pin',
      ).exists();
      final evidencePin = await File(
        '${scopeDirectory.path}/.${VisualAssetPersistentPin.evidence.name}.pin',
      ).exists();
      final retention = _runtimePins.contains(scopeKey)
          ? _CacheRetention.runtime
          : evidencePin
          ? _CacheRetention.evidence
          : savedPin
          ? _CacheRetention.saved
          : _CacheRetention.unpinned;
      entries.add(
        _CacheFile(
          file: entity,
          size: stat.size,
          lastAccessedAt: stat.modified,
          retention: retention,
        ),
      );
    }
    if (total <= _budgetBytes && entries.length <= _entryLimit) return total;
    entries.sort((left, right) {
      final priority = left.retention.index.compareTo(right.retention.index);
      if (priority != 0) return priority;
      final age = left.lastAccessedAt.compareTo(right.lastAccessedAt);
      if (age != 0) return age;
      return left.file.path.compareTo(right.file.path);
    });
    var evicted = 0;
    var remainingEntries = entries.length;
    for (final entry in entries) {
      if (total <= _budgetBytes && remainingEntries <= _entryLimit) break;
      if (await entry.file.exists()) {
        await _removeScope(entry.file.parent);
        total -= entry.size;
        remainingEntries--;
        evicted++;
      }
    }
    if (evicted > 0) {
      emitTelemetry(telemetry, PakPerkTelemetryEvent.documentCacheEviction, {
        'reason': 'lru',
        'count': evicted,
      });
    }
    return total;
  }

  Future<T> _mutate<T>(Future<T> Function() operation) async {
    final prior = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await prior;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }
}

final class VisualAssetRepository {
  const VisualAssetRepository({
    required VisualAssetRemoteDataSource remote,
    required VisualAssetCache cache,
    required TransportNetworkStatus networkStatus,
    required ClientFulltextPolicy fulltextPolicy,
    required AccountDataWriteBarrier accountWrites,
    required bool Function(String accountId, int authEpoch)
    accountScopeIsCurrent,
    TelemetrySink telemetry = const NoopTelemetrySink(),
  }) : _remote = remote,
       _cache = cache,
       _networkStatus = networkStatus,
       _fulltextPolicy = fulltextPolicy,
       _accountWrites = accountWrites,
       _accountScopeIsCurrent = accountScopeIsCurrent,
       _telemetry = telemetry;

  final VisualAssetRemoteDataSource _remote;
  final VisualAssetCache _cache;
  final TransportNetworkStatus _networkStatus;
  final ClientFulltextPolicy _fulltextPolicy;
  final AccountDataWriteBarrier _accountWrites;
  final bool Function(String accountId, int authEpoch) _accountScopeIsCurrent;
  final TelemetrySink _telemetry;

  Future<VisualAssetLease> acquire(
    VisualAssetRequest request, {
    required bool saved,
    RequestCancellation? cancellation,
  }) async {
    if (!_isCurrent(request)) throw _visualAssetScopeChanged;
    final cacheAllowed = _fulltextPolicy.allowsDerivedDeviceFallback;
    if (cacheAllowed) {
      _cache.retain(request);
    }
    try {
      if (cacheAllowed) {
        if (!saved) {
          final unpinned = await _accountWrites.writeIfCurrent(
            accountId: request.accountId,
            authEpoch: request.authEpoch,
            isCurrent: () => _isCurrent(request),
            write: () => _cache.setPersistentPin(
              request,
              VisualAssetPersistentPin.saved,
              false,
            ),
          );
          if (!unpinned) throw _visualAssetScopeChanged;
        }
        VisualAssetPayload? cached;
        final readForCurrentScope = await _accountWrites.writeIfCurrent(
          accountId: request.accountId,
          authEpoch: request.authEpoch,
          isCurrent: () => _isCurrent(request),
          write: () async {
            cached = await _cache.read(request);
          },
        );
        if (!readForCurrentScope) throw _visualAssetScopeChanged;
        emitTelemetry(_telemetry, PakPerkTelemetryEvent.documentCacheLookup, {
          'outcome': cached == null ? 'miss' : 'hit',
          'offline': _networkStatus.isOffline,
        });
        final cachedPayload = cached;
        if (cachedPayload != null) {
          if (saved) {
            final pinned = await _accountWrites.writeIfCurrent(
              accountId: request.accountId,
              authEpoch: request.authEpoch,
              isCurrent: () => _isCurrent(request),
              write: () => _cache.setPersistentPin(
                request,
                VisualAssetPersistentPin.saved,
                true,
              ),
            );
            if (!pinned) throw _visualAssetScopeChanged;
          }
          return VisualAssetLease(cachedPayload, () => _cache.release(request));
        }
      }
      if (_networkStatus.isOffline) {
        throw const ApiException(
          code: 'OFFLINE_FIGURE_ASSET_UNAVAILABLE',
          message: 'This figure derivative is not available offline.',
          retryable: true,
          isOffline: true,
        );
      }
      final payload = await _remote.fetch(
        request: request,
        cancellation: cancellation,
      );
      if (!_isCurrent(request)) throw _visualAssetScopeChanged;
      if (cacheAllowed) {
        final written = await _accountWrites.writeIfCurrent(
          accountId: request.accountId,
          authEpoch: request.authEpoch,
          isCurrent: () => _isCurrent(request),
          write: () => _cache.write(request, payload),
        );
        if (!written) throw _visualAssetScopeChanged;
        if (saved) {
          final pinned = await _accountWrites.writeIfCurrent(
            accountId: request.accountId,
            authEpoch: request.authEpoch,
            isCurrent: () => _isCurrent(request),
            write: () => _cache.setPersistentPin(
              request,
              VisualAssetPersistentPin.saved,
              true,
            ),
          );
          if (!pinned) throw _visualAssetScopeChanged;
        }
      }
      return VisualAssetLease(
        payload,
        cacheAllowed ? () => _cache.release(request) : () {},
      );
    } on Object {
      if (cacheAllowed) _cache.release(request);
      rethrow;
    }
  }

  Future<void> pinAsEvidence(VisualAssetRequest request) {
    if (!_fulltextPolicy.allowsDerivedDeviceFallback) {
      return Future<void>.value();
    }
    return _pinAsEvidence(request);
  }

  Future<void> unpinAsEvidence(VisualAssetRequest request) {
    if (!_fulltextPolicy.allowsDerivedDeviceFallback) {
      return Future<void>.value();
    }
    return _setEvidencePin(request, false);
  }

  Future<void> reconcilePaperSaved(
    VisualAssetPaperScope scope, {
    required bool saved,
  }) async {
    if (!_fulltextPolicy.allowsDerivedDeviceFallback) return;
    final reconciled = await _accountWrites.writeIfCurrent(
      accountId: scope.accountId,
      authEpoch: scope.authEpoch,
      isCurrent: () => _accountScopeIsCurrent(scope.accountId, scope.authEpoch),
      write: () => _cache.setPaperSaved(scope, saved),
    );
    if (!reconciled) throw _visualAssetScopeChanged;
  }

  Future<void> _pinAsEvidence(VisualAssetRequest request) async {
    await _setEvidencePin(request, true);
  }

  Future<void> _setEvidencePin(VisualAssetRequest request, bool enabled) async {
    final pinned = await _accountWrites.writeIfCurrent(
      accountId: request.accountId,
      authEpoch: request.authEpoch,
      isCurrent: () => _isCurrent(request),
      write: () => _cache.setPersistentPin(
        request,
        VisualAssetPersistentPin.evidence,
        enabled,
      ),
    );
    if (!pinned) throw _visualAssetScopeChanged;
  }

  bool _isCurrent(VisualAssetRequest request) =>
      _accountScopeIsCurrent(request.accountId, request.authEpoch);
}

const _visualAssetScopeChanged = ApiException(
  code: 'REQUEST_CANCELLED',
  message: 'The account context changed before the figure could be loaded.',
  retryable: false,
);

enum _CacheRetention { unpinned, saved, evidence, runtime }

final class _CacheFile {
  const _CacheFile({
    required this.file,
    required this.size,
    required this.lastAccessedAt,
    required this.retention,
  });

  final File file;
  final int size;
  final DateTime lastAccessedAt;
  final _CacheRetention retention;
}

Future<VisualAssetPayload> _readBoundedAsset(
  Response<ResponseBody> response, {
  required VisualAssetRequest request,
  required CancelToken cancelToken,
}) async {
  final body = response.data;
  if (body == null) throw const FormatException('Missing asset body.');
  final contentTypeValues = response.headers[Headers.contentTypeHeader];
  final contentType = contentTypeValues?.length == 1
      ? contentTypeValues!.single.split(';').first.trim().toLowerCase()
      : null;
  if (contentType == null || !_supportedRasterType(contentType)) {
    throw const FormatException('Unsupported asset media type.');
  }
  final generationValues = response.headers['x-pakperk-document-generation'];
  final generation = generationValues?.length == 1
      ? int.tryParse(generationValues!.single.trim())
      : null;
  if (generation != request.generation) {
    throw const FormatException('Stale asset generation.');
  }
  final variantValues = response.headers['x-pakperk-image-variant'];
  final variant = variantValues?.length == 1
      ? variantValues!.single.trim().toLowerCase()
      : null;
  if (variant != request.variant.name) {
    throw const FormatException('Unexpected asset variant.');
  }
  final revisionValues = response.headers['x-pakperk-image-revision'];
  final revision = revisionValues?.length == 1
      ? revisionValues!.single.trim().toLowerCase()
      : null;
  if (revision != request.revision) {
    throw const FormatException('Unexpected asset revision.');
  }
  final checksumValues = response.headers['x-content-sha256'];
  final checksum = checksumValues?.length == 1
      ? checksumValues!.single.trim().toLowerCase()
      : null;
  if (checksum == null || !_sha256Pattern.hasMatch(checksum)) {
    throw const FormatException('Missing asset checksum.');
  }
  final declaredLengths = response.headers[Headers.contentLengthHeader];
  if (declaredLengths != null) {
    final length = declaredLengths.length == 1
        ? int.tryParse(declaredLengths.single.trim())
        : null;
    if (length == null || length <= 0 || length > maximumVisualAssetBytes) {
      throw const FormatException('Invalid asset size.');
    }
  }
  final bytes = BytesBuilder(copy: false);
  final iterator = StreamIterator<Uint8List>(body.stream);
  var complete = false;
  try {
    while (await iterator.moveNext()) {
      final chunk = iterator.current;
      if (bytes.length + chunk.length > maximumVisualAssetBytes) {
        throw const FormatException('Asset exceeds byte limit.');
      }
      bytes.add(chunk);
    }
    complete = true;
    final payload = VisualAssetPayload(
      bytes: bytes.takeBytes(),
      contentType: contentType,
      checksum: checksum,
    );
    final widthValues = response.headers['x-pakperk-image-width'];
    final heightValues = response.headers['x-pakperk-image-height'];
    final declaredWidth = widthValues?.length == 1
        ? int.tryParse(widthValues!.single.trim())
        : null;
    final declaredHeight = heightValues?.length == 1
        ? int.tryParse(heightValues!.single.trim())
        : null;
    if (declaredWidth != payload.width ||
        declaredHeight != payload.height ||
        !_payloadMatchesRequest(payload, request)) {
      throw const FormatException('Asset dimensions do not match metadata.');
    }
    return payload;
  } finally {
    if (!complete && !cancelToken.isCancelled) {
      cancelToken.cancel('bounded visual asset response rejected');
      await Future<void>.delayed(Duration.zero);
    }
    await iterator.cancel();
  }
}

bool _payloadMatchesRequest(
  VisualAssetPayload payload,
  VisualAssetRequest request,
) {
  if (request.variant == VisualAssetVariant.large) {
    return payload.width == request.width && payload.height == request.height;
  }
  final maximumWidth = switch (request.variant) {
    VisualAssetVariant.small => 480,
    VisualAssetVariant.medium => 960,
    VisualAssetVariant.large => request.width,
  };
  if (payload.width <= 0 ||
      payload.height <= 0 ||
      payload.width > request.width ||
      payload.height > request.height ||
      payload.width > maximumWidth) {
    return false;
  }
  final aspectDelta =
      (payload.width * request.height - payload.height * request.width).abs();
  final roundingTolerance = request.width > request.height
      ? request.width
      : request.height;
  return aspectDelta <= roundingTolerance;
}

Future<Uint8List> _readBoundedFile(File file, int maximumBytes) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw const FormatException('Cached visual asset exceeds byte limit.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<bool> _containsAsset(Directory directory) async {
  if (!await directory.exists()) return false;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File && entity.path.endsWith('.asset')) return true;
  }
  return false;
}

Future<void> _writeScopeIdentity(Directory directory, String paperKey) async {
  final marker = File('${directory.path}/.paper-$paperKey');
  if (!await marker.exists()) await marker.writeAsBytes(const []);
}

Future<void> _removeScope(Directory directory) async {
  if (await directory.exists()) await directory.delete(recursive: true);
}

Future<int> _assetCount(Directory directory) async {
  var count = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && entity.path.endsWith('.asset')) count++;
  }
  return count;
}

String _assetChecksumFromPath(String path) {
  final name = path.split(Platform.pathSeparator).last;
  if (!name.endsWith('.asset')) {
    throw const FormatException('Invalid cache entry.');
  }
  final checksum = name.substring(0, name.length - '.asset'.length);
  if (!_sha256Pattern.hasMatch(checksum)) {
    throw const FormatException('Invalid cache checksum.');
  }
  return checksum;
}

bool _supportedRasterType(String value) => value == 'image/png';

String? _rasterContentType(List<int> bytes) {
  if (_pngDimensions(bytes) != null) {
    return 'image/png';
  }
  return null;
}

_RasterDimensions? _rasterDimensions(List<int> bytes, String contentType) =>
    contentType == 'image/png' ? _pngDimensions(bytes) : null;

_RasterDimensions? _pngDimensions(List<int> bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a &&
      _uint32BigEndian(bytes, 8) == 13 &&
      bytes[12] == 0x49 &&
      bytes[13] == 0x48 &&
      bytes[14] == 0x44 &&
      bytes[15] == 0x52) {
    final width = _uint32BigEndian(bytes, 16);
    final height = _uint32BigEndian(bytes, 20);
    return _RasterDimensions(width, height);
  }
  return null;
}

int _uint32BigEndian(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

final class _RasterDimensions {
  const _RasterDimensions(this.width, this.height);

  final int width;
  final int height;
}

String _hexSha256(List<int> bytes) => sha256.convert(bytes).toString();
