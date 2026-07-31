import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_invalidation_store.dart';
import 'secure_token_store.dart';

/// Device-bound encrypted persistence for the refresh credential record.
final class FlutterSecureTokenStore implements SecureTokenStore {
  FlutterSecureTokenStore({
    FlutterSecureStorage? storage,
    AuthInvalidationStore invalidationStore =
        const SharedPreferencesAuthInvalidationStore(),
    SecureAuthRecordCodec codec = const SecureAuthRecordCodec(),
    String key = 'pakperk.auth.record.v1',
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(
               storageNamespace: 'pakperk_auth',
               migrateWithBackup: true,
             ),
             iOptions: IOSOptions(
               accountName: 'pakperk.auth',
               accessibility: KeychainAccessibility.first_unlock_this_device,
               synchronizable: false,
             ),
           ),
       _invalidationStore = invalidationStore,
       _codec = codec,
       _key = key;

  final FlutterSecureStorage _storage;
  final AuthInvalidationStore _invalidationStore;
  final SecureAuthRecordCodec _codec;
  final String _key;

  @override
  Future<SecureAuthRecord?> read() async {
    // Read the independent guard first. A stale platform credential must never
    // be returned after local invalidation has begun, even if the platform key
    // later becomes readable again.
    if (await _invalidationStore.isInvalidated()) return null;
    final encoded = await _storage.read(key: _key);
    if (encoded == null) return null;
    final record = _codec.decode(encoded);
    if (record == null) {
      // Corrupt or legacy-shaped credentials fail closed and are not retried on
      // every launch.
      await clear();
    }
    return record;
  }

  @override
  Future<void> write(SecureAuthRecord record) async {
    // Clear the guard only after the replacement is durable. If clearing the
    // guard fails, future reads remain guest rather than exposing stale state.
    await _storage.write(key: _key, value: _codec.encode(record));
    await _invalidationStore.clearInvalidation();
  }

  @override
  Future<void> clear() async {
    Object? guardFailure;
    try {
      // Persist this before touching the platform key so a crash or a failed
      // delete cannot make the old refresh credential restorable.
      await _invalidationStore.markInvalidated();
    } on Object catch (error) {
      guardFailure = error;
    }

    try {
      await _storage.delete(key: _key);
    } on Object {
      // The repository may next try an atomic non-secret overwrite. If that
      // also fails, a successfully persisted guard remains authoritative.
      rethrow;
    }

    // Deletion itself establishes the invariant, so a guard backend failure
    // does not turn a successful local sign-out into an error.
    if (guardFailure != null) return;
  }
}
