import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/semantic_span.dart';
import '../paper_reader/reader_navigation_controller.dart';

final semanticFacetDensityProvider = Provider.family<SemanticDensity, String>(
  (ref, readerKey) =>
      ref.watch(readerNavigationStateProvider(readerKey)).semanticDensity,
);

final semanticFacetControllerProvider =
    Provider.family<SemanticFacetController, String>(
      (ref, readerKey) => SemanticFacetController(ref, readerKey),
    );

final class SemanticFacetController {
  const SemanticFacetController(this._ref, this.readerKey);

  final Ref _ref;
  final String readerKey;

  void select(SemanticDensity density) {
    _ref
        .read(paperReaderNavigationControllerProvider(readerKey))
        .setSemanticDensity(density);
  }
}
