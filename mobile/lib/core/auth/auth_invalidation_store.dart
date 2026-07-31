import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret durable guard that prevents a stale secure credential from being
/// restored after local invalidation has begun.
///
/// Implementations must store only the boolean invalidated state. Tokens,
/// account identifiers, provider subjects, and profile data never belong in
/// this store.
abstract interface class AuthInvalidationStore {
  Future<bool> isInvalidated();

  Future<void> markInvalidated();

  Future<void> clearInvalidation();
}

/// Persists the fail-closed guard independently from the platform token key.
///
/// The separate boundary matters when a keychain/keystore record remains
/// readable but temporarily refuses both deletion and replacement.
final class SharedPreferencesAuthInvalidationStore
    implements AuthInvalidationStore {
  const SharedPreferencesAuthInvalidationStore({this.key = defaultKey});

  static const defaultKey = 'pakperk.auth.invalidated.v1';

  final String key;

  @override
  Future<bool> isInvalidated() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(key) ?? false;
  }

  @override
  Future<void> markInvalidated() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(key, true)) {
      throw StateError('Could not persist the auth invalidation guard.');
    }
  }

  @override
  Future<void> clearInvalidation() async {
    final preferences = await SharedPreferences.getInstance();
    if (!preferences.containsKey(key)) return;
    if (!await preferences.remove(key)) {
      throw StateError('Could not clear the auth invalidation guard.');
    }
  }
}
