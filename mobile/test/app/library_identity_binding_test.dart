import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/core/account/account.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/cache/drift_local_store.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/auth/auth_fakes.dart';
import '../support/fakes.dart';

void main() {
  test(
    'cold restore cannot sync a stale account before /v1/me binding',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = PakPerkDatabase(NativeDatabase.memory());
      final store = DriftLocalStore(
        preferences: await SharedPreferences.getInstance(),
        database: database,
      );
      final dao = LibraryDao(
        database,
        clock: () => DateTime.utc(2026, 8, 1, 12),
        operationId: () => _accountAOperation,
      );
      await dao.enqueueMutation(
        accountId: _accountA,
        paperId: samplePaper.paperId,
        saved: true,
        paper: samplePaper,
      );

      final oidc = FakeOidcClient()
        ..refreshHandler = (_) async => tokenSet(
          accessToken: 'account-b-access',
          refreshToken: 'account-b-refresh',
        );
      final tokens = MemorySecureTokenStore(storedRecord(accountId: _accountA));
      final accountAdapter = _BlockingAccountAdapter(accountId: _accountB);
      final libraryRemote = _AccountBLibraryRemote();
      final delegate = _StartupDelegate();
      final container = ProviderContainer(
        overrides: [
          appBuildConfigProvider.overrideWithValue(_accountLibraryConfig()),
          localStoreProvider.overrideWithValue(store),
          initialAnonymousSessionIdProvider.overrideWithValue(
            await store.getOrCreateSessionId(),
          ),
          oidcClientProvider.overrideWithValue(oidc),
          secureTokenStoreProvider.overrideWithValue(tokens),
          libraryApiProvider.overrideWithValue(libraryRemote),
          ...accountApplicationOverrides(delegate),
        ],
      );
      final runtime = container.listen<void>(
        libraryRuntimeProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(() async {
        runtime.close();
        container.dispose();
        await store.close();
      });
      container.read(pakPerkDioProvider).httpClientAdapter = accountAdapter;

      final startup = container.read(startupBootstrapperProvider);
      expect(
        await startup.checkAuthenticatedSession(),
        StartupSessionStatus.refreshRequired,
      );
      expect(
        container.read(libraryDisplayScopeProvider)?.accountId,
        _accountA,
        reason: 'stale local data remains readable until identity is known',
      );
      expect(container.read(verifiedLibraryScopeProvider), isNull);
      expect(libraryRemote.requestCount, 0);

      final postReady = startup.runPostReadyWork();
      await accountAdapter.started.future;

      expect(
        container.read(authSessionProvider).phase,
        AuthSessionPhase.authenticated,
      );
      expect(container.read(authSessionProvider).accountId, _accountA);
      expect(
        container.read(currentAccountProvider).phase,
        CurrentAccountPhase.loading,
      );
      expect(container.read(verifiedLibraryScopeProvider), isNull);
      expect(libraryRemote.requestCount, 0);
      final staleOutbox = await database
          .select(database.syncOutbox)
          .getSingle();
      expect(staleOutbox.accountId, _accountA);
      expect(staleOutbox.operationId, _accountAOperation);
      expect(staleOutbox.state, 'queued');
      expect(staleOutbox.attemptCount, 0);

      accountAdapter.release.complete();
      await postReady;
      // Riverpod delivers the derived verified-scope notification after the
      // account controller's state publication completes.
      await Future<void>.delayed(Duration.zero);
      await container.read(librarySyncControllerProvider.notifier).refresh();

      expect(tokens.record?.accountId, _accountB);
      expect(container.read(authSessionProvider).accountId, _accountB);
      expect(container.read(currentAccountProvider).profile?.id, _accountB);
      expect(
        container.read(currentAccountProvider).verifiedAuthEpoch,
        container.read(authSessionProvider).epoch,
      );
      expect(
        container.read(verifiedLibraryScopeProvider)?.accountId,
        _accountB,
      );
      expect(
        libraryRemote.mutationOperationIds,
        isEmpty,
        reason: 'account A outbox work must never be sent with B credentials',
      );
      expect(libraryRemote.listCalls, greaterThanOrEqualTo(1));
      expect(libraryRemote.changesCalls, greaterThanOrEqualTo(1));

      expect(await database.select(database.syncOutbox).get(), isEmpty);
      final syncStates = await database
          .select(database.librarySyncStates)
          .get();
      expect(syncStates, hasLength(1));
      expect(syncStates.single.accountId, _accountB);
      final rows = await database.select(database.libraryItems).get();
      expect(rows, hasLength(1));
      expect(rows.single.accountId, _accountB);
      expect(rows.single.paperId, _accountBPaper.paperId);
      expect(
        rows.where((row) => row.accountId == _accountA),
        isEmpty,
        reason: 'B responses must never be committed beneath the stale A key',
      );
      expect(
        await store.loadPaper(samplePaper.paperId),
        isNotNull,
        reason: 'identity cleanup preserves public paper metadata',
      );
    },
  );
}

