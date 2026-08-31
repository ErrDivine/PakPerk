import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/account/account.dart';
import '../../core/auth/auth.dart';
import '../../core/providers.dart';
import 'guest_you_screen.dart';

class AccountYouScreen extends ConsumerWidget {
  const AccountYouScreen({
    required this.onSignIn,
    required this.onCompleteProfile,
    required this.onOpenLibrary,
    required this.onOpenComments,
    required this.onOpenBlockedUsers,
    this.onOpenMemory,
    required this.onOpenSettings,
    required this.onOpenPrivacy,
    required this.onOpenTerms,
    required this.onOpenCommunityGuidelines,
    required this.onOpenSupport,
    required this.onOpenDeleteAccount,
    super.key,
  });

  final VoidCallback onSignIn;
  final VoidCallback onCompleteProfile;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenComments;
  final VoidCallback onOpenBlockedUsers;
  final VoidCallback? onOpenMemory;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenCommunityGuidelines;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenDeleteAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final features = ref.watch(featureFlagsProvider);
    if (!features.accounts) {
      return GuestYouScreen(
        accountsEnabled: false,
        libraryEnabled: features.library,
        commentsEnabled: features.comments,
        onSignIn: null,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
      );
    }

    final auth = ref.watch(authSessionProvider);
    final offlineLibraryScope =
        auth.phase == AuthSessionPhase.offlineAuthUnknown && features.library
        ? ref.watch(libraryDisplayScopeProvider)
        : null;
    return switch (auth.phase) {
      AuthSessionPhase.guest || AuthSessionPhase.unavailable => GuestYouScreen(
        accountsEnabled: true,
        libraryEnabled: features.library,
        commentsEnabled: features.comments,
        onSignIn: onSignIn,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
      ),
      AuthSessionPhase.offlineAuthUnknown => _OfflineAccountScreen(
        onRetry: () =>
            unawaited(ref.read(accountSessionRecoveryProvider).recover()),
        onSignOut: () => _signOut(ref),
        onOpenLibrary: offlineLibraryScope == null ? null : onOpenLibrary,
        onOpenSettings: onOpenSettings,
      ),
      AuthSessionPhase.authenticated => _AuthenticatedAccountLoader(
        onCompleteProfile: onCompleteProfile,
        onOpenLibrary: onOpenLibrary,
        onOpenComments: onOpenComments,
        onOpenBlockedUsers: onOpenBlockedUsers,
        onOpenMemory: onOpenMemory,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
        onOpenDeleteAccount: onOpenDeleteAccount,
      ),
      AuthSessionPhase.deletionPending => _DeletionPendingAccountScreen(
        onOpenStatus: onOpenDeleteAccount,
        onOpenSupport: onOpenSupport,
      ),
      AuthSessionPhase.checkingStoredSession ||
      AuthSessionPhase.authenticating ||
      AuthSessionPhase.refreshRequired ||
      AuthSessionPhase.refreshing ||
      AuthSessionPhase.signingOut => const _AccountProgressScreen(),
    };
  }
}

class _AuthenticatedAccountLoader extends ConsumerWidget {
  const _AuthenticatedAccountLoader({
    required this.onCompleteProfile,
    required this.onOpenLibrary,
    required this.onOpenComments,
    required this.onOpenBlockedUsers,
    this.onOpenMemory,
    required this.onOpenSettings,
    required this.onOpenPrivacy,
    required this.onOpenTerms,
    required this.onOpenCommunityGuidelines,
    required this.onOpenSupport,
    required this.onOpenDeleteAccount,
  });

