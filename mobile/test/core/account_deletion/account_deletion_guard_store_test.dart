import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account_deletion/account_deletion.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'corrupt process-death guard fails closed with clear-all cleanup',
    () async {
      SharedPreferences.setMockInitialValues(const {
        SharedPreferencesAccountDeletionGuardStore.defaultKey:
            '{"account_id":"secret-or-corrupt-without-version"}',
      });
      final guard = const SharedPreferencesAccountDeletionGuardStore();
      final auth = AuthRepository(
        configuration: testOidcConfiguration,
        oidcClient: FakeOidcClient(),
        secureTokenStore: MemorySecureTokenStore(),
      );
      final cleanupScopes = <String?>[];
      final repository = AccountDeletionRepository(
        auth: auth,
        remote: const _UnusedRemote(),
        guardStore: guard,
        finalizeLocalDeletion: (scope) async {
          cleanupScopes.add(scope);
          return true;
        },
        telemetry: const NoopTelemetrySink(),
      );

      final recovered = await repository.recoverLocalCleanup();

      expect(cleanupScopes, [null]);
      expect(recovered?.acceptance, LocalAccountDeletionAcceptance.inFlight);
      expect(recovered?.accountId, isNull);
      expect(recovered?.localCleanupComplete, isTrue);
    },
  );
}

final class _UnusedRemote implements AccountDeletionRemoteDataSource {
  const _UnusedRemote();

  @override
  Future<AccountDeletionOperation> deleteCurrentAccount({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) => throw StateError('remote deletion must not run during recovery');

  @override
  Future<AccountDeletionVerification> verifyCurrentSession({
    required int expectedAuthEpoch,
  }) => throw StateError('remote verification must not run during recovery');

  @override
  Future<AccountDeletionVerification> verifyRecentSession({
    required String recentBearer,
    required int expectedAuthEpoch,
  }) => throw StateError('remote verification must not run during recovery');
}
