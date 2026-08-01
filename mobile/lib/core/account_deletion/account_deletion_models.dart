enum AccountDeletionServerState {
  requested('requested'),
  sessionsRevoked('sessions_revoked'),
  identityDeleted('identity_deleted'),
  appDataDeleted('app_data_deleted'),
  completed('completed'),
  failedRetryable('failed_retryable'),
  failedTerminal('failed_terminal');

  const AccountDeletionServerState(this.wireValue);

  final String wireValue;

  static AccountDeletionServerState parse(Object? value) => switch (value) {
    'requested' => requested,
    'sessions_revoked' => sessionsRevoked,
    'identity_deleted' => identityDeleted,
    'app_data_deleted' => appDataDeleted,
    'completed' => completed,
    'failed_retryable' => failedRetryable,
    'failed_terminal' => failedTerminal,
    _ => throw const FormatException('Invalid account deletion state.'),
  };
}

enum AccountDeletionVerificationStatus {
  active('active'),
  suspended('suspended'),
  deletionPending('deletion_pending'),
  deleted('deleted');

  const AccountDeletionVerificationStatus(this.wireValue);

  final String wireValue;

  static AccountDeletionVerificationStatus parse(Object? value) =>
      switch (value) {
        'active' => active,
        'suspended' => suspended,
        'deletion_pending' => deletionPending,
        'deleted' => deleted,
        _ => throw const FormatException(
          'Invalid account deletion verification status.',
        ),
      };
}

/// Minimal, deletion-only identity binding returned without JIT provisioning.
///
/// The client deliberately compares the server's opaque internal UUID from a
/// normal bearer with the UUID from the fresh recent-auth bearer. It never
/// parses or trusts a client-side JWT subject.
final class AccountDeletionVerification {
  AccountDeletionVerification({
    required this.accountId,
    required this.status,
    required this.deletionOperationId,
  }) {
    if (!isAccountDeletionUuid(accountId) ||
        (deletionOperationId != null &&
            !isAccountDeletionUuid(deletionOperationId!)) ||
        ((status == AccountDeletionVerificationStatus.deletionPending) !=
                (deletionOperationId != null) ||
            (status != AccountDeletionVerificationStatus.deletionPending &&
                deletionOperationId != null))) {
      throw const FormatException(
        'Invalid account deletion verification identity.',
      );
    }
  }

  factory AccountDeletionVerification.fromJson(Map<String, dynamic> json) {
    const keys = {'id', 'status', 'deletion_operation_id'};
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        json['deletion_operation_id'] is! String? ||
        json['id'] is! String) {
      throw const FormatException(
        'Invalid account deletion verification fields.',
      );
    }
    return AccountDeletionVerification(
      accountId: json['id']! as String,
      status: AccountDeletionVerificationStatus.parse(json['status']),
      deletionOperationId: json['deletion_operation_id'] as String?,
    );
  }

  final String accountId;
  final AccountDeletionVerificationStatus status;
  final String? deletionOperationId;
}

final class AccountDeletionOperation {
  AccountDeletionOperation({
    required this.operationId,
    required this.state,
    required this.requestedAt,
    required this.updatedAt,
  }) {
    if (!isAccountDeletionUuid(operationId) ||
        updatedAt.isBefore(requestedAt)) {
      throw const FormatException('Invalid account deletion operation.');
    }
  }

  factory AccountDeletionOperation.fromJson(Map<String, dynamic> json) {
    const keys = {'operation_id', 'state', 'requested_at', 'updated_at'};
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Invalid account deletion fields.');
    }
    return AccountDeletionOperation(
      operationId: _requiredString(json, 'operation_id'),
      state: AccountDeletionServerState.parse(json['state']),
      requestedAt: _requiredTime(json, 'requested_at'),
      updatedAt: _requiredTime(json, 'updated_at'),
    );
  }

  final String operationId;
  final AccountDeletionServerState state;
  final DateTime requestedAt;
  final DateTime updatedAt;

  @override
  String toString() =>
      'AccountDeletionOperation(state: ${state.wireValue}, '
      'operationId: <redacted>)';
}

enum AccountDeletionAcceptance { accepted, serviceUnavailable, ambiguous }

/// Result surfaced after the mobile session has already failed closed.
///
/// Only a validated 202 or the exact post-commit deletion-unavailable error
/// confirms server ownership. An ambiguous transport/generic-5xx outcome must
/// remain visibly unknown even though local credentials have been cleared.
final class AccountDeletionRequestResult {
  const AccountDeletionRequestResult.accepted(this.operation)
    : acceptance = AccountDeletionAcceptance.accepted,
      requestId = null;

  const AccountDeletionRequestResult.serviceUnavailable({this.requestId})
    : acceptance = AccountDeletionAcceptance.serviceUnavailable,
      operation = null;

  const AccountDeletionRequestResult.ambiguous()
    : acceptance = AccountDeletionAcceptance.ambiguous,
      operation = null,
      requestId = null;

  final AccountDeletionAcceptance acceptance;
  final AccountDeletionOperation? operation;
  final String? requestId;
}

bool isAccountDeletionUuid(String value) =>
    value.length == 36 && _uuid.hasMatch(value);

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 128) {
    throw FormatException('Invalid account deletion field: $key.');
  }
  return value;
}

DateTime _requiredTime(Map<String, dynamic> json, String key) {
  final encoded = _requiredString(json, key);
  if (!_rfc3339Milliseconds.hasMatch(encoded)) {
    throw FormatException('Invalid account deletion field: $key.');
  }
  final parsed = DateTime.tryParse(encoded);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('Invalid account deletion field: $key.');
  }
  return parsed.toUtc();
}

final _rfc3339Milliseconds = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
);
