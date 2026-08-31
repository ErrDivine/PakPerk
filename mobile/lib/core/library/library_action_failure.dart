import '../models/paper.dart';

/// A local, account-scoped notice for a terminal user-initiated Library
/// mutation. The durable outbox payload and raw server error are deliberately
/// absent so presentation code cannot expose private Library content.
enum LibraryActionFailureKind {
  paperAdd,
  paperRemove,
  paperEdit,
  collectionsEdit,
  localDataIssue,
  unknown,
}

enum LibraryActionFailureAction {
  reviewPaper,
  reviewItem,
  reviewCollections,
  signIn,
  reviewLibrary,
}

final class LibraryActionFailure {
  const LibraryActionFailure({
    required this.operationId,
    required this.kind,
    required this.action,
    required this.occurredAt,
    this.paper,
  }) : assert(
         (action != LibraryActionFailureAction.reviewPaper &&
                 action != LibraryActionFailureAction.reviewItem) ||
             paper != null,
         'Paper review failures require safe cached paper metadata.',
       );

  /// Opaque local identity used only for a scope-guarded dismissal.
  final String operationId;
  final LibraryActionFailureKind kind;
  final LibraryActionFailureAction action;
  final DateTime occurredAt;

  /// Public paper metadata from the existing cache. Never sourced from the
  /// outbox payload, which can contain private notes and collection names.
  final PaperSummary? paper;

  @override
  bool operator ==(Object other) =>
      other is LibraryActionFailure &&
      other.operationId == operationId &&
      other.kind == kind &&
      other.action == action &&
      other.occurredAt == occurredAt &&
      other.paper == paper;

  @override
  int get hashCode => Object.hash(operationId, kind, action, occurredAt, paper);
}
