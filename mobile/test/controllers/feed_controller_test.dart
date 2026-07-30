import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/features/feed/feed_controller.dart';

import '../support/fakes.dart';

void main() {
  test(
    'cached feed is published before network revalidation completes',
    () async {
      final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeedCompleter = pendingNetwork;
      final controller = FeedController(repository);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(pendingNetwork.isCompleted, isFalse);
      expect(controller.state.loadingInitial, isFalse);
      expect(controller.state.items.single.paperId, samplePaper.paperId);
      expect(controller.state.origin, DataOrigin.deviceCache);
      expect(repository.cachedFeedWrites, isEmpty);

      pendingNetwork.complete(
        RepositoryValue(
          value: FeedPage(items: [samplePaper]),
          origin: DataOrigin.network,
          offline: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
    },
  );

  test('new version is cached before it is published to readers', () async {
    final newerPaper = PaperSummary.fromJson(
      samplePaper.toJson()..['arxiv_id'] = '1706.03762v8',
    );
    final cacheGate = Completer<void>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeed = FeedPage(items: [newerPaper])
      ..cacheFeedCompleter = cacheGate;
    final controller = FeedController(repository);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      repository.cachedFeedWrites.single.items.single.arxivId,
      '1706.03762v8',
    );
    expect(controller.state.items.single.arxivId, samplePaper.arxivId);

    cacheGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.items.single.arxivId, '1706.03762v8');
    controller.dispose();
  });

  test(
    'empty initial network refresh preserves a nonempty cached feed',
    () async {
      final repository = FakePaperDataSource(paper: samplePaper)
        ..networkFeed = const FeedPage(items: []);
      final controller = FeedController(repository);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.loadingInitial, isFalse);
      expect(controller.state.items.single.paperId, samplePaper.paperId);
      expect(controller.state.origin, DataOrigin.deviceCache);
      expect(controller.state.offline, isFalse);
      controller.dispose();
    },
  );

  test('empty category refresh remains an explicit empty state', () async {
    final repository = FakePaperDataSource(paper: samplePaper);
    final controller = FeedController(repository);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    repository.networkFeed = const FeedPage(items: []);
    repository.cachedFeedWrites.clear();
    repository.cachedFeedReplaceFlags.clear();
    await controller.loadInitial(category: 'cs.CV');

    expect(controller.state.loadingInitial, isFalse);
    expect(controller.state.category, 'cs.CV');
    expect(controller.state.items, isEmpty);
    expect(controller.state.origin, DataOrigin.network);
    expect(repository.cachedFeedWrites, hasLength(1));
    expect(repository.cachedFeedReplaceFlags.single, isFalse);
    controller.dispose();
  });

  test('disposing the feed cancels its in-flight network request', () async {
    final pendingNetwork = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..networkFeedCompleter = pendingNetwork;
    final controller = FeedController(repository);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final cancellation = repository.lastFeedCancellation;
    expect(cancellation, isNotNull);
    expect(cancellation!.isCancelled, isFalse);

    controller.dispose();
    expect(cancellation.isCancelled, isTrue);

    pendingNetwork.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  });
}
