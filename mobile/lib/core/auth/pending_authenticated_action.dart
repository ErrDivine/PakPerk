import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Marker implemented by feature-owned, immutable authenticated actions.
///
/// Pending actions are held in memory only. They must not contain credentials
/// and disappear on process death by design.
abstract interface class PendingAuthenticatedAction {
  String get actionType;
}

/// A synchronous one-slot handoff used to resume an action after sign-in.
///
/// [take] clears the slot before returning, so re-entrant consumers cannot
/// execute the same action twice.
final class PendingAuthenticatedActionController<
  T extends PendingAuthenticatedAction
>
    extends StateNotifier<T?> {
  PendingAuthenticatedActionController() : super(null);

  void replace(T action) {
    state = action;
  }

  T? take() {
    final pending = state;
    state = null;
    return pending;
  }

  /// Restores a taken action only when no newer user intent has replaced it.
  /// This lets a failed handoff remain retryable without overwriting a newer
  /// action that arrived while the original executor was running.
  void restoreIfEmpty(T action) {
    if (state == null) state = action;
  }

  void clear() {
    state = null;
  }
}
