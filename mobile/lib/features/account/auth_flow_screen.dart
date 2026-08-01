import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/account_providers.dart';
import '../../app/router.dart';
import '../../core/account/account.dart';
import '../../core/auth/auth.dart';
import '../../core/providers.dart';
import '../placeholders/phase_one_placeholder_screens.dart';

class AccountAuthRouteScreen extends ConsumerWidget {
  const AccountAuthRouteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(featureFlagsProvider).accounts) {
      return PhaseOnePlaceholderScreen(
        title: 'Accounts are not enabled',
        message:
            'Sign in and account creation are disabled in this build. No '
            'credentials are collected by this screen.',
        icon: Icons.lock_outline,
        closeTooltip: 'Close account sign in',
        onClose: () => closePakPerkRootRoute(context),
      );
    }
    return const AuthFlowScreen();
  }
}

class AuthFlowScreen extends ConsumerStatefulWidget {
  const AuthFlowScreen({super.key});

  @override
  ConsumerState<AuthFlowScreen> createState() => _AuthFlowScreenState();
}

class _AuthFlowScreenState extends ConsumerState<AuthFlowScreen> {
  final _formKey = GlobalKey<FormState>();
  final _handle = TextEditingController();
  final _displayName = TextEditingController();
  bool _running = false;
  bool _termsAccepted = false;
  bool _guidelinesAccepted = false;
  String? _safeError;
  String? _initializedProfileId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _handle.dispose();
    _displayName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final profile = account.profile;
    final pending = ref.watch(pendingAuthenticatedActionProvider);
    if (profile != null && _initializedProfileId != profile.id) {
      _initializedProfileId = profile.id;
      _handle.text = profile.handle ?? '';
      _displayName.text = profile.displayName ?? '';
      _termsAccepted = profile.termsCurrent;
      _guidelinesAccepted = profile.communityGuidelinesCurrent;
    }

