import 'dart:convert';

import '../models/paper.dart';
import '../models/reader_state.dart';

const defaultFeedPageLimit = 30;

/// Produces the opaque, versioned identity shared by feed persistence,
/// conditional requests, and prefetch coordination.
///
/// Category values are bounded before encoding so user-controlled text never
/// leaks into database keys or telemetry dimensions.
String feedQueryKey({String? category, int limit = defaultFeedPageLimit}) {
  // arXiv subject identifiers are case-sensitive on the wire (`cs.AI` is not
  // interchangeable with `cs.ai`), so canonicalization may trim but must not
  // fold case.
  final normalized = category?.trim();
  final bounded = normalized == null || normalized.isEmpty
      ? null
      : normalized.substring(
          0,
          normalized.length > 128 ? 128 : normalized.length,
        );
  final categoryPart = bounded == null
      ? 'all'
      : base64Url.encode(utf8.encode(bounded)).replaceAll('=', '');
  final boundedLimit = limit.clamp(1, 100);
  return 'feed:v1:category:$categoryPart:limit:$boundedLimit';
}

class FeedCacheValidator {
  const FeedCacheValidator({required this.refreshedAt, this.etag});

  final String? etag;
  final DateTime refreshedAt;
}

/// Optional capability used by HTTP cache revalidation.
///
/// Implementations must persist this with the feed query, never in the small
/// preferences store used for session/restoration state.
abstract interface class FeedConditionalCache {
  Future<FeedCacheValidator?> loadFeedValidator(String queryKey);

  Future<void> storeFeedValidator(
    String queryKey, {
    required String? etag,
    required DateTime refreshedAt,
  });

  Future<void> touchFeedRefreshedAt(String queryKey, DateTime refreshedAt);
}

class FeedCacheUsage {
  const FeedCacheUsage({
    required this.metadataRows,
    required this.databaseBytes,
    int? physicalDatabaseBytes,
  }) : physicalDatabaseBytes = physicalDatabaseBytes ?? databaseBytes;

  final int metadataRows;

  /// Live SQLite page bytes, excluding pages already on the freelist. This is
  /// the byte bound eviction can enforce without an in-swipe VACUUM.
  final int databaseBytes;

  /// On-disk allocation including reclaimable freelist pages. Compaction may
  /// reduce this later under a safe lifecycle condition.
  final int physicalDatabaseBytes;
}

/// Result of an explicit, user-requested removal of rebuildable public data.
///
/// Physical SQLite allocation can remain larger until lifecycle-safe
/// compaction runs, so callers must distinguish live bytes from allocated
/// bytes instead of promising that foreground deletion immediately shrinks
/// the database file.
class PublicCacheClearResult {
  const PublicCacheClearResult({required this.before, required this.after});

  final FeedCacheUsage before;
  final FeedCacheUsage after;

  int get removedMetadataRows =>
      (before.metadataRows - after.metadataRows).clamp(0, before.metadataRows);
}

/// Optional local-store capability used by the public Settings surface.
///
/// Implementations remove only rebuildable feed/metadata/derived records.
/// Account data, saves, drafts, pending synchronization, identity, and active
/// reading restoration must remain intact.
abstract interface class PublicCacheControl {
  Future<FeedCacheUsage> measurePublicCache();

  Future<PublicCacheClearResult> clearRebuildablePublicCache();
}

class CacheEvictionResult {
  const CacheEvictionResult({
    required this.expiredCommentPages,
    required this.oldFeedEntries,
    required this.unpinnedPapers,
    required this.derivedRows,
    required this.usageAfter,
  });

  final int expiredCommentPages;
  final int oldFeedEntries;
  final int unpinnedPapers;
  final int derivedRows;
  final FeedCacheUsage usageAfter;
}

class CacheCompactionResult {
  const CacheCompactionResult({
    required this.ran,
    required this.boundSatisfied,
    required this.before,
    required this.after,
  });

  final bool ran;
  final bool boundSatisfied;
  final FeedCacheUsage before;
  final FeedCacheUsage after;
}

/// Physical compaction is intentionally separate from swipe-time eviction.
abstract interface class CacheCompactionPersistence {
  Future<CacheCompactionResult> compactCacheIfNeeded({
    required bool lifecycleSafe,
    int maxDatabaseBytes = 64 * 1024 * 1024,
  });
}

/// Lets navigation publish in-memory restoration state before its debounced
/// preferences write, closing the window where a newly opened paper or chat
/// could otherwise be selected for eviction.
abstract interface class LiveRestorationCacheProtection {
  void updateLiveRestorationProtection(AppRestorationState value);
}

/// Optional durable-cache operations needed by the feed prefetch coordinator.
abstract interface class FeedCachePersistence {
  Future<FeedPage?> loadFeedPage(String queryKey);

  Future<Set<String>> cachedPaperIds(Iterable<String> paperIds);

  Future<void> recordPaperAccess(String paperId, {DateTime? accessedAt});

  Future<void> ensurePaperMetadata(
    Iterable<PaperSummary> papers, {
    DateTime? accessedAt,
  });

  /// Persists metadata, membership positions, cursor and validator atomically.
  Future<void> persistFeedPage({
    required String queryKey,
    required FeedPage page,
    required bool replace,
    String? category,
    String? etag,
    DateTime? refreshedAt,
  });

  Future<FeedCacheUsage> measureCache();

  Future<CacheEvictionResult> evictCache({
    required String activeQueryKey,
    required Set<String> protectedPaperIds,
    int maxMetadataPapers = 500,
    int maxDatabaseBytes = 64 * 1024 * 1024,
    Duration metadataTtl = const Duration(days: 7),
    DateTime? now,
  });
}
