import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../app/feature_flags.dart';
import 'api/api_client.dart';
import 'api/transport_network_status.dart';
import 'cache/demo_asset_store.dart';
import 'cache/feed_cache_persistence.dart';
import 'cache/local_store.dart';
import 'content_policy.dart';
import 'models/reader_state.dart';
import 'repository/paper_repository.dart';
import 'telemetry/otlp_http_telemetry_sink.dart';
import 'telemetry/telemetry.dart';

final appBuildConfigProvider = Provider<AppBuildConfig>(
  (ref) => AppBuildConfig.fromCompileTime(),
);

final featureFlagsProvider = Provider<FeatureFlags>(
  (ref) => ref.watch(appBuildConfigProvider).features,
);

TelemetrySink createTelemetryExporter(AppBuildConfig config) {
  final endpoint = config.telemetryEndpointUri;
  if (endpoint == null) return const NoopTelemetrySink();
  return OtlpHttpTelemetrySink(
    endpoint: endpoint,
    environment: config.environment.name,
  );
}

/// Installs the bounded OTLP/HTTP exporter only when the build declares an
/// endpoint. A zero-config development build remains network-silent.
final telemetryExporterProvider = Provider<TelemetrySink>((ref) {
  final config = ref.watch(appBuildConfigProvider);
  final exporter = createTelemetryExporter(config);
  if (exporter is OtlpHttpTelemetrySink) ref.onDispose(exporter.dispose);
  return exporter;
});

final telemetrySinkProvider = Provider<TelemetrySink>(
  (ref) => RedactingTelemetrySink(ref.watch(telemetryExporterProvider)),
);

final localStoreProvider = Provider<LocalStore>(
  (ref) =>
      throw StateError('localStoreProvider must be overridden at startup.'),
);

/// Returns the opened local store as soon as it is safe for independent local
/// cleanup work. Production startup overrides this so deletion recovery can
/// wait for Drift to open without waiting for feed/restoration hydration.
final localStoreWhenReadyProvider = Provider<Future<LocalStore> Function()>(
  (ref) =>
      () async => ref.read(localStoreProvider),
);

/// Null in focused tests or alternate stores that do not provide relational
/// feed persistence; production startup supplies a Drift-backed store.
final feedCachePersistenceProvider = Provider<FeedCachePersistence?>((ref) {
  final store = ref.watch(localStoreProvider);
  return store is FeedCachePersistence ? store as FeedCachePersistence : null;
});

final initialAnonymousSessionIdProvider = Provider<String>(
  (ref) => const Uuid().v4(),
);

final anonymousSessionIdProvider =
    StateNotifierProvider<AnonymousSessionController, String>(
      (ref) => AnonymousSessionController(
        store: ref.watch(localStoreProvider),
        initialSessionId: ref.watch(initialAnonymousSessionIdProvider),
      ),
    );

final initialRestorationProvider = Provider<AppRestorationState>(
  (ref) => const AppRestorationState(),
);

final clientFulltextPolicyProvider = Provider<ClientFulltextPolicy>(
  (ref) => ClientFulltextPolicy.fromWire(
    ref.watch(appBuildConfigProvider).fulltextPolicy,
  ),
);

final demoContentStoreProvider = Provider<DemoContentStore>(
  (ref) => BundleDemoContentStore(),
);

final transportNetworkStatusProvider = Provider<TransportNetworkStatus>((ref) {
  final status = TransportNetworkStatus();
  ref.onDispose(status.dispose);
  return status;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: ref.watch(appBuildConfigProvider).apiBaseUri.toString(),
    sessionId: ref.watch(anonymousSessionIdProvider),
    networkStatus: ref.watch(transportNetworkStatusProvider),
  );
  ref.onDispose(client.dispose);
  return client;
});

final paperRepositoryProvider = Provider<PaperDataSource>((ref) {
  final repository = PaperRepository(
    api: ref.watch(apiClientProvider),
    localStore: ref.watch(localStoreProvider),
    demoContent: ref.watch(demoContentStoreProvider),
    fulltextPolicy: ref.watch(clientFulltextPolicyProvider),
    networkStatus: ref.watch(transportNetworkStatusProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

final networkOfflineProvider = StreamProvider<bool>((ref) async* {
  final repository = ref.watch(paperRepositoryProvider);
  yield repository.isOffline;
  yield* repository.offlineChanges;
});

abstract interface class ExternalLinkOpener {
  Future<bool> open(Uri uri);
}

class SystemExternalLinkOpener implements ExternalLinkOpener {
  @override
  Future<bool> open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}

final externalLinkOpenerProvider = Provider<ExternalLinkOpener>(
  (ref) => SystemExternalLinkOpener(),
);

class AnonymousSessionController extends StateNotifier<String> {
  AnonymousSessionController({
    required LocalStore store,
    required String initialSessionId,
  }) : _store = store,
       super(initialSessionId);

  final LocalStore _store;
  Future<String>? _rotation;

  /// Replaces the anonymous identity and removes locally restorable chat state.
  ///
  /// There is intentionally no old-ID recovery path: this is an anonymous
  /// rate-limit/privacy identity, not an account credential.
  Future<String> rotate() {
    final active = _rotation;
    if (active != null) return active;
    final operation = _rotate();
    _rotation = operation;
    return operation.whenComplete(() {
      if (identical(_rotation, operation)) _rotation = null;
    });
  }

  Future<String> reset() => rotate();

  Future<String> _rotate() async {
    final next = await _store.rotateAnonymousSession();
    if (mounted) state = next;
    return next;
  }
}
