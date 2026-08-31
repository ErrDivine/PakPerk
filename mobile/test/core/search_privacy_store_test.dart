import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/discovery_search/search_privacy_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'history is disabled by default and disabling removes raw queries',
    () async {
      final store = SharedPreferencesSearchPrivacyStore();
      expect((await store.loadHistory(_accountA)).enabled, isFalse);

      final snapshot = PrivateSearchHistorySnapshot(
        enabled: true,
        entries: [
          PrivateSearchHistoryEntry(
            query: '  Efficient   adaptation  ',
            mode: PrivateSearchHistoryMode.explore,
            searchedAt: DateTime.utc(2026, 8, 28),
          ),
        ],
      );
      await store.saveHistory(_accountA, snapshot);
      final loaded = await store.loadHistory(_accountA);
      expect(loaded.enabled, isTrue);
      expect(loaded.entries.single.query, 'Efficient adaptation');

      final preferences = await SharedPreferences.getInstance();
      final key = preferences.getKeys().single;
      expect(key, isNot(contains(_accountA)));
      expect(key, contains(searchPrivacyScopeFingerprint(_accountA)));
      expect(preferences.getString(key), contains('Efficient adaptation'));

      await store.saveHistory(
        _accountA,
        PrivateSearchHistorySnapshot.disabled(),
      );
      expect(
        preferences.getString(key),
        isNot(contains('Efficient adaptation')),
      );
      expect((await store.loadHistory(_accountA)).entries, isEmpty);
    },
  );

  test('expired history is physically compacted on load', () async {
    final store = SharedPreferencesSearchPrivacyStore();
    final searchedAt = DateTime.utc(2026, 1, 1);
    await store.saveHistory(
      _accountA,
      PrivateSearchHistorySnapshot(
        enabled: true,
        entries: [
          PrivateSearchHistoryEntry(
            query: 'expired private query',
            mode: PrivateSearchHistoryMode.lookup,
            searchedAt: searchedAt,
          ),
        ],
      ),
    );

    final snapshot = await store.loadHistory(
      _accountA,
      now: searchedAt.add(const Duration(days: 31)),
    );

    expect(snapshot.enabled, isTrue);
    expect(snapshot.entries, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getKeys().map(preferences.getString).join(),
      isNot(contains('expired private query')),
    );
  });

  test(
    'Explore cache key is a normalized SHA-256 query/filter fingerprint',
    () async {
      final first = exploreSearchCacheFingerprint(
        query: '  Graph   Neural Networks ',
        categories: const ['cs.LG', 'cs.AI'],
        topics: const ['Robustness'],
        sort: 'relevance',
        publishedAfter: '2025-01-01',
        publishedBefore: null,
      );
      final equivalent = exploreSearchCacheFingerprint(
        query: 'graph neural networks',
        categories: const ['cs.ai', 'CS.LG'],
        topics: const ['robustness'],
        sort: 'relevance',
        publishedAfter: '2025-01-01',
        publishedBefore: null,
      );
      final different = exploreSearchCacheFingerprint(
        query: 'graph neural networks',
        categories: const ['cs.AI'],
        topics: const ['robustness'],
        sort: 'relevance',
        publishedAfter: '2025-01-01',
        publishedBefore: null,
      );

      expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(equivalent, first);
      expect(different, isNot(first));
    },
  );

  test(
    'Explore cache is typed, bounded, account scoped, and expires',
    () async {
      final store = SharedPreferencesSearchPrivacyStore();
      final now = DateTime.utc(2026, 8, 28, 8);
      final fingerprint = exploreSearchCacheFingerprint(
        query: 'causal representation learning',
        categories: const ['cs.LG'],
        topics: const [],
        sort: 'recency',
        publishedAfter: null,
        publishedBefore: null,
      );
      final entry = ExploreSearchCacheEntry(
        queryFingerprint: fingerprint,
        papers: [samplePaper],
        coverageLabel: 'Partial arXiv metadata coverage · 1 match',
        disclaimer: 'This is not a systematic or exhaustive search.',
        cachedAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
      );
      await store.saveExplore(_accountA, entry);

      final loaded = await store.loadExplore(
        _accountA,
        fingerprint,
        now: now.add(const Duration(minutes: 14)),
      );
      expect(loaded?.papers.single.paperId, samplePaper.paperId);
      expect(await store.loadExplore(_accountB, fingerprint), isNull);

      var keys = (await SharedPreferences.getInstance()).getKeys();
      expect(keys.single, contains(fingerprint));
      expect(keys.single, isNot(contains('causal')));
      expect(keys.single, isNot(contains('representation')));

      expect(
        await store.loadExplore(
          _accountA,
          fingerprint,
          now: now.add(const Duration(minutes: 16)),
        ),
        isNull,
      );
      keys = (await SharedPreferences.getInstance()).getKeys();
      expect(keys, isEmpty);
    },
  );

  test('account cleanup removes history and Explore cache together', () async {
    final store = SharedPreferencesSearchPrivacyStore();
    final now = DateTime.utc(2026, 8, 28, 8);
    final fingerprint = exploreSearchCacheFingerprint(
      query: 'diffusion policy',
      categories: const [],
      topics: const [],
      sort: 'relevance',
      publishedAfter: null,
      publishedBefore: null,
    );
    await store.saveHistory(
      _accountA,
      PrivateSearchHistorySnapshot(
        enabled: true,
        entries: [
          PrivateSearchHistoryEntry(
            query: 'diffusion policy',
            mode: PrivateSearchHistoryMode.explore,
            searchedAt: now,
          ),
        ],
      ),
    );
    await store.saveExplore(
      _accountA,
      ExploreSearchCacheEntry(
        queryFingerprint: fingerprint,
        papers: [samplePaper],
        coverageLabel: 'Partial arXiv metadata coverage · 1 match',
        disclaimer: 'This is not a systematic or exhaustive search.',
        cachedAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
      ),
    );

    await store.clear(_accountA);

    expect((await store.loadHistory(_accountA)).enabled, isFalse);
    expect(await store.loadExplore(_accountA, fingerprint), isNull);
  });
}

const _accountA = 'account-a';
const _accountB = 'account-b';
