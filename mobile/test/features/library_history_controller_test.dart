import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_history_store.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/library/library_history_controller.dart';
import 'package:pakperk/features/library/library_history_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'history storage is account-scoped and corrupt state fails disabled',
    () async {
      SharedPreferences.setMockInitialValues({
        '${libraryHistoryPreferencesPrefix}account-b': '{"schema":9}',
      });
      final store = SharedPreferencesLibraryHistoryStore();
      await store.save(
        'account-a',
        LibraryHistorySnapshot(
          enabled: true,
          entries: [
            LibraryHistoryEntry(
              paper: samplePaper,
              openedAt: DateTime.utc(2026, 8, 19, 10),
            ),
          ],
        ),
      );

      final accountA = await store.load('account-a');
      final accountB = await store.load('account-b');
      expect(accountA.enabled, isTrue);
      expect(accountA.entries.single.paper.paperId, samplePaper.paperId);
      expect(accountB.enabled, isFalse);
      expect(accountB.entries, isEmpty);

      await store.clear('account-a');
      expect((await store.load('account-a')).enabled, isFalse);
      await store.clearAll();
      expect(
        (await SharedPreferences.getInstance()).getKeys().where(
          (key) => key.startsWith(libraryHistoryPreferencesPrefix),
        ),
        isEmpty,
      );
    },
  );

  test(
    'controller deduplicates opens and rejects stale account scope',
    () async {
      final store = _MemoryHistoryStore(LibraryHistorySnapshot(enabled: true));
      var scopeIsCurrent = true;
      var minute = 0;
      final controller = LibraryHistoryController(
        store: store,
        accountId: 'account-a',
        scopeIsCurrent: () => scopeIsCurrent,
        clock: () => DateTime.utc(2026, 8, 19, 10, minute++),
      );
      addTearDown(controller.dispose);

      await controller.load();
      await controller.record(samplePaper);
      await controller.record(samplePaper);
      expect(controller.state.entries, hasLength(1));
      expect(
        controller.state.entries.single.openedAt,
        DateTime.utc(2026, 8, 19, 10, 1),
      );
      expect(store.saveCalls, 2);

      scopeIsCurrent = false;
      await controller.clear();
      expect(store.saveCalls, 2);
      expect(controller.state.entries, hasLength(1));
    },
  );

  testWidgets('private history remains usable at 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clearCalls = 0;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: LibraryHistoryView(
                  enabled: true,
                  entries: [
                    LibraryHistoryEntry(
                      paper: samplePaper,
                      openedAt: DateTime.utc(2026, 8, 19, 10),
                    ),
                  ],
                  loading: false,
                  saving: false,
                  errorMessage: null,
                  onEnabledChanged: (_) {},
                  onClear: () => clearCalls += 1,
                  onOpenPaper: (_) => opened = true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('It never changes To Read'), findsOneWidget);
    final clear = find.byKey(const ValueKey('library-history-clear'));
    await tester.ensureVisible(clear);
    expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
    await tester.tap(clear);
    expect(clearCalls, 1);

    final paper = find.byKey(
      ValueKey('library-history-paper-${samplePaper.paperId}'),
    );
    await tester.ensureVisible(paper);
    await tester.tap(paper);
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });
}

final class _MemoryHistoryStore implements LibraryHistoryStore {
  _MemoryHistoryStore(this.snapshot);

  LibraryHistorySnapshot snapshot;
  int saveCalls = 0;

  @override
  Future<LibraryHistorySnapshot> load(String accountId) async => snapshot;

  @override
  Future<void> save(String accountId, LibraryHistorySnapshot next) async {
    saveCalls += 1;
    snapshot = next;
  }

  @override
  Future<void> clear(String accountId) async {
    snapshot = const LibraryHistorySnapshot.disabled();
  }

  @override
  Future<void> clearAll() async {
    snapshot = const LibraryHistorySnapshot.disabled();
  }
}
