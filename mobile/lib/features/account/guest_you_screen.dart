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
    final colors = Theme.of(context).colorScheme;
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
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            const SizedBox(height: 18),
            Card(
              color: colors.primaryContainer.withValues(alpha: .58),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ExcludeSemantics(
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            accountCard.icon,
                            size: 26,
                            color: colors.onPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      accountCard.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 7),
                    Text(
                      accountCard.message,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
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
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'ON THIS DEVICE',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 7),
            _YouInsetGroup(
              children: [
                _YouDestination(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  supportingText:
                      'Appearance, motion, cache, and app information',
                  onTap: onOpenSettings,
                ),
                const _YouDivider(),
                _YouDestination(
                  icon: Icons.privacy_tip_outlined,
                  label: 'Privacy',
                  onTap: onOpenPrivacy,
                ),
                const _YouDivider(),
                _YouDestination(
                  icon: Icons.description_outlined,
                  label: 'Terms',
                  onTap: onOpenTerms,
                ),
                const _YouDivider(),
                _YouDestination(
                  icon: Icons.groups_outlined,
                  label: 'Community guidelines',
                  onTap: onOpenCommunityGuidelines,
                ),
                const _YouDivider(),
                _YouDestination(
                  icon: Icons.support_agent_outlined,
                  label: 'Support',
                  supportingText: onOpenSupport == null
                      ? 'Support contact is not configured in this build'
                      : null,
                  onTap: onOpenSupport,
                ),
                const _YouDivider(),
                const AboutListTile(
                  icon: _YouLeadingIcon(icon: Icons.info_outline),
                  applicationName: 'Pakperk',
                  applicationVersion: PakPerkBuildInfo.displayVersion,
                  applicationLegalese: 'Production v0.0 release candidate',
                ),
              ],
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
      leading: _YouLeadingIcon(icon: icon),
      title: Text(label),
      subtitle: supportingText == null ? null : Text(supportingText!),
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}

class _YouInsetGroup extends StatelessWidget {
  const _YouInsetGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _YouDivider extends StatelessWidget {
  const _YouDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: .5,
    indent: 60,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .7),
  );
}

class _YouLeadingIcon extends StatelessWidget {
  const _YouLeadingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
