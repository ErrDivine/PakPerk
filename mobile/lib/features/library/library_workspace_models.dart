import '../../core/library/library_models.dart';

final class LibraryEditorScope {
  const LibraryEditorScope({required this.accountId, required this.authEpoch});

  final String accountId;
  final int authEpoch;

  @override
  bool operator ==(Object other) =>
      other is LibraryEditorScope &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch;

  @override
  int get hashCode => Object.hash(accountId, authEpoch);
}

/// A presentation command translated by the Library v2 adapter. It keeps
/// server DTO details out of widgets while enforcing the same field bounds.
final class LibraryItemEditDraft {
  LibraryItemEditDraft({
    required this.state,
    required String privateNote,
    required Iterable<String> listNames,
    required Iterable<String> tagNames,
    DateTime? reminderAt,
  }) : privateNote = _boundedNote(privateNote),
       listNames = _normalizedNames(listNames, maximumLength: 100),
       tagNames = _normalizedNames(tagNames, maximumLength: 60),
       reminderAt = reminderAt?.toUtc() {
    if (this.reminderAt != null && !state.isActive) {
      throw ArgumentError.value(reminderAt, 'reminderAt');
    }
  }

  factory LibraryItemEditDraft.fromItem(LibraryListItem item) =>
      LibraryItemEditDraft(
        state: item.state,
        privateNote: item.privateNote ?? '',
        listNames: item.listNames,
        tagNames: item.tagNames,
        reminderAt: item.reminderAt,
      );

  final LibraryItemState state;
  final String privateNote;
  final List<String> listNames;
  final List<String> tagNames;
  final DateTime? reminderAt;

  bool differsFrom(LibraryListItem item) =>
      state != item.state ||
      privateNote != (item.privateNote ?? '') ||
      reminderAt != item.reminderAt?.toUtc() ||
      !_sameNames(listNames, item.listNames) ||
      !_sameNames(tagNames, item.tagNames);
}

typedef LibraryItemEditCallback =
    Future<void> Function(
      LibraryListItem item,
      LibraryItemEditDraft draft,
      int? expectedLibraryRevision,
    );

final class LibraryEditorCapabilities {
  const LibraryEditorCapabilities({
    required this.state,
    required this.privateNote,
    required this.lists,
    required this.tags,
    this.unavailableReason,
    this.reminders = false,
  });

  const LibraryEditorCapabilities.none({
    this.unavailableReason =
        'Library organization will be available after the account sync '
        'upgrade is enabled.',
  }) : state = false,
       privateNote = false,
       lists = false,
       tags = false,
       reminders = false;

  const LibraryEditorCapabilities.all({this.reminders = true})
    : state = true,
      privateNote = true,
      lists = true,
      tags = true,
      unavailableReason = null;

  final bool state;
  final bool privateNote;
  final bool lists;
  final bool tags;
  final bool reminders;
  final String? unavailableReason;

  bool get canEdit => state || privateNote || lists || tags || reminders;
}

/// A single account-scoped view of local queue authority for Library chrome.
/// Recommendation presentation continues to use ReadingFeedPolicy; this model
/// mirrors the same safe states so the Library destination never contradicts
/// it while a final mutation or revision reset is unresolved.
final class LibraryWorkspaceAuthority {
  const LibraryWorkspaceAuthority({
    required this.activeItemCount,
    required this.pendingSaveCount,
    required this.pendingRemoveCount,
    required this.checkpoint,
  });

  factory LibraryWorkspaceAuthority.from({
    required Iterable<LibraryListItem> items,
    required LibraryPendingIntentCounts pendingIntents,
    required LibrarySyncCheckpoint checkpoint,
  }) => LibraryWorkspaceAuthority(
    activeItemCount: items.where((item) => item.state.isActive).length,
    pendingSaveCount: pendingIntents.saves,
    pendingRemoveCount: pendingIntents.removes,
    checkpoint: checkpoint,
  );

  final int activeItemCount;
  final int pendingSaveCount;
  final int pendingRemoveCount;
  final LibrarySyncCheckpoint checkpoint;

  int get pendingCount => pendingSaveCount + pendingRemoveCount;
  bool get finishingQueue => activeItemCount == 0 && pendingRemoveCount > 0;
  bool get queueBlocksDiscovery =>
      activeItemCount > 0 || pendingSaveCount > 0 || pendingRemoveCount > 0;
  bool get authorityComplete =>
      checkpoint.initialized && !checkpoint.resetting && pendingCount == 0;
}

String _boundedNote(String value) {
  final normalized = value.trim();
  if (normalized.length > 500 || normalized.runes.any((rune) => rune == 0)) {
    throw ArgumentError.value(value, 'privateNote', 'Invalid private note.');
  }
  return normalized;
}

List<String> _normalizedNames(
  Iterable<String> values, {
  required int maximumLength,
}) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    if (value.length > maximumLength ||
        value.runes.any((rune) => rune < 0x20)) {
      throw ArgumentError.value(raw, 'values', 'Invalid collection name.');
    }
    if (seen.add(value.toLowerCase())) normalized.add(value);
    if (normalized.length > 20) {
      throw ArgumentError.value(values, 'values', 'Too many collections.');
    }
  }
  return List<String>.unmodifiable(normalized);
}

bool _sameNames(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
