import '../models/connections.dart';
import '../models/chat.dart';
import '../models/introduction.dart';
import '../models/paper.dart';
import '../models/processing.dart';

/// Optional capability for network responses tied to a paper generation.
///
/// A `false` result means metadata advanced while the request was in flight;
/// callers must not publish the stale derived response as current content.
abstract interface class VersionedDerivedCache {
  Future<bool> saveProcessingForVersion(
    PaperProcessingState value, {
    required PaperVersionKey expectedVersionKey,
  });

  Future<bool> saveIntroductionForVersion(
    PaperIntroduction value, {
    required PaperVersionKey expectedVersionKey,
  });

  Future<bool> saveConnectionsForVersion(
    PaperConnections value, {
    required PaperVersionKey expectedVersionKey,
  });
}

/// Optional capability for atomically persisting chat under the processing
/// generation returned by the backend.
abstract interface class GenerationScopedChatCache {
  Future<bool> saveChatForGeneration(
    String readerKey,
    ChatSnapshot value, {
    required PaperVersionKey expectedVersionKey,
    required int expectedGeneration,
  });
}
