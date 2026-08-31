import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../core/api/api_exception.dart';
import '../core/api/request_cancellation.dart';
import '../core/models/arxiv_identifier.dart';
import '../core/models/assistant_v2.dart';
import '../core/models/paper.dart';
import '../core/models/reader_state.dart';
import '../core/providers.dart';
import '../core/telemetry/telemetry.dart';
import '../core/widgets/responsive_reader_frame.dart';
import '../design_system/motion.dart';
import '../features/account/account_home_screen.dart';
import '../features/account/account_deletion_screen.dart';
import '../features/account/auth_flow_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_sheet.dart';
import '../features/chat/assistant_v2_sheet.dart';
import '../features/comments/blocked_users_screen.dart';
import '../features/comments/comments_screen.dart';
import '../features/comments/my_comments_screen.dart';
import '../features/engagement/engagement_destination.dart';
import '../features/feed/feed_screen.dart';
import '../features/library/library_destination.dart';
import '../features/library/library_history_controller.dart';
import '../features/legal/legal_document_screen.dart';
import '../features/memory/memory_review_destination.dart';
import '../features/paper_reader/paper_metadata_controller.dart';
import '../features/paper_reader/paper_reader.dart';
import '../features/paper_reader/paper_processing_controller.dart';
import '../features/document_reader/reader_entry_context.dart';
import '../features/paper_reader/reader_navigation_controller.dart';
import '../features/placeholders/phase_one_placeholder_screens.dart';
import '../features/settings/public_settings_screen.dart';
import '../features/search/research_search_destination.dart';
import '../features/research_profiles/research_profile_destination.dart';
import 'library_providers.dart';

abstract final class PakPerkRoutes {
  static const read = '/read';
  static const readBrief = '/read/brief';
  static const search = '/read/search';
  static const library = '/library';
  static const you = '/you';

  /// Compatibility entry point for v0.0 saved links.
  static const youLibrary = '/you/library';
  static const youComments = '/you/comments';
  static const youBlockedUsers = '/you/blocked';
  static const youSettings = '/you/settings';
  static const youResearchProfile = '/you/research-profile';
  static const youReadingUpdates = '/you/reading-updates';
  static const youMemory = '/you/memory';
  static const youAccountDelete = '/you/account/delete';
  static const auth = '/auth';
  static const privacy = '/legal/privacy';
  static const terms = '/legal/terms';
  static const communityGuidelines = '/legal/community';
  static const support = '/support';
  static const accountDeletionPolicy = '/legal/account-deletion';
  static const openSourceLicenses = '/legal/open-source-licenses';

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

  static String arxivConnections(String arxivId) =>
      '${arxiv(arxivId)}?view=connections';

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
  static String? normalizeIncomingLink(Uri uri, {Uri? appLinkOrigin}) {
    if (!uri.hasScheme) {
      return uri.hasAuthority ? read : null;
    }
    final custom = normalizeCustomScheme(uri);
    if (custom != null) return custom;
    final allowedOrigin = appLinkOrigin ?? Uri.parse('https://pakperk.app');
    if (uri.scheme.toLowerCase() != allowedOrigin.scheme.toLowerCase() ||
        uri.host.toLowerCase() != allowedOrigin.host.toLowerCase() ||
        _effectivePort(uri) != _effectivePort(allowedOrigin) ||
        uri.userInfo.isNotEmpty ||
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

  static int _effectivePort(Uri uri) => uri.hasPort
      ? uri.port
      : switch (uri.scheme.toLowerCase()) {
          'https' => 443,
          'http' => 80,
          _ => -1,
        };
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
    this.paperVersionKey,
    this.generation,
    this.assistantScope = const AssistantRequestScope.paper(),
    this.initialQuestion,
    this.submitInitialQuestion = false,
  });

  final String paperId;
  final String readerKey;
  final String paperTitle;
  final bool chatEnabled;
  final PaperVersionKey? paperVersionKey;
  final int? generation;
  final AssistantRequestScope assistantScope;
  final String? initialQuestion;
  final bool submitInitialQuestion;

