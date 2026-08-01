import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../core/account_deletion/account_deletion.dart';
import '../../core/auth/auth.dart';
import '../../core/providers.dart';

final class AccountDeletionScreen extends ConsumerStatefulWidget {
  const AccountDeletionScreen({super.key});

  @override
  ConsumerState<AccountDeletionScreen> createState() =>
      _AccountDeletionScreenState();
}

final class _AccountDeletionScreenState
    extends ConsumerState<AccountDeletionScreen> {
  bool _understands = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(featureFlagsProvider).accounts) {
        unawaited(
          ref
              .read(accountDeletionControllerProvider.notifier)
              .recoverAtStartup(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(featureFlagsProvider).accounts) {
      return const AccountDeletionDisabledScreen();
    }
    final deletion = ref.watch(accountDeletionControllerProvider);
    final session = ref.watch(authSessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        child:
            deletion.deletionPending ||
                session.phase == AuthSessionPhase.deletionPending
            ? _buildPending(deletion)
            : _buildConfirmation(deletion, session),
      ),
    );
  }

  Widget _buildConfirmation(
    AccountDeletionState deletion,
    AuthSessionState session,
  ) {
    final canRequest =
        session.phase == AuthSessionPhase.authenticated && !deletion.busy;
    return ListView(
      key: const ValueKey('account-deletion-confirmation'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      children: [
        Icon(
          Icons.person_off_outlined,
          size: 54,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 18),
        Text(
          'Permanently delete your Pakperk account?',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        const _Consequence(
          icon: Icons.logout,
          text:
              'Your Pakperk access is disabled immediately and provider '
              'sessions are revoked by the deletion worker.',
        ),
        const _Consequence(
          icon: Icons.bookmarks_outlined,
          text:
              'Your To Read list, sync history, drafts, blocks, and other '
              'account-owned app data are deleted.',
        ),
        const _Consequence(
          icon: Icons.forum_outlined,
          text:
              'Comments you authored are deleted. Reports and narrowly '
              'necessary security/moderation audit records may be retained '
              'only in anonymized form for the published retention period.',
        ),
        const _Consequence(
          icon: Icons.key_off_outlined,
          text:
              'Your identity-provider account is erased asynchronously. This '
              'cannot be undone.',
        ),
        const SizedBox(height: 18),
        CheckboxListTile(
          key: const ValueKey('account-deletion-understand'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _understands,
          onChanged: deletion.busy
              ? null
              : (value) => setState(() => _understands = value ?? false),
          title: const Text(
            'I understand that deletion is permanent and may complete '
            'asynchronously.',
          ),
        ),
        if (deletion.errorMessage case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey('account-deletion-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const ValueKey('account-deletion-submit'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: canRequest && _understands
              ? () => _request(session.accountId, session.epoch)
              : null,
          icon: deletion.busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_reset),
          label: Text(
            deletion.busy
                ? 'Opening recent sign in…'
                : 'Reauthenticate and request deletion',
          ),
        ),
        if (!canRequest && !deletion.busy) ...[
          const SizedBox(height: 10),
          const Text(
            'A saved account session is required for in-app deletion. '
            'Suspended accounts and sessions interrupted before profile '
            'binding can still use this action; otherwise use the web '
            'request below.',
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const ValueKey('account-deletion-web-path'),
          onPressed: () =>
              _open(ref.read(appBuildConfigProvider).accountDeletionUri),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Use the web deletion request'),
        ),
        TextButton(
          onPressed: () => _open(ref.read(appBuildConfigProvider).supportUri),
          child: const Text('Contact support'),
        ),
      ],
    );
  }

  Widget _buildPending(AccountDeletionState deletion) {
    final requestId = deletion.guard?.requestId ?? deletion.result?.requestId;
    final terminalFailure =
        deletion.result?.operation?.state ==
            AccountDeletionServerState.failedTerminal ||
        deletion.guard?.serverState ==
            AccountDeletionServerState.failedTerminal;
    final outcomeUnknown =
        deletion.result?.acceptance == AccountDeletionAcceptance.ambiguous ||
        deletion.guard?.acceptance == LocalAccountDeletionAcceptance.inFlight ||
        (deletion.result == null && deletion.guard == null);
    return Center(
      child: SingleChildScrollView(
        key: const ValueKey('account-deletion-pending'),
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                terminalFailure
                    ? Icons.error_outline
                    : Icons.hourglass_top_outlined,
                size: 54,
              ),
              const SizedBox(height: 18),
              Text(
                terminalFailure
                    ? 'Deletion needs operator review'
                    : outcomeUnknown
                    ? 'Deletion outcome unknown'
                    : 'Deletion requested',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                terminalFailure
                    ? 'Your account remains disabled. Server cleanup stopped '
                          'after a terminal failure and will not continue '
                          'automatically. Pakperk operators must review the '
                          'operation; contact support instead of signing in '
                          'again or submitting another deletion.'
                    : outcomeUnknown
                    ? 'Pakperk could not confirm whether the server received '
                          'the deletion request. To fail closed, this device '
                          'cleared secure credentials and private account '
                          'data. Use the public web deletion request to '
                          'confirm or submit deletion, or contact support.'
                    : 'Your account is disabled and server cleanup is still '
                          'in progress. Pakperk has removed or is retrying '
                          'removal of secure credentials and private account '
                          'data on this device. The server worker and '
                          'operators own any retry; you do not need to keep '
                          'credentials or submit another deletion.',
                textAlign: TextAlign.center,
              ),
              if (deletion.errorMessage case final message?) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 18),
              if (outcomeUnknown)
                FilledButton.icon(
                  key: const ValueKey('account-deletion-confirm-web'),
                  onPressed: () => _open(
                    ref.read(appBuildConfigProvider).accountDeletionUri,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Confirm deletion on the web'),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('account-deletion-support'),
                  onPressed: () => _open(_supportUri(requestId)),
                  icon: const Icon(Icons.support_agent_outlined),
                  label: const Text('Contact support about deletion'),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: outcomeUnknown
                    ? const ValueKey('account-deletion-unknown-support')
                    : null,
                onPressed: () => outcomeUnknown
                    ? _open(_supportUri(requestId))
                    : _open(
                        ref.read(appBuildConfigProvider).accountDeletionUri,
                      ),
                icon: Icon(
                  outcomeUnknown
                      ? Icons.support_agent_outlined
                      : Icons.policy_outlined,
                ),
                label: Text(
                  outcomeUnknown
                      ? 'Contact support'
                      : 'Read deletion and retention details',
                ),
              ),
              if (deletion.localCleanupComplete) ...[
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('account-deletion-continue-guest'),
                  onPressed: _continueAsGuest,
                  child: const Text('Continue with public reading'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _request(String? accountId, int epoch) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await ref
        .read(accountDeletionControllerProvider.notifier)
        .request(accountId: accountId, expectedAuthEpoch: epoch);
  }

  Uri _supportUri(String? requestId) {
    final base = ref.read(appBuildConfigProvider).supportUri;
    if (requestId == null || !isAccountDeletionUuid(requestId)) return base;
    return base.replace(queryParameters: {'request_id': requestId});
  }

  Future<void> _open(Uri uri) async {
    await ref.read(externalLinkOpenerProvider).open(uri);
  }

  Future<void> _continueAsGuest() async {
    final cleared = await ref
        .read(accountDeletionControllerProvider.notifier)
        .continueAsGuest();
    if (!cleared) return;
    ref.read(authSessionProvider.notifier).continueAsGuestAfterDeletion();
  }
}

/// Public, credential-free fallback for disabled-account builds.
///
/// This widget deliberately reads no auth or deletion providers, so a direct
/// link or restored route remains safe even when those providers are absent.
final class AccountDeletionDisabledScreen extends ConsumerWidget {
  const AccountDeletionDisabledScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      key: const ValueKey('account-deletion-disabled'),
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person_off_outlined, size: 54),
                  const SizedBox(height: 18),
                  Text(
                    'Account services are not enabled',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'This build cannot hold a Pakperk account or submit an '
                    'authenticated in-app deletion request. The public '
                    'deletion policy and web request remain available.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const ValueKey('account-deletion-disabled-policy'),
                    onPressed: () =>
                        context.push<void>('/legal/account-deletion'),
                    icon: const Icon(Icons.policy_outlined),
                    label: const Text('Read the deletion policy'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('account-deletion-disabled-web'),
                    onPressed: () => ref
                        .read(externalLinkOpenerProvider)
                        .open(
                          ref.read(appBuildConfigProvider).accountDeletionUri,
                        ),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Use the web deletion request'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _Consequence extends StatelessWidget {
  const _Consequence({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(text),
  );
}
