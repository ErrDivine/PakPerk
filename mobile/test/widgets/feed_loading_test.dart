import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/repository/paper_repository.dart';
import 'package:pakperk/design_system/skeleton.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/feed/feed_screen.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('cache miss renders an accessible paper-card skeleton', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final cached = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..cachedFeedCompleter = cached;

    await _pumpFeed(tester, repository);

    expect(
      find.byKey(const ValueKey('feed-cache-miss-skeleton')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(PaperCardSkeleton.semanticsLabel),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    semantics.dispose();

    cached.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.deviceCache,
        offline: false,
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('stale cached abstract remains visible during revalidation', (
    tester,
  ) async {
    final network = Completer<RepositoryValue<FeedPage>>();
    final repository = FakePaperDataSource(paper: samplePaper)
      ..cachedFeed = FeedPage(items: [samplePaper])
      ..networkFeedCompleter = network;

    await _pumpFeed(tester, repository);
    await tester.pump();

    expect(find.text(samplePaper.title), findsWidgets);
    expect(
      find.byKey(const ValueKey('feed-cache-miss-skeleton')),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    network.complete(
      RepositoryValue(
        value: FeedPage(items: [samplePaper]),
        origin: DataOrigin.network,
        offline: false,
      ),
    );
    await tester.pumpAndSettle();
  });
}

Future<void> _pumpFeed(
  WidgetTester tester,
  FakePaperDataSource repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        paperRepositoryProvider.overrideWithValue(repository),
        localStoreProvider.overrideWithValue(MemoryLocalStore()),
        initialRestorationProvider.overrideWithValue(
          const AppRestorationState(),
        ),
      ],
      child: MaterialApp(theme: PakPerkTheme.light(), home: const FeedScreen()),
    ),
  );
  await tester.pump();
}
