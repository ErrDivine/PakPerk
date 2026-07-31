import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api/api_exception.dart';
import '../core/api/request_cancellation.dart';
import '../core/models/arxiv_identifier.dart';
import '../core/models/paper.dart';
import '../core/models/reader_state.dart';
import '../core/providers.dart';
import '../core/widgets/responsive_reader_frame.dart';
import '../features/account/guest_you_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_sheet.dart';
import '../features/feed/feed_screen.dart';
import '../features/paper_reader/paper_metadata_controller.dart';
import '../features/paper_reader/paper_reader.dart';
import '../features/paper_reader/reader_navigation_controller.dart';
import '../features/placeholders/phase_one_placeholder_screens.dart';

abstract final class PakPerkRoutes {
  static const read = '/read';
  static const you = '/you';
  static const youLibrary = '/you/library';
  static const youComments = '/you/comments';
  static const youSettings = '/you/settings';
  static const youAccountDelete = '/you/account/delete';
  static const auth = '/auth';
  static const privacy = '/legal/privacy';
  static const terms = '/legal/terms';
  static const communityGuidelines = '/legal/community';
  static const support = '/support';

  static String paper(String paperId) =>
      '/read/paper/${_validatedPaperId(paperId)}';

  static String paperChat(String paperId) => '${paper(paperId)}/chat';

  static String paperComments(String paperId) => '${paper(paperId)}/comments';

  static String publicPaper(String paperId) =>
      '/p/${_validatedPaperId(paperId)}';

  static String publicPaperComments(String paperId) =>
      '${publicPaper(paperId)}/comments';

  static String arxiv(String arxivId) {
    final normalized = ArxivIdentifier.tryParse(arxivId);
    if (normalized == null) {
      throw ArgumentError.value(
        arxivId,
        'arxivId',
        'must be a modern or legacy arXiv identifier',
      );
    }
    return '/arxiv/${normalized.encodedRouteSegment}';
  }

  /// Normalizes the registered custom-scheme form before route matching.
  /// Unknown hosts, extra path segments, and malformed IDs fail closed.
  static String? normalizeCustomScheme(Uri uri) {
    if (uri.scheme.toLowerCase() != 'pakperk') return null;
    if (!uri.hasAuthority ||
        uri.host != 'paper' ||
        uri.authority != 'paper' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty) {
      return read;
    }
    final segments = uri.pathSegments;
    if (segments.isEmpty) return read;
    final paperId = segments.first;
    if (!PakPerkRouteIdentifiers.isValidPaperId(paperId)) return read;
    if (segments.length == 1) return paper(paperId);
    if (segments.length == 2 && segments[1] == 'comments') {
      return paperComments(paperId);
    }
    return read;
  }

  /// Converts only registered, public app links into internal locations.
  /// Absolute links on any other origin fail closed before path matching.
  static String? normalizeIncomingLink(Uri uri) {
    if (!uri.hasScheme) {
      return uri.hasAuthority ? read : null;
    }
    final custom = normalizeCustomScheme(uri);
    if (custom != null) return custom;
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'pakperk.app' ||
        uri.authority.toLowerCase() != 'pakperk.app' ||
        uri.hasQuery ||
        uri.hasFragment) {
      return read;
    }
    final segments = uri.pathSegments;
    if (segments.length == 2 && segments.first == 'p') {
      final paperId = segments[1];
      return PakPerkRouteIdentifiers.isValidPaperId(paperId)
          ? paper(paperId)
          : read;
    }
    if (segments.length == 3 &&
        segments.first == 'p' &&
        segments[2] == 'comments') {
      final paperId = segments[1];
      return PakPerkRouteIdentifiers.isValidPaperId(paperId)
          ? paperComments(paperId)
          : read;
    }
    if (segments.length == 2 && segments.first == 'arxiv') {
      final identifier = ArxivIdentifier.tryParse(segments[1]);
      return identifier == null ? read : arxiv(identifier.queryId);
    }
    return read;
  }

  static String _validatedPaperId(String value) {
    if (!PakPerkRouteIdentifiers.isValidPaperId(value)) {
      throw ArgumentError.value(value, 'paperId', 'must be a UUID');
    }
    return value.toLowerCase();
  }
}

