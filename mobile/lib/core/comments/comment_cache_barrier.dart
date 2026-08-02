import 'dart:async';

typedef CommentCacheGuard = bool Function();

/// Coordinates cached comment reads and writes with account-deletion purges.
///
/// Deletion invalidates the current generation synchronously, before it waits
/// for the store or a previously queued write. A write that already reached
/// the database is therefore followed by the purge, while a delayed response
/// from the invalidated generation is rejected. Cached reads and writes stay
/// closed if the purge fails and reopen only after a successful purge.
final class CommentCacheBarrier {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  int? _availableGeneration = 0;

  int captureGeneration() => _generation;

  bool isAvailable({
    required int generation,
    required CommentCacheGuard isCurrent,
  }) =>
      generation == _generation &&
      _availableGeneration == generation &&
      isCurrent();

  Future<bool> writeIfCurrent({
    required int generation,
    required CommentCacheGuard isCurrent,
    required Future<bool> Function() write,
  }) => _serialized(() async {
    if (!isAvailable(generation: generation, isCurrent: isCurrent)) {
      return false;
    }
    final written = await write();
    return written && isAvailable(generation: generation, isCurrent: isCurrent);
  });

  /// Invalidates outstanding operations before returning the purge future.
  Future<void> invalidateAndPurge(Future<void> Function() purge) {
    final purgeGeneration = ++_generation;
    _availableGeneration = null;
    return _serialized(() async {
      await purge();
      if (_generation == purgeGeneration) {
        _availableGeneration = purgeGeneration;
      }
    });
  }

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
