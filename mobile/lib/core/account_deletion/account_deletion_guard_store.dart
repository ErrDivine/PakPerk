import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'account_deletion_models.dart';

enum LocalAccountDeletionAcceptance {
  inFlight('in_flight'),
  accepted('accepted'),
  serviceUnavailable('service_unavailable');

  const LocalAccountDeletionAcceptance(this.wireValue);

  final String wireValue;
}

/// Non-secret process-death guard written before credentials are invalidated.
///
/// It contains only internal/random identifiers and state. Bearers, refresh
/// tokens, OIDC subjects, emails, handles, and comment text are prohibited.
final class AccountDeletionGuardRecord {
  AccountDeletionGuardRecord({
    required this.acceptance,
    required this.acceptedAt,
    required this.localCleanupComplete,
    this.accountId,
    this.operationId,
    this.requestId,
    this.serverState,
  }) {
    if ((accountId != null && !isAccountDeletionUuid(accountId!)) ||
        (operationId != null && !isAccountDeletionUuid(operationId!)) ||
        (requestId != null && !isAccountDeletionUuid(requestId!)) ||
        (acceptance == LocalAccountDeletionAcceptance.accepted &&
            (operationId == null || serverState == null)) ||
        (acceptance != LocalAccountDeletionAcceptance.accepted &&
            operationId != null)) {
      throw const FormatException('Invalid local account deletion guard.');
    }
  }

  final LocalAccountDeletionAcceptance acceptance;
  final String? accountId;
  final String? operationId;
  final String? requestId;
  final AccountDeletionServerState? serverState;
  final DateTime acceptedAt;
  final bool localCleanupComplete;

  AccountDeletionGuardRecord cleanupCompleted() => AccountDeletionGuardRecord(
    acceptance: acceptance,
    operationId: operationId,
    requestId: requestId,
    serverState: serverState,
    acceptedAt: acceptedAt,
    localCleanupComplete: true,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'acceptance': acceptance.wireValue,
    if (accountId != null) 'account_id': accountId,
    if (operationId != null) 'operation_id': operationId,
    if (requestId != null) 'request_id': requestId,
    if (serverState != null) 'server_state': serverState!.wireValue,
    'accepted_at': acceptedAt.toUtc().toIso8601String(),
    'local_cleanup_complete': localCleanupComplete,
  };

  @override
  String toString() =>
      'AccountDeletionGuardRecord(acceptance: $acceptance, '
      'serverState: ${serverState?.wireValue}, identifiers: <redacted>, '
      'localCleanupComplete: $localCleanupComplete)';
}

abstract interface class AccountDeletionGuardStore {
  Future<AccountDeletionGuardRecord?> read();

  Future<void> write(AccountDeletionGuardRecord record);

  Future<void> clearAfterCompletedCleanup();

  /// Clears only a pre-dispatch marker after a response that the server
  /// contract guarantees could not have accepted deletion.
  Future<void> clearInFlight();
}

