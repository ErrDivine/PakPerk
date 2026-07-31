import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/account_providers.dart';
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
        onSignIn: null,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
      );
    }

    final auth = ref.watch(authSessionProvider);
    return switch (auth.phase) {
      AuthSessionPhase.guest || AuthSessionPhase.unavailable => GuestYouScreen(
        onSignIn: onSignIn,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
      ),
      AuthSessionPhase.offlineAuthUnknown => _OfflineAccountScreen(
        onRetry: () =>
            unawaited(ref.read(authSessionProvider.notifier).restoreSession()),
        onSignOut: () => _signOut(ref),
        onOpenSettings: onOpenSettings,
      ),
      AuthSessionPhase.authenticated => _AuthenticatedAccountLoader(
        onCompleteProfile: onCompleteProfile,
        onOpenLibrary: onOpenLibrary,
        onOpenComments: onOpenComments,
        onOpenBlockedUsers: onOpenBlockedUsers,
        onOpenSettings: onOpenSettings,
        onOpenPrivacy: onOpenPrivacy,
        onOpenTerms: onOpenTerms,
        onOpenCommunityGuidelines: onOpenCommunityGuidelines,
        onOpenSupport: onOpenSupport,
        onOpenDeleteAccount: onOpenDeleteAccount,
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
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenCommunityGuidelines;
  final VoidCallback onOpenSupport;
  final VoidCallback onOpenDeleteAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    if (account.phase == CurrentAccountPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(currentAccountProvider.notifier).load();
      });
    }
    final profile = account.profile;
    if (profile == null) {
      if (account.phase == CurrentAccountPhase.failed) {
        return _AccountLoadFailureScreen(
          message:
              account.error?.message ??
              'Your account could not be loaded safely.',
          onRetry: () =>
              unawaited(ref.read(currentAccountProvider.notifier).load()),
          onSignOut: () => _signOut(ref),
        );
      }
      return const _AccountProgressScreen();
    }

    return AuthenticatedAccountHomeScreen(
      profile: profile,
      updateError: account.phase == CurrentAccountPhase.failed
          ? account.error?.message
          : null,
      updating: account.phase == CurrentAccountPhase.updating,
      onCompleteProfile: onCompleteProfile,
      onEditDisplayName: () => _editDisplayName(context, ref, profile),
      onOpenLibrary: onOpenLibrary,
      onOpenComments: onOpenComments,
      onOpenBlockedUsers: onOpenBlockedUsers,
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
    this.updateError,
    super.key,
  });

  final AccountProfile profile;
  final bool updating;
  final String? updateError;
  final VoidCallback onCompleteProfile;
  final VoidCallback onEditDisplayName;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenComments;
  final VoidCallback onOpenBlockedUsers;
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
            _AccountDestination(
              icon: Icons.bookmarks_outlined,
              label: 'To Read',
              supportingText: 'Sync arrives with the Phase 4 library.',
              onTap: onOpenLibrary,
            ),
            _AccountDestination(
              icon: Icons.comment_outlined,
              label: 'My comments',
              supportingText: 'Paper discussions arrive in Phase 5.',
              onTap: onOpenComments,
            ),
            _AccountDestination(
              icon: Icons.block_outlined,
              label: 'Blocked users',
              supportingText: 'Available when discussions are enabled.',
              onTap: onOpenBlockedUsers,
            ),
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
                  'End-to-end deletion is not available until Phase 6.',
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
    required this.onOpenSettings,
  });

  final VoidCallback onRetry;
  final VoidCallback onSignOut;
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
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => _AccountMessageScreen(
    icon: Icons.person_outline,
    title: 'Account details unavailable',
    message: message,
    primaryLabel: 'Retry',
    onPrimary: onRetry,
    secondary: [
      TextButton(onPressed: onSignOut, child: const Text('Sign out')),
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
