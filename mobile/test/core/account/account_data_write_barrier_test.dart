import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';

void main() {
  const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

  test('sign-out cleanup wins over an already-entered private write', () async {
    final barrier = AccountDataWriteBarrier();
    final entered = Completer<void>();
    final release = Completer<void>();
    final pages = <String, String>{};
    final drafts = <String, String>{};
    final blocks = <String>{};
    var current = true;

    final write = barrier.writeIfCurrent(
      accountId: accountA,
      authEpoch: 1,
      isCurrent: () => current,
      write: () async {
        entered.complete();
        await release.future;
        pages[accountA] = 'pending_review: private body';
        drafts[accountA] = 'private draft';
        blocks.add(accountA);
      },
    );
    await entered.future;
    current = false;
    final cleanup = barrier.clear(
      accountId: accountA,
      invalidatedThroughEpoch: 2,
      clearAccount: (accountId) async {
        pages.remove(accountId);
        drafts.remove(accountId);
        blocks.remove(accountId);
      },
      clearAll: () async {},
    );

    release.complete();
    expect(await write, isFalse);
    await cleanup;
    expect(pages, isEmpty);
    expect(drafts, isEmpty);
    expect(blocks, isEmpty);
  });

  test('A to B switch rejects late A cache draft and block writes', () async {
    final barrier = AccountDataWriteBarrier();
    final remoteA = Completer<void>();
    final rows = <String, List<String>>{};
    var currentAccount = accountA;
    var currentEpoch = 1;
    bool guard(String accountId, int epoch) =>
        currentAccount == accountId && currentEpoch == epoch;

    await barrier.activate(
      accountId: accountA,
      authEpoch: 1,
      isCurrent: () => guard(accountA, 1),
    );
    final lateA = () async {
      await remoteA.future;
      return barrier.writeIfCurrent(
        accountId: accountA,
        authEpoch: 1,
        isCurrent: () => guard(accountA, 1),
        write: () async {
          rows[accountA] = [
            'pending_review: private body',
            'private draft',
            'blocked user',
          ];
        },
      );
    }();

    currentAccount = accountB;
    currentEpoch = 2;
    await barrier.clear(
      accountId: accountA,
      invalidatedThroughEpoch: 1,
      clearAccount: (accountId) async => rows.remove(accountId),
      clearAll: () async => rows.clear(),
    );
    await barrier.activate(
      accountId: accountB,
      authEpoch: 2,
      isCurrent: () => guard(accountB, 2),
    );
    expect(
      await barrier.writeIfCurrent(
        accountId: accountB,
        authEpoch: 2,
        isCurrent: () => guard(accountB, 2),
        write: () async => rows[accountB] = ['B draft', 'B block'],
      ),
      isTrue,
    );

    remoteA.complete();
    expect(await lateA, isFalse);
    expect(rows[accountA], isNull);
    expect(rows[accountB], ['B draft', 'B block']);
  });

  test(
    'stale cleanup cannot delete a newer epoch for the same account',
    () async {
      final barrier = AccountDataWriteBarrier();
      final rows = <String, String>{};
      var epoch = 2;
      await barrier.activate(
        accountId: accountA,
        authEpoch: 2,
        isCurrent: () => epoch == 2,
      );
      await barrier.writeIfCurrent(
        accountId: accountA,
        authEpoch: 2,
        isCurrent: () => epoch == 2,
        write: () async => rows[accountA] = 'new epoch draft',
      );
      var cleanupCalls = 0;

      await barrier.clear(
        accountId: accountA,
        invalidatedThroughEpoch: 1,
        clearAccount: (accountId) async {
          cleanupCalls += 1;
          rows.remove(accountId);
        },
        clearAll: () async => rows.clear(),
      );
      expect(
        await barrier.writeIfCurrent(
          accountId: accountA,
          authEpoch: 1,
          isCurrent: () => epoch == 1,
          write: () async => rows[accountA] = 'stale epoch body',
        ),
        isFalse,
      );

      expect(cleanupCalls, 0);
      expect(rows[accountA], 'new epoch draft');
      epoch = 3;
    },
  );
}
