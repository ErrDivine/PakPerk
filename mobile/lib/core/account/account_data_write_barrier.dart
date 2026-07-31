import 'dart:async';

typedef AccountScopeGuard = bool Function();

/// Serializes account-owned writes with identity cleanup.
///
/// Network work deliberately happens outside this queue. The final local
/// write must enter through [writeIfCurrent], where the exact account and auth
/// epoch are checked again. Cleanup uses the same queue, so either a write
/// finishes first and is deleted, or cleanup finishes first and the stale
/// write is rejected. Epoch ordering also prevents an old cleanup request from
/// deleting rows already owned by a newer session for the same account.
final class AccountDataWriteBarrier {
  Future<void> _tail = Future<void>.value();
  final Map<String, int> _activeEpochs = {};

  Future<bool> activate({
    required String accountId,
    required int authEpoch,
    required AccountScopeGuard isCurrent,
  }) => _serialized(() async {
    if (!isCurrent()) return false;
    final active = _activeEpochs[accountId];
    if (active != null && active > authEpoch) return false;
    _activeEpochs[accountId] = authEpoch;
    return isCurrent();
  });

  Future<bool> writeIfCurrent({
    required String accountId,
    required int authEpoch,
    required AccountScopeGuard isCurrent,
    required Future<void> Function() write,
  }) => _serialized(() async {
    if (!isCurrent()) return false;
    final active = _activeEpochs[accountId];
    if (active != null && active > authEpoch) return false;
    _activeEpochs[accountId] = authEpoch;
    if (!isCurrent()) return false;
    await write();
    return isCurrent();
  });

  Future<void> clear({
    required String? accountId,
    required int invalidatedThroughEpoch,
    required Future<void> Function(String accountId) clearAccount,
    required Future<void> Function() clearAll,
  }) => _serialized(() async {
    if (accountId != null) {
      final active = _activeEpochs[accountId];
      if (active != null && active > invalidatedThroughEpoch) return;
      _activeEpochs.remove(accountId);
      await clearAccount(accountId);
      return;
    }

    // A null identity is the fail-closed "clear every account" path used
    // before interactive sign-in. Never let a delayed invocation erase a
    // newer, already activated session.
    if (_activeEpochs.values.any((epoch) => epoch > invalidatedThroughEpoch)) {
      return;
    }
    _activeEpochs.removeWhere((_, epoch) => epoch <= invalidatedThroughEpoch);
    await clearAll();
  });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
