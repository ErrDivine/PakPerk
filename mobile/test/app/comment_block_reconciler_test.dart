import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/comments_providers.dart';
import 'package:pakperk/core/comments/comment_repository.dart';

void main() {
  test('account switch queues the latest block reconciliation', () async {
    const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
    const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
    const scopeA = (accountId: accountA, authEpoch: 1);
    const scopeB = (accountId: accountB, authEpoch: 2);
    final gates = <VerifiedCommentScope, Completer<void>>{
      scopeA: Completer<void>(),
      scopeB: Completer<void>(),
    };
    final started = <VerifiedCommentScope>[];
    final applied = <VerifiedCommentScope>[];
    var current = scopeA;
    final reconciler = CommentBlockReconciler(
      reconcile: (scope) async {
        started.add(scope);
        await gates[scope]!.future;
        if (current == scope) applied.add(scope);
      },
    );

    final runA = reconciler.run(scopeA);
    await Future<void>.delayed(Duration.zero);
    expect(started, [scopeA]);

    current = scopeB;
    final runB = reconciler.run(scopeB);
    gates[scopeA]!.complete();
    while (started.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(started, [scopeA, scopeB]);
    expect(applied, isEmpty);

    gates[scopeB]!.complete();
    await Future.wait([runA, runB]);
    expect(applied, [scopeB]);
  });
}
