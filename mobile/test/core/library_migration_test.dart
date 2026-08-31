import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test(
    'frozen v3 upgrades through Library v2 without losing legacy rows',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      raw.execute(_schemaV3);
      raw.execute(
        'INSERT INTO cached_papers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [_paperId, '2607.00001', 1, _paperJson, 1, 2, 3, 4, 0],
      );
      raw.execute('INSERT INTO library_items VALUES (?, ?, ?, ?, ?, ?)', [
        _accountId,
        _paperId,
        'to_read',
        20,
        21,
        0,
      ]);
      raw.execute(
        'INSERT INTO sync_outbox VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          _oldOperationId,
          _accountId,
          'library_item',
          _paperId,
          'library_save',
          '{"state":"to_read"}',
          22,
          0,
          null,
          null,
        ],
      );
      raw.execute(
        'INSERT INTO sync_outbox VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          _newOperationId,
          _accountId,
          'library_item',
          _paperId,
          'library_remove',
          '{}',
          23,
          0,
          null,
          null,
        ],
      );
      raw.execute('PRAGMA user_version = 3');

      final database = PakPerkDatabase(NativeDatabase.opened(raw));
      addTearDown(database.close);

      expect(database.schemaVersion, 10);
      final tables = await database
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      expect(
        tables.map((row) => row.read<String>('name')),
        containsAll(const {
          'library_sync_states',
          'library_custom_lists',
          'library_tags',
          'library_list_memberships',
          'library_tag_memberships',
        }),
      );
      final libraryColumns = await database
          .customSelect('PRAGMA table_info(library_items)')
          .get();
      expect(
        libraryColumns.map((row) => row.read<String>('name')),
        containsAll(const {
          'saved_at',
          'removed_at',
          'revision',
          'last_operation_id',
          'canonical_deleted',
          'canonical_saved_at',
          'canonical_removed_at',
          'private_note',
          'save_source_kind',
          'reminder_at',
          'reviewed_at',
          'archived_at',
          'canonical_list_state',
          'canonical_private_note',
          'canonical_save_source_kind',
          'canonical_reminder_at',
          'canonical_reviewed_at',
          'canonical_archived_at',
        }),
      );
      final outboxColumns = await database
          .customSelect('PRAGMA table_info(sync_outbox)')
          .get();
      expect(
        outboxColumns.map((row) => row.read<String>('name')),
        containsAll(const {'state', 'started_at', 'updated_at'}),
      );

      final item = await database.select(database.libraryItems).getSingle();
      expect(item.paperId, _paperId);
      expect(item.deleted, isFalse);
      expect(item.savedAt, item.clientUpdatedAt);
      expect(item.canonicalDeleted, isFalse);
      expect(item.canonicalSavedAt, item.clientUpdatedAt);
      expect(item.lastOperationId, isNull);
      expect(item.revision, isNull);
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isTrue,
      );

      final outbox = await database.select(database.syncOutbox).get();
      expect(
        outbox,
        hasLength(1),
        reason: 'migration keeps newest queued intent',
      );
      expect(outbox.single.operationId, _newOperationId);
      expect(outbox.single.state, 'queued');
      expect(outbox.single.updatedAt, outbox.single.createdAt);

      await (database.update(database.syncOutbox)
            ..where((row) => row.operationId.equals(_newOperationId)))
          .write(const SyncOutboxCompanion(state: Value('in_flight')));
      await database
          .into(database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              operationId: _queuedOperationId,
              accountId: const Value(_accountId),
              entityKind: 'library_item',
              entityId: _paperId,
              operation: 'library_save',
              payloadJson: '{"state":"to_read"}',
              createdAt: DateTime.utc(2026, 7, 31, 12),
              state: const Value('queued'),
              updatedAt: Value(DateTime.utc(2026, 7, 31, 12)),
            ),
          );
      await expectLater(
        database
            .into(database.syncOutbox)
            .insert(
              SyncOutboxCompanion.insert(
                operationId: _duplicateQueuedOperationId,
                accountId: const Value(_accountId),
                entityKind: 'library_item',
                entityId: _paperId,
                operation: 'library_remove',
                payloadJson: '{}',
                createdAt: DateTime.utc(2026, 7, 31, 12, 1),
                state: const Value('queued'),
                updatedAt: Value(DateTime.utc(2026, 7, 31, 12, 1)),
              ),
            ),
        throwsA(isA<Exception>()),
      );

      await (database.update(database.libraryItems)..where(
            (row) =>
                row.accountId.equals(_accountId) & row.paperId.equals(_paperId),
          ))
          .write(const LibraryItemsCompanion(deleted: Value(true)));
      expect(
        (await database.select(database.cachedPapers).getSingle())
            .pinnedByLibrary,
        isFalse,
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      expect(
        (await database.customSelect('PRAGMA integrity_check').getSingle())
            .data
            .values
            .single,
        'ok',
      );
    },
  );

  test('v9 account-owned schema has no credential or reply columns', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final tables = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    for (final table
        in tables
            .map((row) => row.read<String>('name'))
            .where((name) => !name.startsWith('sqlite_'))) {
      final columns = await database
          .customSelect('PRAGMA table_info($table)')
          .get();
      final names = columns
          .map((row) => row.read<String>('name').toLowerCase())
          .toList();
      expect(
        names.where(
          (name) =>
              name.contains('access_token') ||
              name.contains('refresh_token') ||
              name.contains('authorization_code') ||
              name.contains('client_secret'),
        ),
        isEmpty,
        reason: '$table must not store credentials',
      );
    }
    final draftColumns = await database
        .customSelect('PRAGMA table_info(comment_drafts)')
        .get();
    expect(
      draftColumns.map((row) => row.read<String>('name')),
      isNot(contains('parent_comment_id')),
    );
  });

  test(
    'frozen v4 upgrades to v9, scopes drafts, and removes reply metadata',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      raw.execute(_schemaV3);
      raw.execute(_schemaV4Delta);
      raw.execute(
        'INSERT INTO cached_papers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [_paperId, '2607.00001', 1, _paperJson, 1, 2, 3, 4, 0],
      );
      raw.execute(
        'INSERT INTO cached_comment_pages VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'comments:first',
          _paperId,
          null,
          '{"items":[],"next_cursor":null}',
          10,
          11,
          null,
        ],
      );
      raw.execute('INSERT INTO comment_drafts VALUES (?, ?, ?, ?, ?, ?, ?)', [
        'scoped-draft',
        _accountId,
        _paperId,
        'legacy-parent-that-must-be-discarded',
        'keep until this account signs out',
        12,
        13,
      ]);
      raw.execute('INSERT INTO comment_drafts VALUES (?, ?, ?, ?, ?, ?, ?)', [
        'unbound-draft',
        null,
        _paperId,
        null,
        'must not attach to a future login',
        12,
        13,
      ]);
      raw.execute('PRAGMA user_version = 4');

      final database = PakPerkDatabase(NativeDatabase.opened(raw));
      addTearDown(database.close);

      expect(database.schemaVersion, 10);
      final cached = await database.select(database.cachedCommentPages).get();
      expect(cached, hasLength(1));
      expect(cached.single.viewerAccountId, isNull);
      expect(cached.single.payloadJson, contains('next_cursor'));
      final drafts = await database.select(database.commentDrafts).get();
      expect(drafts, hasLength(1));
      expect(drafts.single.draftId, 'scoped-draft');
      expect(drafts.single.clientRequestId, isNull);
      expect(drafts.single.lastAttemptedBody, isNull);
      final draftColumns = await database
          .customSelect('PRAGMA table_info(comment_drafts)')
          .get();
      expect(
        draftColumns.map((row) => row.read<String>('name')),
        isNot(contains('parent_comment_id')),
      );
      final tables = await database
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      expect(
        tables.map((row) => row.read<String>('name')),
        contains('blocked_users'),
      );
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      expect(
        (await database.customSelect('PRAGMA integrity_check').getSingle())
            .data
            .values
            .single,
        'ok',
      );
    },
  );

  test('frozen v7 adds nullable visible and canonical reminders', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pakperk-reminder-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/library.sqlite');
    final current = PakPerkDatabase.atPath(NativeDatabase(file), file.path);
    await current.customSelect('SELECT 1').get();
    await current.close();

    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('ALTER TABLE library_items DROP COLUMN reminder_at');
    raw.execute('ALTER TABLE library_items DROP COLUMN canonical_reminder_at');
    raw.execute('PRAGMA user_version = 7');
    raw.close();

    final upgraded = PakPerkDatabase.atPath(NativeDatabase(file), file.path);
    addTearDown(upgraded.close);
    final columns = await upgraded
        .customSelect('PRAGMA table_info(library_items)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll(const {'reminder_at', 'canonical_reminder_at'}),
    );
    expect(upgraded.schemaVersion, 10);
  });
}

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
const _paperId = '018f47a6-4b56-7f4c-8c7a-e2656e820101';
const _oldOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _newOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _queuedOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820203';
const _duplicateQueuedOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820204';
const _paperJson =
    '''
{"paper_id":"$_paperId","arxiv_id":"2607.00001v1","title":"Saved",
"abstract":"","authors":["Ada"],"primary_category":"cs.CL",
"categories":["cs.CL"],"published_at":"2026-07-01T00:00:00Z",
"updated_at":"2026-07-02T00:00:00Z",
"abs_url":"https://arxiv.org/abs/2607.00001v1",
"pdf_url":"https://arxiv.org/pdf/2607.00001v1"}
''';

