import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/api/request_cancellation.dart';
import 'package:pakperk/core/database/account_cache_dao.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/document_cache_dao.dart';
import 'package:pakperk/core/content_policy.dart';
import 'package:pakperk/core/api/transport_network_status.dart';
import 'package:pakperk/core/document/document_api.dart';
import 'package:pakperk/core/document/document_repository.dart';
import 'package:pakperk/core/models/document_block.dart';
import 'package:pakperk/core/models/provenance.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/models/reading_checkpoint.dart';
import 'package:pakperk/core/models/semantic_span.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/reader_modes/reader_mode.dart';

void main() {
  test('document cache is generation/account fenced', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final cache = DocumentCacheDao(database);
    final snapshot = _snapshot();

    await cache.writeSnapshot(accountId: 'account-a', snapshot: snapshot);

    final restored = await cache.readSnapshot(
      accountId: 'account-a',
      paperId: snapshot.paperId,
      versionKey: snapshot.versionKey,
      generation: snapshot.generation,
    );
    expect(restored, isNotNull);
    expect(restored!.semanticSpans.single.facet, SemanticFacet.method);
    expect(
      await cache.readSnapshot(
        accountId: 'account-b',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
      ),
      isNull,
    );
    expect(
      await cache.readSnapshot(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation + 1,
      ),
      isNull,
    );
  });

  test('a cancelled remote load cannot write a stale account cache', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final cache = DocumentCacheDao(database);
    final network = TransportNetworkStatus();
    addTearDown(network.dispose);
    final cancellation = RequestCancellation();
    final snapshot = _snapshot();
    final barrier = AccountDataWriteBarrier();
    final repository = DocumentRepository(
      remote: _CancelingDocumentRemote(snapshot),
      cache: cache,
      networkStatus: network,
      fulltextPolicy: ClientFulltextPolicy.prototype,
      accountWrites: barrier,
      accountScopeIsCurrent: (accountId, authEpoch) =>
          accountId == 'account-a' && authEpoch == 1,
    );

    await expectLater(
      repository.load(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
        expectedAuthEpoch: 1,
        includePassport: false,
        includeSemanticFacets: true,
        includeVisualObjects: false,
        force: true,
        cancellation: cancellation,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'REQUEST_CANCELLED',
        ),
      ),
    );
    expect(
      await cache.readSnapshot(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
      ),
      isNull,
    );
  });

  test(
    'document cache emits only bounded hit, size, and eviction signals',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final telemetry = _RecordingTelemetrySink();
      final redacting = RedactingTelemetrySink(telemetry);
      final cache = DocumentCacheDao(database, telemetry: redacting);
      final network = TransportNetworkStatus();
      addTearDown(network.dispose);
      final barrier = AccountDataWriteBarrier();
      final repository = DocumentRepository(
        remote: _UnusedDocumentRemote(),
        cache: cache,
        networkStatus: network,
        fulltextPolicy: ClientFulltextPolicy.prototype,
        accountWrites: barrier,
        accountScopeIsCurrent: (accountId, authEpoch) =>
            accountId == 'account-a' && authEpoch == 1,
        telemetry: redacting,
      );
      final snapshot = _snapshot();

      await cache.writeSnapshot(accountId: 'account-a', snapshot: snapshot);
      expect(
        telemetry.events.single.$1,
        PakPerkTelemetryEvent.documentCacheSize,
      );
      expect(telemetry.events.single.$2.keys, const ['bytes']);
      expect(telemetry.events.single.$2['bytes'], greaterThan(0));

      telemetry.events.clear();
      final hit = await repository.load(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
        expectedAuthEpoch: 1,
        includePassport: false,
        includeSemanticFacets: false,
        includeVisualObjects: false,
        force: false,
      );
      expect(hit.fromCache, isTrue);
      expect(telemetry.events.single.$2, const {
        'outcome': 'hit',
        'offline': false,
      });

      telemetry.events.clear();
      await cache.readSnapshot(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
        now: snapshot.fetchedAt.add(const Duration(days: 31)),
      );
      expect(
        telemetry.events.single.$1,
        PakPerkTelemetryEvent.documentCacheEviction,
      );
      expect(telemetry.events.single.$2, const {
        'reason': 'expired',
        'count': 1,
      });

      telemetry.events.clear();
      network.markOffline();
      await expectLater(
        repository.load(
          accountId: 'account-a',
          paperId: snapshot.paperId,
          versionKey: snapshot.versionKey,
          generation: snapshot.generation,
          expectedAuthEpoch: 1,
          includePassport: false,
          includeSemanticFacets: false,
          includeVisualObjects: false,
          force: false,
        ),
        throwsA(isA<Object>()),
      );
      expect(telemetry.events.single.$2, const {
        'outcome': 'miss',
        'offline': true,
      });
    },
  );

  test(
    'account cleanup cannot be followed by a late document cache write',
    () async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final cache = DocumentCacheDao(database);
      final accounts = AccountCacheDao(database);
      final network = TransportNetworkStatus();
      addTearDown(network.dispose);
      final barrier = AccountDataWriteBarrier();
      final remote = _DelayedDocumentRemote();
      final snapshot = _snapshot();
      var current = true;
      final repository = DocumentRepository(
        remote: remote,
        cache: cache,
        networkStatus: network,
        fulltextPolicy: ClientFulltextPolicy.prototype,
        accountWrites: barrier,
        accountScopeIsCurrent: (accountId, authEpoch) =>
            current && accountId == 'account-a' && authEpoch == 1,
      );

      final load = repository.load(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
        expectedAuthEpoch: 1,
        includePassport: false,
        includeSemanticFacets: true,
        includeVisualObjects: false,
        force: true,
      );
      await remote.started.future;
      current = false;
      await barrier.clear(
        accountId: 'account-a',
        invalidatedThroughEpoch: 1,
        clearAccount: accounts.clearAccountData,
        clearAll: accounts.clearAllAccountData,
      );
      remote.result.complete(snapshot);

      await expectLater(
        load,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'REQUEST_CANCELLED',
          ),
        ),
      );
      expect(
        await cache.readSnapshot(
          accountId: 'account-a',
          paperId: snapshot.paperId,
          versionKey: snapshot.versionKey,
          generation: snapshot.generation,
        ),
        isNull,
      );
    },
  );

  test('checkpoint schema has no Library-state authority', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final columns = await database
        .customSelect('PRAGMA table_info(reading_checkpoints)')
        .get();
    final names = columns
        .map((row) => row.read<String>('name').toLowerCase())
        .toSet();

    expect(
      names,
      containsAll(const {
        'account_id',
        'paper_id',
        'generation',
        'mode',
        'stage',
        'block_id',
        'scroll_fraction',
        'last_read_at',
        'revision',
        'pending_sync',
      }),
    );
    expect(names, isNot(contains('library_state')));
    expect(names, isNot(contains('reviewed')));
    expect(names, isNot(contains('queue_state')));
  });

  test('account cleanup removes documents and checkpoints together', () async {
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final cache = DocumentCacheDao(database);
    final snapshot = _snapshot();
    final checkpoint = ReadingCheckpoint(
      accountId: 'account-a',
      paperId: snapshot.paperId,
      generation: snapshot.generation,
      mode: ReaderDepthMode.inspect,
      stage: PaperStage.introduction,
      blockId: 'block-1',
      scrollFraction: .5,
      lastReadAt: DateTime.utc(2026, 8, 31),
      revision: 0,
      pendingSync: true,
    );
    await cache.writeSnapshot(accountId: 'account-a', snapshot: snapshot);
    await cache.writeCheckpoint(checkpoint);

    await AccountCacheDao(database).clearAccountData('account-a');

    expect(
      await cache.readSnapshot(
        accountId: 'account-a',
        paperId: snapshot.paperId,
        versionKey: snapshot.versionKey,
        generation: snapshot.generation,
      ),
      isNull,
    );
    expect(
      await cache.readCheckpoint(
        accountId: 'account-a',
        paperId: snapshot.paperId,
      ),
      isNull,
    );
  });
}

