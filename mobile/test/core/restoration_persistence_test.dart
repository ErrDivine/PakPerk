import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/cache/restoration_persistence.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart'
    as navigation;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  test(
    'compact record persists paper references without paper content',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final storage = RestorationPreferences(preferences);
      final readerKey = routeReaderKey('route-1', samplePaper);
      final state = AppRestorationState(
        activeBranchIndex: 1,
        feedIndex: 4,
        feedPaperId: samplePaper.paperId,
        feedArxivId: samplePaper.arxivId,
        routeStack: [PaperRouteEntry(routeId: 'route-1', paper: samplePaper)],
        readerStates: {
          readerKey: const ReaderNavigationState(
            stageIndex: 2,
            connectionsOffset: 125,
          ),
        },
      );

      await storage.saveCompact(CompactRestorationRecord.fromState(state));

      final raw = preferences.getString(compactRestorationPreferencesKey)!;
      expect(raw, isNot(contains(samplePaper.title)));
      expect(raw, isNot(contains(samplePaper.abstractText)));
      expect(raw, isNot(contains(samplePaper.authors.first)));
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      expect(json['format'], CompactRestorationRecord.format);
      expect(json['feed_ref'], {
        'paper_id': samplePaper.paperId,
        'arxiv_id': samplePaper.arxivId,
      });
      expect(json['route_refs'], [
        {
          'route_id': 'route-1',
          'paper_id': samplePaper.paperId,
          'arxiv_id': samplePaper.arxivId,
        },
      ]);

      final restored = storage.loadCompact()!;
      expect(restored.activeBranchIndex, 1);
      expect(restored.feedIndex, 4);
      expect(restored.feedReference?.paperId, samplePaper.paperId);
      expect(restored.feedReference?.arxivId, samplePaper.arxivId);
      expect(restored.routeReferences.single.routeId, 'route-1');
      expect(restored.readerStates[readerKey]?.stageIndex, 2);
      expect(restored.readerStates[readerKey]?.connectionsOffset, 125);
    },
  );

  test(
    'legacy decoder keeps valid routes when a sibling route is corrupt',
    () async {
      final validRoute = PaperRouteEntry(
        routeId: 'valid-route',
        paper: samplePaper,
      ).toJson();
      SharedPreferences.setMockInitialValues({
        legacyRestorationPreferencesKey: jsonEncode({
          'active_branch_index': 1,
          'feed_index': 7,
          'route_stack': [
            validRoute,
            {'route_id': 'broken', 'paper': 'not-a-map'},
            42,
          ],
          'reader_states': {
            'valid-reader': const ReaderNavigationState(
              stageIndex: 1,
              introductionOffset: 88,
            ).toJson(),
            'broken-reader': {'chat_sheet_open': 'not-a-bool'},
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();

      final restored = RestorationPreferences(preferences).loadLegacy()!;

      expect(restored.activeBranchIndex, 1);
      expect(restored.feedIndex, 7);
      expect(restored.routeStack, hasLength(1));
      expect(restored.routeStack.single.routeId, 'valid-route');
      expect(restored.routeStack.single.paper.paperId, samplePaper.paperId);
      expect(restored.readerStates.keys, ['valid-reader']);
      expect(restored.readerState('valid-reader').introductionOffset, 88);
    },
  );

  test(
    'compact decoder drops malformed route references independently',
    () async {
      SharedPreferences.setMockInitialValues({
        compactRestorationPreferencesKey: jsonEncode({
          'format': CompactRestorationRecord.format,
          'active_branch_index': 0,
          'feed_index': 2,
          'route_refs': [
            {
              'route_id': 'valid-route',
              'paper_id': samplePaper.paperId,
              'arxiv_id': samplePaper.arxivId,
            },
            {'route_id': 'missing-paper', 'paper_id': ''},
            'not-a-map',
          ],
          'reader_states': const {},
        }),
      });
      final preferences = await SharedPreferences.getInstance();

      final restored = RestorationPreferences(preferences).loadCompact()!;

      expect(restored.feedIndex, 2);
      expect(restored.routeReferences, hasLength(1));
      expect(restored.routeReferences.single.routeId, 'valid-route');
    },
  );

  test('decoder caps match the navigation restoration bounds', () {
    expect(maxDecodedRestorationRouteDepth, navigation.maxRestoredRouteDepth);
    expect(
      maxDecodedRestorationReaderStates,
      navigation.maxRestoredReaderStates,
    );
  });

  test(
    'compact decoder bounds routes and readers while retaining live readers',
    () async {
      final firstRetainedRouteKey = routeReaderKey('route-8', samplePaper);
      final currentFeedKey = feedReaderKey(samplePaper);
      SharedPreferences.setMockInitialValues({
        compactRestorationPreferencesKey: jsonEncode({
          'format': CompactRestorationRecord.format,
          'active_branch_index': 0,
          'feed_index': 9,
          'feed_ref': {
            'paper_id': samplePaper.paperId,
            'arxiv_id': samplePaper.arxivId,
          },
          'route_refs': [
            for (var index = 0; index < 40; index += 1)
              {
                'route_id': 'route-$index',
                'paper_id': samplePaper.paperId,
                'arxiv_id': samplePaper.arxivId,
              },
          ],
          'reader_states': {
            firstRetainedRouteKey: const ReaderNavigationState(
              stageIndex: 1,
            ).toJson(),
            currentFeedKey: const ReaderNavigationState(stageIndex: 2).toJson(),
            for (var index = 0; index < 80; index += 1)
              'feed:old-$index:old-v$index': ReaderNavigationState(
                abstractOffset: index.toDouble(),
              ).toJson(),
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();

      final restored = RestorationPreferences(preferences).loadCompact()!;

      expect(
        restored.routeReferences,
        hasLength(maxDecodedRestorationRouteDepth),
      );
      expect(restored.routeReferences.first.routeId, 'route-8');
      expect(restored.routeReferences.last.routeId, 'route-39');
      expect(
        restored.readerStates,
        hasLength(maxDecodedRestorationReaderStates),
      );
      expect(restored.readerStates, contains(firstRetainedRouteKey));
      expect(restored.readerStates, contains(currentFeedKey));
      expect(restored.readerStates, isNot(contains('feed:old-17:old-v17')));
      expect(restored.readerStates, contains('feed:old-18:old-v18'));
    },
  );

  test(
    'legacy decoder bounds routes and readers while retaining live readers',
    () async {
      final firstRetainedRouteKey = routeReaderKey('route-8', samplePaper);
      final currentFeedKey = feedReaderKey(samplePaper);
      SharedPreferences.setMockInitialValues({
        legacyRestorationPreferencesKey: jsonEncode({
          'active_branch_index': 0,
          'feed_index': 9,
          'feed_paper_id': samplePaper.paperId,
          'feed_arxiv_id': samplePaper.arxivId,
          'route_stack': [
            for (var index = 0; index < 40; index += 1)
              PaperRouteEntry(
                routeId: 'route-$index',
                paper: samplePaper,
              ).toJson(),
          ],
          'reader_states': {
            firstRetainedRouteKey: const ReaderNavigationState(
              stageIndex: 1,
            ).toJson(),
            currentFeedKey: const ReaderNavigationState(stageIndex: 2).toJson(),
            for (var index = 0; index < 80; index += 1)
              'feed:old-$index:old-v$index': ReaderNavigationState(
                abstractOffset: index.toDouble(),
              ).toJson(),
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();

      final restored = RestorationPreferences(preferences).loadLegacy()!;

      expect(restored.routeStack, hasLength(maxDecodedRestorationRouteDepth));
      expect(restored.routeStack.first.routeId, 'route-8');
      expect(restored.routeStack.last.routeId, 'route-39');
      expect(
        restored.readerStates,
        hasLength(maxDecodedRestorationReaderStates),
      );
      expect(restored.readerStates, contains(firstRetainedRouteKey));
      expect(restored.readerStates, contains(currentFeedKey));
      expect(restored.readerStates, isNot(contains('feed:old-17:old-v17')));
      expect(restored.readerStates, contains('feed:old-18:old-v18'));
    },
  );
}
