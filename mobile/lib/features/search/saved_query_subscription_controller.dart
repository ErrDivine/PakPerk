import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/engagement/engagement_api.dart';
import '../../core/engagement/engagement_models.dart';
import 'research_search_models.dart';

enum SavedQuerySubscriptionPhase { idle, subscribing, subscribed, failed }

/// Owns the authenticated, idempotent handoff from one saved search to one
/// discovery subscription.
///
/// Retry identities are keyed only by the canonical saved-search UUID. They
/// remain stable after a failed attempt, but are cleared synchronously when
/// the verified account scope changes.
final class SavedQuerySubscriptionController extends ChangeNotifier {
  SavedQuerySubscriptionController({
    required EngagementRemoteDataSource remote,
    required ResearchSearchAccountScope? accountScope,
    required this.enabled,
    String Function()? createUuid,
  }) : _remote = remote,
       _scope = accountScope,
       _createUuid = createUuid ?? _uuidV7;

  final EngagementRemoteDataSource _remote;
  final bool enabled;
  final String Function() _createUuid;
  final Map<String, String> _operationIds = {};
  final Map<String, String> _subscriptionIds = {};
  final Map<String, SavedQuerySubscriptionPhase> _phases = {};

  ResearchSearchAccountScope? _scope;
  RequestCancellation? _request;
  var _generation = 0;
  var _disposed = false;

  bool get available => enabled && _scope != null;
  bool get busy => _request != null;

  SavedQuerySubscriptionPhase phaseFor(SavedResearchQueryDraft query) {
    final savedSearchId = query.savedSearchId;
    if (savedSearchId == null) return SavedQuerySubscriptionPhase.idle;
    return _phases[savedSearchId] ?? SavedQuerySubscriptionPhase.idle;
  }

  void updateAccountScope(ResearchSearchAccountScope? next) {
    if (_scope == next) return;
    _generation += 1;
    _request?.cancel('The saved-query subscription account scope changed.');
    _request = null;
    _scope = next;
    _operationIds.clear();
    _subscriptionIds.clear();
    _phases.clear();
    _notify();
  }

  /// Drops presentation-only retry state after the saved query and any linked
  /// subscription have been retired atomically by the server.
  void forgetSavedQuery(String savedSearchId) {
    final hadOperation = _operationIds.remove(savedSearchId) != null;
    final hadSubscription = _subscriptionIds.remove(savedSearchId) != null;
    final hadPhase = _phases.remove(savedSearchId) != null;
    if (hadOperation || hadSubscription || hadPhase) _notify();
  }

  Future<void> subscribe(SavedResearchQueryDraft query) async {
    final scope = _scope;
    final savedSearchId = query.savedSearchId;
    if (!enabled ||
        scope == null ||
        savedSearchId == null ||
        _request != null ||
        phaseFor(query) == SavedQuerySubscriptionPhase.subscribed) {
      return;
    }

    final request = RequestCancellation();
    _request = request;
    final generation = ++_generation;
    final operationId = _operationIds.putIfAbsent(savedSearchId, _createUuid);
    final subscriptionId = _subscriptionIds.putIfAbsent(
      savedSearchId,
      _createUuid,
    );
    _phases[savedSearchId] = SavedQuerySubscriptionPhase.subscribing;
    _notify();

    try {
      final subscription = await _remote.createSubscription(
        operationId: operationId,
        id: subscriptionId,
        kind: SubscriptionKind.savedQuery,
        key: savedSearchId,
        label: _boundedSavedQueryLabel(query.query),
        savedSearchId: savedSearchId,
        frequency: SubscriptionFrequency.daily,
        expectedAuthEpoch: scope.authEpoch,
        cancellation: request,
      );
      if (!_isCurrent(scope, generation, request)) return;
      if (subscription.id != subscriptionId ||
          subscription.kind != SubscriptionKind.savedQuery ||
          subscription.key != savedSearchId ||
          subscription.savedSearchId != savedSearchId ||
          subscription.deleted) {
        throw const FormatException(
          'Saved-query subscription response does not match the request.',
        );
      }
      _operationIds.remove(savedSearchId);
      _subscriptionIds.remove(savedSearchId);
      _phases[savedSearchId] = SavedQuerySubscriptionPhase.subscribed;
      _notify();
    } on ApiException catch (error) {
      if (!_isCurrent(scope, generation, request) || error.cancelled) return;
      _phases[savedSearchId] = SavedQuerySubscriptionPhase.failed;
      _notify();
    } on Object {
      if (!_isCurrent(scope, generation, request)) return;
      _phases[savedSearchId] = SavedQuerySubscriptionPhase.failed;
      _notify();
    } finally {
      if (identical(_request, request)) {
        _request = null;
        _notify();
      }
    }
  }

  bool _isCurrent(
    ResearchSearchAccountScope scope,
    int generation,
    RequestCancellation request,
  ) =>
      !_disposed &&
      !request.isCancelled &&
      _scope == scope &&
      _generation == generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request?.cancel('The saved-query subscription controller closed.');
    _request = null;
    super.dispose();
  }
}

String _boundedSavedQueryLabel(String query) {
  final normalized = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .join(' ');
  if (normalized.isEmpty) return 'Saved research search';
  final buffer = StringBuffer();
  var codeUnits = 0;
  for (final rune in normalized.runes) {
    final character = String.fromCharCode(rune);
    if (codeUnits + character.length > 160) break;
    buffer.write(character);
    codeUnits += character.length;
  }
  return buffer.toString();
}

String _uuidV7() => const Uuid().v7();