final class _UnusedDocumentRemote implements DocumentRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CancelingDocumentRemote implements DocumentRemoteDataSource {
  const _CancelingDocumentRemote(this.snapshot);

  final DocumentSnapshot snapshot;

  @override
  Future<DocumentSnapshot> fetchSnapshot({
    required String paperId,
    required String versionKey,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    RequestCancellation? cancellation,
  }) async {
    cancellation?.cancel('Superseded by a newer document request.');
    return snapshot;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DelayedDocumentRemote implements DocumentRemoteDataSource {
  final started = Completer<void>();
  final result = Completer<DocumentSnapshot>();

  @override
  Future<DocumentSnapshot> fetchSnapshot({
    required String paperId,
    required String versionKey,
    required int expectedGeneration,
    required int expectedAuthEpoch,
    required bool includePassport,
    required bool includeSemanticFacets,
    required bool includeVisualObjects,
    RequestCancellation? cancellation,
  }) {
    started.complete();
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingTelemetrySink implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map<String, Object?>.from(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

DocumentSnapshot _snapshot() {
  const provenance = ProvenanceSummary(status: 'ready');
  const paperId = '00000000-0000-4000-8000-000000000001';
  const blockId = '00000000-0000-4000-8000-000000000002';
  return DocumentSnapshot(
    paperId: paperId,
    versionKey: '2601.00001v1',
    generation: 2,
    outline: DocumentOutline(
      paperId: paperId,
      generation: 2,
      sections: [
        DocumentSection(
          id: 'section-1',
          stableKey: 'introduction',
          title: 'Introduction',
          level: 1,
          ordinal: 0,
          blockIds: const [blockId],
        ),
      ],
      provenance: provenance,
    ),
    blocks: [
      DocumentBlock(
        id: blockId,
        paperId: paperId,
        generation: 2,
        stableKey: 'introduction:paragraph:0',
        ordinal: 0,
        sectionPath: const ['Introduction'],
        kind: DocumentBlockKind.paragraph,
        text: 'A cached document paragraph.',
        contentHash: 'hash-1',
      ),
    ],
    figures: const [],
    tables: const [],
    equations: const [],
    terms: const [],
    semanticSpans: [
      SemanticSpan(
        id: '00000000-0000-4000-8000-000000000003',
        blockId: blockId,
        ordinal: 0,
        startOffset: 0,
        endOffset: 8,
        facet: SemanticFacet.method,
        minimumDensity: SemanticDensity.key,
        sourceKind: SemanticSpanSourceKind.deterministic,
        confidenceBasisPoints: 8000,
        supportStatus: SemanticSupportStatus.supported,
        provenanceId: '00000000-0000-4000-8000-000000000004',
        createdAt: DateTime.utc(2026, 8, 31),
      ),
    ],
    passport: null,
    provenance: provenance,
    fetchedAt: DateTime.utc(2026, 8, 31),
    semanticFacetsIncluded: true,
  );
}