  String? get normalizedInitialQuestion {
    final normalized = initialQuestion?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.runes.length > 500 ||
        normalized.contains('\u0000')) {
      return null;
    }
    return normalized;
  }

  bool matchesPathPaper(String pathPaperId) =>
      PakPerkRouteIdentifiers.isValidPaperId(paperId) &&
      paperId.toLowerCase() == pathPaperId.toLowerCase() &&
      readerKey.trim().isNotEmpty &&
      readerKey.length <= 256 &&
      paperTitle.length <= 1000 &&
      (paperVersionKey == null || paperVersionKey!.paperId == paperId) &&
      (initialQuestion == null || normalizedInitialQuestion != null) &&
      (!submitInitialQuestion || normalizedInitialQuestion != null);
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

/// Private navigation provenance for opening the global memory review from a
/// reader. It intentionally carries no memory body, account id, or Library
/// state. The origin key lets a normal back action return to the exact reader
/// stage and position retained beneath the review route.
final class MemoryReviewRouteData {
  const MemoryReviewRouteData({this.originReaderKey});

  final String? originReaderKey;

  String? get safeOriginReaderKey {
    final value = originReaderKey?.trim();
    return value == null || value.isEmpty || value.length > 256 ? null : value;
  }
}

bool shouldRecordLibraryHistoryForReaderEntry(ReaderEntryContext entry) =>
    entry.source != ReaderEntrySource.memory;

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
      child: PaperCommentsRouteScreen(
        paperId: data.paperId,
        initialData: data,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

/// Imperative push is intentional: it retains the Library branch match below
/// the Read destination so a normal platform back action returns to the exact
/// saved-list route. [PakPerkAppShell] derives the visible branch from the
/// current route because go_router keeps an imperative cross-branch match on
/// the originating branch's navigator stack.
void openSavedPaperFromLibrary(BuildContext context, PaperSummary paper) {
  unawaited(
    context.push<void>(
      PakPerkRoutes.paper(paper.paperId),
      extra: PaperRouteLaunch(
        paper: paper,
        entryContext: const ReaderEntryContext.library(),
      ),
    ),
  );
}

final class PaperRouteLaunch extends PaperSummary {
  PaperRouteLaunch({required PaperSummary paper, required this.entryContext})
    : super(
        paperId: paper.paperId,
        arxivId: paper.arxivId,
        title: paper.title,
        abstractText: paper.abstractText,
        authors: paper.authors,
        primaryCategory: paper.primaryCategory,
        categories: paper.categories,
        publishedAt: paper.publishedAt,
        updatedAt: paper.updatedAt,
        absUrl: paper.absUrl,
        pdfUrl: paper.pdfUrl,
        capabilities: paper.capabilities,
      );

  /// Keeps route construction typed while remaining compatible with embedders
  /// that historically treated `state.extra` as a [PaperSummary].
  PaperSummary get paper => this;
  final ReaderEntryContext entryContext;
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
      library = GlobalKey<NavigatorState>(debugLabel: 'pakperk-library'),
      you = GlobalKey<NavigatorState>(debugLabel: 'pakperk-you');

  final GlobalKey<NavigatorState> root;
  final GlobalKey<NavigatorState> read;
  final GlobalKey<NavigatorState> library;
  final GlobalKey<NavigatorState> you;
}

final pakPerkNavigatorKeysProvider = Provider<PakPerkNavigatorKeys>(
  (ref) => PakPerkNavigatorKeys(),
);

final pakPerkRouterProvider = Provider<GoRouter>((ref) {
  final keys = ref.watch(pakPerkNavigatorKeysProvider);
  final appLinkOrigin = ref.watch(appBuildConfigProvider).appLinkOriginUri;
  final restoredBranch = ref.read(activeAppBranchProvider);
  final router = GoRouter(
    navigatorKey: keys.root,
    restorationScopeId: 'pakperk-router',
    initialLocation: switch (restoredBranch) {
      AppBranch.read => PakPerkRoutes.read,
      AppBranch.library => PakPerkRoutes.library,
      AppBranch.you => PakPerkRoutes.you,
    },
    redirect: (_, state) => PakPerkRoutes.normalizeIncomingLink(
      state.uri,
      appLinkOrigin: appLinkOrigin,
    ),
    routes: [
      GoRoute(path: '/', redirect: (_, __) => PakPerkRoutes.read),
      GoRoute(
        path: PakPerkRoutes.auth,
        parentNavigatorKey: keys.root,
        pageBuilder: (context, state) =>
            _rootPage(state, child: const AccountAuthRouteScreen()),
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
                    path: 'brief',
                    pageBuilder: (context, state) => MaterialPage<void>(
                      key: state.pageKey,
                      restorationId: 'reading-brief',
                      child: EngagementDestination.briefOnly(
                        onOpenPaper: (paper) =>
                            openSavedPaperFromLibrary(context, paper),
                      ),
                    ),
                  ),
                  GoRoute(
                    path: 'search',
                    pageBuilder: (context, state) => MaterialPage<void>(
                      key: state.pageKey,
                      restorationId: 'research-search',
                      child: ResearchSearchDestination(
                        onOpenPaper: (arxivId) => context.push(
                          PakPerkRoutes.arxiv(arxivId),
                          extra: const ReaderEntryContext.search(),
                        ),
                        onMapPaper: (arxivId) => context.push(
                          PakPerkRoutes.arxivConnections(arxivId),
                        ),
                      ),
                    ),
                  ),
                  GoRoute(
                    path: 'paper/:paperId',
                    pageBuilder: (context, state) {
                      final paperId = state.pathParameters['paperId'] ?? '';
                      final extra = state.extra;
                      final launch = switch (extra) {
                        final PaperRouteLaunch value => value,
                        final PaperSummary value => PaperRouteLaunch(
                          paper: value,
                          entryContext: const ReaderEntryContext.external(),
                        ),
                        _ => null,
                      };
                      final initialPaper =
                          launch != null &&
                              launch.paper.paperId.toLowerCase() ==
                                  paperId.toLowerCase()
                          ? launch.paper
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
                          entryContext:
                              launch?.entryContext ??
                              const ReaderEntryContext.external(),
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
                  final views = state.uri.queryParametersAll['view'];
                  final initialStage =
                      state.uri.queryParametersAll.length == 1 &&
                          views?.length == 1 &&
                          views!.single == 'connections'
                      ? PaperStage.connections
                      : PaperStage.abstractView;
                  return MaterialPage<void>(
                    key: state.pageKey,
                    restorationId: normalized == null
                        ? 'invalid-arxiv-paper'
                        : 'arxiv-paper-${normalized.queryId.replaceAll('/', '-')}',
                    child: ArxivDeepLinkScreen(
                      arxivId: arxivId,
                      initialStage: initialStage,
                      entryContext: state.extra is ReaderEntryContext
                          ? state.extra! as ReaderEntryContext
                          : const ReaderEntryContext.external(),
                    ),
                  );
                },
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: keys.library,
            restorationScopeId: 'pakperk-library-branch',
            initialLocation: PakPerkRoutes.library,
            routes: [
              GoRoute(
                path: PakPerkRoutes.library,
                pageBuilder: (context, state) => MaterialPage<void>(
                  key: state.pageKey,
                  restorationId: 'library-root-page',
                  child: LibraryDestination(
                    onOpenPaper: (paper) =>
                        openSavedPaperFromLibrary(context, paper),
                  ),
                ),
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
                  child: AccountYouScreen(
                    onSignIn: () => context.push(PakPerkRoutes.auth),
                    onCompleteProfile: () => context.push(PakPerkRoutes.auth),
                    onOpenLibrary: () => context.go(PakPerkRoutes.library),
                    onOpenComments: () =>
                        context.push(PakPerkRoutes.youComments),
                    onOpenBlockedUsers: () =>
                        context.push(PakPerkRoutes.youBlockedUsers),
                    onOpenMemory: ref.watch(featureFlagsProvider).researchMemory
                        ? () => context.push(PakPerkRoutes.youMemory)
                        : null,
                    onOpenSettings: () =>
                        context.push(PakPerkRoutes.youSettings),
                    onOpenPrivacy: () => context.push(PakPerkRoutes.privacy),
                    onOpenTerms: () => context.push(PakPerkRoutes.terms),
                    onOpenCommunityGuidelines: () =>
                        context.push(PakPerkRoutes.communityGuidelines),
                    onOpenSupport: () => context.push(PakPerkRoutes.support),
                    onOpenDeleteAccount: () =>
                        context.push(PakPerkRoutes.youAccountDelete),
                  ),
                ),
                routes: [
                  GoRoute(
                    path: 'library',
                    redirect: (_, __) => PakPerkRoutes.library,
                  ),
                  GoRoute(
                    path: 'comments',
                    builder: (_, __) => const _CommentsFeatureRoute(
                      title: 'My comments',
                      child: MyCommentsScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'blocked',
                    builder: (_, __) => const _CommentsFeatureRoute(
                      title: 'Blocked users',
                      child: BlockedUsersScreen(),
                    ),
                  ),
                  GoRoute(
                    path: 'settings',
                    builder: (context, _) => PublicSettingsScreen(
                      onOpenDeleteAccount: () =>
                          context.push(PakPerkRoutes.youAccountDelete),
                      onOpenResearchProfile: () =>
                          context.push(PakPerkRoutes.youResearchProfile),
                      onOpenReadingUpdates: () =>
                          context.push(PakPerkRoutes.youReadingUpdates),
                    ),
                  ),
                  GoRoute(
                    path: 'research-profile',
                    builder: (_, __) => const ResearchProfileDestination(),
                  ),
                  GoRoute(
                    path: 'reading-updates',
                    builder: (context, __) => EngagementDestination(
                      onOpenPaper: (paper) =>
                          openSavedPaperFromLibrary(context, paper),
                    ),
                  ),
                  GoRoute(
                    path: 'memory',
                    pageBuilder: (context, state) {
                      final data = state.extra is MemoryReviewRouteData
                          ? state.extra! as MemoryReviewRouteData
                          : const MemoryReviewRouteData();
                      return MaterialPage<void>(
                        key: state.pageKey,
                        restorationId: 'global-memory-review',
                        child: MemoryReviewDestination(
                          onOpenSource: (paper, _) {
                            context.push<void>(
                              PakPerkRoutes.paper(paper.paperId),
                              extra: PaperRouteLaunch(
                                paper: paper,
                                entryContext: ReaderEntryContext.memory(
                                  originReaderKey: data.safeOriginReaderKey,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  GoRoute(
                    path: 'account/delete',
                    builder: (_, __) => const AccountDeletionScreen(),
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
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.privacy,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.terms,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.terms,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.communityGuidelines,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.communityGuidelines,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.support,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.support,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.accountDeletionPolicy,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.accountDeletion,
      onClose: () => closePakPerkRootRoute(context),
    ),
  ),
  GoRoute(
    path: PakPerkRoutes.openSourceLicenses,
    parentNavigatorKey: rootNavigatorKey,
    builder: (context, _) => LegalDocumentScreen(
      kind: LegalDocumentKind.openSourceLicenses,
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

  static const navigationRailBreakpoint = 600.0;

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoredBranch = ref.watch(activeAppBranchProvider);
    // The child Builder establishes a dependency on go_router's route-state
    // registry. RouterDelegate itself does not notify for an imperative match
    // pushed across StatefulShellRoute branches.
    return Builder(
      builder: (context) {
        final routerPath = GoRouterState.of(context).uri.path;
        final visibleBranchIndex = pakPerkVisibleBranchIndex(
          routerPath: routerPath,
          shellBranchIndex: navigationShell.currentIndex,
        );
        if (restoredBranch.shellIndex != visibleBranchIndex) {
          final controller = ref.read(
            appRestorationControllerProvider.notifier,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              controller.setActiveBranch(
                AppBranch.fromShellIndex(visibleBranchIndex).index,
              );
            }
          });
        }
        void selectDestination(int index) => _selectDestination(
          context,
          ref,
          index,
          visibleBranchIndex: visibleBranchIndex,
        );
        final usesNavigationRail =
            MediaQuery.sizeOf(context).width >= navigationRailBreakpoint;
        if (usesNavigationRail) {
          final textDirection = Directionality.of(context);
          return Scaffold(
            body: Row(
              // Paint the nested Navigator before the rail so an active
              // route's BlockSemantics never hides primary navigation. The
              // reversed flex direction keeps the rail on the leading edge.
              textDirection: textDirection == TextDirection.ltr
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              children: [
                Expanded(child: navigationShell),
                const VerticalDivider(width: 1, thickness: 1),
                SafeArea(
                  left: textDirection == TextDirection.ltr,
                  right: textDirection == TextDirection.rtl,
                  child: NavigationRail(
                    key: const ValueKey<String>('primary-navigation'),
                    selectedIndex: visibleBranchIndex,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -1,
                    onDestinationSelected: selectDestination,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.auto_stories_outlined),
                        selectedIcon: Icon(Icons.auto_stories),
                        label: Text('Read'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.local_library_outlined),
                        selectedIcon: Icon(Icons.local_library),
                        label: Text('Library'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.person_outline),
                        selectedIcon: Icon(Icons.person),
                        label: Text('You'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: navigationShell,
          bottomNavigationBar: _PrimaryNavigationBar(
            selectedIndex: visibleBranchIndex,
            onDestinationSelected: selectDestination,
          ),
        );
      },
    );
  }

  void _selectDestination(
    BuildContext context,
    WidgetRef ref,
    int index, {
    required int visibleBranchIndex,
  }) {
    final branch = AppBranch.fromShellIndex(index);
    emitTelemetry(
      ref.read(telemetrySinkProvider),
      PakPerkTelemetryEvent.shellDestinationSelected,
      {'destination': branch.name, 'reselected': index == visibleBranchIndex},
    );
    final controller = ref.read(appRestorationControllerProvider.notifier);
    if (index == navigationShell.currentIndex &&
        index != visibleBranchIndex &&
        context.canPop()) {
      // A saved-paper route is an imperative Read match above the retained
      // Library/You branch. goBranch would be a no-op because the shell still
      // owns that underlying branch, so close the match explicitly.
      context.pop();
      controller.setActiveBranch(branch.index);
      return;
    }
    if (index == visibleBranchIndex) {
      if (branch != AppBranch.read) {
        // Match the familiar tab-bar convention: selecting the active tab a
        // second time returns to that tab's root without disturbing the
        // retained state of the other branch.
        navigationShell.goBranch(index, initialLocation: true);
        return;
      }
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
    controller.setActiveBranch(branch.index);
  }
}

/// A quiet, platform-like material layer around the primary destinations.
///
/// The NavigationBar stays in the tree so Flutter retains its tab semantics,
/// keyboard behavior, and generous hit targets. The surrounding blur and
/// translucent fill communicate that navigation floats above the current
/// task. High-contrast users receive an opaque surface and defined edge.
class _PrimaryNavigationBar extends StatelessWidget {
  const _PrimaryNavigationBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final highContrast = media.highContrast;
    final opaqueMaterials =
        highContrast || platformPrefersReducedTransparency(context);
    final surface = theme.colorScheme.surface.withValues(
      alpha: opaqueMaterials ? 1 : .88,
    );
    Widget bar = ColoredBox(
      color: surface,
      child: NavigationBar(
        key: const ValueKey<String>('primary-navigation'),
        selectedIndex: selectedIndex,
        backgroundColor: Colors.transparent,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: 'Read',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_library_outlined),
            selectedIcon: Icon(Icons.local_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'You',
          ),
        ],
      ),
    );
    if (!opaqueMaterials) {
      bar = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: bar,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: opaqueMaterials
            ? Border(top: BorderSide(color: theme.colorScheme.outline))
            : null,
        boxShadow: opaqueMaterials
            ? const []
            : [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(
                    alpha: theme.brightness == Brightness.dark ? .28 : .1,
                  ),
                  blurRadius: 18,
                  offset: const Offset(0, -6),
                ),
              ],
      ),
      child: ClipRect(child: bar),
    );
  }
}

@visibleForTesting
int pakPerkVisibleBranchIndex({
  required String routerPath,
  required int shellBranchIndex,
}) {
  if (routerPath == PakPerkRoutes.read ||
      routerPath.startsWith('${PakPerkRoutes.read}/') ||
      routerPath.startsWith('/arxiv/')) {
    return AppBranch.read.shellIndex;
  }
  if (routerPath == PakPerkRoutes.library ||
      routerPath.startsWith('${PakPerkRoutes.library}/')) {
    return AppBranch.library.shellIndex;
  }
  if (routerPath == PakPerkRoutes.you ||
      routerPath.startsWith('${PakPerkRoutes.you}/')) {
    return AppBranch.you.shellIndex;
  }
  return shellBranchIndex;
}

class ReadBranchNavigator extends ConsumerWidget {
  const ReadBranchNavigator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restoration = ref.watch(appRestorationControllerProvider);
    final readActive = ref.watch(activeAppBranchProvider) == AppBranch.read;
    final searchEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.searchLookupEnabled),
    );
    final readingBriefsEnabled = ref.watch(
      featureFlagsProvider.select((flags) => flags.readingBriefsEnabled),
    );
    final pages = <Page<void>>[
      MaterialPage<void>(
        key: ValueKey('feed-route'),
        name: PakPerkRoutes.read,
        restorationId: 'read-feed',
        child: FeedScreen(
          onOpenBrief: readingBriefsEnabled
              ? () => context.push(PakPerkRoutes.readBrief)
              : null,
          onOpenSearch: searchEnabled
              ? () => context.push(PakPerkRoutes.search)
              : null,
        ),
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
    required this.entryContext,
    this.initialPaper,
    super.key,
  });

  final String paperId;
  final PaperSummary? initialPaper;
  final ReaderEntryContext entryContext;

  @override
  ConsumerState<PaperDeepLinkScreen> createState() =>
      _PaperDeepLinkScreenState();
}

class ArxivDeepLinkScreen extends ConsumerStatefulWidget {
  const ArxivDeepLinkScreen({
    required this.arxivId,
    required this.entryContext,
    this.initialStage = PaperStage.abstractView,
    super.key,
  });

  final String arxivId;
  final PaperStage initialStage;
  final ReaderEntryContext entryContext;

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
    } else if (oldWidget.initialStage != widget.initialStage &&
        _paper != null) {
      _initializeReaderStage(_paper!);
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
        entry: PaperRouteEntry(
          routeId: _routeId,
          paper: paper,
          entryContext: widget.entryContext,
        ),
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
      _initializeReaderStage(result.value);
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

  void _initializeReaderStage(PaperSummary paper) {
    ref
        .read(appRestorationControllerProvider.notifier)
        .updateReader(
          routeReaderKey(_routeId, paper),
          (current) => current.copyWith(stageIndex: widget.initialStage.index),
        );
  }

  void _openLinkedPaper(PaperSummary paper) {
    context.push<void>(
      PakPerkRoutes.paper(paper.paperId),
      extra: PaperRouteLaunch(
        paper: paper,
        entryContext: ReaderEntryContext.connection(
          originReaderKey: routeReaderKey(_routeId, _paper ?? paper),
        ),
      ),
    );
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
        entry: PaperRouteEntry(
          routeId: _routeId,
          paper: paper,
          entryContext: widget.entryContext,
        ),
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
    context.push<void>(
      PakPerkRoutes.paper(paper.paperId),
      extra: PaperRouteLaunch(
        paper: paper,
        entryContext: ReaderEntryContext.connection(
          originReaderKey: routeReaderKey(_routeId, _paper ?? paper),
        ),
      ),
    );
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
    final config = ref.watch(appBuildConfigProvider);
    if (config.features.assistantV2) {
      final generation = routeData.generation;
      final paperVersionKey = routeData.paperVersionKey;
      if (generation == null || generation <= 0 || paperVersionKey == null) {
        return PhaseOnePlaceholderScreen(
          title: 'Assistant unavailable',
          message:
              'This reader session does not have a current document generation.',
          icon: Icons.chat_bubble_outline,
          closeTooltip: 'Close assistant',
          onClose: onClose,
        );
      }
      final offline = ref
          .watch(networkOfflineProvider)
          .maybeWhen(data: (value) => value, orElse: () => true);
      final currentGeneration = ref
          .watch(paperProcessingControllerProvider(paperVersionKey))
          .processing
          ?.generation;
      final generationIsCurrent = currentGeneration == generation;
      final sheet = AssistantV2Sheet(
        paperId: routeData.paperId,
        readerKey: routeData.readerKey,
        paperTitle: routeData.paperTitle,
        generation: generation,
        scope: routeData.assistantScope,
        initialQuestion: routeData.normalizedInitialQuestion,
        submitInitialQuestion: routeData.submitInitialQuestion,
        enabled: routeData.chatEnabled && !offline && generationIsCurrent,
        generationIsCurrent: generationIsCurrent,
        onClose: onClose,
      );
      return Scaffold(
        resizeToAvoidBottomInset: true,
        body: protectTopInset ? SafeArea(bottom: false, child: sheet) : sheet,
      );
    }
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
/// the real, paper-scoped discussion surface.
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
    if (_data == null && _hasValidPaperId && _commentsEnabled) _load();
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
    if (_data == null && _hasValidPaperId && _commentsEnabled) _load();
  }

  @override
  void dispose() {
    _request?.cancel('The comments link was closed.');
    super.dispose();
  }

  bool get _hasValidPaperId =>
      PakPerkRouteIdentifiers.isValidPaperId(widget.paperId);

  bool get _commentsEnabled => ref.read(featureFlagsProvider).comments;

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
    if (!ref.watch(featureFlagsProvider).comments) {
      return PhaseOnePlaceholderScreen(
        title: 'Paper discussions',
        message: 'Comments are not enabled in this build.',
        icon: Icons.forum_outlined,
        closeTooltip: 'Close paper discussions',
        onClose: widget.onClose,
      );
    }
    final data = _data;
    if (data != null) {
      return CommentsScreen(
        paperId: data.paperId,
        paperTitle: data.paperTitle,
        onClose: widget.onClose,
      );
    }
    if (_request == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _request == null) _load();
      });
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

final class _CommentsFeatureRoute extends ConsumerWidget {
  const _CommentsFeatureRoute({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(featureFlagsProvider).comments) return child;
    return PhaseOnePlaceholderScreen(
      title: title,
      message: 'Comments are not enabled in this build.',
      icon: Icons.forum_outlined,
    );
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
  String? _recordedHistoryPaperId;

  @override
  void initState() {
    super.initState();
    _scheduleMetadataLoad(widget.entry.paper);
    _scheduleHistoryRecord(widget.entry.paper);
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

  void _scheduleHistoryRecord(PaperSummary paper) {
    // Memory review is an explicit private resurfacing branch. Merely opening
    // its source must not write Library history or influence automatic-feed
    // recency; an explicit Add to To Read action remains available separately.
    if (!shouldRecordLibraryHistoryForReaderEntry(widget.entry.entryContext)) {
      return;
    }
    if (_recordedHistoryPaperId == paper.paperId) return;
    _recordedHistoryPaperId = paper.paperId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(featureFlagsProvider).libraryV2Enabled) return;
      final scope = ref.read(libraryDisplayScopeProvider);
      if (scope == null) return;
      unawaited(
        ref
            .read(libraryHistoryControllerProvider(scope).notifier)
            .record(paper),
      );
    });
  }

  @override
  void didUpdateWidget(covariant PaperRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.paper.versionKey != widget.entry.paper.versionKey) {
      _scheduleMetadataLoad(widget.entry.paper);
    }
    if (oldWidget.entry.paper.paperId != widget.entry.paper.paperId) {
      _scheduleHistoryRecord(widget.entry.paper);
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
          entryContext: widget.entry.entryContext,
          onOpenLinkedPaper: widget.onOpenLinkedPaper,
        ),
      ),
    );
  }
}
