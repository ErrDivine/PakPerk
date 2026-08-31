final class ProvenanceSummary {
  const ProvenanceSummary({
    required this.status,
    this.recordId,
    this.parserId,
    this.parserVersion,
    this.modelId,
    this.schemaVersion,
    this.createdAt,
  });

  final String status;
  final String? recordId;
  final String? parserId;
  final String? parserVersion;
  final String? modelId;
  final String? schemaVersion;
  final DateTime? createdAt;

  bool get isReady => status == 'ready' || status == 'supported';

  factory ProvenanceSummary.fromJson(Map<String, dynamic> json) {
    return ProvenanceSummary(
      status: _bounded(json['status'], fallback: 'unknown', maximum: 32),
      recordId: _optionalBounded(json['id'] ?? json['record_id'], 128),
      parserId: _optionalBounded(json['parser_id'], 128),
      parserVersion: _optionalBounded(json['parser_version'], 64),
      modelId: _optionalBounded(json['model_id'], 128),
      schemaVersion: _optionalBounded(
        json['schema_version'] ?? json['prompt_version'],
        64,
      ),
      createdAt: DateTime.tryParse(
        json['created_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
    'status': status,
    if (recordId != null) 'record_id': recordId,
    if (parserId != null) 'parser_id': parserId,
    if (parserVersion != null) 'parser_version': parserVersion,
    if (modelId != null) 'model_id': modelId,
    if (schemaVersion != null) 'schema_version': schemaVersion,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
  };
}

String _bounded(
  Object? value, {
  required String fallback,
  required int maximum,
}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty || text.length > maximum ? fallback : text;
}

String? _optionalBounded(Object? value, int maximum) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty || text.length > maximum ? null : text;
}
