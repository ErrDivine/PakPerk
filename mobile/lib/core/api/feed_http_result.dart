import '../models/paper.dart';

/// Transport result for a conditional first-page feed request.
///
/// A 304 deliberately carries no reconstructed body: the repository owns the
/// validated local snapshot and decides how to expose its origin/staleness.
class FeedHttpResult {
  const FeedHttpResult.modified({required this.page, this.etag})
    : assert(page != null),
      notModified = false;

  const FeedHttpResult.notModified({this.etag})
    : page = null,
      notModified = true;

  final FeedPage? page;
  final String? etag;
  final bool notModified;
}
