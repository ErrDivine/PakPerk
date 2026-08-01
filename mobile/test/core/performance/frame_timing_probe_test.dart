import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/performance/frame_timing_probe.dart';

void main() {
  test('frame summary uses deterministic nearest-rank percentiles', () {
    final collector = PakPerkFrameTimingCollector();
    for (var index = 1; index <= 10; index += 1) {
      collector.add(
        PakPerkFrameTiming(
          build: Duration(milliseconds: index),
          raster: Duration(milliseconds: 11 - index),
          total: const Duration(milliseconds: 16),
        ),
      );
    }

    final summary = collector.snapshot();
    expect(summary.sampleCount, 10);
    expect(summary.buildP90, const Duration(milliseconds: 9));
    expect(summary.buildMax, const Duration(milliseconds: 10));
    expect(summary.rasterP90, const Duration(milliseconds: 9));
    expect(summary.rasterMax, const Duration(milliseconds: 10));
    expect(summary.totalP90, const Duration(milliseconds: 16));
    expect(summary.totalMax, const Duration(milliseconds: 16));
    expect(summary.toJson(), {
      'sample_count': 10,
      'build_p90_us': 9000,
      'build_max_us': 10000,
      'raster_p90_us': 9000,
      'raster_max_us': 10000,
      'total_p90_us': 16000,
      'total_max_us': 16000,
    });
  });

  test('empty summaries are explicit and negative durations fail closed', () {
    final collector = PakPerkFrameTimingCollector();
    expect(collector.snapshot().toJson(), {
      'sample_count': 0,
      'build_p90_us': 0,
      'build_max_us': 0,
      'raster_p90_us': 0,
      'raster_max_us': 0,
      'total_p90_us': 0,
      'total_max_us': 0,
    });

    expect(
      () => collector.add(
        const PakPerkFrameTiming(
          build: Duration(microseconds: -1),
          raster: Duration.zero,
          total: Duration.zero,
        ),
      ),
      throwsArgumentError,
    );
  });
}