abstract final class PakPerkRouteIdentifiers {
  static final RegExp _paperId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isValidPaperId(String value) =>
      value.length == 36 && _paperId.hasMatch(value);

  static bool isValidArxivId(String value) =>
      ArxivIdentifier.tryParse(value) != null;
}

class PaperChatRouteData {
  const PaperChatRouteData({
    required this.paperId,
    required this.readerKey,
    required this.paperTitle,
    required this.chatEnabled,
  });

  final String paperId;
  final String readerKey;
  final String paperTitle;
  final bool chatEnabled;

  bool matchesPathPaper(String pathPaperId) =>
      PakPerkRouteIdentifiers.isValidPaperId(paperId) &&
      paperId.toLowerCase() == pathPaperId.toLowerCase() &&
      readerKey.trim().isNotEmpty &&
      readerKey.length <= 256 &&
      paperTitle.length <= 1000;
}

class PaperCommentsRouteData {
  const PaperCommentsRouteData({
    required this.paperId,
    required this.paperTitle,
  });

  final String paperId;
  final String paperTitle;

  bool matchesPathPaper(String pathPaperId) =>
      PakPerkRouteIdentifiers.isValidPaperId(paperId) &&
      paperId.toLowerCase() == pathPaperId.toLowerCase() &&
      paperTitle.length <= 1000;
}

