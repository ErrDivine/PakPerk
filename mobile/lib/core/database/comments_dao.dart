import 'package:drift/drift.dart';

import '../comments/comment_models.dart';
import 'app_database.dart';

final class CommentDraftValue {
  const CommentDraftValue({
    required this.accountId,
    required this.paperId,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.clientRequestId,
    required this.lastAttemptedBody,
  });

  final String accountId;
  final String paperId;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? clientRequestId;
  final String? lastAttemptedBody;
}

final class BlockedUserValue {
  const BlockedUserValue({
    required this.userId,
    required this.handle,
    required this.createdAt,
    required this.serverConfirmed,
    this.displayName,
  });

  final String userId;
  final String handle;
  final String? displayName;
  final DateTime createdAt;
  final bool serverConfirmed;
}

final class CommentsDao {
  CommentsDao(this.database);

  final PakPerkDatabase database;

  Future<CommentDraftValue?> loadDraft(String accountId, String paperId) async {
    _requireUuid(accountId, 'accountId');
    _requireUuid(paperId, 'paperId');
    final row =
        await (database.select(database.commentDrafts)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.paperId.equals(paperId),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    return CommentDraftValue(
      accountId: accountId,
      paperId: paperId,
      body: row.body,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      clientRequestId: row.clientRequestId,
      lastAttemptedBody: row.lastAttemptedBody,
    );
  }

  Future<void> saveDraft({
    required String accountId,
    required String paperId,
    required String body,
    required String clientRequestId,
    DateTime? now,
  }) async {
    _requireUuid(accountId, 'accountId');
    _requireUuid(paperId, 'paperId');
    _requireUuid(clientRequestId, 'clientRequestId');
    _requireValidDraftBody(body);
    final normalizedAccountId = accountId.toLowerCase();
    final normalizedPaperId = paperId.toLowerCase();
    if (body.isEmpty) {
      await clearDraft(normalizedAccountId, normalizedPaperId);
      return;
    }
    final timestamp = (now ?? DateTime.now()).toUtc();
    final existing = await loadDraft(normalizedAccountId, normalizedPaperId);
    await database
        .into(database.commentDrafts)
        .insertOnConflictUpdate(
          CommentDraftsCompanion.insert(
            draftId: '$normalizedAccountId:$normalizedPaperId',
            accountId: Value(normalizedAccountId),
            paperId: normalizedPaperId,
            body: body,
            clientRequestId: Value(
              existing?.clientRequestId ?? clientRequestId.toLowerCase(),
            ),
            // Editing a local draft does not itself create a new remote
            // mutation intent. Explicit send preparation below compares the
            // canonical payload and rotates atomically only when necessary.
            lastAttemptedBody: Value(existing?.lastAttemptedBody),
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  Future<CommentDraftValue> prepareDraftAttempt({
    required String accountId,
    required String paperId,
    required String canonicalBody,
    required String nextClientRequestId,
    DateTime? now,
  }) async {
    _requireUuid(accountId, 'accountId');
    _requireUuid(paperId, 'paperId');
    _requireUuid(nextClientRequestId, 'nextClientRequestId');
    final analysis = analyzeCommentBody(canonicalBody);
    if (analysis.issue != null || analysis.canonicalBody != canonicalBody) {
      throw ArgumentError.value(
        canonicalBody.length,
        'canonicalBody',
        analysis.issue ?? 'Comment body must already be canonical.',
      );
    }
    final normalizedAccountId = accountId.toLowerCase();
    final normalizedPaperId = paperId.toLowerCase();
    final normalizedNextRequestId = nextClientRequestId.toLowerCase();
    final timestamp = (now ?? DateTime.now()).toUtc();
    return database.transaction(() async {
      final existing = await loadDraft(normalizedAccountId, normalizedPaperId);
      final canonicalLastAttempt = _canonicalValidCommentBody(
        existing?.lastAttemptedBody,
      );
      final existingRequestId = existing?.clientRequestId;
      final reusesExistingIntent =
          existingRequestId != null &&
          (existing?.lastAttemptedBody == null ||
              canonicalLastAttempt == canonicalBody);
      final requestId = reusesExistingIntent
          ? existingRequestId
          : normalizedNextRequestId;
      final createdAt = existing?.createdAt ?? timestamp;
      await database
          .into(database.commentDrafts)
          .insertOnConflictUpdate(
            CommentDraftsCompanion.insert(
              draftId: '$normalizedAccountId:$normalizedPaperId',
              accountId: Value(normalizedAccountId),
              paperId: normalizedPaperId,
              body: canonicalBody,
              clientRequestId: Value(requestId),
              lastAttemptedBody: Value(canonicalBody),
              createdAt: createdAt,
              updatedAt: timestamp,
            ),
          );
      return CommentDraftValue(
        accountId: normalizedAccountId,
        paperId: normalizedPaperId,
        body: canonicalBody,
        createdAt: createdAt,
        updatedAt: timestamp,
        clientRequestId: requestId,
        lastAttemptedBody: canonicalBody,
      );
    });
  }

  Future<void> clearDraft(String accountId, String paperId) {
    _requireUuid(accountId, 'accountId');
    _requireUuid(paperId, 'paperId');
    return (database.delete(database.commentDrafts)..where(
          (table) =>
              table.accountId.equals(accountId) & table.paperId.equals(paperId),
        ))
        .go();
  }

  Stream<List<BlockedUserValue>> watchBlockedUsers(String accountId) {
    _requireUuid(accountId, 'accountId');
    final query = database.select(database.blockedUsers)
      ..where((table) => table.accountId.equals(accountId))
      ..orderBy([
        (table) => OrderingTerm.desc(table.createdAt),
        (table) => OrderingTerm.asc(table.blockedUserId),
      ]);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => BlockedUserValue(
              userId: row.blockedUserId,
              handle: row.handle,
              displayName: row.displayName,
              createdAt: row.createdAt,
              serverConfirmed: row.serverConfirmed,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<Set<String>> blockedUserIds(String accountId) async {
    _requireUuid(accountId, 'accountId');
    return (await (database.select(
          database.blockedUsers,
        )..where((table) => table.accountId.equals(accountId))).get())
        .map((row) => row.blockedUserId)
        .toSet();
  }

  Future<void> blockLocally({
    required String accountId,
    required String blockedUserId,
    required String handle,
    String? displayName,
    DateTime? createdAt,
    bool serverConfirmed = false,
  }) {
    _requireUuid(accountId, 'accountId');
    _requireUuid(blockedUserId, 'blockedUserId');
    if (!_handle.hasMatch(handle) ||
        (displayName != null &&
            (displayName.isEmpty || displayName.runes.length > 80))) {
      throw ArgumentError('Invalid blocked-user projection.');
    }
    return database
        .into(database.blockedUsers)
        .insertOnConflictUpdate(
          BlockedUsersCompanion.insert(
            accountId: accountId,
            blockedUserId: blockedUserId,
            handle: handle,
            displayName: Value(displayName),
            createdAt: (createdAt ?? DateTime.now()).toUtc(),
            serverConfirmed: Value(serverConfirmed),
          ),
        );
  }

  Future<void> markBlockConfirmed(String accountId, String blockedUserId) {
    _requireUuid(accountId, 'accountId');
    _requireUuid(blockedUserId, 'blockedUserId');
    return (database.update(database.blockedUsers)..where(
          (table) =>
              table.accountId.equals(accountId) &
              table.blockedUserId.equals(blockedUserId),
        ))
        .write(const BlockedUsersCompanion(serverConfirmed: Value(true)));
  }

  Future<void> unblockLocally(String accountId, String blockedUserId) {
    _requireUuid(accountId, 'accountId');
    _requireUuid(blockedUserId, 'blockedUserId');
    return (database.delete(database.blockedUsers)..where(
          (table) =>
              table.accountId.equals(accountId) &
              table.blockedUserId.equals(blockedUserId),
        ))
        .go();
  }

  Future<void> replaceConfirmedBlocks({
    required String accountId,
    required List<BlockedUserValue> values,
  }) {
    _requireUuid(accountId, 'accountId');
    return database.transaction(() async {
      final remoteIds = values.map((value) => value.userId).toSet();
      final existing = await (database.select(
        database.blockedUsers,
      )..where((table) => table.accountId.equals(accountId))).get();
      for (final row in existing) {
        if (row.serverConfirmed && !remoteIds.contains(row.blockedUserId)) {
          await unblockLocally(accountId, row.blockedUserId);
        }
      }
      for (final value in values) {
        await blockLocally(
          accountId: accountId,
          blockedUserId: value.userId,
          handle: value.handle,
          displayName: value.displayName,
          createdAt: value.createdAt,
          serverConfirmed: true,
        );
      }
    });
  }

  Future<List<BlockedUserValue>> pendingBlocks(String accountId) async {
    _requireUuid(accountId, 'accountId');
    final rows =
        await (database.select(database.blockedUsers)..where(
              (table) =>
                  table.accountId.equals(accountId) &
                  table.serverConfirmed.equals(false),
            ))
            .get();
    return rows
        .map(
          (row) => BlockedUserValue(
            userId: row.blockedUserId,
            handle: row.handle,
            displayName: row.displayName,
            createdAt: row.createdAt,
            serverConfirmed: false,
          ),
        )
        .toList(growable: false);
  }
}

void _requireValidDraftBody(String body) {
  final issue = validateCommentDraftInput(body);
  if (issue != null) {
    throw ArgumentError.value(body.length, 'body', issue);
  }
}

String? _canonicalValidCommentBody(String? body) {
  if (body == null) return null;
  final analysis = analyzeCommentBody(body);
  return analysis.issue == null ? analysis.canonicalBody : null;
}

void _requireUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Must be a canonical UUID.');
  }
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
final _handle = RegExp(r'^[a-z0-9_]{3,30}$');
