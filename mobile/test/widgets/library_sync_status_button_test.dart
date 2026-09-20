import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/features/library/library_sync_status_button.dart';

void main() {
  testWidgets('pending badge opens truthful status and can be dismissed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LibrarySyncStatusButton(
            pendingCount: 3,
            issue: LibrarySyncIssue(
              code: 'FEATURE_DISABLED',
              message: 'Library writes are disabled.',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('library-sync-status')));
    await tester.pumpAndSettle();
    expect(find.text('Sync status'), findsOneWidget);
    expect(
      find.textContaining('3 library changes waiting to sync'),
      findsOneWidget,
    );
    expect(find.textContaining('saved on this device'), findsOneWidget);
    expect(find.textContaining('Library writes are disabled.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Sync status'), findsNothing);
  });
}
