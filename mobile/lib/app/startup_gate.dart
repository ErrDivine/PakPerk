import 'package:flutter/material.dart';

import '../design_system/colors.dart';
import '../design_system/motion.dart';
import '../design_system/sizes.dart';
import '../design_system/spacing.dart';
import 'startup_controller.dart';

enum ReducedMotionPreference { system, reduce, full }

class StartupGate extends StatefulWidget {
  const StartupGate({
    required this.state,
    required this.openingMotionEnabled,
    required this.onRetry,
    required this.onRepairAndRetry,
    required this.onFirstUsableFrame,
    required this.onOpeningComplete,
    required this.child,
    this.reducedMotionPreference = ReducedMotionPreference.system,
    super.key,
  });

  final StartupState state;
  final bool openingMotionEnabled;
  final VoidCallback onRetry;
  final VoidCallback onRepairAndRetry;
  final VoidCallback onFirstUsableFrame;
  final VoidCallback onOpeningComplete;
  final ReducedMotionPreference reducedMotionPreference;
  final Widget child;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _firstUsableFrameNotified = false;
  bool _openingCompletionScheduled = false;

  @override
  void didUpdateWidget(covariant StartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.attempt != widget.state.attempt) {
      _firstUsableFrameNotified = false;
      _openingCompletionScheduled = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.state.phase) {
      StartupPhase.recoverableFailure => _StartupFailureSurface(
        failure: widget.state.failure,
        onRetry: widget.onRetry,
        onRepairAndRetry: widget.onRepairAndRetry,
      ),
      StartupPhase.ready => _buildReady(),
      _ => const _StartupLaunchSurface(),
    };
  }

  Widget _buildReady() {
    _scheduleFirstUsableFrame();
    final shouldAnimate =
        widget.openingMotionEnabled &&
        widget.state.shouldShowOpening &&
        widget.state.launchMode != StartupLaunchMode.warm;
    if (!shouldAnimate) {
      _scheduleOpeningComplete();
      return widget.child;
    }

    return StartupOpeningTransition(
      launchMode: widget.state.launchMode,
      reducedMotionPreference: widget.reducedMotionPreference,
      onComplete: widget.onOpeningComplete,
      child: widget.child,
    );
  }

  void _scheduleFirstUsableFrame() {
    if (_firstUsableFrameNotified) return;
    _firstUsableFrameNotified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFirstUsableFrame();
    });
  }

  void _scheduleOpeningComplete() {
    if (_openingCompletionScheduled || widget.state.openingCompleted) return;
    _openingCompletionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onOpeningComplete();
    });
  }
}

class StartupOpeningTransition extends StatefulWidget {
  const StartupOpeningTransition({
    required this.launchMode,
    required this.onComplete,
    required this.child,
    this.reducedMotionPreference = ReducedMotionPreference.system,
    super.key,
  });

  final StartupLaunchMode launchMode;
  final ReducedMotionPreference reducedMotionPreference;
  final VoidCallback onComplete;
  final Widget child;

  @override
  State<StartupOpeningTransition> createState() =>
      _StartupOpeningTransitionState();
}

