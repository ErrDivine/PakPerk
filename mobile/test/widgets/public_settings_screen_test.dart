import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/settings/appearance.dart';
import 'package:pakperk/features/settings/public_settings_screen.dart';

import '../support/fakes.dart';
import '../core/auth/auth_fakes.dart';

void main() {
  testWidgets('appearance choice updates immediately and persists', (
    tester,
  ) async {
    final store = _CacheControlStore(
      initial: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
    );
    await _pump(tester, store);

    expect(find.text('Use device setting'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appearance-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(find.text('Dark'), findsOneWidget);
    expect(store.appearance, AppAppearance.dark);
  });

  testWidgets('shows cache usage and clears only after explicit confirmation', (
    tester,
  ) async {
    final store = _CacheControlStore(
      initial: const FeedCacheUsage(
        metadataRows: 8,
        databaseBytes: 4 * 1024 * 1024,
        physicalDatabaseBytes: 6 * 1024 * 1024,
      ),
      after: const FeedCacheUsage(
        metadataRows: 2,
        databaseBytes: 1024 * 1024,
        physicalDatabaseBytes: 6 * 1024 * 1024,
      ),
    );
    await _pump(tester, store);

    expect(find.textContaining('8 cached paper records'), findsOneWidget);
    expect(find.textContaining('6.00 MiB allocated'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('clear-reading-cache')));
    await tester.pumpAndSettle();
    expect(find.text('Clear reading cache?'), findsOneWidget);
    expect(
      find.textContaining('saved papers, drafts, pending sync'),
      findsOneWidget,
    );
    expect(store.clearCalls, 0);

    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();

    expect(store.clearCalls, 1);
    expect(find.textContaining('2 cached paper records'), findsOneWidget);
    expect(
      find.text('Reading cache cleared. 6 rebuildable papers were removed.'),
      findsOneWidget,
    );
  });

  testWidgets('cache clear failure is safe and retryable', (tester) async {
    final store = _CacheControlStore(
      initial: const FeedCacheUsage(metadataRows: 3, databaseBytes: 2048),
      after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 1024),
      failClear: true,
    );
    await _pump(tester, store);

    await tester.tap(find.byKey(const ValueKey('clear-reading-cache')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();

    expect(store.clearCalls, 1);
    expect(
      find.text('The reading cache could not be cleared on this device.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('clear-reading-cache')))
          .enabled,
      isTrue,
    );
  });

  testWidgets('clear all data requires confirmation and resets local state', (
    tester,
  ) async {
    final store =
        _CacheControlStore(
            initial: const FeedCacheUsage(metadataRows: 3, databaseBytes: 2048),
            after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
          )
          ..sessionId = '00000000-0000-4000-8000-000000000777'
          ..feed = FeedPage(items: [samplePaper])
          ..papers[samplePaper.paperId] = samplePaper
          ..appearance = AppAppearance.dark;
    await _pump(tester, store);

    await tester.tap(find.byKey(const ValueKey('clear-all-local-data')));
    await tester.pumpAndSettle();
    expect(find.text('Clear all data?'), findsOneWidget);
    expect(find.textContaining('pending changes'), findsOneWidget);
    expect(store.clearAllCalls, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.clearAllCalls, 0);

    await tester.tap(find.byKey(const ValueKey('clear-all-local-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all data'));
    await tester.pumpAndSettle();

    expect(store.clearAllCalls, 1);
    expect(store.feed, isNull);
    expect(store.papers, isEmpty);
    expect(store.appearance, AppAppearance.system);
    expect(find.text('All local data was cleared.'), findsOneWidget);
  });

  testWidgets(
    'clear all invalidates a residual secure session when accounts are off',
    (tester) async {
      final store = _CacheControlStore(
        initial: const FeedCacheUsage(metadataRows: 1, databaseBytes: 1024),
        after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      );
      final tokens = MemorySecureTokenStore(storedRecord());
      await _pump(tester, store, secureStore: tokens);

      await tester.tap(find.byKey(const ValueKey('clear-all-local-data')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear all data'));
      await tester.pumpAndSettle();

      expect(tokens.clearCalls, 1);
      expect(tokens.record, isNull);
      expect(tokens.invalidationStore.invalidated, isTrue);
      expect(store.clearAllCalls, 1);
      expect(find.text('All local data was cleared.'), findsOneWidget);
    },
  );

  testWidgets(
    'secure cleanup failure still clears local data and reports partial work',
    (tester) async {
      final store = _CacheControlStore(
        initial: const FeedCacheUsage(metadataRows: 1, databaseBytes: 1024),
        after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      );
      final tokens = MemorySecureTokenStore(storedRecord())
        ..clearError = StateError('simulated secure-delete failure');
      await _pump(tester, store, secureStore: tokens);

      await tester.tap(find.byKey(const ValueKey('clear-all-local-data')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear all data'));
      await tester.pumpAndSettle();

      expect(tokens.clearCalls, 1);
      expect(tokens.record, isNotNull);
      expect(tokens.invalidationStore.invalidated, isTrue);
      expect(store.clearAllCalls, 1);
      expect(
        find.textContaining('secure sign-out needs another attempt'),
        findsOneWidget,
      );
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _CacheControlStore store, {
  MemorySecureTokenStore? secureStore,
}) async {
  final tokens = secureStore ?? MemorySecureTokenStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        featureFlagsProvider.overrideWithValue(const FeatureFlags.disabled()),
        secureTokenStoreProvider.overrideWithValue(tokens),
        localStoreProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(home: PublicSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

final class _CacheControlStore extends MemoryLocalStore
    implements PublicCacheControl {
  _CacheControlStore({
    required this.initial,
    required this.after,
    this.failClear = false,
  });

  final FeedCacheUsage initial;
  final FeedCacheUsage after;
  final bool failClear;
  int clearCalls = 0;
  int clearAllCalls = 0;

  @override
  Future<void> clearAllLocalData() async {
    clearAllCalls += 1;
    await super.clearAllLocalData();
  }

  @override
  Future<FeedCacheUsage> measurePublicCache() async => initial;

  @override
  Future<PublicCacheClearResult> clearRebuildablePublicCache() async {
    clearCalls += 1;
    if (failClear) throw StateError('simulated storage failure');
    return PublicCacheClearResult(before: initial, after: after);
  }
}
