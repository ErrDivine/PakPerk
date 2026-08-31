import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/discovery_search/search_privacy_store.dart';
import 'package:pakperk/features/search/research_search_models.dart';
import 'package:pakperk/features/search/search_privacy_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('successful queries are retained only after explicit opt in', () async {
    final store = SharedPreferencesSearchPrivacyStore();
    final controller = SearchPrivacyController(
      store: store,
      accountDataWriteBarrier: AccountDataWriteBarrier(),
      accountScope: _scopeA,
      clock: () => DateTime.utc(2026, 8, 28),
    );
    addTearDown(controller.dispose);
    await _settle();

    await controller.record(
      PrivateSearchHistoryMode.explore,
      'graph neural networks',
    );
    expect(controller.state.entries, isEmpty);

    await controller.setEnabled(true);
    await controller.record(
      PrivateSearchHistoryMode.explore,
      'graph neural networks',
    );
    expect(controller.state.enabled, isTrue);
    expect(controller.state.entries.single.query, 'graph neural networks');

    await controller.setEnabled(false);
    expect(controller.state.enabled, isFalse);
    expect(controller.state.entries, isEmpty);
    expect((await store.loadHistory(_scopeA.accountId)).entries, isEmpty);
  });

  test('account switch clears visible history synchronously', () async {
    final store = SharedPreferencesSearchPrivacyStore();
    await store.saveHistory(
      _scopeA.accountId,
      PrivateSearchHistorySnapshot(
        enabled: true,
        entries: [
          PrivateSearchHistoryEntry(
            query: 'private account A query',
            mode: PrivateSearchHistoryMode.lookup,
            searchedAt: DateTime.utc(2026, 8, 28),
          ),
        ],
      ),
    );
    final controller = SearchPrivacyController(
      store: store,
      accountDataWriteBarrier: AccountDataWriteBarrier(),
      accountScope: _scopeA,
    );
    addTearDown(controller.dispose);
    await _settle();
    expect(controller.state.entries.single.query, 'private account A query');

    controller.updateAccountScope(_scopeB);

    expect(controller.state.loading, isTrue);
    expect(controller.state.enabled, isFalse);
    expect(controller.state.entries, isEmpty);
    await _settle();
    expect(controller.state.entries, isEmpty);
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

const _scopeA = ResearchSearchAccountScope(
  accountId: 'account-a',
  authEpoch: 1,
  accountGeneration: 0,
);
const _scopeB = ResearchSearchAccountScope(
  accountId: 'account-b',
  authEpoch: 2,
  accountGeneration: 1,
);
