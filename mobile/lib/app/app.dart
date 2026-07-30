import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/paper_reader/reader_navigation_controller.dart';
import 'router.dart';
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(appRestorationControllerProvider.notifier).flush());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pakperk',
      debugShowCheckedModeBanner: false,
      theme: buildPakPerkTheme(),
      restorationScopeId: 'pakperk-app',
      home: const PakPerkRouter(),
    );
  }
}
