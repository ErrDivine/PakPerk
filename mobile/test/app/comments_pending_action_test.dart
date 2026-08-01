import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/comments_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/providers.dart';

void main() {
  const accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';
  const targetId = '018f47a6-4b56-7f4c-8c7a-e2656e820002';

  test('post-auth user-report intent stays distinct from blocking', () async {
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWithValue(
          const FeatureFlags(
            accounts: true,
            library: true,
            comments: true,
            openingMotion: false,
          ),
        ),
        verifiedCommentScopeProvider.overrideWithValue(const (
          accountId: accountId,
          authEpoch: 7,
        )),
        ...commentsApplicationOverrides(),
      ],
    );
    addTearDown(container.dispose);
    final execute = container.read(pendingAuthenticatedActionExecutorProvider);

    await execute(
      AppPendingAuthenticatedAction(
        kind: AppPendingActionKind.reportUser,
        targetId: targetId,
      ),
    );

    expect(
      container.read(commentUiIntentProvider),
      isA<CommentUiIntent>()
          .having(
            (intent) => intent.kind,
            'kind',
            CommentUiIntentKind.reportUser,
          )
          .having((intent) => intent.targetId, 'targetId', targetId),
    );
    container.read(commentUiIntentProvider.notifier).take();

    await execute(
      AppPendingAuthenticatedAction(
        kind: AppPendingActionKind.blockUser,
        targetId: targetId,
      ),
    );
    expect(
      container.read(commentUiIntentProvider),
      isA<CommentUiIntent>()
          .having(
            (intent) => intent.kind,
            'kind',
            CommentUiIntentKind.blockUser,
          )
          .having((intent) => intent.targetId, 'targetId', targetId),
    );
  });

  test('post-auth user report fails closed without a verified scope', () async {
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWithValue(
          const FeatureFlags(
            accounts: true,
            library: true,
            comments: true,
            openingMotion: false,
          ),
        ),
        verifiedCommentScopeProvider.overrideWithValue(null),
        ...commentsApplicationOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(pendingAuthenticatedActionExecutorProvider)(
        AppPendingAuthenticatedAction(
          kind: AppPendingActionKind.reportUser,
          targetId: targetId,
        ),
      ),
      throwsStateError,
    );
    expect(container.read(commentUiIntentProvider), isNull);
  });
}
