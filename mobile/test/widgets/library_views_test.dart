import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pakperk/app/account_providers.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/library_providers.dart';
import 'package:pakperk/core/account/account_profile.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:pakperk/core/database/app_database.dart';
import 'package:pakperk/core/database/library_dao.dart';
import 'package:pakperk/core/library/library_api.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_repository.dart';
import 'package:pakperk/core/models/paper.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/core/sync/library_sync_controller.dart';
import 'package:pakperk/core/sync/outbox_controller.dart';
import 'package:pakperk/features/library/paper_save_control.dart';
import 'package:pakperk/features/library/to_read_list.dart';
import 'package:pakperk/features/library/to_read_screen.dart';

import '../core/auth/auth_fakes.dart';

void main() {
  testWidgets(
    'account-keyed library projections never retain account A values for B',
    (tester) async {
      const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
      const scopeA = (accountId: _accountId, authEpoch: 7);
      const scopeB = (accountId: accountB, authEpoch: 7);
      final paperA = _paper('Private paper for A', 8);
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = LibraryDao(database);
      await dao.enqueueMutation(
        accountId: _accountId,
        paperId: paperA.paperId,
        saved: true,
        paper: paperA,
      );
      final repository = LibraryRepository(
        local: dao,
        remote: _UnusedLibraryRemote(),
        sessionScope: () => scopeA,
        verifiedScope: () => null,
      );
      final activeScopeProvider = StateProvider<ActiveLibraryScope>(
        (ref) => scopeA,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [libraryRepositoryProvider.overrideWithValue(repository)],
          child: Consumer(
            builder: (context, ref, child) {
              final scope = ref.watch(activeScopeProvider);
              final items = ref.watch(toReadItemsProvider(scope));
              final saved = ref.watch(
                paperSavedStateProvider((
                  accountId: scope.accountId,
                  authEpoch: scope.authEpoch,
                  paperId: paperA.paperId,
                )),
              );
              final pending = ref.watch(libraryPendingCountProvider(scope));
              final itemLabel = items.isLoading
                  ? 'loading'
                  : '[${items.value?.map((item) => item.paper.title).join(',')} ]';
              final savedLabel = saved.isLoading
                  ? 'loading'
                  : '${saved.value?.saved}';
              final pendingLabel = pending.isLoading
                  ? 'loading'
                  : '${pending.value}';
              return MaterialApp(
                home: Text(
                  '${scope.accountId}|$itemLabel|$savedLabel|$pendingLabel',
                  key: const ValueKey('library-scope-projection'),
                ),
              );
            },
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            _projectionText(tester).contains('Private paper for A') &&
            _projectionText(tester).endsWith('|true|1'),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('library-scope-projection'))),
      );
      container.read(activeScopeProvider.notifier).state = scopeB;
      await tester.pump();

      expect(_projectionText(tester), startsWith('$accountB|'));
      expect(_projectionText(tester), isNot(contains('Private paper for A')));
      expect(_projectionText(tester), isNot(endsWith('|true|1')));
      await _pumpUntil(
        tester,
        () => _projectionText(tester).endsWith('|false|0'),
      );
      expect(_projectionText(tester), isNot(contains('Private paper for A')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('guest save records one credential-free intent before auth', (
    tester,
  ) async {
    final pending =
        PendingAuthenticatedActionController<AppPendingAuthenticatedAction>();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) =>
              Scaffold(body: PaperSaveControl(paper: _paper('Guest paper', 3))),
        ),
        GoRoute(
          path: '/auth',
          builder: (_, __) => const Scaffold(body: Text('Auth route')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(_libraryFlags),
          libraryDisplayScopeProvider.overrideWithValue(null),
          libraryMutationScopeProvider.overrideWithValue(null),
          libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
          paperSavedStateProvider.overrideWith(
            (ref, view) => Stream.value(const LibrarySavedState.notSaved()),
          ),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Save to To Read'));
    await tester.pumpAndSettle();
    expect(find.text('Save across your devices'), findsOneWidget);
    expect(pending.state, isNull);

    await tester.tap(find.byKey(const ValueKey('save-sign-in-continue')));
    await tester.pumpAndSettle();

    expect(find.text('Auth route'), findsOneWidget);
    expect(pending.state?.kind, AppPendingActionKind.savePaper);
    expect(pending.state?.targetId, _paper('Guest paper', 3).paperId);
  });

  testWidgets(
    'deletion-pending library stays read-only without a retained account ID',
    (tester) async {
      final auth = AuthSessionController(
        repository: AuthRepository(
          configuration: testOidcConfiguration,
          oidcClient: FakeOidcClient(),
          secureTokenStore: MemorySecureTokenStore(
            storedRecord(accountId: _accountId),
          ),
        ),
        clearAccountOwnedData: (_, __) async {},
      );
      await auth.inspectStoredSession();
      expect(
        await auth.enterAccountDeletionPending(accountId: _accountId),
        isTrue,
      );
      final pending =
          PendingAuthenticatedActionController<AppPendingAuthenticatedAction>();
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(_libraryFlags),
          authSessionProvider.overrideWith((ref) => auth),
          paperSavedStateProvider.overrideWith(
            (ref, view) => Stream.value(const LibrarySavedState.notSaved()),
          ),
          pendingAuthenticatedActionProvider.overrideWith((ref) => pending),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(libraryDisplayScopeProvider), isNull);
      expect(container.read(libraryMutationScopeProvider), isNull);
      expect(
        container.read(libraryReadOnlyAccountStatusProvider),
        AccountStatus.deletionPending,
      );

      final paper = _paper('Deletion-pending paper', 4);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: PaperSaveControl(paper: paper)),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byTooltip('Account deletion pending · To Read is read-only'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('paper-save-control')))
            .onTap,
        isNull,
      );
      expect(find.text('Save across your devices'), findsNothing);
      expect(pending.state, isNull);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ToReadScreen(onOpenPaper: (_) {})),
        ),
      );
      await tester.pump();

      expect(find.text('Account deletion is pending'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(pending.state, isNull);
    },
  );

  testWidgets('save control exposes exact action and pending semantics', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaperSaveControlView(
            state: const LibrarySavedState(saved: false, syncPending: false),
            onPressed: () => taps += 1,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Save to To Read'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paper-save-control')));
    expect(taps, 1);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PaperSaveControlView(
            state: LibrarySavedState(saved: true, syncPending: true),
            onPressed: null,
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);
    expect(find.byKey(const ValueKey('save-sync-pending')), findsOneWidget);
  });

  testWidgets(
    'two save controls stay consistent through one saved-state stream',
    (tester) async {
      final paper = _paper('Shared state paper', 6);
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = LibraryRepository(
        local: LibraryDao(
          database,
          clock: () => DateTime.utc(2026, 8, 1, 12),
          operationId: () => _dualControlOperationId,
        ),
        remote: _UnusedLibraryRemote(),
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => (accountId: _accountId, authEpoch: 7),
      );
      var savedStateStreams = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(_libraryFlags),
            libraryDisplayScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryMutationScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
            libraryRepositoryProvider.overrideWithValue(repository),
            paperSavedStateProvider.overrideWith((ref, view) {
              savedStateStreams += 1;
              return repository.watchSavedState(_accountId, view.paperId);
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  PaperSaveControl(paper: paper),
                  PaperSaveControl(paper: paper),
                ],
              ),
            ),
          ),
        ),
      );
      final controls = find.byKey(const ValueKey('paper-save-control'));
      await _pumpUntil(
        tester,
        () =>
            controls.evaluate().length == 2 &&
            tester
                .widgetList<InkWell>(controls)
                .every((control) => control.onTap != null),
      );

      expect(find.bySemanticsLabel('Save to To Read'), findsNWidgets(2));
      expect(savedStateStreams, 1);
      await tester.tap(controls.first);
      await _pumpUntil(
        tester,
        () =>
            find.bySemanticsLabel('Remove from To Read').evaluate().length == 2,
      );

      expect(find.bySemanticsLabel('Remove from To Read'), findsNWidgets(2));
      expect(savedStateStreams, 1);
      expect(
        await repository.watchSavedState(_accountId, paper.paperId).first,
        const LibrarySavedState(saved: true, syncPending: true),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('shared unsave offers Undo as a fresh saved operation', (
    tester,
  ) async {
    final paper = _paper('Undo paper', 4);
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final operationIds = Queue.of([
      _seedOperationId,
      _removeOperationId,
      _undoOperationId,
    ]);
    final dao = LibraryDao(
      database,
      clock: () => DateTime.utc(2026, 8, 1, 12),
      operationId: operationIds.removeFirst,
    );
    final repository = LibraryRepository(
      local: dao,
      remote: _UnusedLibraryRemote(),
      sessionScope: () => (accountId: _accountId, authEpoch: 7),
      verifiedScope: () => (accountId: _accountId, authEpoch: 7),
    );
    await repository.setSaved(
      accountId: _accountId,
      authEpoch: 7,
      paperId: paper.paperId,
      saved: true,
      paper: paper,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(_libraryFlags),
          libraryDisplayScopeProvider.overrideWithValue(const (
            accountId: _accountId,
            authEpoch: 7,
          )),
          libraryMutationScopeProvider.overrideWithValue(const (
            accountId: _accountId,
            authEpoch: 7,
          )),
          libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(body: PaperSaveControl(paper: paper)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.bySemanticsLabel('Remove from To Read'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('paper-save-control')));
    await _pumpUntil(
      tester,
      () => find.text('Removed from To Read').evaluate().isNotEmpty,
    );

    expect(find.text('Removed from To Read'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    var outbox = await database.select(database.syncOutbox).get();
    expect(outbox, hasLength(1));
    expect(outbox.single.operationId, _removeOperationId);
    expect(outbox.single.operation, 'library_remove');

    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('paper-save-undo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    outbox = await database.select(database.syncOutbox).get();
    expect(outbox, hasLength(1));
    expect(outbox.single.operationId, _undoOperationId);
    expect(outbox.single.operationId, isNot(_removeOperationId));
    expect(outbox.single.operation, 'library_save');
    expect(
      await repository.watchSavedState(_accountId, paper.paperId).first,
      const LibrarySavedState(saved: true, syncPending: true),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'To Read unsave still syncs and offers Undo when platform feedback fails',
    (tester) async {
      final paper = _paper('Feedback-independent paper', 5);
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final operationIds = Queue.of([_seedOperationId, _removeOperationId]);
      final dao = LibraryDao(
        database,
        clock: () => DateTime.utc(2026, 8, 1, 12),
        operationId: operationIds.removeFirst,
      );
      final remote = _RecordingLibraryRemote();
      final repository = LibraryRepository(
        local: dao,
        remote: remote,
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => (accountId: _accountId, authEpoch: 7),
      );
      final sync = LibrarySyncController(
        repository: repository,
        outbox: LibraryOutboxController(repository: repository),
        clock: () => DateTime.utc(2026, 8, 1, 12, 5),
      );
      await sync.start(accountId: _accountId, authEpoch: 7);
      await repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: paper.paperId,
        saved: true,
        paper: paper,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(_libraryFlags),
            libraryDisplayScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryMutationScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
            libraryRepositoryProvider.overrideWithValue(repository),
            librarySyncControllerProvider.overrideWith((ref) => sync),
            authSessionOfflineUnknownProvider.overrideWithValue(false),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(home: ToReadScreen(onOpenPaper: (_) {})),
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(ValueKey('remove-to-read-${paper.paperId}'))
            .evaluate()
            .isNotEmpty,
      );

      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          throw PlatformException(code: 'feedback-unavailable');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.tap(find.byKey(ValueKey('remove-to-read-${paper.paperId}')));
      await _pumpUntil(
        tester,
        () =>
            remote.removeCalls == 1 &&
            find.text('Removed from To Read').evaluate().isNotEmpty,
      );

      expect(find.text('Removed from To Read'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(
        find.text('This paper could not be removed on this device.'),
        findsNothing,
      );
      expect(remote.removeCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'OIDC offline state marks cached To Read offline when transport is online',
    (tester) async {
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = LibraryRepository(
        local: LibraryDao(database),
        remote: _UnusedLibraryRemote(),
        sessionScope: () => (accountId: _accountId, authEpoch: 7),
        verifiedScope: () => null,
        localMutationScope: () => (accountId: _accountId, authEpoch: 7),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(_libraryFlags),
            libraryDisplayScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryMutationScopeProvider.overrideWithValue(const (
              accountId: _accountId,
              authEpoch: 7,
            )),
            libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
            libraryRepositoryProvider.overrideWithValue(repository),
            toReadItemsProvider.overrideWith(
              (ref, scope) => Stream.value(const <LibraryListItem>[]),
            ),
            authSessionOfflineUnknownProvider.overrideWithValue(true),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(home: ToReadScreen(onOpenPaper: (_) {})),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Offline. Pull to refresh when you reconnect.'),
        findsOneWidget,
      );
      expect(find.byType(RefreshIndicator), findsOneWidget);
    },
  );

  testWidgets('suspended account is read-only and cannot enqueue outbox work', (
    tester,
  ) async {
    final paper = _paper('Read-only paper', 7);
    final database = PakPerkDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = LibraryRepository(
      local: LibraryDao(database),
      remote: _UnusedLibraryRemote(),
      sessionScope: () => (accountId: _accountId, authEpoch: 7),
      verifiedScope: () => null,
      localMutationScope: () => null,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(_libraryFlags),
          libraryDisplayScopeProvider.overrideWithValue(const (
            accountId: _accountId,
            authEpoch: 7,
          )),
          libraryMutationScopeProvider.overrideWithValue(null),
          libraryReadOnlyAccountStatusProvider.overrideWithValue(
            AccountStatus.suspended,
          ),
          libraryRepositoryProvider.overrideWithValue(repository),
          paperSavedStateProvider.overrideWith(
            (ref, view) => Stream.value(const LibrarySavedState.notSaved()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: PaperSaveControl(paper: paper)),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byTooltip('Account suspended · To Read is read-only'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('paper-save-control')))
          .onTap,
      isNull,
    );
    expect(
      () => repository.setSaved(
        accountId: _accountId,
        authEpoch: 7,
        paperId: paper.paperId,
        saved: true,
        paper: paper,
      ),
      throwsA(isA<LibraryScopeChanged>()),
    );
    expect(await database.select(database.syncOutbox).get(), isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToReadListView(
            items: [_item('Read-only paper', 7)],
            onOpen: (_) {},
            onRemove: null,
            readOnlyMessage:
                'Account suspended. Saved papers are read-only on this device.',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('to-read-read-only')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(
              ValueKey(
                'remove-to-read-${_item('Read-only paper', 7).paper.paperId}',
              ),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ToReadListView(
            items: [],
            onOpen: _ignoreLibraryItem,
            onRemove: null,
            readOnlyMessage:
                'Account suspended. Saved papers are read-only on this device.',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('No saved papers are available'), findsOneWidget);
    expect(
      find.textContaining('Save a paper from any Read stage'),
      findsNothing,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ToReadListView(
            items: [],
            onOpen: _ignoreLibraryItem,
            onRemove: null,
            offline: true,
            readOnlyMessage:
                'Account suspended. Saved papers are read-only on this device.',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Offline. Showing cached saves.'), findsOneWidget);
    expect(
      find.text('Offline. Pull to refresh when you reconnect.'),
      findsNothing,
    );
  });

  testWidgets('To Read is newest first with explicit remove and open actions', (
    tester,
  ) async {
    final older = _item('Older paper', 1);
    final newer = _item('Newer paper', 2, pending: true);
    LibraryListItem? opened;
    LibraryListItem? removed;

    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ToReadListView(
            items: [older, newer],
            onOpen: (item) => opened = item,
            onRemove: (item) => removed = item,
            onRefresh: () async {},
          ),
        ),
      ),
    );

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    expect(
      titles.indexOf('Newer paper'),
      lessThan(titles.indexOf('Older paper')),
    );
    expect(find.text('Waiting to sync'), findsOneWidget);

    await tester.tap(find.text('Newer paper'));
    expect(opened?.paper.title, 'Newer paper');
    await tester.tap(
      find.byKey(ValueKey('remove-to-read-${older.paper.paperId}')),
    );
    expect(removed?.paper.title, 'Older paper');
  });

  testWidgets(
    'To Read sort, search, and category filters stay local and accessible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final oldest = _item(
        'Zeta Systems',
        1,
        category: 'stat.ML',
        authors: const ['Ada Lovelace'],
      );
      final middle = _item(
        'Beta Logic',
        2,
        category: 'cs.AI',
        authors: const ['Grace Hopper'],
      );
      final newest = _item(
        'Alpha Vision',
        3,
        category: 'cs.CV',
        authors: const ['Katherine Johnson'],
      );
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToReadListView(
              items: [middle, oldest, newest],
              onOpen: (_) {},
              onRemove: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      _expectTitleOrder(tester, ['Alpha Vision', 'Beta Logic', 'Zeta Systems']);
      expect(find.byKey(const ValueKey('to-read-search')), findsOneWidget);
      expect(find.bySemanticsLabel('3 saved papers'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('to-read-sort-menu'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('to-read-category-menu')))
            .height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(const ValueKey('to-read-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest saved').last);
      await tester.pumpAndSettle();
      _expectTitleOrder(tester, ['Zeta Systems', 'Beta Logic', 'Alpha Vision']);

      await tester.tap(find.byKey(const ValueKey('to-read-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title A–Z').last);
      await tester.pumpAndSettle();
      _expectTitleOrder(tester, ['Alpha Vision', 'Beta Logic', 'Zeta Systems']);

      await tester.enterText(
        find.byKey(const ValueKey('to-read-search')),
        'katherine',
      );
      await tester.pump();
      expect(find.text('Alpha Vision'), findsOneWidget);
      expect(find.text('Beta Logic'), findsNothing);
      expect(find.text('Zeta Systems'), findsNothing);
      expect(
        find.bySemanticsLabel('1 of 3 saved papers shown'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('to-read-clear-search')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('to-read-category-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cs.AI').last);
      await tester.pumpAndSettle();
      expect(find.text('Beta Logic'), findsOneWidget);
      expect(find.text('Alpha Vision'), findsNothing);
      expect(find.text('Zeta Systems'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('to-read-search')),
        'no such paper',
      );
      await tester.pump();
      expect(find.text('No saved papers match these filters'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('to-read-clear-filters')));
      await tester.pump();
      expect(find.text('Alpha Vision'), findsOneWidget);
      expect(find.text('Beta Logic'), findsOneWidget);
      expect(find.text('Zeta Systems'), findsOneWidget);
      expect(find.text('All categories'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'To Read controls and scroll offset do not cross account scopes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
      const scopeA = (accountId: _accountId, authEpoch: 7);
      const scopeB = (accountId: accountB, authEpoch: 7);
      final activeScopeProvider = StateProvider<ActiveLibraryScope>(
        (ref) => scopeA,
      );
      final accountAItems = List.generate(
        24,
        (index) => _item(
          'Account A saved paper ${index + 1}',
          index + 1,
          category: index.isEven ? 'cs.AI' : 'cs.CV',
        ),
      );
      final accountBItems = List.generate(
        24,
        (index) => _item(
          'Account B saved paper ${index + 1}',
          index + 1,
          category: index.isEven ? 'stat.ML' : 'math.OC',
        ),
      );
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = LibraryRepository(
        local: LibraryDao(database),
        remote: _UnusedLibraryRemote(),
        sessionScope: () => scopeA,
        verifiedScope: () => null,
        localMutationScope: () => null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(_libraryFlags),
            libraryDisplayScopeProvider.overrideWith(
              (ref) => ref.watch(activeScopeProvider),
            ),
            libraryMutationScopeProvider.overrideWithValue(null),
            libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
            libraryRepositoryProvider.overrideWithValue(repository),
            toReadItemsProvider.overrideWith(
              (ref, scope) =>
                  Stream.value(scope == scopeA ? accountAItems : accountBItems),
            ),
            authSessionOfflineUnknownProvider.overrideWithValue(false),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(home: ToReadScreen(onOpenPaper: (_) {})),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('to-read-search')),
        'account a',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('to-read-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest saved').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('to-read-category-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cs.AI').last);
      await tester.pumpAndSettle();

      expect(_toReadSearchText(tester), 'account a');
      expect(find.text('Oldest saved'), findsOneWidget);
      expect(find.text('cs.AI'), findsOneWidget);
      await tester.drag(
        find.byKey(const PageStorageKey<String>('to-read-list')),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();

      expect(_toReadScrollOffset(tester), greaterThan(0));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ToReadScreen)),
      );
      container.read(activeScopeProvider.notifier).state = scopeB;
      await tester.pumpAndSettle();

      expect(_toReadSearchText(tester), isEmpty);
      expect(find.text('Newest saved'), findsOneWidget);
      expect(find.text('All categories'), findsOneWidget);
      expect(_toReadScrollOffset(tester), 0);
      expect(find.text('Account B saved paper 24'), findsOneWidget);
      expect(find.textContaining('Account A saved paper'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'To Read dismisses an account-derived category overlay when display scope '
    'changes asynchronously',
    (tester) async {
      const accountB = '018f47a6-4b56-7f4c-8c7a-e2656e820002';
      const scopeA = (accountId: _accountId, authEpoch: 7);
      const scopeB = (accountId: accountB, authEpoch: 8);
      final activeScopeProvider = StateProvider<ActiveLibraryScope>(
        (ref) => scopeA,
      );
      final database = PakPerkDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = LibraryRepository(
        local: LibraryDao(database),
        remote: _UnusedLibraryRemote(),
        sessionScope: () => scopeA,
        verifiedScope: () => null,
        localMutationScope: () => null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureFlagsProvider.overrideWithValue(_libraryFlags),
            libraryDisplayScopeProvider.overrideWith(
              (ref) => ref.watch(activeScopeProvider),
            ),
            libraryMutationScopeProvider.overrideWithValue(null),
            libraryReadOnlyAccountStatusProvider.overrideWithValue(null),
            libraryRepositoryProvider.overrideWithValue(repository),
            toReadItemsProvider.overrideWith(
              (ref, scope) => Stream.value([
                scope == scopeA
                    ? _item('Account A private paper', 1, category: 'cs.AI')
                    : _item('Account B private paper', 2, category: 'stat.ML'),
              ]),
            ),
            authSessionOfflineUnknownProvider.overrideWithValue(false),
            networkOfflineProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(home: ToReadScreen(onOpenPaper: (_) {})),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('to-read-category-menu')));
      await tester.pumpAndSettle();
      expect(find.text('cs.AI'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ToReadScreen)),
      );
      // Invalid-grant cleanup and identity rebinding can update this provider
      // without a gesture while an account-derived menu is open.
      await Future<void>.microtask(
        () => container.read(activeScopeProvider.notifier).state = scopeB,
      );
      await tester.pump();

      expect(find.text('cs.AI'), findsNothing);
      expect(find.text('Account A private paper'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Account B private paper'), findsOneWidget);
      expect(find.text('All categories'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('To Read controls reflow at 200 percent text without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: ToReadListView(
                items: [_item('Accessible saved paper', 4)],
                onOpen: (_) {},
                onRemove: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('to-read-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('to-read-sort-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('to-read-category-menu')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty offline list remains usable at 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: ToReadListView(
                items: const [],
                offline: true,
                onOpen: (_) {},
                onRemove: (_) {},
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Your To Read list is empty'), findsOneWidget);
    expect(find.textContaining('Offline.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _projectionText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('library-scope-projection')))
    .data!;

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 40 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

LibraryListItem _item(
  String title,
  int day, {
  bool pending = false,
  String category = 'cs.AI',
  List<String> authors = const ['Ada Reader', 'Grace Hopper'],
}) {
  final timestamp = DateTime.utc(2026, 7, day);
  return LibraryListItem(
    paper: _paper(title, day, category: category, authors: authors),
    savedAt: timestamp,
    savedState: LibrarySavedState(saved: true, syncPending: pending),
  );
}

PaperSummary _paper(
  String title,
  int day, {
  String category = 'cs.AI',
  List<String> authors = const ['Ada Reader', 'Grace Hopper'],
}) {
  final paperId = '17060376-2000-4000-8000-${day.toString().padLeft(12, '0')}';
  final timestamp = DateTime.utc(2026, 7, day);
  return PaperSummary(
    paperId: paperId,
    arxivId: '2401.${day.toString().padLeft(5, '0')}v1',
    title: title,
    abstractText: 'Abstract',
    authors: authors,
    primaryCategory: category,
    categories: [category],
    publishedAt: timestamp,
    updatedAt: timestamp,
    absUrl: 'https://arxiv.org/abs/2401.00001v1',
    pdfUrl: 'https://arxiv.org/pdf/2401.00001v1',
  );
}

void _expectTitleOrder(WidgetTester tester, List<String> titles) {
  final offsets = titles
      .map((title) => tester.getTopLeft(find.text(title)).dy)
      .toList();
  expect(offsets, orderedEquals([...offsets]..sort()));
}

String _toReadSearchText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('to-read-search')))
    .controller!
    .text;

double _toReadScrollOffset(WidgetTester tester) {
  final list = find.byKey(const PageStorageKey<String>('to-read-list'));
  final scrollable = find.descendant(
    of: list,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    ),
  );
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

const _libraryFlags = FeatureFlags(
  accounts: true,
  library: true,
  comments: false,
  openingMotion: false,
);

final class _UnusedLibraryRemote implements LibraryRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('The disconnected widget test must not upload.');
}

final class _RecordingLibraryRemote implements LibraryRemoteDataSource {
  int removeCalls = 0;

  @override
  Future<LibraryListPage> list({
    required int expectedAuthEpoch,
    String? cursor,
    int limit = 100,
  }) async =>
      const LibraryListPage(items: [], nextCursor: null, syncRevision: 0);

  @override
  Future<LibraryChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) async => LibraryChangesPage(
    items: const [],
    nextAfterRevision: afterRevision,
    hasMore: false,
    syncRevision: afterRevision,
  );

  @override
  Future<LibraryMutationResult> remove({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) async {
    removeCalls += 1;
    final savedAt = DateTime.utc(2026, 8, 1, 12);
    final removedAt = DateTime.utc(2026, 8, 1, 12, 1);
    return LibraryMutationResult(
      LibraryCanonicalItem(
        paperId: paperId,
        state: 'to_read',
        savedAt: savedAt,
        updatedAt: removedAt,
        removed: true,
        removedAt: removedAt,
        revision: 1,
        lastOperationId: operationId,
      ),
    );
  }

  @override
  Future<LibraryMutationResult> save({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => throw StateError('The regression path must upload only removal.');
}

const _accountId = '018f47a6-4b56-7f4c-8c7a-e2656e820001';

void _ignoreLibraryItem(LibraryListItem _) {}
const _dualControlOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820200';
const _seedOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _removeOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
const _undoOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820203';
