import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../l10n/ui.dart';
import 'product_survey_controller.dart';

final surveyRoutesProvider = Provider((ref) => SurveyRouteTracker());

class SurveyRouteTracker {
  final _routes = <Route<dynamic>>{};
  bool get hasPopup => _routes.any((route) => route is PopupRoute);
  NavigatorObserver observer() => _SurveyRouteObserver(this);
}

class _SurveyRouteObserver extends NavigatorObserver {
  _SurveyRouteObserver(this.tracker);
  final SurveyRouteTracker tracker;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      tracker._routes.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      tracker._routes.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      tracker._routes.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    tracker._routes.remove(oldRoute);
    if (newRoute != null) tracker._routes.add(newRoute);
  }
}

class ProductSurveyPromptHost extends ConsumerStatefulWidget {
  const ProductSurveyPromptHost({
    required this.enabled,
    required this.child,
    super.key,
  });
  final bool enabled;
  final Widget child;
  @override
  ConsumerState<ProductSurveyPromptHost> createState() =>
      _ProductSurveyPromptHostState();
}

class _ProductSurveyPromptHostState
    extends ConsumerState<ProductSurveyPromptHost>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _showing = false;
  bool _resumed = true;
  late ProductSurveyController _survey;
  @override
  void initState() {
    super.initState();
    _survey = ref.read(productSurveyProvider);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateActive();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _survey.tick();
      if (mounted) unawaited(_maybeInvite());
    });
  }

  void _updateActive() => _survey.setForeground(widget.enabled && _resumed);
  @override
  void didUpdateWidget(ProductSurveyPromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateActive();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _updateActive();
  }

  Future<void> _maybeInvite() async {
    if (_showing ||
        !widget.enabled ||
        !_resumed ||
        !_survey.invitationDue ||
        ref.read(surveyRoutesProvider).hasPopup) {
      return;
    }
    final navigator = ref.read(pakPerkNavigatorKeysProvider).root;
    final context = navigator.currentContext;
    if (context == null || navigator.currentState == null) return;
    final path = ref
        .read(pakPerkRouterProvider)
        .routeInformationProvider
        .value
        .uri
        .path;
    if (path.startsWith('/auth') ||
        path.contains('account-delete') ||
        path.contains('questionnaire') ||
        MediaQuery.viewInsetsOf(context).bottom > 0) {
      return;
    }
    _showing = true;
    try {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: Icon(
            Icons.chat_bubble_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const UiText('How’s it going so far?'),
          content: const UiText(
            'Would you spare two or three minutes to tell us how PakPerk has been for you?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'refuse'),
              child: const UiText('I refuse'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'later'),
              child: const UiText('Remind me later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'accept'),
              child: const UiText('Of course'),
            ),
          ],
        ),
      );
      await _survey.choose(choice ?? 'later');
      if (choice == 'accept' && mounted && context.mounted) {
        await GoRouter.of(context).push('/you/questionnaire');
      }
    } finally {
      _showing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _survey.setForeground(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
