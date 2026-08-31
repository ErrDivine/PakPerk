import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/features/document_reader/reader_interaction_state.dart';
import 'package:pakperk/features/reader_modes/reader_mode_controller.dart';
import 'package:pakperk/features/reader_modes/reader_mode_selector.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('mode selector scales to 200 percent with 48 point targets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: const Scaffold(
                body: Column(
                  children: [
                    ReaderModeSelector(readerKey: 'reader-a'),
                    _SelectedMode(readerKey: 'reader-a'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    for (final mode in ['skim', 'read', 'inspect']) {
      final finder = find.byKey(ValueKey('reader-mode-$mode'));
      expect(finder, findsOneWidget);
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    }
    expect(find.byType(FittedBox), findsNothing);
    expect(
      tester
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
          .every((widget) => widget.duration == Duration.zero),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    final inspect = find.byKey(const ValueKey('reader-mode-inspect'));
    await tester.ensureVisible(inspect);
    await tester.pump();
    await tester.tap(inspect);
    await tester.pump();
    expect(find.text('selected: inspect'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Inspect reading mode' &&
            widget.properties.selected == true,
      ),
      findsOneWidget,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderModeSelector)),
    );
    expect(
      container.read(readerInteractionControllerProvider('reader-a')),
      const ReaderInteractionState(),
      reason: 'Inspect mode is a display mode, not an active gesture owner.',
    );
  });

  testWidgets('rapid mode commits retarget the in-place transition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(520, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
          initialRestorationProvider.overrideWithValue(
            const AppRestorationState(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ReaderModeSelector(readerKey: 'reader-b'),
                _SelectedMode(readerKey: 'reader-b'),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('reader-mode-read')));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const ValueKey('reader-mode-inspect')));
    await tester.pump();

    expect(find.text('selected: inspect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced transparency is an explicit independent policy', (
    tester,
  ) async {
    Future<void> pump({
      required bool reduceTransparency,
      required bool highContrast,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(highContrast: highContrast),
            child: PakPerkAccessibilityPreferences(
              reduceTransparency: reduceTransparency,
              child: Builder(
                builder: (context) => Text(
                  'opaque: ${platformPrefersReducedTransparency(context)}',
                ),
              ),
            ),
          ),
        ),
      );
    }

    await pump(reduceTransparency: true, highContrast: false);
    expect(find.text('opaque: true'), findsOneWidget);

    await pump(reduceTransparency: false, highContrast: true);
    expect(find.text('opaque: false'), findsOneWidget);
  });
}

class _SelectedMode extends ConsumerWidget {
  const _SelectedMode({required this.readerKey});

  final String readerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(readerDepthModeProvider(readerKey));
    return Text('selected: ${mode.wireValue}');
  }
}