class _StartupOpeningTransitionState extends State<StartupOpeningTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;
  bool _finished = false;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reducedMotion = _resolveReducedMotion(context);

    if (widget.launchMode == StartupLaunchMode.warm) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _complete());
      return;
    }

    _controller.duration = _reducedMotion
        ? PakPerkMotion.crossFade
        : widget.launchMode == StartupLaunchMode.deepLink
        ? PakPerkMotion.deepLinkOpening
        : PakPerkMotion.coldOpening;
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _complete();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished || widget.launchMode == StartupLaunchMode.warm) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final progress = _controller.value;
        if (_reducedMotion) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Opacity(opacity: progress, child: child),
              IgnorePointer(
                child: Opacity(
                  opacity: 1 - progress,
                  child: const _StartupLaunchSurface(),
                ),
              ),
            ],
          );
        }

        final intervals = widget.launchMode == StartupLaunchMode.deepLink
            ? const _OpeningIntervals(
                markStart: 0,
                markEnd: .45,
                contentStart: .15,
              )
            : const _OpeningIntervals(
                markStart: .19,
                markEnd: .58,
                contentStart: .48,
              );
        final markProgress = CurvedAnimation(
          parent: _controller,
          curve: Interval(
            intervals.markStart,
            intervals.markEnd,
            curve: PakPerkMotion.emphasized,
          ),
        ).value;
        final contentProgress = CurvedAnimation(
          parent: _controller,
          curve: Interval(
            intervals.contentStart,
            1,
            curve: PakPerkMotion.enter,
          ),
        ).value;

        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: contentProgress < 1,
              child: Opacity(
                opacity: contentProgress,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - contentProgress)),
                  child: child,
                ),
              ),
            ),
            IgnorePointer(
              child: Opacity(
                opacity: 1 - contentProgress,
                child: _StartupLaunchSurface(
                  markScale: .96 + (.04 * markProgress),
                  wordmarkOpacity: markProgress,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _resolveReducedMotion(BuildContext context) {
    return switch (widget.reducedMotionPreference) {
      ReducedMotionPreference.reduce => true,
      ReducedMotionPreference.full => false,
      ReducedMotionPreference.system =>
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ||
            (MediaQuery.maybeOf(context)?.accessibleNavigation ?? false),
    };
  }

  void _complete() {
    if (!mounted || _finished) return;
    setState(() => _finished = true);
    widget.onComplete();
  }
}

class _OpeningIntervals {
  const _OpeningIntervals({
    required this.markStart,
    required this.markEnd,
    required this.contentStart,
  });

  final double markStart;
  final double markEnd;
  final double contentStart;
}

class _StartupLaunchSurface extends StatelessWidget {
  const _StartupLaunchSurface({this.markScale = 1, this.wordmarkOpacity = 0});

  final double markScale;
  final double wordmarkOpacity;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final semantic = Theme.of(context).extension<PakPerkSemanticColors>();
    final background =
        semantic?.paper ??
        (dark ? PakPerkColors.darkPaper : PakPerkColors.paper);
    final ink =
        semantic?.ink ?? (dark ? PakPerkColors.darkInk : PakPerkColors.ink);
    final mark = Image.asset(
      dark
          ? 'assets/brand/pakperk_mark_dark.png'
          : 'assets/brand/pakperk_mark.png',
      key: const ValueKey('startup-brand-mark'),
      width: PakPerkSizes.openingMark,
      height: PakPerkSizes.openingMark,
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    );

    return ColoredBox(
      key: const ValueKey('startup-launch-surface'),
      color: background,
      child: Center(
        child: Semantics(
          label: 'Pakperk is opening',
          image: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (markScale == 1)
                mark
              else
                Transform.scale(scale: markScale, child: mark),
              const SizedBox(height: PakPerkSpacing.sm),
              Opacity(
                opacity: wordmarkOpacity,
                child: Text(
                  'Pakperk',
                  key: const ValueKey('startup-wordmark'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: ink,
                    letterSpacing: -.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartupFailureSurface extends StatelessWidget {
  const _StartupFailureSurface({
    required this.failure,
    required this.onRetry,
    required this.onRepairAndRetry,
  });

  final StartupFailure? failure;
  final VoidCallback onRetry;
  final VoidCallback onRepairAndRetry;

  @override
  Widget build(BuildContext context) {
    final message = failure?.timedOut ?? false
        ? 'Local startup took longer than expected.'
        : 'Pakperk could not open its local reading data.';

    return Scaffold(
      key: const ValueKey('startup-recoverable-failure'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(PakPerkSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_stories_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: PakPerkSpacing.md),
                    Text(
                      'Your library needs attention',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: PakPerkSpacing.sm),
                    Text(
                      '$message Retry, or rebuild only the local cache. '
                      'Your sign-in credentials are kept.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: PakPerkSpacing.xl),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ),
                    const SizedBox(height: PakPerkSpacing.xs),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: onRepairAndRetry,
                        child: const Text('Rebuild local data'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
