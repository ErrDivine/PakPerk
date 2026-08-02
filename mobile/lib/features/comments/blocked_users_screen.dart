import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/comments_providers.dart';
import '../../app/router.dart';
import '../../core/comments/comment_repository.dart';
import '../../core/database/comments_dao.dart';

final class BlockedUsersScreen extends ConsumerStatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  ConsumerState<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends ConsumerState<BlockedUsersScreen> {
  bool _syncing = false;
  String? _error;
  VerifiedCommentScope? _displayedScope;

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(verifiedCommentScopeProvider);
    if (scope == null) {
      final viewer = ref.watch(commentViewerScopeProvider);
      final readOnlyStatus = ref.watch(commentReadOnlyAccountStatusProvider);
      return Scaffold(
        appBar: AppBar(title: const Text('Blocked users')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: viewer.authenticated
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        readOnlyStatus == null
                            ? 'Account is offline'
                            : 'Blocked users are read-only',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        readOnlyStatus == null
                            ? 'Reconnect and verify this saved session to '
                                  'manage blocked users.'
                            : 'This account cannot report, block, or unblock '
                                  'users. Public comments remain readable.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  )
                : FilledButton.icon(
                    onPressed: () => context.push<void>(PakPerkRoutes.auth),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in to manage blocked users'),
                  ),
          ),
        ),
      );
    }
    if (_displayedScope != scope) {
      _displayedScope = scope;
      _syncing = false;
      _error = null;
    }
    final blocked = ref.watch(blockedUsersProvider(scope));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Blocked users'),
        actions: [
          IconButton(
            tooltip: 'Refresh blocked users',
            onPressed: _syncing ? null : () => _sync(scope),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: blocked.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(
          child: Text('Blocked users could not be read from this device.'),
        ),
        data: (items) => _list(scope, items),
      ),
    );
  }

  Widget _list(VerifiedCommentScope scope, List<BlockedUserValue> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error ?? 'You have not blocked anyone.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length + (_error == null ? 0 : 1),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (_error != null && index == 0) {
          return ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(_error!),
          );
        }
        final item = items[index - (_error == null ? 0 : 1)];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_off_outlined)),
          title: Text(item.displayName ?? '@${item.handle}'),
          subtitle: Text(
            item.serverConfirmed
                ? '@${item.handle}'
                : '@${item.handle} · waiting to sync',
          ),
          trailing: TextButton(
            onPressed: _syncing ? null : () => _unblock(scope, item),
            child: const Text('Unblock'),
          ),
        );
      },
    );
  }

  Future<void> _sync(VerifiedCommentScope scope) async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await ref
          .read(commentRepositoryProvider)
          .reconcileBlocks(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
          );
    } on Object {
      if (_isCurrent(scope)) {
        setState(() {
          _error = 'Offline blocks stay active here and will retry later.';
        });
      }
    } finally {
      if (_isCurrent(scope)) setState(() => _syncing = false);
    }
  }

  Future<void> _unblock(
    VerifiedCommentScope scope,
    BlockedUserValue item,
  ) async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await ref
          .read(commentRepositoryProvider)
          .unblock(
            accountId: scope.accountId,
            authEpoch: scope.authEpoch,
            blockedUserId: item.userId,
          );
    } on Object {
      if (_isCurrent(scope)) {
        setState(() => _error = 'This user could not be unblocked.');
      }
    } finally {
      if (_isCurrent(scope)) setState(() => _syncing = false);
    }
  }

  bool _isCurrent(VerifiedCommentScope scope) =>
      mounted && ref.read(verifiedCommentScopeProvider) == scope;
}
