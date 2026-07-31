import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/cache/drift_restoration_persistence.dart';
import 'package:pakperk/core/cache/restoration_persistence.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  test(
    'paper commit completes before compact route reference is written',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final papers = <String, PaperSummary>{};
      var paperCommitFinished = false;
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (values) async {
          for (final paper in values) {
            papers[paper.paperId] = paper;
          }
          paperCommitFinished = true;
          expect(
            preferences.containsKey(compactRestorationPreferencesKey),
            isFalse,
          );
        },
        loadPaper: (paperId) async => papers[paperId],
      );

      await persistence.save(
        AppRestorationState(
          routeStack: [PaperRouteEntry(routeId: 'route-1', paper: samplePaper)],
        ),
      );

      expect(paperCommitFinished, isTrue);
      expect(preferences.containsKey(compactRestorationPreferencesKey), isTrue);
      final restored = await persistence.load();
      expect(restored.routeStack.single.paper, same(samplePaper));
    },
  );

  test(
    'legacy full routes migrate to compact refs through the paper store',
    () async {
      final unreadable = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['paper_id'] = 'unreadable-paper'
          ..['arxiv_id'] = '2401.99999v1',
      );
      SharedPreferences.setMockInitialValues({
        legacyRestorationPreferencesKey: jsonEncode(
          AppRestorationState(
            activeBranchIndex: 1,
            feedIndex: 3,
            routeStack: [
              PaperRouteEntry(routeId: 'kept', paper: samplePaper),
              PaperRouteEntry(routeId: 'skipped', paper: unreadable),
            ],
            readerStates: {
              routeReaderKey('kept', samplePaper): const ReaderNavigationState(
                stageIndex: 2,
              ),
              routeReaderKey('skipped', unreadable):
                  const ReaderNavigationState(stageIndex: 1),
            },
          ).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final papers = <String, PaperSummary>{};
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (values) async {
          for (final paper in values) {
            if (paper.paperId != unreadable.paperId) {
              papers[paper.paperId] = paper;
            }
          }
        },
        loadPaper: (paperId) async => papers[paperId],
      );

      final restored = await persistence.load();

      expect(restored.activeBranchIndex, 1);
      expect(restored.feedIndex, 3);
      expect(restored.routeStack.map((route) => route.routeId), ['kept']);
      expect(restored.readerStates.keys, [routeReaderKey('kept', samplePaper)]);
      expect(preferences.containsKey(legacyRestorationPreferencesKey), isFalse);
      final compact = RestorationPreferences(preferences).loadCompact()!;
      expect(compact.routeReferences.map((route) => route.routeId), ['kept']);
      final raw = preferences.getString(compactRestorationPreferencesKey)!;
      expect(raw, isNot(contains(samplePaper.title)));
      expect(raw, isNot(contains(samplePaper.abstractText)));
    },
  );

  test(
    'legacy conversion failure is nonblocking, masked, and retryable',
    () async {
      final derived = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['capabilities'] = {
            'metadata': true,
            'introduction': true,
            'chat': true,
            'connections': true,
          },
      );
      SharedPreferences.setMockInitialValues({
        legacyRestorationPreferencesKey: jsonEncode(
          AppRestorationState(
            feedIndex: 6,
            routeStack: [
              PaperRouteEntry(routeId: 'legacy-route', paper: derived),
            ],
          ).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (_) async => throw StateError('injected DB failure'),
        loadPaper: (_) async => null,
        normalizePaper: (paper) =>
            paper.copyWith(capabilities: const PaperCapabilities()),
      );

      final restored = await persistence.load();

      expect(restored.feedIndex, 6);
      expect(restored.routeStack.single.routeId, 'legacy-route');
      expect(
        restored.routeStack.single.paper.capabilities.introduction,
        isFalse,
      );
      expect(preferences.containsKey(legacyRestorationPreferencesKey), isTrue);
      expect(
        preferences.containsKey(compactRestorationPreferencesKey),
        isFalse,
      );
    },
  );

  test(
    'missing compact paper skips only that route and rewrites the record',
    () async {
      final missing = PaperSummary.fromJson(
        samplePaper.toJson()
          ..['paper_id'] = 'missing-paper'
          ..['arxiv_id'] = '2402.00001v1',
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await RestorationPreferences(preferences).saveCompact(
        CompactRestorationRecord.fromState(
          AppRestorationState(
            feedIndex: 5,
            routeStack: [
              PaperRouteEntry(routeId: 'kept', paper: samplePaper),
              PaperRouteEntry(routeId: 'missing', paper: missing),
            ],
          ),
        ),
      );
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (_) async {},
        loadPaper: (paperId) async =>
            paperId == samplePaper.paperId ? samplePaper : null,
      );

      final restored = await persistence.load();

      expect(restored.feedIndex, 5);
      expect(restored.routeStack.map((route) => route.routeId), ['kept']);
      expect(
        RestorationPreferences(
          preferences,
        ).loadCompact()!.routeReferences.map((route) => route.routeId),
        ['kept'],
      );
    },
  );

  test(
    'a newer cached version hydrates and rewrites an older reference',
    () async {
      final current = PaperSummary.fromJson(
        samplePaper.toJson()..['arxiv_id'] = '${samplePaper.arxivBaseId}v8',
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await RestorationPreferences(preferences).saveCompact(
        CompactRestorationRecord.fromState(
          AppRestorationState(
            routeStack: [
              PaperRouteEntry(routeId: 'route-1', paper: samplePaper),
            ],
            readerStates: {
              routeReaderKey('route-1', samplePaper):
                  const ReaderNavigationState(stageIndex: 2),
            },
          ),
        ),
      );
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (_) async {},
        loadPaper: (_) async => current,
      );

      final restored = await persistence.load();

      expect(restored.routeStack.single.paper.arxivId, current.arxivId);
      expect(restored.readerStates, isEmpty);
      expect(
        RestorationPreferences(
          preferences,
        ).loadCompact()!.routeReferences.single.arxivId,
        current.arxivId,
      );
    },
  );

  test('current feed identity rebases a compacted feed index', () async {
    final earlier = PaperSummary.fromJson(
      samplePaper.toJson()
        ..['paper_id'] = 'earlier-paper'
        ..['arxiv_id'] = '2401.00001v1',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await RestorationPreferences(preferences).saveCompact(
      CompactRestorationRecord.fromState(
        AppRestorationState(
          feedIndex: 48,
          feedPaperId: samplePaper.paperId,
          feedArxivId: samplePaper.arxivId,
        ),
      ),
    );
    final persistence = DriftRestorationPersistence(
      preferences: RestorationPreferences(preferences),
      persistPapers: (_) async {},
      loadPaper: (paperId) async =>
          paperId == samplePaper.paperId ? samplePaper : null,
      loadFeed: () async => FeedPage(items: [earlier, samplePaper]),
    );

    final restored = await persistence.load();

    expect(restored.feedIndex, 1);
    expect(restored.feedPaperId, samplePaper.paperId);
    expect(restored.feedArxivId, samplePaper.arxivId);
    final rewritten = RestorationPreferences(preferences).loadCompact()!;
    expect(rewritten.feedIndex, 1);
    expect(rewritten.feedReference?.paperId, samplePaper.paperId);
  });

  test(
    'legacy index remains compatible when feed identity is absent',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await RestorationPreferences(preferences).saveCompact(
        CompactRestorationRecord.fromState(
          const AppRestorationState(feedIndex: 12),
        ),
      );
      final persistence = DriftRestorationPersistence(
        preferences: RestorationPreferences(preferences),
        persistPapers: (_) async {},
        loadPaper: (_) async => null,
        loadFeed: () async => FeedPage(items: [samplePaper]),
      );

      final restored = await persistence.load();

      expect(restored.feedIndex, 12);
      expect(restored.feedPaperId, isNull);
      expect(restored.feedArxivId, isNull);
    },
  );

  test('a verified compact record retires a leftover legacy key', () async {
    SharedPreferences.setMockInitialValues({
      legacyRestorationPreferencesKey: jsonEncode(
        const AppRestorationState(feedIndex: 99).toJson(),
      ),
    });
    final preferences = await SharedPreferences.getInstance();
    await RestorationPreferences(preferences).saveCompact(
      CompactRestorationRecord.fromState(
        const AppRestorationState(feedIndex: 2),
      ),
    );
    final persistence = DriftRestorationPersistence(
      preferences: RestorationPreferences(preferences),
      persistPapers: (_) async {},
      loadPaper: (_) async => null,
    );

    final restored = await persistence.load();

    expect(restored.feedIndex, 2);
    expect(preferences.containsKey(legacyRestorationPreferencesKey), isFalse);
  });

  test('writes are serialized so a later state cannot be overtaken', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final firstCommit = Completer<void>();
    final papers = <String, PaperSummary>{};
    var calls = 0;
    final persistence = DriftRestorationPersistence(
      preferences: RestorationPreferences(preferences),
      persistPapers: (values) async {
        calls += 1;
        if (calls == 1) await firstCommit.future;
        for (final paper in values) {
          papers[paper.paperId] = paper;
        }
      },
      loadPaper: (paperId) async => papers[paperId],
    );
    final first = persistence.save(const AppRestorationState(feedIndex: 1));
    final second = persistence.save(const AppRestorationState(feedIndex: 2));

    await Future<void>.delayed(Duration.zero);
    firstCommit.complete();
    await Future.wait([first, second]);

    expect(RestorationPreferences(preferences).loadCompact()!.feedIndex, 2);
  });
}
