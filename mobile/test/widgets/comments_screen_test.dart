import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/comments_providers.dart';
import 'package:pakperk/app/router.dart';
import 'package:pakperk/core/account/account_data_write_barrier.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/comments/comment_controllers.dart';
import 'package:pakperk/core/comments/comment_models.dart';
import 'package:pakperk/core/comments/comment_repository.dart';
import 'package:pakperk/core/comments/comments_api.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/comment_cache_dao.dart';
import 'package:pakperk/core/database/comments_dao.dart';
import 'package:pakperk/core/database/paper_cache_dao.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/comments/comments_screen.dart';

import '../support/fakes.dart';

void main() {
  const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

  testWidgets('guest CTA explains sign-in and preserves one composer intent', (
    tester,
  ) async {
    final fixture = await _fixture(
      viewerAccountId: null,
      page: CommentPage(
        items: [_comment(authorId: accountB, idSuffix: '11')],
        nextCursor: null,
      ),
    );
    addTearDown(fixture.database.close);
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => CommentsScreen(
            paperId: samplePaper.paperId,
            paperTitle: samplePaper.title,
            onClose: () {},
          ),
        ),
        GoRoute(
          path: PakPerkRoutes.auth,
          builder: (_, __) => const Scaffold(body: Text('Secure auth route')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentViewerScopeProvider.overrideWithValue(
            const CommentViewerScope.guest(),
          ),
          commentComposerEligibleProvider.overrideWithValue(false),
          verifiedCommentScopeProvider.overrideWithValue(null),
          commentThreadProvider.overrideWith(
            (ref, paperId) => fixture.controller,
          ),
          networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A published observation.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comments-sign-in-cta')));
    await tester.pumpAndSettle();
    expect(find.text('Join the paper discussion'), findsOneWidget);
    expect(pending.state, isNull);

    await tester.tap(find.byKey(const ValueKey('comments-sign-in-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Secure auth route'), findsOneWidget);
    expect(pending.state?.kind, AppPendingActionKind.openComposer);
    expect(pending.state?.targetId, samplePaper.paperId);
  });

  testWidgets(
    'authenticated report intent waits for its reloaded comment target',
    (tester) async {
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: CommentPage(
          items: [_comment(authorId: accountB, idSuffix: '11')],
          nextCursor: null,
        ),
        load: false,
      );
      addTearDown(fixture.database.close);
      final loadGate = Completer<void>();
      fixture.remote.listGate = loadGate;
      final intents = CommentUiIntentController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commentViewerScopeProvider.overrideWithValue(
              const CommentViewerScope.authenticated(
                accountId: accountA,
                authEpoch: 1,
              ),
            ),
            commentComposerEligibleProvider.overrideWithValue(true),
            verifiedCommentScopeProvider.overrideWithValue(const (
              accountId: accountA,
              authEpoch: 1,
            )),
            commentThreadProvider.overrideWith(
              (ref, paperId) => fixture.controller,
            ),
            commentUiIntentProvider.overrideWith((ref) => intents),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(
            home: CommentsScreen(
              paperId: samplePaper.paperId,
              paperTitle: samplePaper.title,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      final load = fixture.controller.load();
      await tester.pump();

      final intent = CommentUiIntent(
        kind: CommentUiIntentKind.reportComment,
        targetId: _commentId('11'),
      );
      intents.show(intent);
      await tester.pump();

      expect(intents.state, same(intent));
      expect(find.widgetWithText(AlertDialog, 'Report comment'), findsNothing);

      loadGate.complete();
      await load;
      await tester.pumpAndSettle();

      expect(intents.state, isNull);
      expect(
        find.widgetWithText(AlertDialog, 'Report comment'),
        findsOneWidget,
      );
      expect(fixture.remote.reportCalls, isEmpty);
    },
  );

  testWidgets('missing resumed target fails once with a visible explanation', (
    tester,
  ) async {
    final fixture = await _fixture(
      viewerAccountId: accountA,
      page: const CommentPage(items: [], nextCursor: null),
    );
    addTearDown(fixture.database.close);
    final intents = CommentUiIntentController();
    intents.show(
      CommentUiIntent(kind: CommentUiIntentKind.blockUser, targetId: accountB),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentViewerScopeProvider.overrideWithValue(
            const CommentViewerScope.authenticated(
              accountId: accountA,
              authEpoch: 1,
            ),
          ),
          commentComposerEligibleProvider.overrideWithValue(true),
          verifiedCommentScopeProvider.overrideWithValue(const (
            accountId: accountA,
            authEpoch: 1,
          )),
          commentThreadProvider.overrideWith(
            (ref, paperId) => fixture.controller,
          ),
          commentUiIntentProvider.overrideWith((ref) => intents),
          networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          home: CommentsScreen(
            paperId: samplePaper.paperId,
            paperTitle: samplePaper.title,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(intents.state, isNull);
    expect(
      find.text('The user is no longer available to block.'),
      findsOneWidget,
    );
    expect(fixture.remote.blockCalls, isEmpty);
  });

  testWidgets('header reveals a count only after pagination is complete', (
    tester,
  ) async {
    final fixture = await _fixture(
      viewerAccountId: null,
      page: CommentPage(
        items: [_comment(authorId: accountB, idSuffix: '11')],
        nextCursor: 'page-2',
      ),
    );
    addTearDown(fixture.database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentViewerScopeProvider.overrideWithValue(
            const CommentViewerScope.guest(),
          ),
          commentComposerEligibleProvider.overrideWithValue(false),
          verifiedCommentScopeProvider.overrideWithValue(null),
          commentThreadProvider.overrideWith(
            (ref, paperId) => fixture.controller,
          ),
          networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: MaterialApp(
          home: CommentsScreen(
            paperId: samplePaper.paperId,
            paperTitle: samplePaper.title,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(samplePaper.title), findsOneWidget);
    expect(find.text('1 comment'), findsNothing);

    fixture.remote.page = CommentPage(
      items: [
        _comment(authorId: accountB, idSuffix: '11'),
        _comment(authorId: accountA, idSuffix: '12'),
      ],
      nextCursor: null,
    );
    await fixture.controller.refresh();
    await tester.pumpAndSettle();

    expect(find.text('2 comments'), findsOneWidget);
  });

  testWidgets('header hides a count for a cached page after refresh fails', (
    tester,
  ) async {
    final fixture = await _fixture(
      viewerAccountId: null,
      page: CommentPage(
        items: [
          _comment(authorId: accountB, idSuffix: '11'),
          _comment(authorId: accountA, idSuffix: '12'),
        ],
        nextCursor: null,
      ),
    );
    addTearDown(fixture.database.close);
    addTearDown(fixture.controller.dispose);
    await fixture.repository.cacheVisibleFirstPage(
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.guest(),
      page: CommentPage(
        items: [_comment(authorId: accountB, idSuffix: '11')],
        nextCursor: null,
      ),
    );
    fixture.remote.listError = const ApiException(
      code: 'OFFLINE',
      message: 'You appear to be offline.',
    );
    final restarted = CommentThreadController(
      repository: fixture.repository,
      paperId: samplePaper.paperId,
      viewer: const CommentViewerScope.guest(),
    );
    await restarted.load();

    expect(restarted.state.showingCached, isTrue);
    expect(restarted.state.items, hasLength(1));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentViewerScopeProvider.overrideWithValue(
            const CommentViewerScope.guest(),
          ),
          commentComposerEligibleProvider.overrideWithValue(false),
          verifiedCommentScopeProvider.overrideWithValue(null),
          commentThreadProvider.overrideWith((ref, paperId) => restarted),
          networkOfflineProvider.overrideWith((ref) => Stream.value(true)),
        ],
        child: MaterialApp(
          home: CommentsScreen(
            paperId: samplePaper.paperId,
            paperTitle: samplePaper.title,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A published observation.'), findsOneWidget);
    expect(find.text('1 comment'), findsNothing);
  });

  testWidgets(
    'comment report, user report, and block remain distinct actions',
    (tester) async {
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: CommentPage(
          items: [_comment(authorId: accountB, idSuffix: '11')],
          nextCursor: null,
        ),
      );
      addTearDown(fixture.database.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commentViewerScopeProvider.overrideWithValue(
              const CommentViewerScope.authenticated(
                accountId: accountA,
                authEpoch: 1,
              ),
            ),
            commentComposerEligibleProvider.overrideWithValue(true),
            verifiedCommentScopeProvider.overrideWithValue(const (
              accountId: accountA,
              authEpoch: 1,
            )),
            commentThreadProvider.overrideWith(
              (ref, paperId) => fixture.controller,
            ),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(
            home: CommentsScreen(
              paperId: samplePaper.paperId,
              paperTitle: samplePaper.title,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final actions = find.byKey(
        const ValueKey('comment-actions-018f47a6-4b56-7f4c-8c7a-e2656e820011'),
      );
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report comment'));
      await tester.pumpAndSettle();

      expect(find.text('Report comment'), findsOneWidget);
      expect(fixture.remote.reportCalls, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, 'Additional detail (optional)'),
        'Repeated unsolicited promotion.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(fixture.remote.reportCalls, hasLength(1));
      expect(fixture.remote.reportCalls.single.commentId, _commentId('11'));
      expect(
        fixture.remote.reportCalls.single.reason,
        CommentReportReason.spam,
      );
      expect(
        fixture.remote.reportCalls.single.detail,
        'Repeated unsolicited promotion.',
      );
      expect(fixture.remote.reportCalls.single.expectedAuthEpoch, 1);
      expect(find.text('Report received. Thank you.'), findsOneWidget);
      expect(find.text('A published observation.'), findsOneWidget);

      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report user'));
      await tester.pumpAndSettle();

      expect(find.text('Report @reader_two'), findsOneWidget);
      expect(fixture.remote.userReportCalls, isEmpty);
      expect(fixture.remote.blockCalls, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, 'Additional detail (optional)'),
        'This profile appears to impersonate another researcher.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(fixture.remote.userReportCalls, hasLength(1));
      expect(fixture.remote.userReportCalls.single.userId, accountB);
      expect(
        fixture.remote.userReportCalls.single.detail,
        'This profile appears to impersonate another researcher.',
      );
      expect(fixture.remote.blockCalls, isEmpty);
      expect(find.text('A published observation.'), findsOneWidget);
      expect(
        find.text('User report received. No block was added.'),
        findsOneWidget,
      );

      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block user'));
      await tester.pumpAndSettle();

      expect(find.text('Block @reader_two?'), findsOneWidget);
      expect(
        find.textContaining('comments will disappear immediately'),
        findsOneWidget,
      );
      expect(fixture.remote.blockCalls, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('A published observation.'), findsOneWidget);
      expect(fixture.remote.blockCalls, isEmpty);

      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block user'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block user'));
      await tester.pumpAndSettle();

      expect(fixture.remote.blockCalls, [accountB]);
      expect(find.text('A published observation.'), findsNothing);
      expect(
        fixture.controller.state.items.where(
          (comment) => comment.author.id == accountB,
        ),
        isEmpty,
      );
      final locallyBlocked = await CommentsDao(
        fixture.database,
      ).blockedUserIds(accountA);
      expect(locallyBlocked, contains(accountB));
    },
  );

  testWidgets(
    'authenticated comments stay accessible with keyboard large text and create kill',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final fixture = await _fixture(
        viewerAccountId: accountA,
        page: CommentPage(
          items: [
            _comment(
              authorId: accountA,
              idSuffix: '12',
              pending: true,
              body: '<b>Private plain text</b>',
            ),
            _comment(authorId: accountB, idSuffix: '11'),
          ],
          nextCursor: null,
        ),
        creationDisabled: true,
      );
      addTearDown(fixture.database.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commentViewerScopeProvider.overrideWithValue(
              const CommentViewerScope.authenticated(
                accountId: accountA,
                authEpoch: 1,
              ),
            ),
            commentComposerEligibleProvider.overrideWithValue(true),
            verifiedCommentScopeProvider.overrideWithValue(const (
              accountId: accountA,
              authEpoch: 1,
            )),
            commentThreadProvider.overrideWith(
              (ref, paperId) => fixture.controller,
            ),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 220),
                padding: const EdgeInsets.only(bottom: 16),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: CommentsScreen(
                paperId: samplePaper.paperId,
                paperTitle: samplePaper.title,
                onClose: () {},
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: 0,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.article_outlined),
                    label: 'Read',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    label: 'You',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('<b>Private plain text</b>'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Your comment, under review'),
        findsOneWidget,
      );
      semantics.dispose();
      expect(find.text('Under review · only you can see this'), findsOneWidget);

      final otherMenu = find.byKey(
        const ValueKey('comment-actions-018f47a6-4b56-7f4c-8c7a-e2656e820011'),
      );
      await tester.scrollUntilVisible(
        otherMenu,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(otherMenu);
      await tester.pumpAndSettle();
      expect(find.text('Report comment'), findsOneWidget);
      expect(find.text('Report user'), findsOneWidget);
      expect(find.text('Block user'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      final composer = find.byKey(const ValueKey('comment-composer'));
      await tester.ensureVisible(composer);
      expect(
        tester.getRect(composer).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(NavigationBar)).top),
      );
      await tester.enterText(composer, 'A deliberate public comment');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('comment-send')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'New comments are paused. Existing discussions remain available.',
        ),
        findsOneWidget,
      );
      expect(find.text('2 comments'), findsOneWidget);
      expect(fixture.controller.state.items, hasLength(2));
      expect(fixture.controller.state.draft, 'A deliberate public comment');
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('comment-send')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<
  ({
    PakPerkDatabase database,
    CommentThreadController controller,
    CommentRepository repository,
    _Remote remote,
  })
>
_fixture({
  required String? viewerAccountId,
  required CommentPage page,
  bool creationDisabled = false,
  bool load = true,
}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  await PaperCacheDao(database).save(samplePaper);
  final remote = _Remote(page: page, creationDisabled: creationDisabled);
  final repository = CommentRepository(
    cache: CommentCacheDao(database),
    local: CommentsDao(database),
    remote: remote,
    accountWrites: AccountDataWriteBarrier(),
    sessionScope: () => (
      accountId: viewerAccountId,
      authEpoch: viewerAccountId == null ? 0 : 1,
    ),
    verifiedScope: () => viewerAccountId == null
        ? null
        : (accountId: viewerAccountId, authEpoch: 1),
  );
  final viewer = viewerAccountId == null
      ? const CommentViewerScope.guest()
      : CommentViewerScope.authenticated(
          accountId: viewerAccountId,
          authEpoch: 1,
        );
  final controller = CommentThreadController(
    repository: repository,
    paperId: samplePaper.paperId,
    viewer: viewer,
  );
  if (load) await controller.load();
  return (
    database: database,
    controller: controller,
    repository: repository,
    remote: remote,
  );
}

final class _Remote implements CommentsRemoteDataSource {
  _Remote({required this.page, required this.creationDisabled});

  CommentPage page;
  final bool creationDisabled;
  ApiException? listError;
  Completer<void>? listGate;
  int listCalls = 0;
  final List<
    ({
      String commentId,
      CommentReportReason reason,
      String? detail,
      int expectedAuthEpoch,
    })
  >
  reportCalls = [];
  final List<
    ({
      String userId,
      CommentReportReason reason,
      String? detail,
      int expectedAuthEpoch,
    })
  >
  userReportCalls = [];
  final List<String> blockCalls = [];

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async {
    listCalls += 1;
    await listGate?.future;
    if (listError case final error?) throw error;
    return page;
  }

  @override
  Future<PaperComment> create({
    required String paperId,
    required String clientRequestId,
    required String body,
    required int expectedAuthEpoch,
  }) async {
    if (creationDisabled) {
      throw const ApiException(
        code: 'FEATURE_DISABLED',
        message: 'New comments are disabled.',
        statusCode: 503,
      );
    }
    return _comment(
      authorId: accountA,
      idSuffix: '13',
      pending: true,
      body: body,
    );
  }

  @override
  Future<CommentReportReceipt> report({
    required String commentId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  }) async {
    reportCalls.add((
      commentId: commentId,
      reason: reason,
      detail: detail,
      expectedAuthEpoch: expectedAuthEpoch,
    ));
    return CommentReportReceipt(
      id: '018f47a6-4b56-7f4c-8c7a-e2656e820099',
      commentId: commentId,
      reason: reason,
      status: 'open',
      createdAt: DateTime.utc(2026, 8, 1, 13),
    );
  }

  @override
  Future<UserReportReceipt> reportUser({
    required String userId,
    required CommentReportReason reason,
    required String? detail,
    required int expectedAuthEpoch,
  }) async {
    userReportCalls.add((
      userId: userId,
      reason: reason,
      detail: detail,
      expectedAuthEpoch: expectedAuthEpoch,
    ));
    return UserReportReceipt(
      id: '018f47a6-4b56-7f4c-8c7a-e2656e820098',
      reportedUserId: userId,
      reason: reason,
      status: 'open',
      createdAt: DateTime.utc(2026, 8, 1, 13),
    );
  }

  @override
  Future<BlockedUser> block({
    required String userId,
    required int expectedAuthEpoch,
  }) async {
    blockCalls.add(userId);
    return BlockedUser(
      user: CommentAuthor(
        id: userId,
        handle: 'reader_two',
        status: CommentAccountStatus.active,
      ),
      createdAt: DateTime.utc(2026, 8, 1, 13),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

String _commentId(String suffix) => '018f47a6-4b56-7f4c-8c7a-e2656e8200$suffix';

PaperComment _comment({
  required String authorId,
  required String idSuffix,
  bool pending = false,
  String body = 'A published observation.',
}) => PaperComment(
  id: _commentId(idSuffix),
  paperId: samplePaper.paperId,
  author: CommentAuthor(
    id: authorId,
    handle: authorId == accountA ? 'reader_one' : 'reader_two',
    displayName: null,
    status: CommentAccountStatus.active,
  ),
  body: body,
  status: pending ? CommentStatus.pendingReview : CommentStatus.published,
  version: 1,
  createdAt: DateTime.utc(2026, 8, 1, 12, int.parse(idSuffix)),
  updatedAt: DateTime.utc(2026, 8, 1, 12, int.parse(idSuffix)),
  editedAt: null,
);
