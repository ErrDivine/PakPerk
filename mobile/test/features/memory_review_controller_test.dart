import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/research_memory.dart';
import 'package:pakperk/core/research/research_repository.dart';
import 'package:pakperk/features/memory/memory_controller.dart';

void main() {
  const scope = (accountId: accountId, authEpoch: 9);
  final now = DateTime.utc(2026, 8, 31, 12);

  test('due queue spans papers and excludes future, retired, and deleted', () {
    final state = MemoryReviewState(
      items: [
        _item(id: itemA, paperId: paperA, nextReviewAt: now),
        _item(
          id: itemB,
          paperId: paperB,
          status: MemoryStatus.snoozed,
          nextReviewAt: now.subtract(const Duration(minutes: 1)),
        ),
        _item(
          id: itemC,
          paperId: paperC,
          nextReviewAt: now.add(const Duration(minutes: 1)),
        ),
        _item(id: itemD, paperId: paperA, status: MemoryStatus.retired),
        _item(
          id: itemE,
          paperId: paperB,
          deletedAt: now.subtract(const Duration(days: 1)),
        ),
      ],
    );

    expect(state.dueItems(now).map((item) => item.id), [itemB, itemA]);
    expect(state.dueItems(now).map((item) => item.paperId).toSet(), {
      paperA,
      paperB,
    });
  });

  test(
    'retirement writes only research memory with exact item paper scope',
    () async {
      final source = _MemoryReviewFake();
      var current = true;
      final controller = MemoryReviewController(
        scope: scope,
        source: source,
        scopeIsCurrent: () => current,
        now: () => now,
      );
      addTearDown(controller.dispose);
      final item = _item(id: itemA, paperId: paperA, nextReviewAt: now);
      source.emit([item]);
      await pumpEventQueue();

      await controller.retire(item);

      expect(source.reviews, hasLength(1));
      final review = source.reviews.single;
      expect(review.itemId, itemA);
      expect(review.paperId, paperA);
      expect(review.generation, 3);
      expect(review.status, MemoryStatus.retired);
      expect(controller.state.items.single.status, MemoryStatus.retired);
      expect(controller.state.statusMessage, contains('paper was not changed'));
      expect(source.libraryMutationCount, 0);
      expect(source.readingFeedMutationCount, 0);

      current = false;
    },
  );

  test('stale account and stale item revision fail closed', () async {
    final source = _MemoryReviewFake();
    var current = true;
    final controller = MemoryReviewController(
      scope: scope,
      source: source,
      scopeIsCurrent: () => current,
      now: () => now,
    );
    addTearDown(controller.dispose);
    final latest = _item(
      id: itemA,
      paperId: paperA,
      nextReviewAt: now,
      revision: 4,
    );
    source.emit([latest]);
    await pumpEventQueue();

    await controller.markReviewed(
      latest.copyWith(revision: 3),
      nextReviewAt: now.add(const Duration(days: 1)),
    );
    expect(source.reviews, isEmpty);
    expect(controller.state.errorMessage, contains('changed'));

    current = false;
    await controller.retire(latest);
    expect(source.reviews, isEmpty);
  });

  test('refresh carries only the verified account fence', () async {
    final source = _MemoryReviewFake();
    var current = true;
    final controller = MemoryReviewController(
      scope: scope,
      source: source,
      scopeIsCurrent: () => current,
    );
    addTearDown(controller.dispose);

    await controller.load();

    expect(source.refreshes, [(accountId: accountId, authEpoch: 9)]);
    expect(controller.state.loading, isFalse);
    expect(source.libraryMutationCount, 0);
    expect(source.readingFeedMutationCount, 0);
    current = false;
  });

  test(
    'review scheduling emits snoozed status and the exact chosen instant',
    () async {
      final source = _MemoryReviewFake();
      final controller = MemoryReviewController(
        scope: scope,
        source: source,
        scopeIsCurrent: () => true,
        now: () => now,
      );
      addTearDown(controller.dispose);
      final item = _item(id: itemA, paperId: paperA, nextReviewAt: now);
      source.emit([item]);
      await pumpEventQueue();
      final chosen = DateTime.parse('2026-09-02T09:30:00+08:00');

      await controller.markReviewed(item, nextReviewAt: chosen);

      final review = source.reviews.single;
      expect(review.status, MemoryStatus.snoozed);
      expect(review.nextReviewAt, chosen.toUtc());
      expect(controller.state.items.single.status, MemoryStatus.snoozed);
      expect(controller.state.items.single.nextReviewAt, chosen.toUtc());
      expect(source.libraryMutationCount, 0);
      expect(source.readingFeedMutationCount, 0);
    },
  );

  test('invalid review dates fail closed before any mutation', () async {
    final source = _MemoryReviewFake();
    final controller = MemoryReviewController(
      scope: scope,
      source: source,
      scopeIsCurrent: () => true,
      now: () => now,
    );
    addTearDown(controller.dispose);
    final item = _item(id: itemA, paperId: paperA, nextReviewAt: now);
    source.emit([item]);
    await pumpEventQueue();

    await controller.snooze(item, nextReviewAt: now);
    await controller.markReviewed(
      item,
      nextReviewAt: now
          .add(maximumCustomMemoryReviewHorizon)
          .add(const Duration(seconds: 1)),
    );

    expect(source.reviews, isEmpty);
    expect(controller.state.errorMessage, contains('future review time'));
    expect(source.libraryMutationCount, 0);
    expect(source.readingFeedMutationCount, 0);
  });
}

