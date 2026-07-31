import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/paper.dart';
import '../../core/repository/paper_repository.dart';

/// Device-local feed data prepared before the production widget tree mounts.
///
/// Keeping the origin with the page lets the feed surface stale-data status
/// immediately, without constructing a repository or starting network work.
class PreloadedFeedSnapshot {
  const PreloadedFeedSnapshot({
    required this.page,
    required this.origin,
    this.offline = false,
  }) : assert(origin != DataOrigin.network);

  final FeedPage page;
  final DataOrigin origin;
  final bool offline;
}

/// Null preserves the direct-test and embedding behavior where FeedController
/// performs its original cache-first load from the repository constructor.
final preloadedFeedSnapshotProvider = Provider<PreloadedFeedSnapshot?>(
  (ref) => null,
);
