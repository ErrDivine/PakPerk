import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/paper_import_draft_store.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/paper_resolution/paper_resolution_models.dart';
import 'package:pakperk/core/telemetry/telemetry.dart';
import 'package:pakperk/features/library/paper_import_drafts.dart';

void main() {
  test(
    'scope changes synchronously clear prior drafts and fail closed loading',
    () async {
      final store = _DraftStore();
      final telemetry = _RecordingTelemetry();
      final controller = PaperImportDraftController(
        store,
        telemetry: RedactingTelemetrySink(telemetry),
        clock: () => DateTime.utc(2026, 8, 28, 8, 20),
      );
      addTearDown(controller.dispose);

      controller.updateScope(_accountA);
      expect(controller.state.loading, isTrue);
      expect(controller.state.drafts, isEmpty);

      store.completeLoad(_accountA, [_draft(1)]);
      await _settle();
      expect(controller.state.loading, isFalse);
      expect(controller.state.drafts, hasLength(1));
      expect(
        telemetry.events.single.$1,
        PakPerkTelemetryEvent.pendingIntentAge,
      );
      expect(telemetry.events.single.$2, const {
        'intent_kind': 'import',
        'age_bucket': '15m_1h',
      });

      controller.updateScope(_accountB);
      expect(controller.state.loading, isTrue);
      expect(controller.state.drafts, isEmpty);
      expect(controller.state.belongsTo(_accountB), isTrue);

      // A late completion from the previous account cannot republish its draft.
      store.completeLoad(_accountB, const []);
      await _settle();
      expect(controller.state.drafts, isEmpty);
    },
  );

  test(
    'load and persistence failures remain explicit fail-closed states',
    () async {
      final store = _DraftStore();
      final telemetry = _RecordingTelemetry();
      final controller = PaperImportDraftController(
        store,
        telemetry: RedactingTelemetrySink(telemetry),
      );
      addTearDown(controller.dispose);
      controller.updateScope(_accountA);
      store.failLoad(_accountA);
      await _settle();

      expect(controller.state.loading, isFalse);
      expect(controller.state.errorMessage, isNotNull);
      expect(controller.state.drafts, isEmpty);
      expect(telemetry.events.single.$2, const {
        'intent_kind': 'import',
        'age_bucket': 'unknown',
      });

      controller.updateScope(_accountB);
      store.completeLoad(_accountB, const []);
      await _settle();
      store.failSave = true;
      await controller.upsert(_draft(2));

      expect(controller.state.drafts, hasLength(1));
      expect(
        controller.state.errorMessage,
        contains('could not be secured locally'),
      );
    },
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

PaperImportDraft _draft(int index) {
  final now = DateTime.utc(2026, 8, 28, 8);
  return PaperImportDraft(
    operationId: '70000000-0000-7000-8000-${index.toString().padLeft(12, '0')}',
    source: PaperImportSource(
      kind: PaperImportSourceKind.arxivId,
      value: '2401.${index.toString().padLeft(5, '0')}v1',
    ),
    saveSourceKind: LibrarySaveSourceKind.arxivId,
    status: PaperImportDraftStatus.importing,
    createdAt: now,
    expiresAt: now.add(PaperImportDraft.defaultRetention),
  );
}

final class _DraftStore implements PaperImportDraftStore {
  final Map<String, Completer<List<PaperImportDraft>>> _loads = {};
  bool failSave = false;

  @override
  Future<List<PaperImportDraft>> load(String accountId, {DateTime? now}) =>
      _loads.putIfAbsent(accountId, Completer.new).future;

  void completeLoad(String accountId, List<PaperImportDraft> drafts) {
    _loads.putIfAbsent(accountId, Completer.new).complete(drafts);
  }

  void failLoad(String accountId) {
    _loads
        .putIfAbsent(accountId, Completer.new)
        .completeError(const FormatException('corrupt'));
  }

  @override
  Future<void> save(String accountId, List<PaperImportDraft> drafts) async {
    if (failSave) throw StateError('disk unavailable');
  }

  @override
  Future<void> clear(String accountId) async {}

  @override
  Future<void> clearAll() async {}
}

final class _RecordingTelemetry implements TelemetrySink {
  final events = <(String, Map<String, Object?>)>[];

  @override
  Future<void> event(String name, Map<String, Object?> attributes) async {
    events.add((name, Map.unmodifiable(attributes)));
  }

  @override
  Future<void> error(
    Object error,
    StackTrace stack, {
    Map<String, Object?> context = const {},
  }) async {}
}

const _accountA = 'account-a';
const _accountB = 'account-b';
