import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

import 'auth_fakes.dart';

void main() {
  test(
    'independent guard blocks a residual token after delete and write fail',
    () async {
      const codec = SecureAuthRecordCodec();
      final oldRecord = storedRecord(refreshToken: 'revoked-refresh-secret');
      final platformStorage = _FailingSecureStorage(codec.encode(oldRecord))
        ..failDelete = true
        ..failWrite = true;
      final guard = MemoryAuthInvalidationStore();
      final store = FlutterSecureTokenStore(
        storage: platformStorage,
        invalidationStore: guard,
      );

      await expectLater(store.clear(), throwsStateError);
      await expectLater(store.write(storedRecord()), throwsStateError);

      expect(guard.invalidated, isTrue);
      expect(platformStorage.encoded, codec.encode(oldRecord));

      // A new store instance represents a process restart. It consults the
      // independent marker before touching the still-readable token key.
      final restarted = FlutterSecureTokenStore(
        storage: platformStorage,
        invalidationStore: guard,
      );
      expect(await restarted.read(), isNull);
      expect(platformStorage.readCalls, 0);
    },
  );
}

final class _FailingSecureStorage extends FlutterSecureStorage {
  _FailingSecureStorage(this.encoded);

  String? encoded;
  bool failDelete = false;
  bool failWrite = false;
  int readCalls = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCalls += 1;
    return encoded;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrite) throw StateError('injected secure-write failure');
    encoded = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDelete) throw StateError('injected secure-delete failure');
    encoded = null;
  }
}
