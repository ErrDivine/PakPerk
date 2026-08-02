import 'package:flutter/material.dart';

import '../../core/build_info.dart';

class GuestYouScreen extends StatelessWidget {
  const GuestYouScreen({
    required this.onOpenSettings,
    required this.onOpenPrivacy,
    required this.onOpenTerms,
    required this.onOpenCommunityGuidelines,
    this.accountsEnabled = true,
    this.libraryEnabled = true,
    this.commentsEnabled = true,
    this.onOpenSupport,
    this.onSignIn,
    super.key,
  });

  final VoidCallback? onSignIn;
  final bool accountsEnabled;
  final bool libraryEnabled;
  final bool commentsEnabled;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;
  final VoidCallback onOpenCommunityGuidelines;
  final VoidCallback? onOpenSupport;

  @override
  Widget build(BuildContext context) {
    final accountCard = _accountCardCopy(
      accountsEnabled: accountsEnabled,
      libraryEnabled: libraryEnabled,
      commentsEnabled: commentsEnabled,
    );
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('guest-you-list'),
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Semantics(
              header: true,
              child: Text(
                'You',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(accountCard.icon, size: 40),
                    const SizedBox(height: 14),
                    Text(
                      accountCard.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(accountCard.message, textAlign: TextAlign.center),
                    if (accountsEnabled) ...[
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: onSignIn,
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in / Create account'),
                      ),
                      if (onSignIn == null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Sign in is temporarily unavailable.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'On this device',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _YouDestination(
              icon: Icons.settings_outlined,
              label: 'Settings',
              supportingText: 'Appearance, motion, cache, and app information',
              onTap: onOpenSettings,
            ),
            _YouDestination(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy',
              onTap: onOpenPrivacy,
            ),
            _YouDestination(
              icon: Icons.description_outlined,
              label: 'Terms',
              onTap: onOpenTerms,
            ),
            _YouDestination(
              icon: Icons.groups_outlined,
              label: 'Community guidelines',
              onTap: onOpenCommunityGuidelines,
            ),
            _YouDestination(
              icon: Icons.support_agent_outlined,
              label: 'Support',
              supportingText: onOpenSupport == null
                  ? 'Support contact is not configured in this build'
                  : null,
              onTap: onOpenSupport,
            ),
            const AboutListTile(
              icon: Icon(Icons.info_outline),
              applicationName: 'Pakperk',
              applicationVersion: PakPerkBuildInfo.displayVersion,
              applicationLegalese: 'Production v0.0 release candidate',
            ),
          ],
        ),
      ),
    );
  }
}

({IconData icon, String title, String message}) _accountCardCopy({
  required bool accountsEnabled,
  required bool libraryEnabled,
  required bool commentsEnabled,
}) {
  if (!accountsEnabled) {
    return (
      icon: Icons.menu_book_outlined,
      title: 'Reading works without an account',
      message:
          'Account services are not enabled in this build. Public reading '
          'and on-device settings remain available.',
    );
  }
  if (libraryEnabled && commentsEnabled) {
    return (
      icon: Icons.bookmark_outline,
      title: 'Keep your reading with you',
      message: 'Sign in to sync your To Read list and join paper discussions.',
    );
  }
  if (libraryEnabled) {
    return (
      icon: Icons.bookmark_outline,
      title: 'Keep your reading with you',
      message: 'Sign in to sync your To Read list across devices.',
    );
  }
  if (commentsEnabled) {
    return (
      icon: Icons.forum_outlined,
      title: 'Join paper discussions',
      message: 'Sign in to participate in moderated paper discussions.',
    );
  }
  return (
    icon: Icons.account_circle_outlined,
    title: 'Your Pakperk account',
    message: 'Sign in to manage your Pakperk account.',
  );
}

class _YouDestination extends StatelessWidget {
  const _YouDestination({
    required this.icon,
    required this.label,
    required this.onTap,
    this.supportingText,
  });

  final IconData icon;
  final String label;
  final String? supportingText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 12,
      leading: Icon(icon),
      title: Text(label),
      subtitle: supportingText == null ? null : Text(supportingText!),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