/// Opens paper chat above the shell and keeps the legacy restoration bit in
/// sync until the root route has closed.
Future<void> openPaperChat(
  BuildContext context,
  PaperChatRouteData data,
) async {
  if (!data.matchesPathPaper(data.paperId)) {
    throw ArgumentError.value(data, 'data', 'contains invalid route data');
  }
  final navigation = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(paperReaderNavigationControllerProvider(data.readerKey));
  navigation.setChatSheetOpen(true);
  try {
    if (GoRouter.maybeOf(context) != null) {
      await context.push<void>(
        PakPerkRoutes.paperChat(data.paperId),
        extra: data,
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        useSafeArea: false,
        isScrollControlled: true,
        builder: (sheetContext) => FractionallySizedBox(
          heightFactor: .9,
          child: PaperChatRouteScreen(
            data: data,
            protectTopInset: false,
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      );
    }
  } finally {
    navigation.setChatSheetOpen(false);
  }
}

Future<void> openPaperComments(
  BuildContext context,
  PaperCommentsRouteData data,
) async {
  if (!data.matchesPathPaper(data.paperId)) {
    throw ArgumentError.value(data, 'data', 'contains invalid route data');
  }
  if (GoRouter.maybeOf(context) != null) {
    await context.push<void>(
      PakPerkRoutes.paperComments(data.paperId),
      extra: data,
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    isScrollControlled: true,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: .9,
      child: PhaseOnePlaceholderScreen(
        title: 'Paper discussions',
        message:
            'Comments for “${data.paperTitle}” are not enabled in this '
            'build. No comment controls are presented as functional.',
        icon: Icons.forum_outlined,
        closeTooltip: 'Close paper discussions',
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

void closePakPerkRootRoute(
  BuildContext context, {
  String fallbackLocation = PakPerkRoutes.read,
}) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(fallbackLocation);
  }
}

class PakPerkNavigatorKeys {
  PakPerkNavigatorKeys()
    : root = GlobalKey<NavigatorState>(debugLabel: 'pakperk-root'),
      read = GlobalKey<NavigatorState>(debugLabel: 'pakperk-read'),
      you = GlobalKey<NavigatorState>(debugLabel: 'pakperk-you');

  final GlobalKey<NavigatorState> root;
  final GlobalKey<NavigatorState> read;
  final GlobalKey<NavigatorState> you;
}

final pakPerkNavigatorKeysProvider = Provider<PakPerkNavigatorKeys>(
  (ref) => PakPerkNavigatorKeys(),
);

final pakPerkRouterProvider = Provider<GoRouter>((ref) {
  final keys = ref.watch(pakPerkNavigatorKeysProvider);
  final restoredBranch = ref.read(activeAppBranchProvider);
  final router = GoRouter(
    navigatorKey: keys.root,
    restorationScopeId: 'pakperk-router',
    initialLocation: restoredBranch == AppBranch.you
        ? PakPerkRoutes.you
        : PakPerkRoutes.read,
    redirect: (_, state) => PakPerkRoutes.normalizeIncomingLink(state.uri),
    routes: [
      GoRoute(path: '/', redirect: (_, __) => PakPerkRoutes.read),
      GoRoute(
        path: PakPerkRoutes.auth,
        parentNavigatorKey: keys.root,
        pageBuilder: (context, state) => _rootPage(
          state,
          child: PhaseOnePlaceholderScreen(
            title: 'Accounts are not enabled',
            message:
                'Sign in and account creation will be connected in the '
                'account phase. No credentials are collected by this screen.',
            icon: Icons.lock_outline,
            closeTooltip: 'Close account sign in',
            onClose: () => closePakPerkRootRoute(context),
          ),
        ),
      ),
      GoRoute(
        path: '/read/paper/:paperId/chat',
        parentNavigatorKey: keys.root,
        pageBuilder: (context, state) {
          final pathPaperId = state.pathParameters['paperId'] ?? '';
          final extra = state.extra;
          final data =
              extra is PaperChatRouteData && extra.matchesPathPaper(pathPaperId)
              ? extra
              : null;
          return _rootPage(
            state,
            child: PaperChatRouteScreen(
              data: data,
              onClose: () => closePakPerkRootRoute(context),
            ),
          );
        },
      ),
      GoRoute(
        path: '/read/paper/:paperId/comments',
        parentNavigatorKey: keys.root,
        pageBuilder: (context, state) {
          final pathPaperId = state.pathParameters['paperId'] ?? '';
          final extra = state.extra;
          final data =
              extra is PaperCommentsRouteData &&
                  extra.matchesPathPaper(pathPaperId)
              ? extra
              : null;
          return _rootPage(
            state,
            child: PaperCommentsRouteScreen(
              paperId: pathPaperId,
              initialData: data,
              onClose: () => closePakPerkRootRoute(context),
            ),
          );
        },
      ),
      for (final legalRoute in _legalRoutes(keys.root)) legalRoute,
      GoRoute(
        path: '/p/:paperId/comments',
        redirect: (_, state) {
          final paperId = state.pathParameters['paperId'] ?? '';
          return PakPerkRouteIdentifiers.isValidPaperId(paperId)
              ? PakPerkRoutes.paperComments(paperId)
              : PakPerkRoutes.read;
        },
      ),
      GoRoute(
        path: '/p/:paperId',
        redirect: (_, state) {
          final paperId = state.pathParameters['paperId'] ?? '';
          return PakPerkRouteIdentifiers.isValidPaperId(paperId)
              ? PakPerkRoutes.paper(paperId)
              : PakPerkRoutes.read;
        },
      ),
      StatefulShellRoute.indexedStack(
        restorationScopeId: 'pakperk-shell',
        builder: (context, state, navigationShell) =>
            PakPerkAppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            navigatorKey: keys.read,
            restorationScopeId: 'pakperk-read-branch',
            initialLocation: PakPerkRoutes.read,
            routes: [
              GoRoute(
                path: PakPerkRoutes.read,
                pageBuilder: (_, state) => MaterialPage<void>(
                  key: state.pageKey,
                  restorationId: 'read-root-page',
                  child: const ReadBranchNavigator(),
                ),
                routes: [
                  GoRoute(
                    path: 'paper/:paperId',
                    pageBuilder: (context, state) {
                      final paperId = state.pathParameters['paperId'] ?? '';
                      final extra = state.extra;
                      final initialPaper =
                          extra is PaperSummary &&
                              extra.paperId.toLowerCase() ==
                                  paperId.toLowerCase()
                          ? extra
                          : null;
                      return MaterialPage<void>(
                        key: state.pageKey,
                        restorationId:
                            PakPerkRouteIdentifiers.isValidPaperId(paperId)
                            ? 'paper-$paperId'
                            : 'invalid-paper',
                        child: PaperDeepLinkScreen(
                          paperId: paperId,
                          initialPaper: initialPaper,
                        ),
                      );
                    },
                  ),
                ],
              ),
              GoRoute(
                path: '/arxiv/:arxivId',
                pageBuilder: (_, state) {
                  final arxivId = state.pathParameters['arxivId'] ?? '';
                  final normalized = ArxivIdentifier.tryParse(arxivId);
                  return MaterialPage<void>(
                    key: state.pageKey,
                    restorationId: normalized == null
                        ? 'invalid-arxiv-paper'
                        : 'arxiv-paper-${normalized.queryId.replaceAll('/', '-')}',
                    child: ArxivDeepLinkScreen(arxivId: arxivId),
                  );
                },
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: keys.you,
            restorationScopeId: 'pakperk-you-branch',
            initialLocation: PakPerkRoutes.you,
            routes: [
              GoRoute(
                path: PakPerkRoutes.you,
                pageBuilder: (context, state) => MaterialPage<void>(
                  key: state.pageKey,
                  restorationId: 'you-root-page',
                  child: GuestYouScreen(
                    onSignIn: null,
                    onOpenSettings: () =>
                        context.push(PakPerkRoutes.youSettings),
                    onOpenPrivacy: () => context.push(PakPerkRoutes.privacy),
                    onOpenTerms: () => context.push(PakPerkRoutes.terms),
                    onOpenCommunityGuidelines: () =>
                        context.push(PakPerkRoutes.communityGuidelines),
                    onOpenSupport: () => context.push(PakPerkRoutes.support),
                  ),
                ),
                routes: [
                  GoRoute(
                    path: 'library',
                    builder: (_, __) => const PhaseOnePlaceholderScreen(
                      title: 'To Read',
                      message:
                          'The synchronized To Read library is not '
                          'enabled in this build.',
                      icon: Icons.bookmarks_outlined,
                    ),
                  ),
                  GoRoute(
                    path: 'comments',
                    builder: (_, __) => const PhaseOnePlaceholderScreen(
                      title: 'My comments',
                      message:
                          'Accounts and public comments are not enabled '
                          'in this build.',
                      icon: Icons.comment_outlined,
                    ),
                  ),
                  GoRoute(
                    path: 'settings',
                    builder: (_, __) => const PublicSettingsScreen(),
                  ),
                  GoRoute(
                    path: 'account/delete',
                    builder: (_, __) => const PhaseOnePlaceholderScreen(
                      title: 'Delete account',
                      message:
                          'There is no account attached to this build, '
                          'so there is nothing to delete.',
                      icon: Icons.person_off_outlined,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => PhaseOnePlaceholderScreen(
      title: 'Link not recognized',
      message:
          'Pakperk could not safely open this link. Return to Read and '
          'choose a paper from the feed.',
      icon: Icons.link_off,
      onClose: () => context.go(PakPerkRoutes.read),
    ),
  );
  ref.onDispose(router.dispose);
  return router;
});

List<GoRoute> _legalRoutes(GlobalKey<NavigatorState> rootNavigatorKey) => [
  GoRoute(
    path: PakPerkRoutes.privacy,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => PhaseOnePlaceholderScreen(
      title: 'Privacy',
      message:
          'The complete production privacy notice will be published '
          'before account features are enabled.',
      icon: Icons.privacy_tip_outlined,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.terms,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => PhaseOnePlaceholderScreen(
      title: 'Terms',
      message:
          'Production terms will be published before account '
          'features are enabled.',
      icon: Icons.description_outlined,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.communityGuidelines,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => PhaseOnePlaceholderScreen(
      title: 'Community guidelines',
      message:
          'Public discussions are not enabled in this build. The '
          'moderation policy will be published before they are enabled.',
      icon: Icons.groups_outlined,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.support,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => PhaseOnePlaceholderScreen(
      title: 'Support',
      message:
          'A production support contact is not configured in this '
          'build. No message or personal data has been submitted.',
      icon: Icons.support_agent_outlined,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
];

MaterialPage<void> _rootPage(GoRouterState state, {required Widget child}) =>
    MaterialPage<void>(
      key: state.pageKey,
      restorationId: state.name ?? state.uri.path,
      fullscreenDialog: true,
      child: child,
    );

/// Compatibility host for widget trees that have not yet moved their outer
/// MaterialApp to `MaterialApp.router`.
class PakPerkRouter extends ConsumerWidget {
  const PakPerkRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Router.withConfig(config: ref.watch(pakPerkRouterProvider));
  }
}

class PakPerkAppShell extends ConsumerWidget {
  const PakPerkAppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoredBranch = ref.watch(activeAppBranchProvider);
    if (restoredBranch.index != navigationShell.currentIndex) {
      final controller = ref.read(appRestorationControllerProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          controller.setActiveBranch(navigationShell.currentIndex);
        }
      });
    }
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        key: const ValueKey<String>('primary-navigation'),
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) =>
            _selectDestination(context, ref, index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: 'Read',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'You',
          ),
        ],
      ),
    );
  }

  void _selectDestination(BuildContext context, WidgetRef ref, int index) {
    final currentIndex = navigationShell.currentIndex;
    final controller = ref.read(appRestorationControllerProvider.notifier);
    if (index == currentIndex) {
      if (index != AppBranch.read.index) return;
      final restoration = ref.read(appRestorationControllerProvider);
      final routerPath = GoRouter.of(
        context,
      ).routerDelegate.currentConfiguration.uri.path;
      final hasNestedReadRoute = routerPath != PakPerkRoutes.read;
      if (!hasNestedReadRoute && restoration.routeStack.isEmpty) return;
      controller.popToFeed();
      navigationShell.goBranch(index, initialLocation: true);
      return;
    }
    navigationShell.goBranch(index);
    controller.setActiveBranch(index);
  }
}

class ReadBranchNavigator extends ConsumerWidget {
  const ReadBranchNavigator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoration = ref.watch(appRestorationControllerProvider);
    final readActive = ref.watch(activeAppBranchProvider) == AppBranch.read;
    final pages = <Page<void>>[
      const MaterialPage<void>(
        key: ValueKey('feed-route'),
        name: PakPerkRoutes.read,
        restorationId: 'read-feed',
        child: FeedScreen(),
      ),
      for (final entry in restoration.routeStack)
        MaterialPage<void>(
          key: ValueKey('paper-route-${entry.routeId}'),
          name: '/read/paper/${entry.paper.paperId}',
          restorationId: 'linked-paper-${entry.routeId}',
          child: PaperRouteScreen(entry: entry),
        ),
    ];
    return NavigatorPopHandler<void>(
      enabled: readActive,
      onPopWithResult: (_) =>
          ref.read(appRestorationControllerProvider.notifier).popPaper(),
      child: Navigator(
        restorationScopeId: 'pakperk-linked-paper-navigator',
        pages: pages,
        onDidRemovePage: (page) {
          if (page is! MaterialPage<void>) return;
          final child = page.child;
          if (child is! PaperRouteScreen) return;
          ref
              .read(appRestorationControllerProvider.notifier)
              .popPaper(routeId: child.entry.routeId);
        },
      ),
    );
  }
}

class PaperDeepLinkScreen extends ConsumerStatefulWidget {
  const PaperDeepLinkScreen({
    required this.paperId,
    this.initialPaper,
    super.key,
  });

  final String paperId;
  final PaperSummary? initialPaper;

  @override
  ConsumerState<PaperDeepLinkScreen> createState() =>
      _PaperDeepLinkScreenState();
}

class ArxivDeepLinkScreen extends ConsumerStatefulWidget {
  const ArxivDeepLinkScreen({required this.arxivId, super.key});

  final String arxivId;

  @override
  ConsumerState<ArxivDeepLinkScreen> createState() =>
      _ArxivDeepLinkScreenState();
}

class _ArxivDeepLinkScreenState extends ConsumerState<ArxivDeepLinkScreen> {
  RequestCancellation? _request;
  PaperSummary? _paper;
  String? _errorMessage;
  String _routeId = const Uuid().v4();

  ArxivIdentifier? get _identifier => ArxivIdentifier.tryParse(widget.arxivId);

  @override
  void initState() {
    super.initState();
    if (_identifier != null) _load();
  }

  @override
  void didUpdateWidget(covariant ArxivDeepLinkScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.arxivId != widget.arxivId) {
      _request?.cancel('A different arXiv link was opened.');
      _routeId = const Uuid().v4();
      _paper = null;
      _errorMessage = null;
      if (_identifier != null) _load();
    }
  }

  @override
  void dispose() {
    _request?.cancel('The arXiv link was closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identifier = _identifier;
    if (identifier == null) {
      return PhaseOnePlaceholderScreen(
        title: 'Invalid arXiv link',
        message:
            'The arXiv identifier is malformed. No network request was '
            'made.',
        icon: Icons.link_off,
        onClose: _close,
      );
    }
    final paper = _paper;
    if (paper != null) {
      return PaperRouteScreen(
        entry: PaperRouteEntry(routeId: _routeId, paper: paper),
        activeOverride: ref.watch(activeAppBranchProvider) == AppBranch.read,
        onBack: _close,
        onOpenLinkedPaper: _openLinkedPaper,
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _close),
        title: const Text('Opening arXiv paper'),
      ),
      body: Center(
        child: _errorMessage == null
            ? Semantics(
                liveRegion: true,
                label: 'Resolving exact arXiv identifier',
                child: const CircularProgressIndicator(),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Future<void> _load() async {
    final identifier = _identifier;
    if (identifier == null) return;
    _request?.cancel('The arXiv link was retried.');
    final request = RequestCancellation();
    _request = request;
    if (mounted) setState(() => _errorMessage = null);
    try {
      final result = await ref
          .read(paperRepositoryProvider)
          .getPaperByArxiv(identifier.queryId, cancellation: request);
      if (!mounted || request.isCancelled) return;
      setState(() => _paper = result.value);
    } on ApiException catch (error) {
      if (!mounted || error.cancelled || request.isCancelled) return;
      setState(() {
        _errorMessage = error.isOffline
            ? 'This arXiv paper is not cached. Reconnect and try again.'
            : error.message;
      });
    } catch (_) {
      if (!mounted || request.isCancelled) return;
      setState(() => _errorMessage = 'The arXiv link could not be resolved.');
    }
  }

  void _close() => closePakPerkRootRoute(context);

  void _openLinkedPaper(PaperSummary paper) {
    context.push<void>(PakPerkRoutes.paper(paper.paperId), extra: paper);
  }
}

class _PaperDeepLinkScreenState extends ConsumerState<PaperDeepLinkScreen> {
  RequestCancellation? _request;
  PaperSummary? _paper;
  String? _errorMessage;
  String _routeId = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    _paper = _matchingInitialPaper;
    if (PakPerkRouteIdentifiers.isValidPaperId(widget.paperId) &&
        _paper == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant PaperDeepLinkScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paperId != widget.paperId) {
      _request?.cancel('A different paper link was opened.');
      _routeId = const Uuid().v4();
      _paper = _matchingInitialPaper;
      _errorMessage = null;
      if (PakPerkRouteIdentifiers.isValidPaperId(widget.paperId) &&
          _paper == null) {
        _load();
      }
    }
  }

  @override
  void dispose() {
    _request?.cancel('The paper link was closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PakPerkRouteIdentifiers.isValidPaperId(widget.paperId)) {
      return PhaseOnePlaceholderScreen(
        title: 'Invalid paper link',
        message:
            'The paper identifier is malformed. No network request was '
            'made.',
        icon: Icons.link_off,
        onClose: _close,
      );
    }
    final paper = _paper;
    if (paper != null) {
      return PaperRouteScreen(
        entry: PaperRouteEntry(routeId: _routeId, paper: paper),
        activeOverride: ref.watch(activeAppBranchProvider) == AppBranch.read,
        onBack: _close,
        onOpenLinkedPaper: _openLinkedPaper,
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: _close),
        title: const Text('Opening paper'),
      ),
      body: Center(
        child: _errorMessage == null
            ? Semantics(
                liveRegion: true,
                label: 'Loading linked paper',
                child: const CircularProgressIndicator(),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Future<void> _load() async {
    _request?.cancel('The paper link was retried.');
    final request = RequestCancellation();
    _request = request;
    if (mounted) setState(() => _errorMessage = null);
    try {
      final result = await ref
          .read(paperRepositoryProvider)
          .getPaper(widget.paperId, cancellation: request);
      if (!mounted || request.isCancelled) return;
      setState(() => _paper = result.value);
    } on ApiException catch (error) {
      if (!mounted || error.cancelled || request.isCancelled) return;
      setState(() {
        _errorMessage = error.isOffline
            ? 'This paper is not cached. Reconnect and try the link again.'
            : error.message;
      });
    } catch (_) {
      if (!mounted || request.isCancelled) return;
      setState(() => _errorMessage = 'The paper could not be opened safely.');
    }
  }

  void _close() => closePakPerkRootRoute(context);

  PaperSummary? get _matchingInitialPaper {
    final paper = widget.initialPaper;
    return paper != null &&
            paper.paperId.toLowerCase() == widget.paperId.toLowerCase()
        ? paper
        : null;
  }

  void _openLinkedPaper(PaperSummary paper) {
    context.push<void>(PakPerkRoutes.paper(paper.paperId), extra: paper);
  }
}

class PaperChatRouteScreen extends ConsumerWidget {
  const PaperChatRouteScreen({
    required this.data,
    required this.onClose,
    this.protectTopInset = true,
    super.key,
  });

  final PaperChatRouteData? data;
  final VoidCallback onClose;
  final bool protectTopInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeData = data;
    if (routeData == null) {
      return PhaseOnePlaceholderScreen(
        title: 'Paper chat link unavailable',
        message:
            'Paper chat needs an active, validated reader session. Open '
            'the paper first and use its Ask control.',
        icon: Icons.chat_bubble_outline,
        closeTooltip: 'Close paper chat',
        onClose: onClose,
      );
    }
    final args = ChatControllerArgs(
      paperId: routeData.paperId,
      readerKey: routeData.readerKey,
    );
    final chat = ref.watch(chatControllerProvider(args));
    final networkOffline = ref
        .watch(networkOfflineProvider)
        .maybeWhen(data: (value) => value, orElse: () => chat.offline);
    final sheet = PaperChatSheet(
      state: ChatStateView(
        messages: chat.messages,
        restoring: chat.restoring,
        sending: chat.sending,
        errorMessage: chat.errorMessage,
      ),
      enabled: routeData.chatEnabled && !networkOffline,
      onClose: onClose,
      onSend: ref.read(chatControllerProvider(args).notifier).send,
    );
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: protectTopInset ? SafeArea(bottom: false, child: sheet) : sheet,
    );
  }
}

/// Resolves metadata for externally opened comments links before presenting
/// the Phase 1 disabled state. This keeps the public route truthful and gives
/// Phase 5 a stable, paper-scoped replacement point without exposing a fake
/// composer in the meantime.
class PaperCommentsRouteScreen extends ConsumerStatefulWidget {
  const PaperCommentsRouteScreen({
    required this.paperId,
    required this.onClose,
    this.initialData,
    super.key,
  });

  final String paperId;
  final PaperCommentsRouteData? initialData;
  final VoidCallback onClose;

  @override
  ConsumerState<PaperCommentsRouteScreen> createState() =>
      _PaperCommentsRouteScreenState();
}

class _PaperCommentsRouteScreenState
    extends ConsumerState<PaperCommentsRouteScreen> {
  RequestCancellation? _request;
  PaperCommentsRouteData? _data;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _data = _matchingInitialData;
    if (_data == null && _hasValidPaperId) _load();
  }

  @override
  void didUpdateWidget(covariant PaperCommentsRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paperId == widget.paperId &&
        oldWidget.initialData == widget.initialData) {
      return;
    }
    _request?.cancel('A different comments link was opened.');
    _data = _matchingInitialData;
    _errorMessage = null;
    if (_data == null && _hasValidPaperId) _load();
  }

  @override
  void dispose() {
    _request?.cancel('The comments link was closed.');
    super.dispose();
  }

  bool get _hasValidPaperId =>
      PakPerkRouteIdentifiers.isValidPaperId(widget.paperId);

  PaperCommentsRouteData? get _matchingInitialData {
    final data = widget.initialData;
    return data != null && data.matchesPathPaper(widget.paperId) ? data : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasValidPaperId) {
      return PhaseOnePlaceholderScreen(
        title: 'Invalid comments link',
        message:
            'The paper identifier is malformed. No paper or comment '
            'request was made.',
        icon: Icons.link_off,
        closeTooltip: 'Close paper discussions',
        onClose: widget.onClose,
      );
    }
    final data = _data;
    if (data != null) {
      return PhaseOnePlaceholderScreen(
        title: 'Paper discussions',
        message:
            'Comments for “${data.paperTitle}” are not enabled in this '
            'build. Nothing posted here will be presented as functional '
            'until the comments service is available.',
        icon: Icons.forum_outlined,
        closeTooltip: 'Close paper discussions',
        onClose: widget.onClose,
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close paper discussions',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close),
        ),
        title: const Text('Paper discussions'),
      ),
      body: Center(
        child: _errorMessage == null
            ? Semantics(
                liveRegion: true,
                label: 'Loading paper details for discussions',
                child: const CircularProgressIndicator(),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Future<void> _load() async {
    _request?.cancel('The comments link was retried.');
    final request = RequestCancellation();
    _request = request;
    if (mounted) setState(() => _errorMessage = null);
    try {
      final result = await ref
          .read(paperRepositoryProvider)
          .getPaper(widget.paperId, cancellation: request);
      if (!mounted || request.isCancelled) return;
      if (result.value.paperId.toLowerCase() != widget.paperId.toLowerCase()) {
        throw const ApiException(
          code: 'INVALID_PAPER_RESPONSE',
          message: 'The service returned a different paper for this link.',
          retryable: true,
          statusCode: 502,
        );
      }
      setState(() {
        _data = PaperCommentsRouteData(
          paperId: result.value.paperId,
          paperTitle: result.value.title,
        );
      });
    } on ApiException catch (error) {
      if (!mounted || error.cancelled || request.isCancelled) return;
      setState(() {
        _errorMessage = error.isOffline
            ? 'This paper is not cached. Reconnect to open its discussions.'
            : error.message;
      });
    } catch (_) {
      if (!mounted || request.isCancelled) return;
      setState(() {
        _errorMessage = 'The paper discussions link could not be resolved.';
      });
    }
  }
}

class PaperRouteScreen extends ConsumerStatefulWidget {
  const PaperRouteScreen({
    required this.entry,
    this.activeOverride,
    this.onBack,
    this.onOpenLinkedPaper,
    super.key,
  });

  final PaperRouteEntry entry;
  final bool? activeOverride;
  final VoidCallback? onBack;
  final ValueChanged<PaperSummary>? onOpenLinkedPaper;

  @override
  ConsumerState<PaperRouteScreen> createState() => _PaperRouteScreenState();
}

class _PaperRouteScreenState extends ConsumerState<PaperRouteScreen> {
  @override
  void initState() {
    super.initState();
    _scheduleMetadataLoad(widget.entry.paper);
  }

  void _scheduleMetadataLoad(PaperSummary snapshot) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.entry.paper.versionKey != snapshot.versionKey) {
        return;
      }
      ref
          .read(paperMetadataControllerProvider(snapshot.versionKey).notifier)
          .ensureLoaded(snapshot);
    });
  }

  @override
  void didUpdateWidget(covariant PaperRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.paper.versionKey != widget.entry.paper.versionKey) {
      _scheduleMetadataLoad(widget.entry.paper);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metadata = ref.watch(
      paperMetadataControllerProvider(widget.entry.paper.versionKey),
    );
    final paper = metadata.paper ?? widget.entry.paper;
    final readerKey = routeReaderKey(widget.entry.routeId, paper);
    final routeStack = ref.watch(appRestorationControllerProvider).routeStack;
    final readSelected = ref.watch(activeAppBranchProvider) == AppBranch.read;
    final active =
        widget.activeOverride ??
        (readSelected &&
            routeStack.isNotEmpty &&
            routeStack.last.routeId == widget.entry.routeId);

    ref.listen<PaperMetadataState>(
      paperMetadataControllerProvider(widget.entry.paper.versionKey),
      (previous, next) {
        final loaded = next.paper;
        if (loaded != null && previous?.paper != loaded) {
          ref
              .read(appRestorationControllerProvider.notifier)
              .updateRoutePaper(widget.entry.routeId, loaded);
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to previous paper',
          onPressed:
              widget.onBack ??
              () => ref
                  .read(appRestorationControllerProvider.notifier)
                  .popPaper(routeId: widget.entry.routeId),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(paper.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (metadata.refreshing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: ResponsiveReaderFrame(
        key: ValueKey('responsive-reader-$readerKey'),
        child: PaperReader(
          key: ValueKey(readerKey),
          paper: paper,
          readerKey: readerKey,
          isActive: active,
          onOpenLinkedPaper: widget.onOpenLinkedPaper,
        ),
      ),
    );
  }
}
