import 'dart:convert';

import 'auth_config.dart';

const _secureAuthRecordVersion = 1;
const _maximumTokenLength = 64 * 1024;

/// The only durable auth payload permitted by the mobile auth layer.
///
/// Access tokens, authorization codes, PKCE verifiers, identity subjects, and
/// profile data are intentionally absent.
final class SecureAuthRecord {
  SecureAuthRecord({
    required this.issuer,
    required this.clientId,
    required this.refreshToken,
    this.idTokenHint,
    this.accountId,
  }) {
    if (!_isValidIssuer(issuer) ||
        clientId.isEmpty ||
        clientId.length > 256 ||
        refreshToken.isEmpty ||
        refreshToken.length > _maximumTokenLength ||
        (idTokenHint?.length ?? 0) > _maximumTokenLength ||
        !_isValidAccountId(accountId)) {
      throw ArgumentError('Invalid secure authentication record.');
    }
  }

  final String issuer;
  final String clientId;
  final String refreshToken;
  final String? idTokenHint;
  final String? accountId;

  bool matches(OidcClientConfiguration configuration) =>
      issuer == configuration.issuerBinding &&
      clientId == configuration.clientId;

  SecureAuthRecord copyWith({
    String? refreshToken,
    String? idTokenHint,
    String? accountId,
    bool clearIdTokenHint = false,
    bool clearAccountId = false,
  }) => SecureAuthRecord(
    issuer: issuer,
    clientId: clientId,
    refreshToken: refreshToken ?? this.refreshToken,
    idTokenHint: clearIdTokenHint ? null : idTokenHint ?? this.idTokenHint,
    accountId: clearAccountId ? null : accountId ?? this.accountId,
  );

  Map<String, Object?> toJson() => {
    'version': _secureAuthRecordVersion,
    'issuer': issuer,
    'client_id': clientId,
    'refresh_token': refreshToken,
    if (idTokenHint != null) 'id_token_hint': idTokenHint,
    if (accountId != null) 'account_id': accountId,
  };

  @override
  String toString() =>
      'SecureAuthRecord(issuer: $issuer, clientId: $clientId, '
      'refreshToken: <redacted>, idTokenHint: '
      '${idTokenHint == null ? '<absent>' : '<redacted>'}, '
      'accountId: ${accountId == null ? '<absent>' : '<redacted>'})';
}

abstract interface class SecureTokenStore {
  /// Returns null while a durable local invalidation guard is active, without
  /// exposing any residual platform credential to the caller.
  Future<SecureAuthRecord?> read();

  /// Durably replaces the record, then clears any local invalidation guard.
  Future<void> write(SecureAuthRecord record);

  /// Marks the session invalidated before attempting to delete the record.
  ///
  /// Production implementations must keep that non-secret guard independent
  /// from the token record so a readable but undeletable credential cannot be
  /// restored by a later process.
  Future<void> clear();
}

/// Strict, size-bounded codec shared by the platform store and unit tests.
final class SecureAuthRecordCodec {
  const SecureAuthRecordCodec();

  static const int maximumEncodedLength = 160 * 1024;

  String encode(SecureAuthRecord record) => jsonEncode(record.toJson());

  SecureAuthRecord? decode(String encoded) {
    if (encoded.isEmpty || encoded.length > maximumEncodedLength) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final json = Map<String, Object?>.from(decoded);
      const allowedKeys = {
        'version',
        'issuer',
        'client_id',
        'refresh_token',
        'id_token_hint',
        'account_id',
      };
      if (json.keys.any((key) => !allowedKeys.contains(key)) ||
          json['version'] != _secureAuthRecordVersion ||
          json['issuer'] is! String ||
          json['client_id'] is! String ||
          json['refresh_token'] is! String ||
          (json['id_token_hint'] != null && json['id_token_hint'] is! String) ||
          (json['account_id'] != null && json['account_id'] is! String)) {
        return null;
      }
      return SecureAuthRecord(
        issuer: json['issuer']! as String,
        clientId: json['client_id']! as String,
        refreshToken: json['refresh_token']! as String,
        idTokenHint: json['id_token_hint'] as String?,
        accountId: json['account_id'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

bool _isValidIssuer(String value) {
  if (value.isEmpty || value.length > 2048) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.isAbsolute &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

bool _isValidAccountId(String? value) =>
    value == null ||
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