final class _MemoryReviewFake implements MemoryReviewDataSource {
  final StreamController<List<MemoryItem>> _items =
      StreamController<List<MemoryItem>>.broadcast();
  final List<({String accountId, int authEpoch})> refreshes = [];
  final List<
    ({
      String itemId,
      String paperId,
      int generation,
      MemoryStatus status,
      DateTime? nextReviewAt,
    })
  >
  reviews = [];
  var libraryMutationCount = 0;
  var readingFeedMutationCount = 0;

  void emit(List<MemoryItem> items) => _items.add(items);

  @override
  bool get isOffline => false;

  @override
  Stream<List<MemoryItem>> watch(String accountId) => _items.stream;

  @override
  Future<void> refresh(
    ResearchAccountRequestScope scope, {
    RequestCancellation? cancellation,
  }) async {
    expect(scope.isCurrent(), isTrue);
    refreshes.add((accountId: scope.accountId, authEpoch: scope.authEpoch));
  }

  @override
  Future<MemoryItem> review({
    required ResearchRequestScope scope,
    required MemoryItem item,
    required MemoryStatus status,
    DateTime? nextReviewAt,
  }) async {
    expect(scope.isCurrent(), isTrue);
    reviews.add((
      itemId: item.id,
      paperId: scope.paperId,
      generation: scope.generation,
      status: status,
      nextReviewAt: nextReviewAt,
    ));
    return item.copyWith(
      status: status,
      nextReviewAt: nextReviewAt,
      clearNextReviewAt: nextReviewAt == null,
      revision: item.revision + 1,
      updatedAt: DateTime.utc(2026, 8, 31, 12, 1),
      syncState: ResearchSyncState.clean,
      clearActiveOperationId: true,
    );
  }
}

MemoryItem _item({
  required String id,
  required String paperId,
  MemoryStatus status = MemoryStatus.active,
  DateTime? nextReviewAt,
  DateTime? deletedAt,
  int revision = 2,
}) => MemoryItem(
  id: id,
  paperId: paperId,
  generation: 3,
  sourceType: MemorySourceType.annotation,
  sourceId: annotationId,
  promptText: 'Why did this result matter?',
  answerText: 'Because the ablation isolates the claimed mechanism.',
  status: status,
  nextReviewAt: nextReviewAt,
  reviewCount: 1,
  revision: revision,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 30),
);

const accountId = '00000000-0000-4000-8000-000000000001';
const paperA = '00000000-0000-4000-8000-000000000011';
const paperB = '00000000-0000-4000-8000-000000000012';
const paperC = '00000000-0000-4000-8000-000000000013';
const itemA = '00000000-0000-4000-8000-000000000021';
const itemB = '00000000-0000-4000-8000-000000000022';
const itemC = '00000000-0000-4000-8000-000000000023';
const itemD = '00000000-0000-4000-8000-000000000024';
const itemE = '00000000-0000-4000-8000-000000000025';
const annotationId = '00000000-0000-4000-8000-000000000031';
