import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/account/account_profile.dart';
import '../../core/database/library_dao.dart';
import '../../core/library/library_models.dart';
import '../../core/models/paper.dart';
import '../../core/providers.dart';
import '../placeholders/phase_one_placeholder_screens.dart';
import 'paper_import_flow.dart';
import 'to_read_list.dart';

class ToReadScreen extends ConsumerWidget {
  const ToReadScreen({required this.onOpenPaper, super.key});

  final ValueChanged<PaperSummary> onOpenPaper;

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
    final readOnlyStatus = ref.watch(libraryReadOnlyAccountStatusProvider);
    final scope = ref.watch(libraryDisplayScopeProvider);
    if (scope == null) {
      return readOnlyStatus == null
          ? const _SignedOutLibraryScreen()
          : _UnavailableReadOnlyLibraryScreen(status: readOnlyStatus);
    }
    final mutationScope = ref.watch(libraryMutationScopeProvider);
    final canImport = ref.watch(paperImportAvailableProvider);

    final items = ref.watch(toReadItemsProvider(scope));
    final sync = ref.watch(librarySyncControllerProvider);
    final offline =
        ref.watch(authSessionOfflineUnknownProvider) ||
        ref
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
          if (canImport)
            IconButton(
              key: const ValueKey('to-read-add-paper'),
              tooltip: 'Add a paper',
              onPressed: () => unawaited(
                showAccountAddPaperFlow(context: context, ref: ref),
              ),
              icon: const Icon(Icons.add_rounded),
            ),
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
          : SafeArea(
              top: false,
              child: ToReadListView(
                // A PageStorageKey resets the stateful controls just like a
                // ValueKey while also namespacing the descendant ListView's
                // persisted scroll offset to this exact account/auth epoch.
                key: PageStorageKey<ActiveLibraryScope>(scope),
                items: cached ?? const [],
                offline: offline,
                syncIssue:
                    sync.issue ??
                    (items.hasError
                        ? LibrarySyncIssue.fromCode('LOCAL_SYNC_UNAVAILABLE')
                        : null),
                readOnlyMessage: readOnlyStatus == null
                    ? null
                    : _libraryReadOnlyMessage(readOnlyStatus),
                onRefresh: mutationScope == null ? null : () => _refresh(ref),
                onOpen: (item) => onOpenPaper(item.paper),
                onRemove: mutationScope == null
                    ? null
                    : (item) =>
                          unawaited(_remove(context, ref, mutationScope, item)),
              ),
            ),
    );
  }

  Future<void> _refresh(WidgetRef ref) async {
    if (ref.read(authSessionOfflineUnknownProvider)) {
      await ref.read(accountSessionRecoveryProvider).recover();
    }
    await ref.read(librarySyncControllerProvider.notifier).refresh();
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ActiveLibraryScope scope,
    LibraryListItem item,
  ) async {
    final repository = ref.read(libraryRepositoryProvider);
    final sync = ref.read(librarySyncControllerProvider.notifier);
    try {
      await repository.setSaved(
        accountId: scope.accountId,
        authEpoch: scope.authEpoch,
        paperId: item.paper.paperId,
        saved: false,
        paper: item.paper,
      );
      // The local mutation and outbox row are already durable. Platform
      // feedback is optional and must never suppress synchronization or Undo.
      unawaited(sync.drain());
      if (!context.mounted) return;
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
      unawaited(_acknowledgeRemoval(context));
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

  Future<void> _acknowledgeRemoval(BuildContext context) async {
    try {
      await HapticFeedback.selectionClick();
    } on Object {
      // A missing platform feedback channel does not affect the saved state.
    }
    if (!context.mounted || !MediaQuery.supportsAnnounceOf(context)) return;
    try {
      await SemanticsService.sendAnnouncement(
        View.of(context),
        'Removed from To Read',
        Directionality.of(context),
      );
    } on Object {
      // The visible snackbar remains the authoritative outcome and Undo path.
    }
  }

  Future<void> _undo(
    WidgetRef ref,
    ActiveLibraryScope scope,
    LibraryListItem item,
  ) async {
    if (ref.read(libraryMutationScopeProvider) != scope) return;
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

String _libraryReadOnlyMessage(AccountStatus status) => switch (status) {
  AccountStatus.suspended =>
    'Account suspended. Saved papers are read-only on this device.',
  AccountStatus.deletionPending =>
    'Account deletion is pending. Saved papers are read-only.',
  AccountStatus.deleted =>
    'This account is deleted. Saved papers are read-only.',
  AccountStatus.active => 'Saved papers are read-only.',
};

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

class _UnavailableReadOnlyLibraryScreen extends StatelessWidget {
  const _UnavailableReadOnlyLibraryScreen({required this.status});

  final AccountStatus status;

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
              const Icon(Icons.lock_outline, size: 52),
              const SizedBox(height: 16),
              Text(
                switch (status) {
                  AccountStatus.suspended => 'Account suspended',
                  AccountStatus.deletionPending =>
                    'Account deletion is pending',
                  AccountStatus.deleted => 'Account deleted',
                  AccountStatus.active => 'To Read is read-only',
                },
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                status == AccountStatus.deletionPending
                    ? 'Saved papers are unavailable while account-owned '
                          'data is being removed. Public reading remains available.'
                    : 'Saved papers are unavailable for this read-only '
                          'account session. Public reading remains available.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