  final VoidCallback onCompleteProfile;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenComments;
  final VoidCallback onOpenBlockedUsers;
  final VoidCallback? onOpenMemory;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenCommunityGuidelines;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenDeleteAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final session = ref.watch(authSessionProvider);
    final readOnlyStatus = ref.watch(effectiveAccountReadOnlyStatusProvider);
    final features = ref.watch(featureFlagsProvider);
    if (readOnlyStatus != null) {
      final libraryScope = features.library
          ? ref.watch(libraryDisplayScopeProvider)
          : null;
      return _ReadOnlyAccountScreen(
        status: readOnlyStatus,
        onRetry: () =>
            unawaited(ref.read(currentAccountProvider.notifier).load()),
        onOpenLibrary: libraryScope == null ? null : onOpenLibrary,
        onOpenSettings: onOpenSettings,
        onOpenSupport: onOpenSupport,
        onDeleteAccount: readOnlyStatus == AccountStatus.suspended
            ? onOpenDeleteAccount
            : null,
        onSignOut: () => _signOut(ref),
      );
    }
    if (account.phase == CurrentAccountPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(currentAccountProvider.notifier).load();
      });
    }
    final retainedProfile = account.profile;
    final profile =
        account.verifiedAuthEpoch == session.epoch &&
            retainedProfile?.id == session.accountId
        ? retainedProfile
        : null;
    if (profile == null) {
      if (account.phase == CurrentAccountPhase.failed ||
          (retainedProfile != null &&
              account.phase != CurrentAccountPhase.loading)) {
        return _AccountLoadFailureScreen(
          message:
              account.error?.message ??
              'Account details do not match this session. Reload them before '
                  'continuing.',
          onRetry: () =>
              unawaited(ref.read(currentAccountProvider.notifier).load()),
          onSignOut: () => _signOut(ref),
          onDeleteAccount: onOpenDeleteAccount,
        );
      }
      return const _AccountProgressScreen();
    }

    final libraryEnabled = features.library;
    final commentsEnabled = features.comments;
    final libraryScope = libraryEnabled
        ? ref.watch(libraryDisplayScopeProvider)
        : null;
    final libraryCount = libraryScope != null
        ? ref.watch(toReadItemsProvider(libraryScope)).value?.length
        : null;
    final pendingLibraryCount = libraryScope != null
        ? ref.watch(libraryPendingCountProvider(libraryScope)).value ?? 0
        : 0;

    return AuthenticatedAccountHomeScreen(
      profile: profile,
      updateError: account.phase == CurrentAccountPhase.failed
          ? account.error?.message
          : null,
      updating: account.phase == CurrentAccountPhase.updating,
      libraryEnabled: libraryEnabled,
      commentsEnabled: commentsEnabled,
      libraryCount: libraryCount,
      pendingLibraryCount: pendingLibraryCount,
      onCompleteProfile: onCompleteProfile,
      onEditDisplayName: () => _editDisplayName(context, ref, profile),
      onOpenLibrary: onOpenLibrary,
      onOpenComments: onOpenComments,
      onOpenBlockedUsers: onOpenBlockedUsers,
      onOpenMemory: onOpenMemory,
      onOpenSettings: onOpenSettings,
      onOpenPrivacy: onOpenPrivacy,
      onOpenTerms: onOpenTerms,
      onOpenCommunityGuidelines: onOpenCommunityGuidelines,
      onOpenSupport: onOpenSupport,
      onOpenDeleteAccount: onOpenDeleteAccount,
      onSignOut: () => _signOut(ref),
    );
  }
}

class AuthenticatedAccountHomeScreen extends StatelessWidget {
  const AuthenticatedAccountHomeScreen({
    required this.profile,
    required this.updating,
    required this.onCompleteProfile,
    required this.onEditDisplayName,
    required this.onOpenLibrary,
    required this.onOpenComments,
    required this.onOpenBlockedUsers,
    required this.onOpenSettings,
    required this.onOpenPrivacy,
    required this.onOpenTerms,
    required this.onOpenCommunityGuidelines,
    required this.onOpenSupport,
    required this.onOpenDeleteAccount,
    required this.onSignOut,
    this.libraryEnabled = false,
    this.commentsEnabled = false,
    this.onOpenMemory,
    this.libraryCount,
    this.pendingLibraryCount = 0,
    this.updateError,
    super.key,
  });

