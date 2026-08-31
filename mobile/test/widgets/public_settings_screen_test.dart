import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/discovery_providers.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/cache/feed_cache_persistence.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/research/research_api.dart';
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

  testWidgets('recoverable account exposes the routed deletion action', (
    tester,
  ) async {
    final store = _CacheControlStore(
      initial: const FeedCacheUsage(metadataRows: 1, databaseBytes: 1024),
      after: const FeedCacheUsage(metadataRows: 1, databaseBytes: 1024),
    );
    final auth = _authController(
      storedRecord(accountId: '018f47a6-4b56-7f4c-8c7a-e2656e820001'),
    );
    expect(
      await auth.inspectStoredSession(),
      AuthStoredSessionStatus.refreshRequired,
    );
    var deletionOpens = 0;

    await _pump(
      tester,
      store,
      features: _accountsEnabled,
      authSession: auth,
      onOpenDeleteAccount: () => deletionOpens += 1,
    );

    final action = find.byKey(const ValueKey('delete-account-setting'));
    await tester.scrollUntilVisible(
      action,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Delete account'), findsOneWidget);
    await tester.tap(action);

    expect(deletionOpens, 1);
  });

  testWidgets('guest does not expose account deletion from public settings', (
    tester,
  ) async {
    final store = _CacheControlStore(
      initial: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
    );
    final auth = _authController();
    expect(await auth.inspectStoredSession(), AuthStoredSessionStatus.guest);

    await _pump(
      tester,
      store,
      features: _accountsEnabled,
      authSession: auth,
      onOpenDeleteAccount: () => fail('Guest deletion action opened.'),
    );

    expect(find.byKey(const ValueKey('delete-account-setting')), findsNothing);
  });

  testWidgets(
    'verified account sees default-off reading updates only when enabled',
    (tester) async {
      final store = _CacheControlStore(
        initial: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
        after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      );
      var opens = 0;
      await _pump(
        tester,
        store,
        features: const FeatureFlags(
          accounts: true,
          library: true,
          comments: false,
          openingMotion: false,
          readingFeed: true,
          readingBriefsEnabled: true,
        ),
        discoveryScope: const (
          accountId: '018f47a6-4b56-7f4c-8c7a-e2656e820001',
          authEpoch: 7,
        ),
        authSession: _authController(),
        onOpenReadingUpdates: () => opens += 1,
      );
      final action = find.byKey(const ValueKey('reading-updates-setting'));
      await tester.scrollUntilVisible(
        action,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(action);
      expect(opens, 1);
    },
  );

  testWidgets(
    'assistant-only account copies every bounded export part in order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final platformCalls = <String>[];
      String? clipboardText;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call.method);
        switch (call.method) {
          case 'Clipboard.setData':
            clipboardText = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return <String, Object?>{'text': clipboardText};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final store = _CacheControlStore(
        initial: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
        after: const FeedCacheUsage(metadataRows: 0, databaseBytes: 0),
      );
      var exportCalls = 0;
      int? exportedEpoch;
      final exportedCursors = <String?>[];
      const features = FeatureFlags(
        accounts: true,
        library: true,
        comments: false,
        openingMotion: false,
        deepReader: true,
        assistantV2: true,
        annotations: false,
      );
      await _pump(
        tester,
        store,
        features: features,
        authSession: _authController(),
        libraryScope: const (
          accountId: '018f47a6-4b56-7f4c-8c7a-e2656e820001',
          authEpoch: 13,
        ),
        researchExportLoader: (authEpoch, cursor) async {
          exportCalls += 1;
          exportedEpoch = authEpoch;
          exportedCursors.add(cursor);
          if (cursor == 'part-two') {
            return ResearchExportArtifact(
              bytes: '{"assistant_messages":[{"id":"second"}]}'.codeUnits,
              mimeType: 'application/json',
              fileName: 'pakperk-research-export.json',
              pageNumber: 2,
            );
          }
          return ResearchExportArtifact(
            bytes: '{"assistant_threads":[]}'.codeUnits,
            mimeType: 'application/json',
            fileName: 'pakperk-research-export.json',
            nextCursor: 'part-two',
          );
        },
      );

      final action = find.byKey(const ValueKey('research-data-export-setting'));
      await tester.scrollUntilVisible(
        action,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Export research data'), findsOneWidget);
      expect(find.textContaining('private Assistant history'), findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));

      await tester.tap(action);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(exportCalls, 1);
      expect(exportedEpoch, 13);
      expect(
        (await Clipboard.getData('text/plain'))?.text,
        '{"assistant_threads":[]}',
      );
      expect(
        platformCalls.indexOf('Clipboard.setData'),
        lessThan(platformCalls.indexOf('HapticFeedback.vibrate')),
      );
      expect(exportedCursors, [null]);
      expect(
        find.text('pakperk-research-export.json part 1 copied.'),
        findsOneWidget,
      );
      final nextPart = find.text('Next part');
      expect(
        tester.getSize(find.byType(SnackBarAction)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(nextPart);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(exportCalls, 2);
      expect(exportedCursors, [null, 'part-two']);
      expect(
        (await Clipboard.getData('text/plain'))?.text,
        '{"assistant_messages":[{"id":"second"}]}',
      );
      expect(
        find.text(
          'pakperk-research-export.json part 2 copied. Export complete.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _CacheControlStore store, {
  MemorySecureTokenStore? secureStore,
  FeatureFlags features = const FeatureFlags.disabled(),
  AuthSessionController? authSession,
  VoidCallback? onOpenDeleteAccount,
  VerifiedDiscoveryAccountScope? discoveryScope,
  ActiveLibraryScope? libraryScope,
  VoidCallback? onOpenReadingUpdates,
  Future<ResearchExportArtifact> Function(
    int expectedAuthEpoch,
    String? cursor,
  )?
  researchExportLoader,
}) async {
  final tokens = secureStore ?? MemorySecureTokenStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        featureFlagsProvider.overrideWithValue(features),
        if (discoveryScope != null)
          verifiedDiscoveryAccountScopeProvider.overrideWithValue(
            discoveryScope,
          ),
        if (libraryScope != null)
          verifiedLibraryScopeProvider.overrideWithValue(libraryScope),
        if (authSession != null)
          authSessionProvider.overrideWith((ref) => authSession),
        secureTokenStoreProvider.overrideWithValue(tokens),
        localStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: PublicSettingsScreen(
          onOpenDeleteAccount: onOpenDeleteAccount,
          onOpenReadingUpdates: onOpenReadingUpdates,
          researchExportLoader: researchExportLoader,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AuthSessionController _authController([SecureAuthRecord? record]) =>
    AuthSessionController(
      repository: AuthRepository(
        configuration: testOidcConfiguration,
        oidcClient: FakeOidcClient(),
        secureTokenStore: MemorySecureTokenStore(record),
      ),
      clearAccountOwnedData: (_, __) async {},
    );

const _accountsEnabled = FeatureFlags(
  accounts: true,
  library: false,
  comments: false,
  openingMotion: false,
);

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
