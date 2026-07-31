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
      expect(find.text('Report'), findsOneWidget);
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

Future<({PakPerkDatabase database, CommentThreadController controller})>
_fixture({
  required String? viewerAccountId,
  required CommentPage page,
  bool creationDisabled = false,
}) async {
  final database = PakPerkDatabase(NativeDatabase.memory());
  await PaperCacheDao(database).save(samplePaper);
  final repository = CommentRepository(
    cache: CommentCacheDao(database),
    local: CommentsDao(database),
    remote: _Remote(page: page, creationDisabled: creationDisabled),
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
  await controller.load();
  return (database: database, controller: controller);
}

final class _Remote implements CommentsRemoteDataSource {
  const _Remote({required this.page, required this.creationDisabled});

  final CommentPage page;
  final bool creationDisabled;

  @override
  Future<CommentPage> listPaper({
    required String paperId,
    required int? expectedAuthEpoch,
    String? cursor,
    int limit = 50,
  }) async => page;

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const accountA = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

PaperComment _comment({
  required String authorId,
  required String idSuffix,
  bool pending = false,
  String body = 'A published observation.',
}) => PaperComment(
  id: '018f47a6-4b56-7f4c-8c7a-e2656e8200$idSuffix',
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
