import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/feed_prefetch_config.dart';

export '../../core/cache/feed_prefetch_config.dart';

/// The single runtime cache policy consumed by startup and feature providers.
final feedPrefetchConfigProvider = Provider<FeedPrefetchConfig>(
  (ref) => const FeedPrefetchConfig(),
);
