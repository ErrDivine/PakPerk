import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

void main() {
  test('online OIDC scopes do not request an offline provider session', () {
    final configuration = OidcClientConfiguration(
      issuer: Uri.parse('https://identity.example.test/realms/pakperk'),
      clientId: 'pakperk-mobile',
      redirectUri: Uri.parse('pakperk-auth://oauth/callback'),
      postLogoutRedirectUri: Uri.parse('pakperk-auth://oauth/logout'),
      scopes: const ['openid', 'profile'],
    );

    expect(configuration.scopes, ['openid', 'profile']);
    expect(configuration.scopes, isNot(contains('offline_access')));
  });

  test('registered private-use callbacks are matched exactly', () {
    OidcClientConfiguration build(String callback) => OidcClientConfiguration(
      issuer: Uri.parse('https://identity.example.test/realms/pakperk'),
      clientId: 'pakperk-mobile',
      redirectUri: Uri.parse(callback),
      postLogoutRedirectUri: Uri.parse('pakperk-auth://oauth/logout'),
      scopes: const ['openid', 'profile'],
    );

    expect(() => build('pakperk-auth://oauth/callback'), returnsNormally);
    expect(
      () => build('pakperk-auth://attacker/callback'),
      throwsArgumentError,
    );
    expect(
      () => build('pakperk-auth://oauth:1234/callback'),
      throwsArgumentError,
    );
    expect(
      () => build('pakperk-auth://oauth/callback?code=embedded'),
      throwsArgumentError,
    );
    expect(() => build('pakperk-auth://oauth/wrong-path'), throwsArgumentError);
  });
}
