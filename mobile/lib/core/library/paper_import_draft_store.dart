import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/arxiv_identifier.dart';
import '../paper_resolution/paper_resolution_models.dart';
import 'library_models.dart';

const paperImportDraftPreferencesPrefix = 'pakperk.paper_import.drafts.v1.';

enum PaperImportDraftStatus { importing, retryableFailure }

/// Minimum durable state needed to safely retry an unresolved Add Paper task.
///
/// The original title is never retained. A selected title result is reduced to
/// its canonical arXiv ID, while an exact URL retains only the canonical arXiv
/// URL required by the idempotency fingerprint.
final class PaperImportDraft {
  PaperImportDraft({
    required this.operationId,
    required this.source,
    required this.saveSourceKind,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.failureCode,
  }) {
    _validateOperationId(operationId);
    _validateSource(source);
    _validateSaveSource(source, saveSourceKind);
    if (!createdAt.isUtc ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt) > maximumRetention) {
      throw ArgumentError('Invalid paper-import draft retention window.');
    }
    if (failureCode != null && !_safeCode.hasMatch(failureCode!)) {
      throw ArgumentError.value(failureCode, 'failureCode');
    }
    if ((status == PaperImportDraftStatus.retryableFailure) !=
        (failureCode != null)) {
      throw ArgumentError('Draft failure status and code must agree.');
    }
  }

  static const maximumRetention = Duration(hours: 24);
  static const defaultRetention = Duration(hours: 1);

  final String operationId;
  final PaperImportSource source;
  final LibrarySaveSourceKind saveSourceKind;
  final PaperImportDraftStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? failureCode;

  String get displayLabel {
    final value = source.kind == PaperImportSourceKind.arxivUrl
        ? Uri.parse(source.value).pathSegments.skip(1).join('/')
        : source.value;
    return 'arXiv $value';
  }

  bool isExpired(DateTime now) => !expiresAt.isAfter(now.toUtc());

  PaperImportDraft withRetryableFailure(String code) => PaperImportDraft(
    operationId: operationId,
    source: source,
    saveSourceKind: saveSourceKind,
    status: PaperImportDraftStatus.retryableFailure,
    createdAt: createdAt,
    expiresAt: expiresAt,
    failureCode: code,
  );

  Map<String, Object?> toJson() => {
    'operation_id': operationId,
    'source': source.toJson(),
    'save_source_kind': saveSourceKind.wireValue,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    'failure_code': failureCode,
  };

  factory PaperImportDraft.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'operation_id',
      'source',
      'save_source_kind',
      'status',
      'created_at',
      'expires_at',
      'failure_code',
    });
    final rawSource = json['source'];
    if (rawSource is! Map) {
      throw const FormatException('Invalid paper-import draft source.');
    }
    final sourceJson = Map<String, dynamic>.from(rawSource);
    _exactKeys(sourceJson, const {'kind', 'value'});
    final value = sourceJson['value'];
    if (value is! String) {
      throw const FormatException('Invalid paper-import draft source.');
    }
    final status = switch (json['status']) {
      'importing' => PaperImportDraftStatus.importing,
      'retryableFailure' => PaperImportDraftStatus.retryableFailure,
      _ => throw const FormatException('Invalid paper-import draft status.'),
    };
    final createdAt = _utcTimestamp(json['created_at']);
    final expiresAt = _utcTimestamp(json['expires_at']);
    final failureCode = json['failure_code'];
    if (failureCode != null && failureCode is! String) {
      throw const FormatException('Invalid paper-import draft failure code.');
    }
    try {
      return PaperImportDraft(
        operationId: json['operation_id'] as String,
        source: PaperImportSource(
          kind: PaperImportSourceKindWire.parse(sourceJson['kind']),
          value: value,
        ),
        saveSourceKind: _parseImportSaveSource(json['save_source_kind']),
        status: status,
        createdAt: createdAt,
        expiresAt: expiresAt,
        failureCode: failureCode as String?,
      );
    } on Object {
      throw const FormatException('Invalid paper-import draft.');
    }
  }
}

abstract interface class PaperImportDraftStore {
  Future<List<PaperImportDraft>> load(String accountId, {DateTime? now});

  Future<void> save(String accountId, List<PaperImportDraft> drafts);

  Future<void> clear(String accountId);

  Future<void> clearAll();
}