/// Frozen production schema v3. Phase 4 must migrate this exact shape in
/// place; changing the fixture to match v4 would hide upgrade regressions.
const _schemaV3 = '''
PRAGMA foreign_keys = ON;
CREATE TABLE cached_papers (
  paper_id TEXT NOT NULL PRIMARY KEY,
  arxiv_base_id TEXT NOT NULL,
  arxiv_version INTEGER NULL,
  metadata_json TEXT NOT NULL,
  published_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_accessed_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  pinned_by_library INTEGER NOT NULL DEFAULT 0 CHECK (pinned_by_library IN (0, 1))
);
CREATE TABLE feed_queries (
  query_key TEXT NOT NULL PRIMARY KEY,
  category TEXT NULL,
  next_cursor TEXT NULL,
  refreshed_at INTEGER NOT NULL,
  exhausted INTEGER NOT NULL DEFAULT 0 CHECK (exhausted IN (0, 1)),
  etag TEXT NULL,
  entry_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE feed_entries (
  query_key TEXT NOT NULL REFERENCES feed_queries(query_key) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  inserted_at INTEGER NOT NULL,
  PRIMARY KEY (query_key, paper_id),
  UNIQUE (query_key, position)
);
CREATE TABLE cached_processing (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_introductions (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  generation INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_connections (
  paper_id TEXT NOT NULL PRIMARY KEY REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  version_key TEXT NOT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NULL
);
CREATE TABLE cached_comment_pages (
  page_key TEXT NOT NULL PRIMARY KEY,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  cursor TEXT NULL,
  payload_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  etag TEXT NULL
);
CREATE TABLE cached_chats (
  session_id TEXT NOT NULL,
  reader_key TEXT NOT NULL,
  paper_id TEXT NULL REFERENCES cached_papers(paper_id) ON DELETE CASCADE,
  version_key TEXT NULL,
  generation INTEGER NOT NULL DEFAULT 0,
  payload_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (session_id, reader_key)
);
CREATE TABLE library_items (
  account_id TEXT NOT NULL,
  paper_id TEXT NOT NULL,
  list_state TEXT NOT NULL DEFAULT 'to_read',
  client_updated_at INTEGER NOT NULL,
  server_updated_at INTEGER NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  PRIMARY KEY (account_id, paper_id)
);
CREATE TABLE comment_drafts (
  draft_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  paper_id TEXT NOT NULL REFERENCES cached_papers(paper_id) ON DELETE RESTRICT,
  parent_comment_id TEXT NULL,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE sync_outbox (
  operation_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NULL,
  entity_kind TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NULL,
  last_error_code TEXT NULL
);
CREATE TABLE cache_metadata (
  key TEXT NOT NULL PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

const _schemaV4Delta = '''
ALTER TABLE library_items ADD COLUMN saved_at INTEGER NULL;
ALTER TABLE library_items ADD COLUMN removed_at INTEGER NULL;
ALTER TABLE library_items ADD COLUMN revision INTEGER NULL;
ALTER TABLE library_items ADD COLUMN last_operation_id TEXT NULL;
ALTER TABLE library_items ADD COLUMN canonical_deleted INTEGER NULL
  CHECK (canonical_deleted IN (0, 1));
ALTER TABLE library_items ADD COLUMN canonical_saved_at INTEGER NULL;
ALTER TABLE library_items ADD COLUMN canonical_removed_at INTEGER NULL;
ALTER TABLE sync_outbox ADD COLUMN state TEXT NOT NULL DEFAULT 'queued';
ALTER TABLE sync_outbox ADD COLUMN started_at INTEGER NULL;
ALTER TABLE sync_outbox ADD COLUMN updated_at INTEGER NULL;
CREATE TABLE library_sync_states (
  account_id TEXT NOT NULL PRIMARY KEY,
  last_revision INTEGER NOT NULL DEFAULT 0,
  initialized INTEGER NOT NULL DEFAULT 0 CHECK (initialized IN (0, 1)),
  last_full_sync_at INTEGER NULL
);
''';
