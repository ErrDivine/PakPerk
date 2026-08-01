import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/startup_controller.dart';
import 'package:pakperk/app/startup_gate.dart';
import 'package:pakperk/design_system/motion.dart';
import 'package:pakperk/design_system/theme.dart';

void main() {
  testWidgets('cold opening ends on real content within the 700 ms budget', (
    tester,
  ) async {
    var completed = 0;
    await _pumpTransition(
      tester,
      launchMode: StartupLaunchMode.cold,
      preference: ReducedMotionPreference.full,
      onComplete: () => completed += 1,
    );

    expect(
      find.byKey(const ValueKey('startup-launch-surface')),
      findsOneWidget,
    );
    expect(completed, 0);
    await tester.pump(
      PakPerkMotion.coldOpening + const Duration(milliseconds: 1),
    );
    await tester.pump();

    expect(completed, 1);
    expect(find.byKey(const ValueKey('startup-launch-surface')), findsNothing);
    expect(find.byKey(const ValueKey('usable-content')), findsOneWidget);
    expect(
      PakPerkMotion.coldOpening,
      lessThanOrEqualTo(PakPerkMotion.maximumOpening),
    );
  });

  testWidgets('deep-link opening uses the shortened transition', (
    tester,
  ) async {
    var completed = 0;
    await _pumpTransition(
      tester,
      launchMode: StartupLaunchMode.deepLink,
      preference: ReducedMotionPreference.full,
      onComplete: () => completed += 1,
    );

    await tester.pump(
      PakPerkMotion.deepLinkOpening - const Duration(milliseconds: 1),
    );
    expect(completed, 0);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(completed, 1);
    expect(PakPerkMotion.deepLinkOpening, lessThan(PakPerkMotion.coldOpening));
  });

  testWidgets('reduced motion cross-fades without moving usable content', (
    tester,
  ) async {
    var completed = 0;
    await _pumpTransition(
      tester,
      launchMode: StartupLaunchMode.cold,
      preference: ReducedMotionPreference.reduce,
      onComplete: () => completed += 1,
    );
    final content = find.byKey(const ValueKey('usable-content'));
    final initialPosition = tester.getTopLeft(content);

    await tester.pump(
      (PakPerkMotion.crossFade ~/ 2) + const Duration(milliseconds: 1),
    );
    expect(tester.getTopLeft(content), initialPosition);
    expect(completed, 0);
    await tester.pump(PakPerkMotion.crossFade ~/ 2);
    await tester.pump();

    expect(completed, 1);
    expect(tester.getTopLeft(content), initialPosition);
    expect(find.byKey(const ValueKey('startup-launch-surface')), findsNothing);
  });

  testWidgets('system reduced-motion changes shorten an active opening', (
    tester,
  ) async {
    var completed = 0;
    Widget app(MediaQueryData media) => MaterialApp(
      theme: PakPerkTheme.light(),
      home: MediaQuery(
        data: media,
        child: StartupOpeningTransition(
          launchMode: StartupLaunchMode.cold,
          reducedMotionPreference: ReducedMotionPreference.system,
          onComplete: () => completed += 1,
          child: const ColoredBox(
            key: ValueKey('usable-content'),
            color: Colors.green,
          ),
        ),
      ),
    );

    await tester.pumpWidget(app(const MediaQueryData()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(completed, 0);

    await tester.pumpWidget(app(const MediaQueryData(disableAnimations: true)));
    await tester.pump(PakPerkMotion.crossFade);
    await tester.pump();

    expect(completed, 1);
    expect(find.byKey(const ValueKey('startup-launch-surface')), findsNothing);
  });

  testWidgets('warm ready state shows content and does not replay opening', (
    tester,
  ) async {
    var firstUsableFrames = 0;
    var openingCompletions = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: StartupGate(
          state: const StartupState(
            phase: StartupPhase.ready,
            launchMode: StartupLaunchMode.warm,
            sessionStatus: StartupSessionStatus.anonymous,
            attempt: 1,
            openingCompleted: true,
          ),
          openingMotionEnabled: true,
          onRetry: () {},
          onRepairAndRetry: () {},
          onFirstUsableFrame: () => firstUsableFrames += 1,
          onOpeningComplete: () => openingCompletions += 1,
          child: const ColoredBox(
            key: ValueKey('usable-content'),
            color: Colors.green,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('usable-content')), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-launch-surface')), findsNothing);
    expect(firstUsableFrames, 1);
    expect(openingCompletions, 0);
  });

  testWidgets('local-ready state exposes cached content before session check', (
    tester,
  ) async {
    var firstUsableFrames = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: StartupGate(
          state: const StartupState(
            phase: StartupPhase.localReady,
            launchMode: StartupLaunchMode.warm,
            attempt: 1,
            openingCompleted: true,
          ),
          openingMotionEnabled: true,
          onRetry: () {},
          onRepairAndRetry: () {},
          onFirstUsableFrame: () => firstUsableFrames += 1,
          onOpeningComplete: () {},
          child: const ColoredBox(
            key: ValueKey('cached-usable-content'),
            color: Colors.green,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('cached-usable-content')), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-launch-surface')), findsNothing);
    expect(firstUsableFrames, 1);
  });

  testWidgets('startup failure offers retry and credential-preserving repair', (
    tester,
  ) async {
    var retries = 0;
    var repairs = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: StartupGate(
          state: StartupState(
            phase: StartupPhase.recoverableFailure,
            launchMode: StartupLaunchMode.cold,
            attempt: 1,
            openingCompleted: false,
            failure: StartupFailure(
              error: StateError('migration failed'),
              stackTrace: StackTrace.current,
              timedOut: false,
            ),
          ),
          openingMotionEnabled: true,
          onRetry: () => retries += 1,
          onRepairAndRetry: () => repairs += 1,
          onFirstUsableFrame: () {},
          onOpeningComplete: () {},
          child: const SizedBox(),
        ),
      ),
    );

    expect(
      find.textContaining('Your sign-in credentials are kept.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Rebuild local data'));
    expect(retries, 1);
    expect(repairs, 1);
  });

  testWidgets('post-local session failure does not offer destructive repair', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PakPerkTheme.light(),
        home: StartupGate(
          state: StartupState(
            phase: StartupPhase.recoverableFailure,
            launchMode: StartupLaunchMode.cold,
            attempt: 1,
            openingCompleted: true,
            failure: StartupFailure(
              error: StateError('secure store unavailable'),
              stackTrace: StackTrace.current,
              timedOut: false,
              localStateUsable: true,
            ),
          ),
          openingMotionEnabled: true,
          onRetry: () {},
          onRepairAndRetry: () => fail('repair must not be exposed'),
          onFirstUsableFrame: () {},
          onOpeningComplete: () {},
          child: const SizedBox(),
        ),
      ),
    );

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Rebuild local data'), findsNothing);
    expect(find.textContaining('cached reading data is safe'), findsOneWidget);
  });
}

Future<void> _pumpTransition(
  WidgetTester tester, {
  required StartupLaunchMode launchMode,
  required ReducedMotionPreference preference,
  required VoidCallback onComplete,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: PakPerkTheme.light(),
      home: StartupOpeningTransition(
        launchMode: launchMode,
        reducedMotionPreference: preference,
        onComplete: onComplete,
        child: const ColoredBox(
          key: ValueKey('usable-content'),
          color: Colors.green,
        ),
      ),
    ),
  );
}
