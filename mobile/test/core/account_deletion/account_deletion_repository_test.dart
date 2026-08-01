import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account_deletion/account_deletion.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';

import '../auth/auth_fakes.dart';

const accountId = '00000000-0000-4000-8000-000000000123';
const otherAccountId = '00000000-0000-4000-8000-000000000456';
const operationId = '00000000-0000-4000-8000-000000000789';
const requestId = '00000000-0000-4000-8000-000000000999';

void main() {
  group('AccountDeletionRepository', () {
    test(
      'writes the process-death guard before DELETE and accepts 202',
      () async {
        final harness = await _Harness.create();
        harness.remote.deleteHandler = () async {
          expect(
            harness.guard.record?.acceptance,
            LocalAccountDeletionAcceptance.inFlight,
          );
          expect(harness.guard.record?.localCleanupComplete, isFalse);
          return _operation();
        };

        final result = await harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.accepted);
        expect(harness.remote.deleteCalls, 1);
        expect(harness.cleanupScopes, [accountId]);
        expect(
          harness.guard.record?.acceptance,
          LocalAccountDeletionAcceptance.accepted,
        );
        expect(harness.guard.record?.operationId, operationId);
        expect(harness.guard.record?.accountId, isNull);
        expect(harness.guard.record?.localCleanupComplete, isTrue);
      },
    );

    test(
      'guard write failure prevents DELETE and retains credentials',
      () async {
        final harness = await _Harness.create();
        harness.guard.writeError = StateError('disk full');

        await expectLater(
          harness.repository.request(
            accountId: accountId,
            expectedAuthEpoch: harness.auth.epoch,
          ),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'ACCOUNT_DELETION_LOCAL_GUARD_FAILED',
            ),
          ),
        );

        expect(harness.remote.deleteCalls, 0);
        expect(harness.cleanupScopes, isEmpty);
        expect(harness.tokens.record?.accountId, accountId);
      },
    );

    test('account switch after guard write cancels before dispatch', () async {
      late final _HookGuardStore guard;
      final harness = await _Harness.create(
        guardFactory: (memory) {
          guard = _HookGuardStore(memory);
          return guard;
        },
      );
      guard.afterFirstWrite = () => harness.auth.signOut();

      await expectLater(
        harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.kind,
            'kind',
            AuthFailureKind.superseded,
          ),
        ),
      );

      expect(harness.remote.deleteCalls, 0);
      expect(harness.guard.record, isNull);
    });

    test('same-account verification prevents cross-account deletion', () async {
      final harness = await _Harness.create();
      harness.remote.recentVerifyHandler = () async =>
          _verification(otherAccountId);

      await expectLater(
        harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        ),
        throwsA(isA<AccountDeletionIdentityMismatch>()),
      );

      expect(harness.remote.deleteCalls, 0);
      expect(harness.guard.record, isNull);
      expect(harness.cleanupScopes, isEmpty);
    });

    for (final status in [
      AccountDeletionVerificationStatus.deletionPending,
      AccountDeletionVerificationStatus.deleted,
    ]) {
      test(
        'mismatched normal ${status.wireValue} identity is not accepted',
        () async {
          final harness = await _Harness.create();
          harness.remote.normalVerifyHandler = () async => _verification(
            otherAccountId,
            status: status,
            deletionOperationId:
                status == AccountDeletionVerificationStatus.deletionPending
                ? operationId
                : null,
          );

          await expectLater(
            harness.repository.request(
              accountId: accountId,
              expectedAuthEpoch: harness.auth.epoch,
            ),
            throwsA(isA<AccountDeletionIdentityMismatch>()),
          );

          expect(harness.remote.recentVerifyCalls, 0);
          expect(harness.remote.deleteCalls, 0);
          expect(harness.guard.record, isNull);
          expect(harness.cleanupScopes, isEmpty);
          expect(harness.tokens.record?.accountId, accountId);
        },
      );

      test(
        'mismatched recent ${status.wireValue} identity is not accepted',
        () async {
          final harness = await _Harness.create();
          harness.remote.recentVerifyHandler = () async => _verification(
            otherAccountId,
            status: status,
            deletionOperationId:
                status == AccountDeletionVerificationStatus.deletionPending
                ? operationId
                : null,
          );

          await expectLater(
            harness.repository.request(
              accountId: accountId,
              expectedAuthEpoch: harness.auth.epoch,
            ),
            throwsA(isA<AccountDeletionIdentityMismatch>()),
          );

          expect(harness.remote.recentVerifyCalls, 1);
          expect(harness.remote.deleteCalls, 0);
          expect(harness.guard.record, isNull);
          expect(harness.cleanupScopes, isEmpty);
          expect(harness.tokens.record?.accountId, accountId);
        },
      );

      test(
        'superseded normal ${status.wireValue} response is not accepted',
        () async {
          final harness = await _Harness.create();
          harness.remote.normalVerifyHandler = () async {
            await harness.auth.signOut();
            return _verification(
              accountId,
              status: status,
              deletionOperationId:
                  status == AccountDeletionVerificationStatus.deletionPending
                  ? operationId
                  : null,
            );
          };

          await expectLater(
            harness.repository.request(
              accountId: accountId,
              expectedAuthEpoch: harness.auth.epoch,
            ),
            throwsA(
              isA<AuthFailure>().having(
                (failure) => failure.kind,
                'kind',
                AuthFailureKind.superseded,
              ),
            ),
          );

          expect(harness.remote.recentVerifyCalls, 0);
          expect(harness.remote.deleteCalls, 0);
          expect(harness.guard.record, isNull);
          expect(harness.cleanupScopes, isEmpty);
        },
      );

      test(
        'superseded recent ${status.wireValue} response is not accepted',
        () async {
          final harness = await _Harness.create();
          harness.remote.recentVerifyHandler = () async {
            await harness.auth.signOut();
            return _verification(
              accountId,
              status: status,
              deletionOperationId:
                  status == AccountDeletionVerificationStatus.deletionPending
                  ? operationId
                  : null,
            );
          };

          await expectLater(
            harness.repository.request(
              accountId: accountId,
              expectedAuthEpoch: harness.auth.epoch,
            ),
            throwsA(
              isA<AuthFailure>().having(
                (failure) => failure.kind,
                'kind',
                AuthFailureKind.superseded,
              ),
            ),
          );

          expect(harness.remote.recentVerifyCalls, 1);
          expect(harness.remote.deleteCalls, 0);
          expect(harness.guard.record, isNull);
          expect(harness.cleanupScopes, isEmpty);
        },
      );
    }

    test('suspended account remains eligible for deletion', () async {
      final harness = await _Harness.create();
      harness.remote.normalVerifyHandler = () async => _verification(
        accountId,
        status: AccountDeletionVerificationStatus.suspended,
      );
      harness.remote.recentVerifyHandler = () async => _verification(
        accountId,
        status: AccountDeletionVerificationStatus.suspended,
      );

      final result = await harness.repository.request(
        accountId: accountId,
        expectedAuthEpoch: harness.auth.epoch,
      );

      expect(result.acceptance, AccountDeletionAcceptance.accepted);
      expect(harness.remote.deleteCalls, 1);
    });

    test(
      'process death before account binding can delete a suspended account',
      () async {
        final harness = await _Harness.create(boundAccountId: null);
        harness.remote.normalVerifyHandler = () async => _verification(
          accountId,
          status: AccountDeletionVerificationStatus.suspended,
        );
        harness.remote.recentVerifyHandler = () async => _verification(
          accountId,
          status: AccountDeletionVerificationStatus.suspended,
        );

        final result = await harness.repository.request(
          accountId: null,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.accepted);
        expect(harness.remote.normalVerifyCalls, 1);
        expect(harness.remote.recentVerifyCalls, 1);
        expect(harness.remote.deleteCalls, 1);
        expect(harness.cleanupScopes, [accountId]);
      },
    );

    test('existing deletion ledger fails closed without recent auth', () async {
      final harness = await _Harness.create();
      harness.remote.normalVerifyHandler = () async => _verification(
        accountId,
        status: AccountDeletionVerificationStatus.deletionPending,
        deletionOperationId: operationId,
      );

      final result = await harness.repository.request(
        accountId: accountId,
        expectedAuthEpoch: harness.auth.epoch,
      );

      expect(result.acceptance, AccountDeletionAcceptance.serviceUnavailable);
      expect(harness.remote.recentVerifyCalls, 0);
      expect(harness.remote.deleteCalls, 0);
      expect(harness.cleanupScopes, [accountId]);
      expect(harness.guard.record?.localCleanupComplete, isTrue);
    });

    test(
      'stale deleted account row is also a fail-closed pending signal',
      () async {
        final harness = await _Harness.create();
        harness.remote.normalVerifyHandler = () async => _verification(
          accountId,
          status: AccountDeletionVerificationStatus.deleted,
        );

        final result = await harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.serviceUnavailable);
        expect(harness.remote.recentVerifyCalls, 0);
        expect(harness.remote.deleteCalls, 0);
        expect(harness.tokens.record, isNull);
      },
    );

    test(
      '503 fails closed and preserves only request ID for support',
      () async {
        final harness = await _Harness.create();
        harness.remote.deleteHandler = () async => throw const ApiException(
          code: 'ACCOUNT_DELETION_UNAVAILABLE',
          message: 'unavailable',
          retryable: true,
          statusCode: 503,
          requestId: requestId,
        );

        final result = await harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.serviceUnavailable);
        expect(result.requestId, requestId);
        expect(harness.guard.record?.requestId, requestId);
        expect(harness.guard.record?.operationId, isNull);
        expect(harness.guard.record?.accountId, isNull);
        expect(harness.guard.record?.localCleanupComplete, isTrue);
        expect(harness.cleanupScopes, [accountId]);
      },
    );

    test('timeout after server commit is ambiguous and fails closed', () async {
      final harness = await _Harness.create();
      harness.remote.deleteHandler = () async => throw const ApiException(
        code: 'NETWORK_TIMEOUT',
        message: 'timeout',
        retryable: true,
      );

      final result = await harness.repository.request(
        accountId: accountId,
        expectedAuthEpoch: harness.auth.epoch,
      );

      expect(result.acceptance, AccountDeletionAcceptance.ambiguous);
      expect(harness.guard.record?.localCleanupComplete, isTrue);
      expect(harness.tokens.record, isNull);
      expect(harness.cleanupScopes, [accountId]);
    });

    test(
      'generic 503 after dispatch remains ambiguous and fails closed',
      () async {
        final harness = await _Harness.create();
        harness.remote.deleteHandler = () async => throw const ApiException(
          code: 'SERVICE_UNAVAILABLE',
          message: 'commit boundary unknown',
          retryable: true,
          statusCode: 503,
        );

        final result = await harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.ambiguous);
        expect(harness.guard.record?.localCleanupComplete, isTrue);
        expect(harness.tokens.record, isNull);
        expect(harness.cleanupScopes, [accountId]);
      },
    );

    test(
      'process death after dispatch can replay credential-free cleanup',
      () async {
        final response = Completer<AccountDeletionOperation>();
        final harness = await _Harness.create();
        harness.remote.deleteHandler = () => response.future;
        final request = harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );
        await harness.remote.deleteStarted.future;

        expect(
          harness.guard.record?.acceptance,
          LocalAccountDeletionAcceptance.inFlight,
        );
        final restartedCleanupScopes = <String?>[];
        final restarted = AccountDeletionRepository(
          auth: harness.auth,
          remote: _FakeRemote(),
          guardStore: harness.guard,
          finalizeLocalDeletion: (scope) async {
            restartedCleanupScopes.add(scope);
            return true;
          },
          telemetry: const NoopTelemetrySink(),
        );

        final recovered = await restarted.recoverLocalCleanup();

        expect(restartedCleanupScopes, [accountId]);
        expect(recovered?.localCleanupComplete, isTrue);
        response.completeError(
          const ApiException(
            code: 'NETWORK_TIMEOUT',
            message: 'lost response',
            retryable: true,
          ),
        );
        expect((await request).acceptance, AccountDeletionAcceptance.ambiguous);
      },
    );

    test(
      'cleanup failure retains an incomplete guard for startup retry',
      () async {
        final harness = await _Harness.create(cleanupSucceeds: false);

        final result = await harness.repository.request(
          accountId: accountId,
          expectedAuthEpoch: harness.auth.epoch,
        );

        expect(result.acceptance, AccountDeletionAcceptance.accepted);
        expect(harness.guard.record?.localCleanupComplete, isFalse);
        expect(harness.guard.record?.accountId, accountId);
      },
    );

    test('exact pre-commit rejection clears guard without cleanup', () async {
      const rejections = <ApiException>[
        ApiException(
          code: 'INVALID_REQUEST',
          message: 'invalid request',
          statusCode: 400,
          requestId: requestId,
        ),
        ApiException(
          code: 'UNAUTHENTICATED',
          message: 'unauthenticated',
          statusCode: 401,
          requestId: requestId,
        ),
        ApiException(
          code: 'TOKEN_EXPIRED',
          message: 'expired',
          statusCode: 401,
          requestId: requestId,
        ),
        ApiException(
          code: 'REAUTHENTICATION_REQUIRED',
          message: 'reauthenticate',
          statusCode: 401,
          requestId: requestId,
        ),
        ApiException(
          code: 'FEATURE_DISABLED',
          message: 'disabled',
          statusCode: 404,
          requestId: requestId,
        ),
        ApiException(
          code: 'ROUTE_NOT_FOUND',
          message: 'missing',
          statusCode: 404,
          requestId: requestId,
        ),
        ApiException(
          code: 'METHOD_NOT_ALLOWED',
          message: 'not allowed',
          statusCode: 405,
          requestId: requestId,
        ),
        ApiException(
          code: 'REQUEST_BODY_TOO_LARGE',
          message: 'too large',
          statusCode: 413,
          requestId: requestId,
        ),
        ApiException(
          code: 'RATE_LIMITED',
          message: 'rate limited',
          retryable: true,
          statusCode: 429,
          requestId: requestId,
          retryAfter: Duration(seconds: 30),
        ),
        ApiException(
          code: 'AUTHENTICATION_UNAVAILABLE',
          message: 'authentication unavailable',
          retryable: true,
          statusCode: 503,
          requestId: requestId,
          retryAfter: Duration(seconds: 30),
        ),
      ];

      for (final rejection in rejections) {
        final harness = await _Harness.create();
        harness.remote.deleteHandler = () async => throw rejection;

        await expectLater(
          harness.repository.request(
            accountId: accountId,
            expectedAuthEpoch: harness.auth.epoch,
          ),
          throwsA(same(rejection)),
          reason: '${rejection.statusCode} ${rejection.code}',
        );

        expect(harness.guard.record, isNull, reason: rejection.code);
        expect(harness.cleanupScopes, isEmpty, reason: rejection.code);
        expect(
          harness.tokens.record?.accountId,
          accountId,
          reason: rejection.code,
        );
      }
    });

    test(
      'generic and near-miss client errors remain ambiguous after dispatch',
      () async {
        const ambiguousErrors = <ApiException>[
          ApiException(
            code: 'HTTP_ERROR',
            message: 'generic proxy response',
            statusCode: 400,
          ),
          ApiException(
            code: 'HTTP_ERROR',
            message: 'generic proxy response',
            statusCode: 401,
          ),
          ApiException(
            code: 'ACCOUNT_SUSPENDED',
            message: 'unexpected handler contract',
            statusCode: 403,
            requestId: requestId,
          ),
          ApiException(
            code: 'HTTP_ERROR',
            message: 'generic proxy response',
            statusCode: 404,
          ),
          ApiException(
            code: 'INVALID_REQUEST',
            message: 'wrong status for code',
            statusCode: 422,
            requestId: requestId,
          ),
          ApiException(
            code: 'RATE_LIMITED',
            message: 'missing request ID and retry-after',
            retryable: true,
            statusCode: 429,
          ),
          ApiException(
            code: 'SERVICE_UNAVAILABLE',
            message: 'commit boundary unknown',
            retryable: true,
            statusCode: 503,
            requestId: requestId,
            retryAfter: Duration(seconds: 30),
          ),
        ];

        for (final ambiguousError in ambiguousErrors) {
          final harness = await _Harness.create();
          harness.remote.deleteHandler = () async => throw ambiguousError;

          final result = await harness.repository.request(
            accountId: accountId,
            expectedAuthEpoch: harness.auth.epoch,
          );

          expect(
            result.acceptance,
            AccountDeletionAcceptance.ambiguous,
            reason: '${ambiguousError.statusCode} ${ambiguousError.code}',
          );
          expect(
            harness.guard.record?.localCleanupComplete,
            isTrue,
            reason: ambiguousError.code,
          );
          expect(harness.tokens.record, isNull, reason: ambiguousError.code);
          expect(harness.cleanupScopes, [accountId]);
        }
      },
    );

    test('unbound global pending response clears all private rows', () async {
      final harness = await _Harness.create();

      final record = await harness.repository.handleServerDeletionPending(
        accountId: null,
        requestId: requestId,
      );

      expect(harness.cleanupScopes, [null]);
      expect(record?.accountId, isNull);
      expect(record?.requestId, requestId);
      expect(record?.localCleanupComplete, isTrue);
    });
  });
}

