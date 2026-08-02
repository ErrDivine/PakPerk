import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account.dart';

void main() {
  test(
    'clear invalidates a late profile response before account binding',
    () async {
      final adapter = _DelayedAdapter();
      final repository = AccountRepository(
        AccountApi(
          Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
            ..httpClientAdapter = adapter,
        ),
      );
      var epoch = 7;
      final boundIds = <String>[];
      final controller = CurrentAccountController(
        repository: repository,
        sessionEpoch: () => epoch,
        sessionAccountId: () => null,
        bindAccountId: (id) async => boundIds.add(id),
      );
      addTearDown(controller.dispose);

      final pending = controller.load();
      expect(controller.state.phase, CurrentAccountPhase.loading);
      epoch += 1;
      controller.clear();
      adapter.release.complete();

      expect(await pending, isNull);
      expect(controller.state.phase, CurrentAccountPhase.idle);
      expect(controller.state.profile, isNull);
      expect(boundIds, isEmpty);
    },
  );

  test('secure account binding failure becomes sanitized state', () async {
    final adapter = _DelayedAdapter()..release.complete();
    final repository = AccountRepository(
      AccountApi(
        Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
          ..httpClientAdapter = adapter,
      ),
    );
    final controller = CurrentAccountController(
      repository: repository,
      sessionEpoch: () => 1,
      sessionAccountId: () => null,
      bindAccountId: (_) async => throw StateError('private storage detail'),
    );
    addTearDown(controller.dispose);

    expect(await controller.load(), isNull);
    expect(controller.state.phase, CurrentAccountPhase.failed);
    expect(controller.state.error?.code, 'ACCOUNT_SESSION_UNAVAILABLE');
    expect(
      controller.state.error?.message,
      isNot(contains('private storage detail')),
    );
  });

  group('same-epoch session identity changes', () {
    test(
      'unbound profile bootstrap binds and publishes the returned account',
      () async {
        final adapter = _DelayedAdapter()..release.complete();
        final repository = AccountRepository(
          AccountApi(
            Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
              ..httpClientAdapter = adapter,
          ),
        );
        String? sessionAccountId;
        final controller = CurrentAccountController(
          repository: repository,
          sessionEpoch: () => 11,
          sessionAccountId: () => sessionAccountId,
          bindAccountId: (id) async => sessionAccountId = id,
        );
        addTearDown(controller.dispose);

        final profile = await controller.load();

        expect(profile?.id, _accountA);
        expect(sessionAccountId, _accountA);
        expect(controller.state.phase, CurrentAccountPhase.ready);
        expect(controller.state.profile?.id, _accountA);
      },
    );

    test('late account A load cannot rebind a same-epoch account B', () async {
      final adapter = _DelayedAdapter();
      final repository = AccountRepository(
        AccountApi(
          Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
            ..httpClientAdapter = adapter,
        ),
      );
      String? sessionAccountId = _accountA;
      final boundIds = <String>[];
      Future<void> bindAccountId(String id) async {
        boundIds.add(id);
        sessionAccountId = id;
      }

      final controller = CurrentAccountController(
        repository: repository,
        sessionEpoch: () => 12,
        sessionAccountId: () => sessionAccountId,
        bindAccountId: bindAccountId,
      );
      addTearDown(controller.dispose);

      final pending = controller.load();
      await adapter.started.future;
      await bindAccountId(_accountB);
      adapter.release.complete();

      expect(await pending, isNull);
      expect(sessionAccountId, _accountB);
      expect(boundIds, [_accountB]);
      expect(controller.state.phase, CurrentAccountPhase.idle);
      expect(controller.state.profile, isNull);
    });

    test(
      'verified account A rejects a cross-wired account B profile response',
      () async {
        final firstAdapter = _DelayedAdapter()..release.complete();
        final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
          ..httpClientAdapter = firstAdapter;
        String? sessionAccountId = _accountA;
        final boundIds = <String>[];
        final controller = CurrentAccountController(
          repository: AccountRepository(AccountApi(dio)),
          sessionEpoch: () => 12,
          sessionAccountId: () => sessionAccountId,
          bindAccountId: (id) async {
            boundIds.add(id);
            sessionAccountId = id;
          },
        );
        addTearDown(controller.dispose);

        expect((await controller.load())?.id, _accountA);
        final adapter = _DelayedAdapter(accountId: _accountB)
          ..release.complete();
        dio.httpClientAdapter = adapter;

        expect(await controller.load(), isNull);
        expect(sessionAccountId, _accountA);
        expect(boundIds, [_accountA]);
        expect(controller.state.phase, CurrentAccountPhase.failed);
        expect(controller.state.profile?.id, _accountA);
        expect(controller.state.error?.code, 'ACCOUNT_SESSION_UNAVAILABLE');
      },
    );

    test(
      'late account A update cannot publish into same-epoch account B',
      () async {
        final initialAdapter = _DelayedAdapter()..release.complete();
        final dio = Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
          ..httpClientAdapter = initialAdapter;
        String? sessionAccountId = _accountA;
        final boundIds = <String>[];
        Future<void> bindAccountId(String id) async {
          boundIds.add(id);
          sessionAccountId = id;
        }

        final controller = CurrentAccountController(
          repository: AccountRepository(AccountApi(dio)),
          sessionEpoch: () => 13,
          sessionAccountId: () => sessionAccountId,
          bindAccountId: bindAccountId,
        );
        addTearDown(controller.dispose);
        expect((await controller.load())?.id, _accountA);

        final updateAdapter = _DelayedAdapter(profileVersion: 2);
        dio.httpClientAdapter = updateAdapter;
        final pending = controller.update(
          const AccountProfilePatch(
            displayName: ProfileField.value('Updated account A'),
          ),
        );
        await updateAdapter.started.future;
        await bindAccountId(_accountB);
        updateAdapter.release.complete();

        expect(await pending, isNull);
        expect(sessionAccountId, _accountB);
        expect(boundIds, [_accountA, _accountB]);
        expect(controller.state.phase, CurrentAccountPhase.idle);
        expect(controller.state.profile, isNull);
      },
    );
  });

  test(
    'authoritative suspension supersedes an older active profile response',
    () async {
      final adapter = _DelayedAdapter();
      final boundIds = <String>[];
      final controller = CurrentAccountController(
        repository: AccountRepository(
          AccountApi(
            Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
              ..httpClientAdapter = adapter,
          ),
        ),
        sessionEpoch: () => 9,
        sessionAccountId: () => null,
        bindAccountId: (id) async => boundIds.add(id),
      );
      addTearDown(controller.dispose);

      final pending = controller.load();
      controller.recordAuthoritativeReadOnlyStatus(
        errorCode: 'ACCOUNT_SUSPENDED',
        authEpoch: 9,
      );
      expect(controller.state.phase, CurrentAccountPhase.failed);
      expect(controller.state.knownReadOnlyStatus, AccountStatus.suspended);
      adapter.release.complete();

      expect(await pending, isNull);
      expect(controller.state.phase, CurrentAccountPhase.failed);
      expect(controller.state.knownReadOnlyStatus, AccountStatus.suspended);
      expect(boundIds, isEmpty);
    },
  );
}

const _accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

final class _DelayedAdapter implements HttpClientAdapter {
  _DelayedAdapter({this.accountId = _accountA, this.profileVersion = 1});

  final String accountId;
  final int profileVersion;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResponseBody.fromString(
      jsonEncode({
        'account': {
          'id': accountId,
          'handle': null,
          'display_name': profileVersion == 1 ? null : 'Updated account A',
          'status': 'active',
          'profile_version': profileVersion,
          'profile_complete': false,
          'terms_version': null,
          'terms_accepted_at': null,
          'current_terms_version': '2026-07',
          'terms_current': false,
          'community_guidelines_version': null,
          'community_guidelines_accepted_at': null,
          'current_community_guidelines_version': '2026-07',
          'community_guidelines_current': false,
          'created_at': '2026-07-30T10:00:00Z',
          'updated_at': '2026-07-30T11:00:00Z',
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'etag': ['"profile-$profileVersion"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
