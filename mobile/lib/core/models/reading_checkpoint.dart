import '../../features/reader_modes/reader_mode.dart';
import 'reader_state.dart';

/// Account-owned reading position. It intentionally contains no Library
/// state, completion flag, recommendation eligibility, or queue membership.
final class ReadingCheckpoint {
  const ReadingCheckpoint({
    required this.accountId,
    required this.paperId,
    required this.generation,
    required this.mode,
    required this.stage,
    required this.lastReadAt,
    required this.revision,
    required this.pendingSync,
    this.blockId,
    this.scrollFraction,
    this.operationId,
  }) : assert(generation > 0),
       assert(revision >= 0),
       assert(
         scrollFraction == null || (scrollFraction >= 0 && scrollFraction <= 1),
       );

  final String accountId;
  final String paperId;
  final int generation;
  final ReaderDepthMode mode;
  final PaperStage stage;
  final String? blockId;
  final double? scrollFraction;
  final DateTime lastReadAt;
  final int revision;
  final bool pendingSync;
  final String? operationId;

  ReadingCheckpoint copyWith({
    int? revision,
    bool? pendingSync,
    String? operationId,
    bool clearOperationId = false,
  }) => ReadingCheckpoint(
    accountId: accountId,
    paperId: paperId,
    generation: generation,
    mode: mode,
    stage: stage,
    blockId: blockId,
    scrollFraction: scrollFraction,
    lastReadAt: lastReadAt,
    revision: revision ?? this.revision,
    pendingSync: pendingSync ?? this.pendingSync,
    operationId: clearOperationId ? null : operationId ?? this.operationId,
  );

  factory ReadingCheckpoint.fromJson(
    Map<String, dynamic> json, {
    required String accountId,
    bool pendingSync = false,
  }) {
    final generation = (json['generation'] as num?)?.toInt() ?? 0;
    final revision = (json['revision'] as num?)?.toInt() ?? 0;
    final fraction = (json['scroll_fraction'] as num?)?.toDouble();
    final lastReadAt = DateTime.tryParse(
      json['last_read_at']?.toString() ?? '',
    )?.toUtc();
    if (generation <= 0 ||
        revision < 0 ||
        lastReadAt == null ||
        (fraction != null &&
            (!fraction.isFinite || fraction < 0 || fraction > 1))) {
      throw const FormatException('Invalid reading checkpoint.');
    }
    final stage = switch (json['stage']) {
      'introduction' => PaperStage.introduction,
      'connections' => PaperStage.connections,
      _ => PaperStage.abstractView,
    };
    final block = json['block_id']?.toString().trim();
    return ReadingCheckpoint(
      accountId: accountId,
      paperId: _requiredText(json['paper_id'], 128),
      generation: generation,
      mode: ReaderDepthMode.fromWire(json['mode']),
      stage: stage,
      blockId: block?.isNotEmpty == true ? block : null,
      scrollFraction: fraction,
      lastReadAt: lastReadAt,
      revision: revision,
      pendingSync: pendingSync,
      operationId: json['operation_id']?.toString(),
    );
  }

  Map<String, Object?> toJson() => {
    'paper_id': paperId,
    'generation': generation,
    'mode': mode.wireValue,
    'stage': switch (stage) {
      PaperStage.abstractView => 'abstract',
      PaperStage.introduction => 'introduction',
      PaperStage.connections => 'connections',
    },
    'block_id': blockId,
    'scroll_fraction': scrollFraction,
    'last_read_at': lastReadAt.toUtc().toIso8601String(),
    'revision': revision,
    if (operationId != null) 'operation_id': operationId,
  };
}

String _requiredText(Object? value, int maximum) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maximum) {
    throw const FormatException('Missing checkpoint identity.');
  }
  return text;
}