final class _Harness {
  _Harness({
    required this.auth,
    required this.tokens,
    required this.remote,
    required this.guard,
    required this.repository,
    required this.cleanupScopes,
  });

  static Future<_Harness> create({
    bool cleanupSucceeds = true,
    String? boundAccountId = accountId,
    AccountDeletionGuardStore Function(MemoryAccountDeletionGuardStore)?
    guardFactory,
  }) async {
    final oidc = FakeOidcClient()
      ..reauthenticateHandler = () async => tokenSet(
        accessToken: 'one-use-recent-bearer',
        refreshToken: null,
        idToken: null,
      );
    final tokens = MemorySecureTokenStore(
      storedRecord(accountId: boundAccountId),
    );
    final auth = AuthRepository(
      configuration: testOidcConfiguration,
      oidcClient: oidc,
      secureTokenStore: tokens,
      clock: () => DateTime.utc(2029, 1, 1),
    );
    await auth.inspectStoredSession();
    final remote = _FakeRemote();
    final memoryGuard = MemoryAccountDeletionGuardStore();
    final guardStore = guardFactory?.call(memoryGuard) ?? memoryGuard;
    final cleanupScopes = <String?>[];
    final repository = AccountDeletionRepository(
      auth: auth,
      remote: remote,
      guardStore: guardStore,
      finalizeLocalDeletion: (scope) async {
        cleanupScopes.add(scope);
        if (cleanupSucceeds) await auth.invalidateForAccountDeletion();
        return cleanupSucceeds;
      },
      telemetry: const NoopTelemetrySink(),
      clock: () => DateTime.utc(2029, 1, 1),
    );
    return _Harness(
      auth: auth,
      tokens: tokens,
      remote: remote,
      guard: memoryGuard,
      repository: repository,
      cleanupScopes: cleanupScopes,
    );
  }

