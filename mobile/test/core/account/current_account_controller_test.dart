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
}

final class _DelayedAdapter implements HttpClientAdapter {
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await release.future;
    return ResponseBody.fromString(
      jsonEncode(const {
        'account': {
          'id': '018f47a6-4b56-7f4c-8c7a-e2656e820001',
          'handle': null,
          'display_name': null,
          'status': 'active',
          'profile_version': 1,
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
        'etag': ['"profile-1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
