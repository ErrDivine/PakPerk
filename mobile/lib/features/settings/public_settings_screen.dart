import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/appearance_controller.dart';
import '../../app/account_providers.dart';
import '../../core/build_info.dart';
import '../../core/cache/feed_cache_persistence.dart';
import '../../core/providers.dart';
import '../../core/settings/appearance.dart';
import '../feed/feed_controller.dart';
import '../paper_reader/reader_navigation_controller.dart';

class PublicSettingsScreen extends ConsumerStatefulWidget {
  const PublicSettingsScreen({super.key});

  @override
  ConsumerState<PublicSettingsScreen> createState() =>
      _PublicSettingsScreenState();
}

class _PublicSettingsScreenState extends ConsumerState<PublicSettingsScreen> {
  FeedCacheUsage? _usage;
  bool _measuring = true;
  bool _clearing = false;
  bool _clearingAll = false;
  bool _measureFailed = false;

  bool get _busy => _clearing || _clearingAll;

  PublicCacheControl? get _cacheControl {
    final store = ref.read(localStoreProvider);
    return store is PublicCacheControl ? store as PublicCacheControl : null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshUsage());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('public-settings-list'),
          children: [
            ListTile(
              key: const ValueKey<String>('appearance-setting'),
              enabled: !_busy,
              leading: Icon(Icons.contrast_outlined),
              title: const Text('Appearance'),
              subtitle: Text(ref.watch(appearanceControllerProvider).label),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : _chooseAppearance,
            ),
            const ListTile(
              leading: Icon(Icons.motion_photos_off_outlined),
              title: Text('Reduced motion'),
              subtitle: Text('Follows the device accessibility setting'),
            ),
            ListTile(
              key: const ValueKey<String>('reading-cache-usage'),
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Reading cache'),
              subtitle: Text(_cacheUsageLabel),
              trailing: _measuring
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      tooltip: 'Refresh cache usage',
                      onPressed: _busy ? null : _refreshUsage,
                      icon: const Icon(Icons.refresh),
                    ),
            ),
            ListTile(
              key: const ValueKey<String>('clear-reading-cache'),
              enabled: _cacheControl != null && !_busy,
              leading: _clearing
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined),
              title: const Text('Clear reading cache'),
              subtitle: const Text(
                'Remove rebuildable feeds and reading data. Saves, drafts, '
                'pending sync, account data, and reading position stay.',
              ),
              onTap: _confirmAndClear,
            ),
            ListTile(
              key: const ValueKey<String>('clear-all-local-data'),
              enabled: !_busy,
              leading: _clearingAll
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.delete_forever_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
              title: Text(
                'Clear all data',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text(
                'Sign out and remove every local paper, save, draft, pending '
                'change, setting, and reading position from this device.',
              ),
              onTap: _busy ? null : _confirmAndClearAll,
            ),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Version'),
              subtitle: Text(PakPerkBuildInfo.displayVersion),
            ),
            ListTile(
              leading: const Icon(Icons.balance_outlined),
              title: const Text('Open-source licenses'),
              subtitle: const Text('Packages and license notices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(PakPerkRoutes.openSourceLicenses),
            ),
          ],
        ),
      ),
    );
  }

  String get _cacheUsageLabel {
    if (_measuring) return 'Measuring cached reading data…';
    final usage = _usage;
    if (usage == null) {
      return _measureFailed
          ? 'Cache usage could not be measured on this device.'
          : 'Cache controls are unavailable for this storage provider.';
    }
    final papers = usage.metadataRows == 1
        ? '1 cached paper record'
        : '${usage.metadataRows} cached paper records';
    final live = formatCacheBytes(usage.databaseBytes);
    final physical = formatCacheBytes(usage.physicalDatabaseBytes);
    if (usage.physicalDatabaseBytes <= usage.databaseBytes) {
      return '$papers · $live on device';
    }
    return '$papers · $live live, $physical allocated. Unused space is '
        'reclaimed after the app backgrounds.';
  }

  Future<void> _refreshUsage() async {
    final control = _cacheControl;
    if (control == null) {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _measuring = false;
        _measureFailed = false;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _measuring = true;
        _measureFailed = false;
      });
    }
    try {
      final usage = await control.measurePublicCache();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _measuring = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _measuring = false;
        _measureFailed = true;
      });
    }
  }

  Future<void> _chooseAppearance() async {
    final current = ref.read(appearanceControllerProvider);
    final selected = await showDialog<AppAppearance>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Appearance'),
        children: [
          for (final appearance in AppAppearance.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(appearance),
              child: Row(
                children: [
                  Icon(
                    appearance == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  Text(appearance.label),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || selected == current || !mounted) return;
    try {
      await ref
          .read(appearanceControllerProvider.notifier)
          .setAppearance(selected);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'The appearance setting could not be saved on this device.',
            ),
          ),
        );
    }
  }

  Future<void> _confirmAndClear() async {
    final control = _cacheControl;
    if (control == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear reading cache?'),
        content: const Text(
          'Downloaded feeds, generated reading views, cached discussions, '
          'and anonymous chat cache will be removed. Your account, saved '
          'papers, drafts, pending sync, and current reading position stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final result = await control.clearRebuildablePublicCache();
      if (!mounted) return;
      setState(() {
        _usage = result.after;
        _measuring = false;
        _measureFailed = false;
        _clearing = false;
      });
      final removed = result.removedMetadataRows;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              removed == 1
                  ? 'Reading cache cleared. 1 rebuildable paper was removed.'
                  : 'Reading cache cleared. $removed rebuildable papers were '
                        'removed.',
            ),
          ),
        );
    } on Object {
      if (!mounted) return;
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'The reading cache could not be cleared on this device.',
            ),
          ),
        );
    }
  }

  Future<void> _confirmAndClearAll() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all data?'),
        content: const Text(
          'This permanently removes cached papers, local saves, drafts, '
          'pending changes, reading position, appearance, and the anonymous '
          'device identity. You will be signed out. Data already synchronized '
          'to your Pakperk account is not deleted from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear all data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearingAll = true);
    var sessionSignOutIncomplete = false;
    var secureCleanupIncomplete = false;
    if (ref.read(featureFlagsProvider).accounts) {
      try {
        await ref.read(authSessionProvider.notifier).signOut();
      } on Object {
        // Continue to the provider-independent credential invalidation below.
        sessionSignOutIncomplete = true;
      }
    }
    try {
      // Feature flags can turn accounts off after a prior build stored a
      // refresh credential. The secure-store invalidation guard therefore
      // belongs to Clear all data itself, not to the current accounts flag.
      await ref.read(secureTokenStoreProvider).clear();
    } on Object {
      // FlutterSecureTokenStore attempts its independent invalidation guard
      // before deletion. Keep clearing non-secret local state and report that
      // the platform credential cleanup still needs another attempt.
      secureCleanupIncomplete = true;
    }
    try {
      final store = ref.read(localStoreProvider);
      await store.clearAllLocalData();
      await ref
          .read(appRestorationControllerProvider.notifier)
          .resetAfterLocalDataClear();
      await ref
          .read(appearanceControllerProvider.notifier)
          .resetAfterLocalDataClear();
      await ref.read(anonymousSessionIdProvider.notifier).reset();
      ref.invalidate(paperRepositoryProvider);
      ref.invalidate(feedControllerProvider);
      final control = _cacheControl;
      final usage = control == null ? null : await control.measurePublicCache();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _measuring = false;
        _measureFailed = false;
        _clearingAll = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              !sessionSignOutIncomplete && !secureCleanupIncomplete
                  ? 'All local data was cleared.'
                  : 'Local data was cleared, but secure sign-out needs '
                        'another attempt. Retry Clear all data before using '
                        'an account on this device.',
            ),
          ),
        );
    } on Object {
      if (!mounted) return;
      setState(() => _clearingAll = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'All local data could not be cleared. No server data changed; '
              'retry on this device.',
            ),
          ),
        );
    }
  }
}

String formatCacheBytes(int bytes) {
  final safe = bytes < 0 ? 0 : bytes;
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var value = safe.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  if (unit == 0) return '$safe B';
  final digits = value >= 10 ? 1 : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
