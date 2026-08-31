import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/paper_import_draft_store.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'draft ledger is bounded, account scoped, and uses hashed keys',
    () async {
      final store = SharedPreferencesPaperImportDraftStore();
      final now = DateTime.utc(2026, 8, 28, 8);
      final drafts = [
        for (var index = 1; index <= 4; index++) _draft(index, now),
      ];

      await store.save(_accountA, drafts);
      final loaded = await store.load(_accountA, now: now);

      expect(loaded, hasLength(4));
      expect(await store.load(_accountB, now: now), isEmpty);
      final key = (await SharedPreferences.getInstance()).getKeys().single;
      expect(key, isNot(contains(_accountA)));
      expect(key, contains(paperImportDraftScopeFingerprint(_accountA)));
      expect(
        () => store.save(_accountA, [...drafts, _draft(5, now)]),
        throwsArgumentError,
      );
    },
  );

  test('expired drafts stop authority and are physically removed', () async {
    final store = SharedPreferencesPaperImportDraftStore();
    final now = DateTime.utc(2026, 8, 28, 8);
    await store.save(_accountA, [_draft(1, now)]);

    final loaded = await store.load(
      _accountA,
      now: now.add(PaperImportDraft.defaultRetention),
    );

    expect(loaded, isEmpty);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'corruption is not converted into an authoritative empty ledger',
    () async {
      final key =
          '$paperImportDraftPreferencesPrefix${paperImportDraftScopeFingerprint(_accountA)}';
      SharedPreferences.setMockInitialValues({key: '{not-json'});
      final store = SharedPreferencesPaperImportDraftStore();

      expect(store.load(_accountA), throwsFormatException);
    },
  );

  test('draft serialization retains only canonical retry identity', () async {
    final store = SharedPreferencesPaperImportDraftStore();
    final now = DateTime.utc(2026, 8, 28, 8);
    final draft = PaperImportDraft(
      operationId: _operationId(1),
      source: const PaperImportSource(
        kind: PaperImportSourceKind.arxivUrl,
        value: 'https://arxiv.org/abs/2401.00001v1',
      ),
      saveSourceKind: LibrarySaveSourceKind.titleSearch,
      status: PaperImportDraftStatus.retryableFailure,
      createdAt: now,
      expiresAt: now.add(PaperImportDraft.defaultRetention),
      failureCode: 'ARXIV_UNAVAILABLE',
    );

    await store.save(_accountA, [draft]);

    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(preferences.getKeys().single)!;
    expect(raw, contains('https://arxiv.org/abs/2401.00001v1'));
    expect(raw, contains('"save_source_kind":"title_search"'));
    expect(raw, isNot(contains('A user-entered paper title')));
    final restored = (await store.load(_accountA, now: now)).single;
    expect(restored.failureCode, 'ARXIV_UNAVAILABLE');
    expect(restored.saveSourceKind, LibrarySaveSourceKind.titleSearch);
  });
}

PaperImportDraft _draft(int index, DateTime now) => PaperImportDraft(
  operationId: _operationId(index),
  source: PaperImportSource(
    kind: PaperImportSourceKind.arxivId,
    value: '2401.${index.toString().padLeft(5, '0')}v1',
  ),
  saveSourceKind: LibrarySaveSourceKind.arxivId,
  status: PaperImportDraftStatus.importing,
  createdAt: now,
  expiresAt: now.add(PaperImportDraft.defaultRetention),
);

String _operationId(int index) =>
    '70000000-0000-7000-8000-${index.toString().padLeft(12, '0')}';

const _accountA = 'account-a';
const _accountB = 'account-b';
