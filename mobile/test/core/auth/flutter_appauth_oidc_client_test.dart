import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

import 'auth_fakes.dart';

void main() {
  test('native Android and iOS network codes remain retryable', () async {
    final cases = <FlutterAppAuthPlatformErrorDetails>[
      FlutterAppAuthPlatformErrorDetails(type: '0', code: '3'),
      FlutterAppAuthPlatformErrorDetails(
        type: 'org.openid.appauth.general',
        code: '-5',
      ),
      FlutterAppAuthPlatformErrorDetails(
        type: 'org.openid.appauth.general',
        code: '-6',
        domain: 'NSURLErrorDomain',
      ),
    ];

    for (final details in cases) {
      final client = FlutterAppAuthOidcClient(
        configuration: testOidcConfiguration,
        appAuth: _FailingAppAuth(details),
      );

      await expectLater(
        client.refresh('durable-refresh'),
        throwsA(
          isA<OidcClientException>().having(
            (failure) => failure.kind,
            'kind',
            OidcClientFailureKind.network,
          ),
        ),
      );
    }
  });

  test('native OAuth invalid_grant codes require reauthentication', () async {
    final cases = <FlutterAppAuthPlatformErrorDetails>[
      FlutterAppAuthPlatformErrorDetails(type: '2', code: '2002'),
      FlutterAppAuthPlatformErrorDetails(
        type: 'org.openid.appauth.oauth_token',
        code: '-10',
      ),
    ];

    for (final details in cases) {
      final client = FlutterAppAuthOidcClient(
        configuration: testOidcConfiguration,
        appAuth: _FailingAppAuth(details),
      );

      await expectLater(
        client.refresh('revoked-refresh'),
        throwsA(
          isA<OidcClientException>().having(
            (failure) => failure.kind,
            'kind',
            OidcClientFailureKind.invalidGrant,
          ),
        ),
      );
    }
  });

  test('other native AppAuth failures remain provider failures', () async {
    final client = FlutterAppAuthOidcClient(
      configuration: testOidcConfiguration,
      appAuth: _FailingAppAuth(
        FlutterAppAuthPlatformErrorDetails(type: '0', code: '4'),
      ),
    );

    await expectLater(
      client.refresh('durable-refresh'),
      throwsA(
        isA<OidcClientException>().having(
          (failure) => failure.kind,
          'kind',
          OidcClientFailureKind.provider,
        ),
      ),
    );
  });
}

final class _FailingAppAuth extends FlutterAppAuth {
  const _FailingAppAuth(this.details);

  final FlutterAppAuthPlatformErrorDetails details;

  @override
  Future<TokenResponse> token(TokenRequest request) async {
    throw FlutterAppAuthPlatformException(
      code: 'token_failed',
      platformErrorDetails: details,
    );
  }
}
