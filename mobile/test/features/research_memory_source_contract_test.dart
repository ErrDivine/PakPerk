import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/transport_network_status.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/research_cache_dao.dart';
import 'package:pakperk/core/models/annotation.dart';
import 'package:pakperk/core/models/evidence_card.dart';
import 'package:pakperk/core/models/paper_passport.dart';
import 'package:pakperk/core/models/research_memory.dart';
import 'package:pakperk/core/research/research_api.dart';
import 'package:pakperk/core/research/research_repository.dart';
import 'package:pakperk/features/research/research_controller.dart';

void main() {
  late PakPerkDatabase database;
  late ResearchCacheDao cache;
  late TransportNetworkStatus network;
  late ResearchRepository repository;
  late ResearchController controller;

  setUp(() {
    database = PakPerkDatabase(NativeDatabase.memory());
    cache = ResearchCacheDao(database);
    network = TransportNetworkStatus()..markOffline();
    repository = ResearchRepository(
      remote: _UnusedRemote(),
      cache: cache,
      networkStatus: network,
    );
    controller = ResearchController(
      args: researchArgs,
      source: repository,
      scopeIsCurrent: () => true,
    );
  });

  tearDown(() async {
    controller.dispose();
    await pumpEventQueue();
    network.dispose();
    await database.close();
  });

  test('question annotations use the user-question memory payload', () async {
    final item = await controller.rememberAnnotation(
      _annotation(kind: AnnotationKind.question),
    );

    expect(item.sourceType, MemorySourceType.userQuestion);
    expect(item.promptText, 'What remains unresolved?');
    expect(item.answerText, 'unresolved question');
    final operation = (await cache.pendingOperations(accountId)).single;
    expect(operation.payload['source_type'], 'user_question');
    expect(operation.payload['prompt_text'], 'What remains unresolved?');
    expect(operation.payload['answer_text'], 'unresolved question');
    expect(operation.payload['paper_id'], paperId);
    expect(operation.payload['generation'], 2);
    expect(await database.select(database.libraryItems).get(), isEmpty);
  });

  test(
    'affected-version annotation becomes an explicit revisit memory',
    () async {
      final item = await controller.rememberAnnotation(
        _annotation(
          kind: AnnotationKind.note,
          anchorStatus: AnnotationAnchorStatus.uncertain,
        ),
      );

      expect(item.sourceType, MemorySourceType.annotation);
      expect(
        item.promptText,
        'Revisit this saved annotation after the paper changed.',
      );
      expect(item.answerText, 'What remains unresolved?');
      expect((await cache.pendingOperations(accountId)), hasLength(1));
      expect(await database.select(database.libraryItems).get(), isEmpty);
    },
  );

  test(
    'unreviewed evidence fails locally without creating an outbox row',
    () async {
      final card = EvidenceCard(
        id: evidenceId,
        paperId: paperId,
        generation: 2,
        title: 'Candidate evidence',
        verificationStatus: EvidenceVerificationStatus.userSelected,
        revision: 1,
        createdAt: now,
        updatedAt: now,
      );

      expect(() => controller.rememberEvidence(card), throwsStateError);
      expect(await cache.pendingOperations(accountId), isEmpty);
      expect(await cache.memoryItems(accountId: accountId), isEmpty);
    },
  );

  test('validated Passport field maps to a bounded memory payload', () async {
    final field = _passportField();

    final item = await controller.rememberPassportField(field);

    expect(item.sourceType, MemorySourceType.passportField);
    expect(item.sourceId, passportFieldId);
    expect(item.promptText, 'What does the paper say about limitations?');
    expect(item.answerText, 'The evaluation covers adults only.');
    final operation = (await cache.pendingOperations(accountId)).single;
    expect(operation.payload['source_type'], 'passport_field');
    expect(operation.payload['source_id'], passportFieldId);
    expect(await database.select(database.libraryItems).get(), isEmpty);
  });

  test('untrusted or unsupported Passport fields fail before outbox', () async {
    final invalid = [
      _passportField(serverValidated: false),
      _passportField(id: 'not-a-uuid'),
      _passportField(status: PassportFieldStatus.conflicting),
      _passportField(clearValue: true),
    ];

    for (final field in invalid) {
      expect(() => controller.rememberPassportField(field), throwsStateError);
    }
    expect(await cache.pendingOperations(accountId), isEmpty);
    expect(await cache.memoryItems(accountId: accountId), isEmpty);
  });
}

Annotation _annotation({
  required AnnotationKind kind,
  AnnotationAnchorStatus anchorStatus = AnnotationAnchorStatus.anchored,
}) => Annotation(
  id: annotationId,
  paperId: paperId,
  generation: 2,
  blockId: blockId,
  kind: kind,
  body: 'What remains unresolved?',
  selector: const TextQuotePositionSelector(exact: 'unresolved question'),
  anchorStatus: anchorStatus,
  revision: 1,
  createdAt: now,
  updatedAt: now,
);

PassportField _passportField({
  String id = passportFieldId,
  PassportFieldStatus status = PassportFieldStatus.supported,
  bool serverValidated = true,
  bool clearValue = false,
}) => PassportField(
  id: id,
  key: 'limitations',
  status: status,
  value: clearValue ? null : 'The evaluation covers adults only.',
  sourceBlockIds: const [blockId],
  confidenceStatus: PassportConfidenceStatus.supported,
  provenanceId: provenanceId,
  createdAt: now,
  serverValidated: serverValidated,
);

final class _UnusedRemote implements ResearchRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const accountId = '00000000-0000-4000-8000-000000000001';
const paperId = '00000000-0000-4000-8000-000000000010';
const annotationId = '00000000-0000-7000-8000-000000000020';
const evidenceId = '00000000-0000-7000-8000-000000000021';
const passportFieldId = '00000000-0000-7000-8000-000000000022';
const provenanceId = '00000000-0000-7000-8000-000000000023';
const blockId = '00000000-0000-4000-8000-000000000030';
const researchArgs = ResearchControllerArgs(
  accountId: accountId,
  authEpoch: 4,
  paperId: paperId,
  versionKey: '2601.00001v2',
  generation: 2,
);
final now = DateTime.utc(2026, 8, 31, 12);
