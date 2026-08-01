import 'package:flutter/scheduler.dart';

/// A deterministic, serializable view of one Flutter frame.
///
/// The production adapter records only durations. It deliberately excludes
/// route names, paper identifiers, text, and timestamps so performance
/// evidence cannot become a content-rich telemetry channel.
final class PakPerkFrameTiming {
  const PakPerkFrameTiming({
    required this.build,
    required this.raster,
    required this.total,
  });

  factory PakPerkFrameTiming.fromFlutter(FrameTiming timing) =>
      PakPerkFrameTiming(
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        total: timing.totalSpan,
      );

  final Duration build;
  final Duration raster;
  final Duration total;
}

/// Aggregate frame measurements suitable for integration-test artifacts.
final class PakPerkFrameTimingSummary {
  const PakPerkFrameTimingSummary({
    required this.sampleCount,
    required this.buildP90,
    required this.buildMax,
    required this.rasterP90,
    required this.rasterMax,
    required this.totalP90,
    required this.totalMax,
  });

  const PakPerkFrameTimingSummary.empty()
    : sampleCount = 0,
      buildP90 = Duration.zero,
      buildMax = Duration.zero,
      rasterP90 = Duration.zero,
      rasterMax = Duration.zero,
      totalP90 = Duration.zero,
      totalMax = Duration.zero;

  final int sampleCount;
  final Duration buildP90;
  final Duration buildMax;
  final Duration rasterP90;
  final Duration rasterMax;
  final Duration totalP90;
  final Duration totalMax;

  Map<String, int> toJson() => {
    'sample_count': sampleCount,
    'build_p90_us': buildP90.inMicroseconds,
    'build_max_us': buildMax.inMicroseconds,
    'raster_p90_us': rasterP90.inMicroseconds,
    'raster_max_us': rasterMax.inMicroseconds,
    'total_p90_us': totalP90.inMicroseconds,
    'total_max_us': totalMax.inMicroseconds,
  };
}

/// In-memory frame aggregator shared by deterministic tests and device probes.
final class PakPerkFrameTimingCollector {
  final List<PakPerkFrameTiming> _samples = [];

  int get sampleCount => _samples.length;

  void add(PakPerkFrameTiming timing) {
    if (timing.build.isNegative ||
        timing.raster.isNegative ||
        timing.total.isNegative) {
      throw ArgumentError.value(
        timing,
        'timing',
        'Durations must be non-negative.',
      );
    }
    _samples.add(timing);
  }

  void addFlutterTimings(Iterable<FrameTiming> timings) {
    for (final timing in timings) {
      add(PakPerkFrameTiming.fromFlutter(timing));
    }
  }

  PakPerkFrameTimingSummary snapshot() {
    if (_samples.isEmpty) return const PakPerkFrameTimingSummary.empty();
    final builds = _samples.map((sample) => sample.build).toList();
    final rasters = _samples.map((sample) => sample.raster).toList();
    final totals = _samples.map((sample) => sample.total).toList();
    return PakPerkFrameTimingSummary(
      sampleCount: _samples.length,
      buildP90: _percentile(builds, .9),
      buildMax: _maximum(builds),
      rasterP90: _percentile(rasters, .9),
      rasterMax: _maximum(rasters),
      totalP90: _percentile(totals, .9),
      totalMax: _maximum(totals),
    );
  }
}

/// Runtime bridge to Flutter's engine frame-timing callback.
///
/// Widget tests may not emit engine timings. The same probe does emit samples
/// when the integration suite runs on a real profile-mode device, and its
/// summary can be attached to the runner's release evidence.
final class PakPerkFlutterFrameTimingProbe {
  PakPerkFlutterFrameTimingProbe({
    SchedulerBinding? binding,
    PakPerkFrameTimingCollector? collector,
  }) : _binding = binding ?? SchedulerBinding.instance,
       collector = collector ?? PakPerkFrameTimingCollector();

  final SchedulerBinding _binding;
  final PakPerkFrameTimingCollector collector;
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) throw StateError('Frame timing probe is already running.');
    _running = true;
    _binding.addTimingsCallback(_record);
  }

  PakPerkFrameTimingSummary stop() {
    if (!_running) throw StateError('Frame timing probe is not running.');
    _binding.removeTimingsCallback(_record);
    _running = false;
    return collector.snapshot();
  }

  void _record(List<FrameTiming> timings) {
    collector.addFlutterTimings(timings);
  }
}

Duration _percentile(List<Duration> values, double percentile) {
  final sorted = values.map((value) => value.inMicroseconds).toList()..sort();
  final index = (percentile * sorted.length).ceil().clamp(1, sorted.length) - 1;
  return Duration(microseconds: sorted[index]);
}

Duration _maximum(List<Duration> values) => values.reduce(
  (current, candidate) => candidate > current ? candidate : current,
);
