import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/core/models/reader_state.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/paper_reader/reader_navigation_controller.dart';

import '../support/fakes.dart';

void main() {
  test(
    'anonymous session rotation replaces the ID and clears chat restoration',
    () async {
      const oldSession = '00000000-0000-4000-8000-000000000099';
      const readerKey = 'feed:anonymous-session';
      const initialRestoration = AppRestorationState(
        readerStates: {
          readerKey: ReaderNavigationState(
            chatSheetOpen: true,
            chatThreadId: 'thread-from-old-session',
          ),
        },
      );
      final store = MemoryLocalStore()
        ..sessionId = oldSession
        ..restoration = initialRestoration
        ..chats[readerKey] = const ChatSnapshot(
          threadId: 'thread-from-old-session',
        );
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          initialAnonymousSessionIdProvider.overrideWithValue(oldSession),
          initialRestorationProvider.overrideWithValue(initialRestoration),
        ],
      );
      addTearDown(container.dispose);

      // Reading restoration establishes its session-change listener.
      expect(
        container
            .read(appRestorationControllerProvider)
            .readerState(readerKey)
            .chatThreadId,
        'thread-from-old-session',
      );
      expect(container.read(anonymousSessionIdProvider), oldSession);
      final oldClient = container.read(apiClientProvider);

      final rotated =
          await container.read(anonymousSessionIdProvider.notifier).rotate();

      expect(rotated, isNot(oldSession));
      expect(container.read(anonymousSessionIdProvider), rotated);
      expect(container.read(apiClientProvider), isNot(same(oldClient)));
      expect(await store.getOrCreateSessionId(), rotated);
      expect(store.chats, isEmpty);
      expect(
        container
            .read(appRestorationControllerProvider)
            .readerState(readerKey)
            .chatThreadId,
        isNull,
      );
      expect(
        container
            .read(appRestorationControllerProvider)
            .readerState(readerKey)
            .chatSheetOpen,
        isFalse,
      );
      expect(store.restoration.readerState(readerKey).chatThreadId, isNull);

      final reset =
          await container.read(anonymousSessionIdProvider.notifier).reset();
      expect(reset, isNot(rotated));
      expect(store.sessionRotations, 2);
    },
  );
}
