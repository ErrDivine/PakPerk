import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/paper.dart';

final class PaperNotes {
  const PaperNotes({this.pages = const ['']});
  final List<String> pages;
  String get body => pages.first;
  bool get isEmpty => pages.every((page) => page.trim().isEmpty);
  @override
  bool operator ==(Object other) =>
      other is PaperNotes && listEquals(other.pages, pages);
  @override
  int get hashCode => Object.hashAll(pages);
}

abstract interface class PaperNotesStore {
  Future<PaperNotes> read(String arxivBaseId);
  Future<void> write(String arxivBaseId, PaperNotes notes);
}

final class PaperNotebook {
  const PaperNotebook(this.paper, this.notes);
  final PaperSummary paper;
  final PaperNotes notes;
}

final class SharedPreferencesPaperNotesStore implements PaperNotesStore {
  const SharedPreferencesPaperNotesStore({this.accountId, this.paper});
  final String? accountId;
  final PaperSummary? paper;
  String get _prefix =>
      'paper_notes_v2:${Uri.encodeComponent(accountId == null ? 'guest' : 'account:$accountId')}:';
  String _key(String id) => '$_prefix${Uri.encodeComponent(id)}';
  @override
  Future<PaperNotes> read(String arxivBaseId) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key(arxivBaseId));
    if (raw != null) return _decode(jsonDecode(raw) as Map<String, dynamic>);
    // Keep existing anonymous notes without assigning them to a signed-in user.
    if (accountId == null) {
      final legacy = preferences.getString(
        'paper_notes_v1:${Uri.encodeComponent(arxivBaseId)}',
      );
      if (legacy != null) {
        return PaperNotes(
          pages: [
            (jsonDecode(legacy) as Map<String, dynamic>)['body'] as String? ??
                '',
          ],
        );
      }
    }
    return const PaperNotes();
  }

  PaperNotes _decode(Map<String, dynamic> value) {
    final pages = (value['pages'] as List).cast<String>();
    return PaperNotes(pages: pages.isEmpty ? [''] : List.unmodifiable(pages));
  }

  @override
  Future<void> write(String arxivBaseId, PaperNotes notes) async {
    final preferences = await SharedPreferences.getInstance();
    final old = preferences.getString(_key(arxivBaseId));
    final metadata =
        paper?.toJson() ??
        (old == null
            ? null
            : (jsonDecode(old) as Map<String, dynamic>)['paper']);
    final saved = await preferences.setString(
      _key(arxivBaseId),
      jsonEncode({
        'pages': notes.pages,
        'paper': metadata,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    if (!saved) throw StateError('Could not save paper notes');
  }

  Future<List<PaperNotebook>> list() async {
    final preferences = await SharedPreferences.getInstance();
    final rows = preferences
        .getKeys()
        .where((key) => key.startsWith(_prefix))
        .map(
          (key) =>
              jsonDecode(preferences.getString(key)!) as Map<String, dynamic>,
        )
        .toList();
    rows.sort(
      (a, b) =>
          (b['updated_at'] as String).compareTo(a['updated_at'] as String),
    );
    return [
      for (final row in rows)
        if (row['paper'] != null && !_decode(row).isEmpty)
          PaperNotebook(
            PaperSummary.fromJson(row['paper'] as Map<String, dynamic>),
            _decode(row),
          ),
    ];
  }
}
