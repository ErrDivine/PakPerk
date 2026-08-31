import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/design_system/sizes.dart';
import 'package:pakperk/features/document_reader/reader_library_control.dart';

import '../support/fakes.dart';

void main() {
  testWidgets('reader exposes canonical Library controls at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const scope = (
      accountId: '018f47a6-4b56-7f4c-8c7a-e2656e820001',
      authEpoch: 7,
    );
    final item = LibraryListItem(
      paper: samplePaper,
      savedAt: DateTime.utc(2026, 8, 19),
      savedState: const LibrarySavedState(saved: true, syncPending: false),
      state: LibraryItemState.reading,
      privateNote: 'Revisit the methods assumptions.',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const FeatureFlags(
              accounts: true,
              library: true,
              comments: false,
              openingMotion: false,
              libraryV2Enabled: true,
            ),
          ),
          libraryDisplayScopeProvider.overrideWithValue(scope),
          libraryMutationScopeProvider.overrideWithValue(scope),
          libraryItemsProvider.overrideWith(
            (ref, requestedScope) =>
                Stream.value(requestedScope == scope ? [item] : const []),
          ),
          toReadItemsProvider.overrideWith(
            (ref, requestedScope) =>
                Stream.value(requestedScope == scope ? [item] : const []),
          ),
          librarySyncCheckpointProvider.overrideWith(
            (ref, requestedScope) => Stream.value(
              requestedScope == scope
                  ? const LibrarySyncCheckpoint(
                      initialized: true,
                      lastRevision: 9,
                    )
                  : const LibrarySyncCheckpoint.unknown(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ReaderLibraryControl(paper: samplePaper),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final control = find.byKey(const ValueKey('reader-library-control'));
    expect(control, findsOneWidget);
    expect(
      tester.getSize(control).width,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );
    expect(
      tester.getSize(control).height,
      greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
    );

    await tester.tap(control);
    await tester.pumpAndSettle();

    expect(find.text('Current: Reading'), findsOneWidget);
    expect(find.text('Reading'), findsWidgets);
    expect(find.text('Reviewed'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Private save note'), findsOneWidget);
    expect(find.text('Save private note'), findsOneWidget);
    expect(find.text('Remove from Library'), findsOneWidget);
    expect(
      find.text('Private. Never used as recommendation input.'),
      findsOneWidget,
    );

    for (final button in [
      find.widgetWithText(FilledButton, 'Reading'),
      find.widgetWithText(OutlinedButton, 'Reviewed'),
      find.widgetWithText(OutlinedButton, 'Archived'),
    ]) {
      expect(button, findsOneWidget);
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(PakPerkSizes.minimumInteractive),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
