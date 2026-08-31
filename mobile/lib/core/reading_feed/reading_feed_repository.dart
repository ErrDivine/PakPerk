import '../api/request_cancellation.dart';
import 'reading_feed_api.dart';
import 'reading_feed_models.dart';

/// Transport-independent entry point for the account-scoped reading feed.
///
/// Keeping cursors inside this repository prevents the authenticated feed
/// controller from accidentally falling back to the public discovery cache.
final class ReadingFeedRepository {
  const ReadingFeedRepository({required ReadingFeedRemoteDataSource remote})
    : _remote = remote;

  final ReadingFeedRemoteDataSource _remote;

  Future<ReadingFeedPage> page({
    required int expectedAuthEpoch,
    ReadingFeedRecommendationMode? recommendationMode,
    String? briefId,
    String? category,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) => _remote.page(
    expectedAuthEpoch: expectedAuthEpoch,
    recommendationMode: recommendationMode,
    briefId: briefId,
    category: category,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );
}
