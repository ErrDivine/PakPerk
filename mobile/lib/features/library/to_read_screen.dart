import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/library_providers.dart';
import '../../core/database/library_dao.dart';
import '../../core/library/library_models.dart';
import '../../core/providers.dart';
import '../placeholders/phase_one_placeholder_screens.dart';
import 'to_read_list.dart';

class ToReadScreen extends ConsumerWidget {
  const ToReadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(featureFlagsProvider).library) {
      return const PhaseOnePlaceholderScreen(
        title: 'To Read is not enabled',
        message:
            'Synchronized saves are disabled in this build. Reading and '
            'cached papers remain available.',
        icon: Icons.bookmarks_outlined,
      );
    }
    final scope = ref.watch(libraryDisplayScopeProvider);
    if (scope == null) return const _SignedOutLibraryScreen();

    final items = ref.watch(toReadItemsProvider);
    final sync = ref.watch(librarySyncControllerProvider);
    final offline = ref
        .watch(networkOfflineProvider)
        .when(
          data: (value) => value,
          loading: () => false,
          error: (_, __) => true,
        );
    final cached = items.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('To Read'),
        actions: [
          if (sync.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Semantics(
                  label: '${sync.pendingCount} library changes waiting to sync',
                  child: Badge(
                    label: Text('${sync.pendingCount}'),
                    child: const Icon(Icons.cloud_upload_outlined),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: cached == null && items.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ToReadListView(
              items: cached ?? const [],
              offline: offline,
              syncIssue:
                  sync.issue ??
                  (items.hasError
                      ? LibrarySyncIssue.fromCode('LOCAL_SYNC_UNAVAILABLE')
                      : null),
              onRefresh: () =>
                  ref.read(librarySyncControllerProvider.notifier).refresh(),
              onOpen: (item) => context.go(
                '/read/paper/${item.paper.paperId}',
                extra: item.paper,
              ),
              onRemove: (item) => unawaited(_remove(context, ref, scope, item)),
            ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ActiveLibraryScope scope,
    LibraryListItem item,
  ) async {
    try {
      await ref
          .read(libraryRepositoryProvider)
          .setSaved(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            paperId: item.paper.paperId,
            saved: false,
            paper: item.paper,
          );
      if (!context.mounted) return;
      await HapticFeedback.selectionClick();
      if (!context.mounted) return;
      if (MediaQuery.supportsAnnounceOf(context)) {
        await SemanticsService.sendAnnouncement(
          View.of(context),
          'Removed from To Read',
          Directionality.of(context),
        );
        if (!context.mounted) return;
      }
      unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Removed from To Read'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => unawaited(_undo(ref, scope, item)),
            ),
          ),
        );
    } on LibraryScopeChanged {
      // A sign-out/account switch owns the screen transition and cleanup.
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This paper could not be removed on this device.'),
        ),
      );
    }
  }

  Future<void> _undo(
    WidgetRef ref,
    ActiveLibraryScope scope,
    LibraryListItem item,
  ) async {
    try {
      await ref
          .read(libraryRepositoryProvider)
          .setSaved(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            paperId: item.paper.paperId,
            saved: true,
            paper: item.paper,
          );
      unawaited(ref.read(librarySyncControllerProvider.notifier).drain());
    } on Object {
      // The reactive row exposes a durable issue if the local mutation itself
      // succeeded; a changed account scope deliberately ignores stale Undo.
    }
  }
}

class _SignedOutLibraryScreen extends StatelessWidget {
  const _SignedOutLibraryScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('To Read')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_sync_outlined, size: 52),
              const SizedBox(height: 16),
              Text(
                'Sign in to see your To Read list',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Your synchronized saves belong to your account. Public '
                'reading stays available without signing in.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.push<void>('/auth'),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
