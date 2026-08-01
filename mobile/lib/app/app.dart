import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/auth/auth.dart';
import '../features/feed/feed_controller.dart';
import '../features/paper_reader/reader_navigation_controller.dart';
import 'account_providers.dart';
import 'appearance_controller.dart';
import 'library_providers.dart';
import 'comments_providers.dart';
import 'router.dart';
import 'startup_controller.dart';
import 'startup_gate.dart';
import 'theme.dart';

class PakPerkApp extends ConsumerStatefulWidget {
  const PakPerkApp({super.key});

  @override
  ConsumerState<PakPerkApp> createState() => _PakPerkAppState();
}

class _PakPerkAppState extends ConsumerState<PakPerkApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.read(featureFlagsProvider).library) {
      unawaited(
        ref.read(librarySyncControllerProvider.notifier).onForeground(),
      );
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(appRestorationControllerProvider.notifier).flush());
    }
  }

  void _notifyFirstUsableFrame() {
    ref.read(startupControllerProvider.notifier).notifyFirstUsableFrame();
    unawaited(
      ref.read(feedControllerProvider.notifier).refreshPreloadedFirstPageOnce(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _observeAccountSession();
    if (ref.watch(featureFlagsProvider).library) {
      ref.watch(libraryRuntimeProvider);
    }
    if (ref.watch(featureFlagsProvider).comments) {
      ref.watch(commentsRuntimeProvider);
    }
    final startup = ref.watch(startupControllerProvider);
    final startupController = ref.read(startupControllerProvider.notifier);
    final openingMotion = ref.watch(featureFlagsProvider).openingMotion;
    return MaterialApp.router(
      title: 'Pakperk',
      debugShowCheckedModeBanner: false,
      theme: buildPakPerkTheme(),
      darkTheme: buildPakPerkDarkTheme(),
      themeMode: ref.watch(appearanceControllerProvider).themeMode,
      restorationScopeId: 'pakperk-app',
      routerConfig: ref.watch(pakPerkRouterProvider),
      builder: (context, child) => StartupGate(
        state: startup,
        openingMotionEnabled: openingMotion,
        onRetry: startupController.retry,
        onRepairAndRetry: startupController.repairAndRetry,
        onFirstUsableFrame: _notifyFirstUsableFrame,
        onOpeningComplete: startupController.markOpeningComplete,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }

  void _observeAccountSession() {
    if (!ref.watch(featureFlagsProvider).accounts) return;
    ref.listen<AuthSessionState>(authSessionProvider, (previous, next) {
      if (next.phase != AuthSessionPhase.guest ||
          previous?.phase == AuthSessionPhase.guest) {
        return;
      }
      ref.read(currentAccountProvider.notifier).clear();
      ref.read(pendingAuthenticatedActionProvider.notifier).clear();
    });
  }
}