final class SharedPreferencesPaperImportDraftStore
    implements PaperImportDraftStore {
  SharedPreferencesPaperImportDraftStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const maximumDrafts = 4;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<List<PaperImportDraft>> load(String accountId, {DateTime? now}) async {
    final preferences = await _preferences();
    final key = _key(accountId);
    final raw = preferences.getString(key);
    if (raw == null) return const [];
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid paper-import draft ledger.');
      }
      final json = Map<String, dynamic>.from(decoded);
      _exactKeys(json, const {'schema', 'drafts'});
      final rawDrafts = json['drafts'];
      if (json['schema'] != 2 ||
          rawDrafts is! List ||
          rawDrafts.length > maximumDrafts) {
        throw const FormatException('Invalid paper-import draft ledger.');
      }
      final drafts = rawDrafts
          .map(
            (value) => value is Map
                ? PaperImportDraft.fromJson(Map<String, dynamic>.from(value))
                : throw const FormatException('Invalid paper-import draft.'),
          )
          .where((draft) => !draft.isExpired(effectiveNow))
          .toList(growable: false);
      if (drafts.map((draft) => draft.operationId).toSet().length !=
          drafts.length) {
        throw const FormatException('Duplicate paper-import operation.');
      }
      if (drafts.length != rawDrafts.length) {
        await _replaceExpiredIfUnchanged(
          preferences: preferences,
          key: key,
          expected: raw,
          drafts: drafts,
        );
      }
      return List.unmodifiable(drafts);
    } on FormatException {
      // Corruption is not interpreted as an empty authoritative ledger.
      rethrow;
    }
  }

  @override
  Future<void> save(String accountId, List<PaperImportDraft> drafts) async {
    if (drafts.length > maximumDrafts ||
        drafts.map((draft) => draft.operationId).toSet().length !=
            drafts.length) {
      throw ArgumentError('Invalid paper-import draft ledger.');
    }
    final preferences = await _preferences();
    final key = _key(accountId);
    if (drafts.isEmpty) {
      final removed = await preferences.remove(key);
      if (!removed && preferences.containsKey(key)) {
        throw StateError('Paper-import drafts could not be cleared.');
      }
      return;
    }
    final written = await preferences.setString(
      key,
      jsonEncode({
        'schema': 2,
        'drafts': drafts.map((draft) => draft.toJson()).toList(growable: false),
      }),
    );
    if (!written) throw StateError('Paper-import drafts could not be saved.');
  }

  @override
  Future<void> clear(String accountId) async {
    final preferences = await _preferences();
    final key = _key(accountId);
    final removed = await preferences.remove(key);
    if (!removed && preferences.containsKey(key)) {
      throw StateError('Paper-import drafts could not be cleared.');
    }
  }

  @override
  Future<void> clearAll() async {
    final preferences = await _preferences();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(paperImportDraftPreferencesPrefix))
        .toList(growable: false);
    for (final key in keys) {
      final removed = await preferences.remove(key);
      if (!removed && preferences.containsKey(key)) {
        throw StateError('Paper-import drafts could not be cleared.');
      }
    }
  }
}

Future<void> _replaceExpiredIfUnchanged({
  required SharedPreferences preferences,
  required String key,
  required String expected,
  required List<PaperImportDraft> drafts,
}) async {
  // Account cleanup or a newer retry may have replaced this ledger while it
  // was decoded. Never let expiry compaction resurrect or overwrite it.
  if (preferences.getString(key) != expected) return;
  if (drafts.isEmpty) {
    final removed = await preferences.remove(key);
    if (!removed && preferences.containsKey(key)) {
      throw StateError('Expired paper-import drafts could not be cleared.');
    }
    return;
  }
  final written = await preferences.setString(
    key,
    jsonEncode({
      'schema': 2,
      'drafts': drafts.map((draft) => draft.toJson()).toList(growable: false),
    }),
  );
  if (!written) {
    throw StateError('Expired paper-import drafts could not be compacted.');
  }
}

String paperImportDraftScopeFingerprint(String accountId) {
  _validateAccountId(accountId);
  return sha256.convert(utf8.encode(accountId)).toString();
}

String _key(String accountId) =>
    '$paperImportDraftPreferencesPrefix${paperImportDraftScopeFingerprint(accountId)}';

void _validateAccountId(String accountId) {
  if (accountId.isEmpty ||
      accountId.length > 128 ||
      accountId.runes.any((rune) => rune < 0x20)) {
    throw ArgumentError.value(accountId, 'accountId', 'Invalid account scope.');
  }
}

void _validateOperationId(String value) {
  if (!_uuid.hasMatch(value)) {
    throw ArgumentError.value(value, 'operationId');
  }
}

void _validateSource(PaperImportSource source) {
  final identifier = switch (source.kind) {
    PaperImportSourceKind.arxivId => ArxivIdentifier.tryParse(source.value),
    PaperImportSourceKind.arxivUrl => () {
      final uri = Uri.tryParse(source.value);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'arxiv.org' ||
          uri.pathSegments.length < 2 ||
          uri.pathSegments.first != 'abs') {
        return null;
      }
      return ArxivIdentifier.tryParse(uri.pathSegments.skip(1).join('/'));
    }(),
  };
  if (identifier == null ||
      (source.kind == PaperImportSourceKind.arxivId &&
          source.value != identifier.queryId) ||
      (source.kind == PaperImportSourceKind.arxivUrl &&
          source.value != identifier.canonicalAbsUri.toString())) {
    throw ArgumentError.value(source.value, 'source', 'Non-canonical source.');
  }
}

void _validateSaveSource(
  PaperImportSource source,
  LibrarySaveSourceKind saveSourceKind,
) {
  if (saveSourceKind != LibrarySaveSourceKind.titleSearch &&
      saveSourceKind != source.directSaveSourceKind) {
    throw ArgumentError.value(
      saveSourceKind,
      'saveSourceKind',
      'Import provenance does not match its canonical source.',
    );
  }
}

LibrarySaveSourceKind _parseImportSaveSource(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid paper-import provenance.');
  }
  final parsed = LibrarySaveSourceKind.tryFromWire(value);
  if (parsed != LibrarySaveSourceKind.titleSearch &&
      parsed != LibrarySaveSourceKind.arxivId &&
      parsed != LibrarySaveSourceKind.arxivUrl) {
    throw const FormatException('Invalid paper-import provenance.');
  }
  return parsed!;
}

DateTime _utcTimestamp(Object? value) {
  if (value is! String || value.length > 64 || !value.endsWith('Z')) {
    throw const FormatException('Invalid paper-import draft timestamp.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw const FormatException('Invalid paper-import draft timestamp.');
  }
  return parsed.toUtc();
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final keys = json.keys.toSet();
  if (keys.difference(expected).isNotEmpty ||
      expected.difference(keys).isNotEmpty) {
    throw const FormatException('Unexpected paper-import draft shape.');
  }
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _safeCode = RegExp(r'^[A-Z][A-Z0-9_]{0,63}$');
