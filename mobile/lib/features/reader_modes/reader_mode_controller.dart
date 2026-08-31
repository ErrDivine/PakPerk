import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../paper_reader/reader_navigation_controller.dart';
import 'reader_mode.dart';

final readerDepthModeProvider = Provider.family<ReaderDepthMode, String>((
  ref,
  readerKey,
) {
  return ref.watch(readerNavigationStateProvider(readerKey)).depthMode;
});

final readerModeControllerProvider =
    Provider.family<ReaderModeController, String>(
      (ref, readerKey) => ReaderModeController(ref, readerKey),
    );

final class ReaderModeController {
  const ReaderModeController(this._ref, this.readerKey);

  final Ref _ref;
  final String readerKey;

  void select(ReaderDepthMode mode) {
    _ref
        .read(paperReaderNavigationControllerProvider(readerKey))
        .setDepthMode(mode);
  }
}