    final requiresCommunity = _requiresCommunityPolicy(pending?.kind);
    final bypassesPublicProfile = _bypassesPublicProfile(pending?.kind);
    final needsSetup =
        profile != null &&
        profile.isActive &&
        (profile.handle == null ||
            !profile.termsCurrent ||
            (requiresCommunity && !profile.communityGuidelinesCurrent)) &&
        !bypassesPublicProfile;
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(pendingAuthenticatedActionProvider.notifier).clear();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close account sign in',
            onPressed: _running ? null : _cancelAndClose,
            icon: const Icon(Icons.close),
          ),
          title: Text(needsSetup ? 'Finish account setup' : 'Sign in'),
        ),
        body: SafeArea(
          top: false,
          child: needsSetup
              ? _buildOnboarding(profile)
              : _buildProgressOrFailure(account),
        ),
      ),
    );
  }

  Widget _buildProgressOrFailure(CurrentAccountState account) {
    final error = _safeError ?? account.error?.message;
    if (error == null) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: 'Opening secure system sign in',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    final pendingKind = ref.watch(pendingAuthenticatedActionProvider)?.kind;
    final saveFailed = pendingKind == AppPendingActionKind.savePaper;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              saveFailed
                  ? Icons.bookmark_add_outlined
                  : Icons.lock_clock_outlined,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              saveFailed
                  ? 'Save could not be completed'
                  : 'Account service unavailable',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _running ? null : _begin,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            TextButton(onPressed: _cancelAndClose, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  Widget _buildOnboarding(AccountProfile profile) {
    final account = ref.watch(currentAccountProvider);
    final busy = _running || account.phase == CurrentAccountPhase.updating;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Choose how you appear in paper discussions.',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Your handle is public and must be unique. Your display name is '
            'optional and can be changed later.',
          ),
          const SizedBox(height: 24),
          TextFormField(
            key: const ValueKey('account-handle-field'),
            controller: _handle,
            enabled: !busy && profile.handle == null,
            maxLength: 30,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Handle',
              prefixText: '@',
              helperText: '3–30 characters. This is your public identifier.',
            ),
            validator: (value) {
              final normalized = value?.trim() ?? '';
              if (normalized.length < 3 || normalized.length > 30) {
                return 'Enter a handle between 3 and 30 characters.';
              }
              return null;
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: const ValueKey('account-display-name-field'),
            controller: _displayName,
            enabled: !busy,
            maxLength: 80,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Display name (optional)',
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('account-terms-checkbox'),
            value: _termsAccepted,
            onChanged: busy
                ? null
                : (value) => setState(() => _termsAccepted = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text(
              'I accept terms version ${profile.currentTermsVersion}.',
            ),
            subtitle: const Text('Required to complete your public profile.'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy
                  ? null
                  : () => context.push<void>(PakPerkRoutes.terms),
              child: const Text('Read the terms'),
            ),
          ),
          if (_requiresCommunityPolicy(
            ref.watch(pendingAuthenticatedActionProvider)?.kind,
          )) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const ValueKey('account-community-checkbox'),
              value: _guidelinesAccepted,
              onChanged: busy
                  ? null
                  : (value) =>
                        setState(() => _guidelinesAccepted = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(
                'I accept Community Guidelines version '
                '${profile.currentCommunityGuidelinesVersion}.',
              ),
              subtitle: const Text(
                'Comments are public. Harassment, threats, illegal content, '
                'doxxing, sexual exploitation, spam, impersonation, and '
                'copyright abuse are prohibited.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                'Support/moderation contact: '
                '${ref.watch(appBuildConfigProvider).supportUri}',
                key: const ValueKey('account-community-support-contact'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => context.push<void>(
                          PakPerkRoutes.communityGuidelines,
                        ),
                  child: const Text('Read the Community Guidelines'),
                ),
                TextButton(
                  key: const ValueKey('account-community-support'),
                  onPressed: busy
                      ? null
                      : () => context.push<void>(PakPerkRoutes.support),
                  child: const Text('Contact support or moderation'),
                ),
              ],
            ),
          ],
          if (_safeError ?? account.error?.message case final message?) ...[
            const SizedBox(height: 8),
            Text(
              message,
              key: const ValueKey('account-onboarding-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            onPressed: busy ? null : () => _submit(profile),
            child: busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Complete account setup'),
          ),
        ],
      ),
    );
  }

  Future<void> _begin() async {
    if (!mounted || _running) return;
    setState(() {
      _running = true;
      _safeError = null;
    });
    final auth = ref.read(authSessionProvider);
    var signedIn = auth.isAuthenticated;
    if (!signedIn) {
      signedIn = await ref.read(authSessionProvider.notifier).signIn();
    }
    if (!mounted) return;
    if (!signedIn) {
      final next = ref.read(authSessionProvider);
      if (next.phase == AuthSessionPhase.guest && next.failure == null) {
        ref.read(pendingAuthenticatedActionProvider.notifier).clear();
        _close();
        return;
      }
      setState(() {
        _running = false;
        _safeError = 'Secure sign in could not be completed. Please try again.';
      });
      return;
    }

    final existing = ref.read(currentAccountProvider).profile;
    final profile =
        existing ?? await ref.read(currentAccountProvider.notifier).load();
    if (!mounted) return;
    if (profile == null) {
      setState(() {
        _running = false;
        _safeError =
            ref.read(currentAccountProvider).error?.message ??
            'Your Pakperk account could not be loaded.';
      });
      return;
    }
    if (!profile.isActive) {
      ref.read(pendingAuthenticatedActionProvider.notifier).clear();
      _close();
      return;
    }
    // Saving is account-owned but is intentionally not gated on a public
    // handle or terms acceptance. Resume it as soon as JIT provisioning has
    // returned an active `/v1/me`; comment/moderation actions still continue
    // through onboarding below.
    final pending = ref.read(pendingAuthenticatedActionProvider);
    if (_bypassesPublicProfile(pending?.kind)) {
      await _resumePendingAndClose();
      return;
    }
    final requiresCommunity = _requiresCommunityPolicy(pending?.kind);
    if (profile.isProfileComplete &&
        (!requiresCommunity || profile.communityGuidelinesCurrent)) {
      await _resumePendingAndClose();
      return;
    }
    setState(() => _running = false);
  }

  Future<void> _submit(AccountProfile profile) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_termsAccepted) {
      setState(() => _safeError = 'Accept the current terms to continue.');
      return;
    }
    final requiresCommunity = _requiresCommunityPolicy(
      ref.read(pendingAuthenticatedActionProvider)?.kind,
    );
    if (requiresCommunity && !_guidelinesAccepted) {
      setState(
        () =>
            _safeError = 'Accept the current Community Guidelines to continue.',
      );
      return;
    }
    setState(() {
      _running = true;
      _safeError = null;
    });
    final display = _displayName.text.trim();
    final originalDisplay = profile.displayName ?? '';
    final updated = await ref
        .read(currentAccountProvider.notifier)
        .update(
          AccountProfilePatch(
            handle: profile.handle == null ? _handle.text.trim() : null,
            displayName: display == originalDisplay
                ? const ProfileField.omitted()
                : display.isEmpty
                ? const ProfileField.clear()
                : ProfileField.value(display),
            acceptTermsVersion: profile.termsCurrent
                ? null
                : profile.currentTermsVersion,
            acceptCommunityGuidelinesVersion:
                !requiresCommunity || profile.communityGuidelinesCurrent
                ? null
                : profile.currentCommunityGuidelinesVersion,
          ),
        );
    if (!mounted) return;
    if (updated == null ||
        !updated.isActive ||
        updated.handle == null ||
        !updated.termsCurrent ||
        (requiresCommunity && !updated.communityGuidelinesCurrent)) {
      setState(() {
        _running = false;
        _safeError =
            ref.read(currentAccountProvider).error?.message ??
            'Account setup could not be completed.';
      });
      return;
    }
    await _resumePendingAndClose();
  }

  Future<void> _resumePendingAndClose() async {
    final pendingController = ref.read(
      pendingAuthenticatedActionProvider.notifier,
    );
    final pending = pendingController.take();
    if (pending == null) {
      _close();
      return;
    }
    final executor = ref.read(pendingAuthenticatedActionExecutorProvider);
    try {
      await executor(pending);
    } on Object {
      pendingController.restoreIfEmpty(pending);
      if (mounted) {
        setState(() {
          _running = false;
          _safeError = _pendingFailureMessage(pending.kind);
        });
      }
      return;
    }
    if (mounted) _close();
  }

  void _cancelAndClose() {
    ref.read(pendingAuthenticatedActionProvider.notifier).clear();
    _close();
  }

  void _close() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(PakPerkRoutes.you);
    }
  }
}

bool _requiresCommunityPolicy(AppPendingActionKind? kind) => switch (kind) {
  AppPendingActionKind.openComposer => true,
  AppPendingActionKind.savePaper ||
  AppPendingActionKind.reportComment ||
  AppPendingActionKind.blockUser ||
  null => false,
};

bool _bypassesPublicProfile(AppPendingActionKind? kind) => switch (kind) {
  AppPendingActionKind.savePaper ||
  AppPendingActionKind.reportComment ||
  AppPendingActionKind.blockUser => true,
  AppPendingActionKind.openComposer || null => false,
};

String _pendingFailureMessage(AppPendingActionKind kind) => switch (kind) {
  AppPendingActionKind.savePaper =>
    'You are signed in, but this paper was not saved. Try again.',
  AppPendingActionKind.openComposer =>
    'Signed in, but the comment composer could not be opened. Try again.',
  AppPendingActionKind.reportComment =>
    'Signed in, but the report could not be opened. Try again.',
  AppPendingActionKind.blockUser =>
    'Signed in, but this user could not be blocked. Try again.',
};
