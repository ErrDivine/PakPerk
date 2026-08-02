import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/account/guest_you_screen.dart';

void main() {
  testWidgets('guest You is honest when accounts are disabled', (tester) async {
    var settingsOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: Scaffold(
          body: GuestYouScreen(
            accountsEnabled: false,
            libraryEnabled: false,
            commentsEnabled: false,
            onOpenSettings: () => settingsOpened = true,
            onOpenPrivacy: () {},
            onOpenTerms: () {},
            onOpenCommunityGuidelines: () {},
          ),
        ),
      ),
    );

    expect(find.text('Reading works without an account'), findsOneWidget);
    expect(
      find.text(
        'Account services are not enabled in this build. Public reading '
        'and on-device settings remain available.',
      ),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);

    await tester.tap(find.text('Settings'));
    expect(settingsOpened, isTrue);
  });

  testWidgets('guest account card describes only enabled capabilities', (
    tester,
  ) async {
    Future<void> pump({required bool library, required bool comments}) =>
        tester.pumpWidget(
          MaterialApp(
            home: GuestYouScreen(
              accountsEnabled: true,
              libraryEnabled: library,
              commentsEnabled: comments,
              onSignIn: () {},
              onOpenSettings: () {},
              onOpenPrivacy: () {},
              onOpenTerms: () {},
              onOpenCommunityGuidelines: () {},
            ),
          ),
        );

    await pump(library: true, comments: false);
    expect(
      find.text('Sign in to sync your To Read list across devices.'),
      findsOneWidget,
    );
    expect(find.textContaining('paper discussions'), findsNothing);

    await pump(library: false, comments: true);
    expect(find.text('Join paper discussions'), findsOneWidget);
    expect(
      find.text('Sign in to participate in moderated paper discussions.'),
      findsOneWidget,
    );
    expect(find.textContaining('To Read'), findsNothing);

    await pump(library: false, comments: false);
    expect(find.text('Your Pakperk account'), findsOneWidget);
    expect(
      find.text('Sign in to manage your Pakperk account.'),
      findsOneWidget,
    );
    expect(find.textContaining('To Read'), findsNothing);
    expect(find.textContaining('discussions'), findsNothing);
  });

  testWidgets('guest You remains usable at 200% text scaling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: GuestYouScreen(
                onOpenSettings: () {},
                onOpenPrivacy: () {},
                onOpenTerms: () {},
                onOpenCommunityGuidelines: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(FilledButton)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.scrollUntilVisible(
      find.text('Community guidelines'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Community guidelines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