  final AccountProfile profile;
  final bool updating;
  final String? updateError;
  final bool libraryEnabled;
  final bool commentsEnabled;
  final int? libraryCount;
  final int pendingLibraryCount;
  final VoidCallback onCompleteProfile;
  final VoidCallback onEditDisplayName;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenComments;
  final VoidCallback onOpenBlockedUsers;
  final VoidCallback? onOpenMemory;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenCommunityGuidelines;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenDeleteAccount;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final complete =
        profile.isActive && profile.handle != null && profile.termsCurrent;
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('authenticated-you-list'),
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Semantics(
              header: true,
              child: Text(
                'You',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CircleAvatar(radius: 28, child: Text(_initials(profile))),
                    const SizedBox(height: 12),
                    Text(
                      profile.displayName ?? profile.handle ?? 'Pakperk reader',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (profile.handle case final handle?)
                      Text('@$handle', textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      _statusLabel(profile.status),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (profile.isActive) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: updating ? null : onEditDisplayName,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit display name'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!complete && profile.isActive) ...[
              const SizedBox(height: 12),
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Finish account setup',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Choose a handle and accept the current terms before '
                        'joining paper discussions.',
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: onCompleteProfile,
                        child: const Text('Complete profile'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (updateError case final message?) ...[
              const SizedBox(height: 12),
              Text(
                message,
                key: const ValueKey('account-update-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Your reading',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (libraryEnabled)
              _AccountDestination(
                icon: Icons.bookmarks_outlined,
                label: 'To Read',
                supportingText: _librarySummary(
                  libraryCount,
                  pendingLibraryCount,
                ),
                onTap: onOpenLibrary,
              ),
            if (onOpenMemory != null)
              _AccountDestination(
                icon: Icons.psychology_alt_outlined,
                label: 'Research memory',
                supportingText:
                    'Review only the notes and evidence you chose to remember.',
                onTap: onOpenMemory!,
              ),
            if (commentsEnabled && profile.isActive) ...[
              _AccountDestination(
                icon: Icons.comment_outlined,
                label: 'My comments',
                supportingText:
                    'Published and privately under-review comments.',
                onTap: onOpenComments,
              ),
              _AccountDestination(
                icon: Icons.block_outlined,
                label: 'Blocked users',
                supportingText: 'Manage authors hidden from discussions.',
                onTap: onOpenBlockedUsers,
              ),
            ],
            const SizedBox(height: 16),
            Text('Account', style: Theme.of(context).textTheme.titleMedium),
            _AccountDestination(
              icon: Icons.settings_outlined,
              label: 'Settings',
              onTap: onOpenSettings,
            ),
            _AccountDestination(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy',
              onTap: onOpenPrivacy,
            ),
            _AccountDestination(
              icon: Icons.description_outlined,
              label: 'Terms',
              supportingText: profile.termsCurrent
                  ? 'Accepted ${profile.termsVersion}'
                  : 'Current version: ${profile.currentTermsVersion}',
              onTap: onOpenTerms,
            ),
            _AccountDestination(
              icon: Icons.groups_outlined,
              label: 'Community guidelines',
              supportingText: profile.communityGuidelinesCurrent
                  ? 'Accepted ${profile.communityGuidelinesVersion}'
                  : 'Current version: '
                        '${profile.currentCommunityGuidelinesVersion}',
              onTap: onOpenCommunityGuidelines,
            ),
            _AccountDestination(
              icon: Icons.support_agent_outlined,
              label: 'Support',
              onTap: onOpenSupport,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: updating ? null : onSignOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
            const SizedBox(height: 28),
            Text(
              'Destructive actions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            _AccountDestination(
              icon: Icons.person_off_outlined,
              label: 'Delete account',
              supportingText:
                  'Permanently erase your account and associated data.',
              onTap: onOpenDeleteAccount,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountDestination extends StatelessWidget {
  const _AccountDestination({
    required this.icon,
    required this.label,
    required this.onTap,
    this.supportingText,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String? supportingText;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      minVerticalPadding: 12,
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: supportingText == null ? null : Text(supportingText!),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _AccountProgressScreen extends StatelessWidget {
  const _AccountProgressScreen();

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: 'Checking account session',
      child: const CircularProgressIndicator(),
    ),
  );
}

class _OfflineAccountScreen extends StatelessWidget {
  const _OfflineAccountScreen({
    required this.onRetry,
    required this.onSignOut,
    required this.onOpenLibrary,
    required this.onOpenSettings,
  });

  final VoidCallback onRetry;
  final VoidCallback onSignOut;
  final VoidCallback? onOpenLibrary;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) => _AccountMessageScreen(
    icon: Icons.cloud_off_outlined,
    title: 'Account status is offline',
    message:
        'Pakperk could not verify this saved session. Public reading remains '
        'available and the account has not been signed out.',
    primaryLabel: 'Try again',
    onPrimary: onRetry,
    secondary: [
      if (onOpenLibrary != null)
        TextButton.icon(
          key: const ValueKey('offline-account-to-read'),
          onPressed: onOpenLibrary,
          icon: const Icon(Icons.bookmarks_outlined),
          label: const Text('Open cached To Read'),
        ),
      TextButton(onPressed: onOpenSettings, child: const Text('Settings')),
      TextButton(onPressed: onSignOut, child: const Text('Sign out')),
    ],
  );
}

class _AccountLoadFailureScreen extends StatelessWidget {
  const _AccountLoadFailureScreen({
    required this.message,
    required this.onRetry,
    required this.onSignOut,
    required this.onDeleteAccount,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;
  final VoidCallback onDeleteAccount;

  @override
  Widget build(BuildContext context) => _AccountMessageScreen(
    icon: Icons.person_outline,
    title: 'Account details unavailable',
    message: message,
    primaryLabel: 'Retry',
    onPrimary: onRetry,
    secondary: [
      TextButton(
        onPressed: onDeleteAccount,
        child: const Text('Delete account'),
      ),
      TextButton(onPressed: onSignOut, child: const Text('Sign out')),
    ],
  );
}

class _ReadOnlyAccountScreen extends StatelessWidget {
  const _ReadOnlyAccountScreen({
    required this.status,
    required this.onRetry,
    required this.onOpenLibrary,
    required this.onOpenSettings,
    required this.onOpenSupport,
    required this.onDeleteAccount,
    required this.onSignOut,
  });

  final AccountStatus status;
  final VoidCallback onRetry;
  final VoidCallback? onOpenLibrary;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenSupport;
  final VoidCallback? onDeleteAccount;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => _AccountMessageScreen(
    icon: Icons.lock_person_outlined,
    title: _statusLabel(status),
    message: switch (status) {
      AccountStatus.suspended =>
        'This account is read-only. Published paper discussions and cached '
            'saved papers remain available, but account changes are disabled.',
      AccountStatus.deletionPending =>
        'Account deletion is pending. Account-owned changes are disabled '
            'while public reading remains available.',
      AccountStatus.deleted =>
        'This account is deleted. Public reading remains available.',
      AccountStatus.active => 'This account is temporarily read-only.',
    },
    primaryLabel: 'Retry account status',
    onPrimary: onRetry,
    secondary: [
      if (onOpenLibrary != null)
        TextButton.icon(
          key: const ValueKey('read-only-account-to-read'),
          onPressed: onOpenLibrary,
          icon: const Icon(Icons.bookmarks_outlined),
          label: const Text('Open cached To Read'),
        ),
      TextButton(onPressed: onOpenSettings, child: const Text('Settings')),
      TextButton(onPressed: onOpenSupport, child: const Text('Support')),
      if (onDeleteAccount != null)
        TextButton.icon(
          key: const ValueKey('read-only-account-delete'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: onDeleteAccount,
          icon: const Icon(Icons.person_off_outlined),
          label: const Text('Delete account'),
        ),
      TextButton(onPressed: onSignOut, child: const Text('Sign out')),
    ],
  );
}

class _DeletionPendingAccountScreen extends StatelessWidget {
  const _DeletionPendingAccountScreen({
    required this.onOpenStatus,
    required this.onOpenSupport,
  });

  final VoidCallback onOpenStatus;
  final VoidCallback onOpenSupport;

  @override
  Widget build(BuildContext context) => _AccountMessageScreen(
    icon: Icons.person_off_outlined,
    title: 'Account deletion pending',
    message:
        'This account is disabled. Secure credentials and private local data '
        'are being removed; public reading remains available.',
    primaryLabel: 'View deletion status',
    onPrimary: onOpenStatus,
    secondary: [
      TextButton(onPressed: onOpenSupport, child: const Text('Support')),
    ],
  );
}

class _AccountMessageScreen extends StatelessWidget {
  const _AccountMessageScreen({
    required this.icon,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final List<Widget> secondary;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
            Wrap(alignment: WrapAlignment.center, children: secondary),
          ],
        ),
      ),
    ),
  );
}

Future<void> _signOut(WidgetRef ref) async {
  await ref.read(authSessionProvider.notifier).signOut();
  ref.read(currentAccountProvider.notifier).clear();
  ref.read(pendingAuthenticatedActionProvider.notifier).clear();
}

Future<void> _editDisplayName(
  BuildContext context,
  WidgetRef ref,
  AccountProfile profile,
) async {
  final controller = TextEditingController(text: profile.displayName ?? '');
  final submitted = await showDialog<String?>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Edit display name'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Display name',
          helperText: 'Optional. Leave blank to remove it.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (submitted == null || !context.mounted) return;
  final normalized = submitted.trim();
  if (normalized == (profile.displayName ?? '')) return;
  await ref
      .read(currentAccountProvider.notifier)
      .update(
        AccountProfilePatch(
          displayName: normalized.isEmpty
              ? const ProfileField.clear()
              : ProfileField.value(normalized),
        ),
      );
}

String _initials(AccountProfile profile) {
  final source = profile.displayName ?? profile.handle ?? 'P';
  final words = source
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .take(2);
  final value = words.map((word) => word.characters.first).join().toUpperCase();
  return value.isEmpty ? 'P' : value;
}

String _statusLabel(AccountStatus status) => switch (status) {
  AccountStatus.active => 'Active account',
  AccountStatus.suspended => 'Account suspended',
  AccountStatus.deletionPending => 'Account deletion pending',
  AccountStatus.deleted => 'Account deleted',
};

String _librarySummary(int? count, int pending) {
  final base = count == null
      ? 'Loading saved papers…'
      : '$count saved ${count == 1 ? 'paper' : 'papers'}';
  return pending == 0 ? base : '$base · $pending waiting to sync';
}