final class SharedPreferencesAccountDeletionGuardStore
    implements AccountDeletionGuardStore {
  const SharedPreferencesAccountDeletionGuardStore({this.key = defaultKey});

  static const defaultKey = 'pakperk.account_deletion.guard.v1';
  static const _maximumEncodedLength = 4096;

  final String key;

  @override
  Future<AccountDeletionGuardRecord?> read() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(key);
      if (encoded == null) return null;
      final record = _decode(encoded);
      if (record != null) return record;

      // A corrupt guard cannot prove which account was active or whether a
      // deletion crossed the network boundary. Best-effort replacement keeps
      // a durable marker, while returning the null-scoped fallback ensures
      // startup still clears every private row if preferences cannot be
      // repaired.
      final fallback = _unboundFailClosedRecord();
      try {
        final encodedFallback = jsonEncode(fallback.toJson());
        await preferences.setString(key, encodedFallback);
      } on Object {
        // The repository will still perform credential and clear-all cleanup.
      }
      return fallback;
    } on Object {
      // Preference reads themselves can fail on a damaged platform channel.
      // Treat that exactly like a corrupt unbound marker; never infer that no
      // deletion is pending.
      return _unboundFailClosedRecord();
    }
  }

  @override
  Future<void> write(AccountDeletionGuardRecord record) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = jsonEncode(record.toJson());
    if (encoded.length > _maximumEncodedLength ||
        !await preferences.setString(key, encoded)) {
      throw StateError('Could not persist the account deletion guard.');
    }
  }

  @override
  Future<void> clearAfterCompletedCleanup() async {
    final current = await read();
    if (current == null) return;
    if (!current.localCleanupComplete) {
      throw StateError('Account deletion cleanup is not complete.');
    }
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.remove(key)) {
      throw StateError('Could not clear the account deletion guard.');
    }
  }

  @override
  Future<void> clearInFlight() async {
    final current = await read();
    if (current == null) return;
    if (current.acceptance != LocalAccountDeletionAcceptance.inFlight) {
      throw StateError('Only an in-flight deletion guard can be cleared.');
    }
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.remove(key)) {
      throw StateError('Could not clear the account deletion guard.');
    }
  }

  AccountDeletionGuardRecord? _decode(String encoded) {
    if (encoded.isEmpty || encoded.length > _maximumEncodedLength) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final json = Map<String, Object?>.from(decoded);
      const keys = {
        'version',
        'acceptance',
        'account_id',
        'operation_id',
        'request_id',
        'server_state',
        'accepted_at',
        'local_cleanup_complete',
      };
      if (json.keys.any((key) => !keys.contains(key)) ||
          json['version'] != 1 ||
          json['accepted_at'] is! String ||
          json['local_cleanup_complete'] is! bool ||
          (json['account_id'] != null && json['account_id'] is! String) ||
          (json['operation_id'] != null && json['operation_id'] is! String) ||
          (json['request_id'] != null && json['request_id'] is! String) ||
          (json['server_state'] != null && json['server_state'] is! String)) {
        return null;
      }
      final acceptance = switch (json['acceptance']) {
        'in_flight' => LocalAccountDeletionAcceptance.inFlight,
        'accepted' => LocalAccountDeletionAcceptance.accepted,
        'service_unavailable' =>
          LocalAccountDeletionAcceptance.serviceUnavailable,
        _ => null,
      };
      final acceptedAt = DateTime.tryParse(json['accepted_at']! as String);
      if (acceptance == null || acceptedAt == null || !acceptedAt.isUtc) {
        return null;
      }
      return AccountDeletionGuardRecord(
        acceptance: acceptance,
        accountId: json['account_id'] as String?,
        operationId: json['operation_id'] as String?,
        requestId: json['request_id'] as String?,
        serverState: json['server_state'] == null
            ? null
            : AccountDeletionServerState.parse(json['server_state']),
        acceptedAt: acceptedAt.toUtc(),
        localCleanupComplete: json['local_cleanup_complete']! as bool,
      );
    } on Object {
      return null;
    }
  }
}

AccountDeletionGuardRecord _unboundFailClosedRecord() =>
    AccountDeletionGuardRecord(
      acceptance: LocalAccountDeletionAcceptance.inFlight,
      acceptedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      localCleanupComplete: false,
    );

final class MemoryAccountDeletionGuardStore
    implements AccountDeletionGuardStore {
  AccountDeletionGuardRecord? record;
  Object? readError;
  Object? writeError;
  Object? clearError;

  @override
  Future<AccountDeletionGuardRecord?> read() async {
    if (readError case final error?) throw error;
    return record;
  }

  @override
  Future<void> write(AccountDeletionGuardRecord value) async {
    if (writeError case final error?) throw error;
    record = value;
  }

  @override
  Future<void> clearAfterCompletedCleanup() async {
    if (clearError case final error?) throw error;
    if (record?.localCleanupComplete != true) {
      throw StateError('Account deletion cleanup is not complete.');
    }
    record = null;
  }

  @override
  Future<void> clearInFlight() async {
    if (clearError case final error?) throw error;
    if (record?.acceptance != LocalAccountDeletionAcceptance.inFlight) {
      throw StateError('Only an in-flight deletion guard can be cleared.');
    }
    record = null;
  }
}