  final AuthRepository auth;
  final MemorySecureTokenStore tokens;
  final _FakeRemote remote;
  final MemoryAccountDeletionGuardStore guard;
  final AccountDeletionRepository repository;
  final List<String?> cleanupScopes;
}

final class _FakeRemote implements AccountDeletionRemoteDataSource {
  Future<AccountDeletionVerification> Function()? normalVerifyHandler;
  Future<AccountDeletionVerification> Function()? recentVerifyHandler;
  Future<AccountDeletionOperation> Function()? deleteHandler;
  int normalVerifyCalls = 0;
  int recentVerifyCalls = 0;
  int deleteCalls = 0;
  final Completer<void> deleteStarted = Completer<void>();

  @override
  Future<AccountDeletionVerification> verifyCurrentSession({
    required int expectedAuthEpoch,
  }) async {
    normalVerifyCalls += 1;
    return normalVerifyHandler?.call() ?? _verification(accountId);
  }

  @override
  Future<AccountDeletionVerification> verifyRecentSession({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) async {
    recentVerifyCalls += 1;
    expect(recentBearer, 'one-use-recent-bearer');
    return recentVerifyHandler?.call() ?? _verification(accountId);
  }

  @override
  Future<AccountDeletionOperation> deleteCurrentAccount({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) {
    deleteCalls += 1;
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    expect(recentBearer, 'one-use-recent-bearer');
    return deleteHandler?.call() ?? Future.value(_operation());
  }
}

final class _HookGuardStore implements AccountDeletionGuardStore {
  _HookGuardStore(this.delegate);

  final MemoryAccountDeletionGuardStore delegate;
  Future<void> Function()? afterFirstWrite;
  var _wrote = false;

  AccountDeletionGuardRecord? get record => delegate.record;

  @override
  Future<AccountDeletionGuardRecord?> read() => delegate.read();

  @override
  Future<void> write(AccountDeletionGuardRecord record) async {
    await delegate.write(record);
    if (!_wrote) {
      _wrote = true;
      await afterFirstWrite?.call();
    }
  }

  @override
  Future<void> clearAfterCompletedCleanup() =>
      delegate.clearAfterCompletedCleanup();

  @override
  Future<void> clearInFlight() => delegate.clearInFlight();
}

AccountDeletionVerification _verification(
  String id, {
  AccountDeletionVerificationStatus status =
      AccountDeletionVerificationStatus.active,
  String? deletionOperationId,
}) => AccountDeletionVerification(
  accountId: id,
  status: status,
  deletionOperationId: deletionOperationId,
);

AccountDeletionOperation _operation() => AccountDeletionOperation(
  operationId: operationId,
  state: AccountDeletionServerState.requested,
  requestedAt: DateTime.utc(2029, 1, 1),
  updatedAt: DateTime.utc(2029, 1, 1),
);