const _accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
const _accountAOperation = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _accountBOperation = '018f47a6-4b56-7f4c-8c7a-e2656e820302';

final _accountBPaper = PaperSummary(
  paperId: '27060376-2000-4000-8000-000000000002',
  arxivId: '2607.00001v1',
  title: 'A paper saved by account B',
  abstractText: 'Remote state that must only be stored beneath account B.',
  authors: const ['B. Reader'],
  primaryCategory: 'cs.SE',
  categories: const ['cs.SE'],
  publishedAt: DateTime.utc(2026, 7, 1),
  updatedAt: DateTime.utc(2026, 7, 31),
  absUrl: 'https://arxiv.org/abs/2607.00001v1',
  pdfUrl: 'https://arxiv.org/pdf/2607.00001v1',
);

AppBuildConfig _accountLibraryConfig() => AppBuildConfig.fromValues(const {
  'PAKPERK_ACCOUNTS_ENABLED': 'true',
  'PAKPERK_LIBRARY_ENABLED': 'true',
  'PAKPERK_OIDC_ISSUER_URL': 'https://identity.example.test/realms/pakperk',
  'PAKPERK_OIDC_CLIENT_ID': 'pakperk-mobile',
  'PAKPERK_OIDC_REDIRECT_URI': 'pakperk-auth://oauth/callback',
  'PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI': 'pakperk-auth://oauth/logout',
});

final class _StartupDelegate implements StartupBootstrapper {
  @override
  Future<void> hydrateLocalState() async {}

  @override
  Future<StartupSessionStatus> checkAuthenticatedSession() async =>
      StartupSessionStatus.anonymous;

  @override
  Future<void> repairLocalStatePreservingCredentials() async {}

  @override
  Future<void> runPostReadyWork() async {}
}

final class _BlockingAccountAdapter implements HttpClientAdapter {
  _BlockingAccountAdapter({required this.accountId});

  final String accountId;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path != '/v1/me') {
      return ResponseBody.fromString('', 404);
    }
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResponseBody.fromString(
      jsonEncode({
        'account': {
          'id': accountId,
          'handle': 'account_b',
          'display_name': 'Account B',
          'status': 'active',
          'profile_version': 1,
          'profile_complete': true,
          'terms_version': '2026-07',
          'terms_accepted_at': '2026-07-30T12:00:00Z',
          'current_terms_version': '2026-07',
          'terms_current': true,
          'created_at': '2026-07-30T10:00:00Z',
          'updated_at': '2026-07-30T12:00:00Z',
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"profile-1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _AccountBLibraryRemote implements LibraryRemoteDataSource {
  int listCalls = 0;
  int changesCalls = 0;
  final List<String> mutationOperationIds = [];

  int get requestCount =>
      listCalls + changesCalls + mutationOperationIds.length;

  LibraryCanonicalItem get item => LibraryCanonicalItem(
    paperId: _accountBPaper.paperId,
    state: 'to_read',
    savedAt: DateTime.utc(2026, 7, 31, 12),
    updatedAt: DateTime.utc(2026, 7, 31, 12),
    removed: false,
    removedAt: null,
    revision: 1,
    lastOperationId: _accountBOperation,
  );

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async {
    listCalls += 1;
    expect(cursor, isNull);
    return LibraryListPage(
      items: [LibraryRemoteEntry(item: item, paper: _accountBPaper)],
      nextCursor: null,
      syncRevision: 1,
    );
  }

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async {
    changesCalls += 1;
    return const LibraryChangesPage(
      items: [],
      nextAfterRevision: 1,
      hasMore: false,
      syncRevision: 1,
    );
  }

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) async {
    mutationOperationIds.add(operationId);
    return LibraryMutationResult(item);
  }

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) async {
    mutationOperationIds.add(operationId);
    return LibraryMutationResult(item);
  }
}
