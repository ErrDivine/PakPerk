import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

import 'auth_fakes.dart';

void main() {
  const codec = SecureAuthRecordCodec();

  test('strict secure record codec round-trips only the allowed payload', () {
    final record = storedRecord(
      refreshToken: 'durable-refresh',
      idTokenHint: 'logout-hint',
      accountId: '00000000-0000-4000-8000-000000000111',
    );

    final encoded = codec.encode(record);
    final decoded = codec.decode(encoded);

    expect(decoded?.issuer, record.issuer);
    expect(decoded?.clientId, record.clientId);
    expect(decoded?.refreshToken, 'durable-refresh');
    expect(decoded?.idTokenHint, 'logout-hint');
    expect(decoded?.accountId, record.accountId);
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>[
        'version',
        'issuer',
        'client_id',
        'refresh_token',
        'id_token_hint',
        'account_id',
      ]),
    );
    expect(json, isNot(contains('access_token')));
    expect(json, isNot(contains('subject')));
    expect(json, isNot(contains('email')));
  });

  test('codec rejects unknown, malformed, oversized, and old records', () {
    expect(codec.decode('not-json'), isNull);
    expect(codec.decode('{"version":0}'), isNull);
    expect(
      codec.decode(
        jsonEncode({
          ...storedRecord().toJson(),
          'access_token': 'must-not-be-accepted',
        }),
      ),
      isNull,
    );
    expect(
      codec.decode('x' * (SecureAuthRecordCodec.maximumEncodedLength + 1)),
      isNull,
    );
    expect(
      codec.decode(
        jsonEncode({...storedRecord().toJson(), 'account_id': 'not-a-uuid'}),
      ),
      isNull,
    );
  });

  test('token-bearing models redact secrets from string output', () {
    const accessSecret = 'very-secret-access';
    const refreshSecret = 'very-secret-refresh';
    const idSecret = 'very-secret-id-token';
    const accountIdentifier = '00000000-0000-4000-8000-000000000222';
    final tokens = tokenSet(
      accessToken: accessSecret,
      refreshToken: refreshSecret,
      idToken: idSecret,
    );
    final credential = AuthAccessCredential(
      value: accessSecret,
      expiresAt: DateTime.utc(2030, 1, 1),
    );
    final record = storedRecord(
      refreshToken: refreshSecret,
      idTokenHint: idSecret,
      accountId: accountIdentifier,
    );
    final state = AuthSessionState.authenticated(
      epoch: 1,
      accountId: accountIdentifier,
    );
    const failure = AuthFailure(
      AuthFailureKind.provider,
      AuthFailureCode.oidcProvider,
    );

    for (final value in [tokens, credential, record, state, failure]) {
      final text = value.toString();
      expect(text, isNot(contains(accessSecret)));
      expect(text, isNot(contains(refreshSecret)));
      expect(text, isNot(contains(idSecret)));
      expect(text, isNot(contains(accountIdentifier)));
    }
  });
}
