import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/appearance_controller.dart';
import '../../app/account_providers.dart';
import '../../app/discovery_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/build_info.dart';
import '../../core/cache/feed_cache_persistence.dart';
import '../../core/providers.dart';
import '../../core/research/research_api.dart';
import '../../core/settings/appearance.dart';
import '../feed/feed_controller.dart';
import '../paper_reader/reader_navigation_controller.dart';

class PublicSettingsScreen extends ConsumerStatefulWidget {
  const PublicSettingsScreen({
    this.onOpenDeleteAccount,
    this.onOpenResearchProfile,
    this.onOpenReadingUpdates,
    this.researchExportLoader,
    super.key,
  });

  final VoidCallback? onOpenDeleteAccount;
  final VoidCallback? onOpenResearchProfile;
  final VoidCallback? onOpenReadingUpdates;
  final Future<ResearchExportArtifact> Function(
    int expectedAuthEpoch,
    String? cursor,
  )?
  researchExportLoader;

  @override
  ConsumerState<PublicSettingsScreen> createState() =>
      _PublicSettingsScreenState();
}

class _PublicSettingsScreenState extends ConsumerState<PublicSettingsScreen> {
  FeedCacheUsage? _usage;
  bool _measuring = true;
  bool _clearing = false;
  bool _clearingAll = false;
  bool _exportingResearch = false;
  bool _measureFailed = false;
  RequestCancellation? _researchExportRequest;

  bool get _busy => _clearing || _clearingAll || _exportingResearch;

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
  void dispose() {
    _researchExportRequest?.cancel('Settings closed.');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final features = ref.watch(featureFlagsProvider);
    final accountsEnabled = features.accounts;
    final canOpenDeleteAccount =
        accountsEnabled &&
        ref.watch(
          authSessionProvider.select(
            (session) => session.mayHaveRecoverableCredentials,
          ),
        );
    final canOpenResearchProfile =
        ref.watch(
          featureFlagsProvider.select(
            (features) => features.researchProfilesEnabled,
          ),
        ) &&
        ref.watch(verifiedDiscoveryAccountScopeProvider) != null;
    final canOpenReadingUpdates =
        ref.watch(
          featureFlagsProvider.select(
            (features) =>
                features.readingBriefsEnabled ||
                features.subscriptionsEnabled ||
                features.notificationsEnabled,
          ),
        ) &&
        ref.watch(verifiedDiscoveryAccountScopeProvider) != null;
    final researchExportScope = ref.watch(verifiedLibraryScopeProvider);
    final canExportResearch =
        accountsEnabled &&
        features.deepReader &&
        (features.annotations || features.assistantV2) &&
        researchExportScope != null;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('public-settings-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const _SettingsSectionLabel('DISPLAY'),
            _SettingsGroup(
              children: [
                ListTile(
                  key: const ValueKey<String>('appearance-setting'),
                  enabled: !_busy,
                  leading: _SettingsIcon(
                    icon: Icons.contrast_outlined,
                    color: colors.primary,
                  ),
                  title: const Text('Appearance'),
                  subtitle: Text(ref.watch(appearanceControllerProvider).label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _chooseAppearance,
                ),
                _SettingsDivider(color: colors.outlineVariant),
                const ListTile(
                  leading: _SettingsIcon(
                    icon: Icons.motion_photos_off_outlined,
                  ),
                  title: Text('Reduced motion'),
                  subtitle: Text('Follows the device accessibility setting'),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const _SettingsSectionLabel('READING DATA'),
            _SettingsGroup(
              children: [
                ListTile(
                  key: const ValueKey<String>('reading-cache-usage'),
                  leading: _SettingsIcon(
                    icon: Icons.storage_outlined,
                    color: colors.primary,
                  ),
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
                _SettingsDivider(color: colors.outlineVariant),
                ListTile(
                  key: const ValueKey<String>('clear-reading-cache'),
                  enabled: _cacheControl != null && !_busy,
                  leading: _clearing
                      ? const _SettingsProgressIcon()
                      : _SettingsIcon(
                          icon: Icons.delete_sweep_outlined,
                          color: colors.primary,
                        ),
                  title: const Text('Clear reading cache'),
                  subtitle: const Text(
                    'Remove rebuildable feeds and reading data. Saves, drafts, '
                    'pending sync, account data, and reading position stay.',
                  ),
                  onTap: _confirmAndClear,
                ),
                _SettingsDivider(color: colors.outlineVariant),
                ListTile(
                  key: const ValueKey<String>('clear-all-local-data'),
                  enabled: !_busy,
                  leading: _clearingAll
                      ? _SettingsProgressIcon(color: colors.error)
                      : _SettingsIcon(
                          icon: Icons.delete_forever_outlined,
                          color: colors.error,
                        ),
                  title: Text(
                    'Clear all data',
                    style: TextStyle(color: colors.error),
                  ),
                  subtitle: const Text(
                    'Sign out and remove every local paper, save, draft, pending '
                    'change, setting, and reading position from this device.',
                  ),
                  onTap: _busy ? null : _confirmAndClearAll,
                ),
              ],
            ),
            if (canOpenDeleteAccount ||
                canOpenResearchProfile ||
                canOpenReadingUpdates ||
                canExportResearch) ...[
              const SizedBox(height: 22),
              const _SettingsSectionLabel('ACCOUNT'),
              _SettingsGroup(
                children: [
                  if (canOpenReadingUpdates)
                    ListTile(
                      key: const ValueKey<String>('reading-updates-setting'),
                      enabled: !_busy,
                      leading: _SettingsIcon(
                        icon: Icons.menu_book_outlined,
                        color: colors.primary,
                      ),
                      title: const Text('Reading updates'),
                      subtitle: const Text(
                        'Briefs, subscriptions, and in-app notifications',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : widget.onOpenReadingUpdates ??
                                () => context.push(
                                  PakPerkRoutes.youReadingUpdates,
                                ),
                    ),
                  if (canOpenReadingUpdates && canOpenResearchProfile)
                    _SettingsDivider(color: colors.outlineVariant),
                  if (canOpenResearchProfile)
                    ListTile(
                      key: const ValueKey<String>('research-profile-setting'),
                      enabled: !_busy,
                      leading: _SettingsIcon(
                        icon: Icons.psychology_alt_outlined,
                        color: colors.primary,
                      ),
                      title: const Text('Research profile'),
                      subtitle: const Text(
                        'Discovery settings and separated interest signals',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : widget.onOpenResearchProfile ??
                                () => context.push(
                                  PakPerkRoutes.youResearchProfile,
                                ),
                    ),
                  if ((canOpenResearchProfile || canOpenReadingUpdates) &&
                      canExportResearch)
                    _SettingsDivider(color: colors.outlineVariant),
                  if (canExportResearch)
                    ListTile(
                      key: const ValueKey<String>(
                        'research-data-export-setting',
                      ),
                      enabled: !_busy,
                      leading: _exportingResearch
                          ? const _SettingsProgressIcon()
                          : _SettingsIcon(
                              icon: Icons.ios_share_outlined,
                              color: colors.primary,
                            ),
                      title: const Text('Export research data'),
                      subtitle: const Text(
                        'Copy bounded JSON parts containing your private Assistant '
                        'history, provenance, and research artifacts. Complete '
                        'paper text is excluded; save each part before continuing.',
                      ),
                      onTap: _busy ? null : _copyResearchExport,
                    ),
                  if ((canOpenResearchProfile ||
                          canOpenReadingUpdates ||
                          canExportResearch) &&
                      canOpenDeleteAccount)
                    _SettingsDivider(color: colors.outlineVariant),
                  if (canOpenDeleteAccount)
                    ListTile(
                      key: const ValueKey<String>('delete-account-setting'),
                      enabled: !_busy,
                      leading: _SettingsIcon(
                        icon: Icons.person_off_outlined,
                        color: colors.error,
                      ),
                      title: Text(
                        'Delete account',
                        style: TextStyle(color: colors.error),
                      ),
                      subtitle: const Text(
                        'Permanently erase your Pakperk account and associated data.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : widget.onOpenDeleteAccount ??
                                () => context.push(
                                  PakPerkRoutes.youAccountDelete,
                                ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 22),
            const _SettingsSectionLabel('ABOUT'),
            _SettingsGroup(
              children: [
                const ListTile(
                  leading: _SettingsIcon(icon: Icons.info_outline),
                  title: Text('Version'),
                  subtitle: Text(PakPerkBuildInfo.displayVersion),
                ),
                _SettingsDivider(color: colors.outlineVariant),
                ListTile(
                  leading: const _SettingsIcon(icon: Icons.balance_outlined),
                  title: const Text('Open-source licenses'),
                  subtitle: const Text('Packages and license notices'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(PakPerkRoutes.openSourceLicenses),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyResearchExport({String? cursor}) async {
    final scope = ref.read(verifiedLibraryScopeProvider);
    final features = ref.read(featureFlagsProvider);
    if (scope == null ||
        !features.accounts ||
        !features.deepReader ||
        (!features.annotations && !features.assistantV2)) {
      return;
    }
    final request = RequestCancellation();
    _researchExportRequest?.cancel(
      'A newer research export replaced this one.',
    );
    _researchExportRequest = request;
    setState(() => _exportingResearch = true);
    try {
      final loader = widget.researchExportLoader;
      final artifact = loader != null
          ? await loader(scope.authEpoch, cursor)
          : await ResearchApi(ref.read(pakPerkDioProvider)).exportResearch(
              format: ResearchExportFormat.json,
              expectedAuthEpoch: scope.authEpoch,
              cursor: cursor,
              cancellation: request,
            );
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope) {
        return;
      }
      final text = utf8.decode(artifact.bytes, allowMalformed: false);
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope) {
        return;
      }
      try {
        await HapticFeedback.lightImpact();
      } on Object {
        // Optional confirmation only after the private export reaches the
        // clipboard. Its absence must not turn a completed export into an
        // error.
      }
      if (!mounted ||
          request.isCancelled ||
          ref.read(verifiedLibraryScopeProvider) != scope) {
        return;
      }
      final nextCursor = artifact.nextCursor;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            artifact.pageNumber == 1 && artifact.isComplete
                ? '${artifact.fileName} copied.'
                : artifact.isComplete
                ? '${artifact.fileName} part ${artifact.pageNumber} copied. Export complete.'
                : '${artifact.fileName} part ${artifact.pageNumber} copied.',
          ),
          action: nextCursor == null
              ? null
              : SnackBarAction(
                  label: 'Next part',
                  onPressed: () =>
                      unawaited(_copyResearchExport(cursor: nextCursor)),
                ),
        ),
      );
    } on ApiException catch (error) {
      if (!mounted || request.isCancelled) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      if (!mounted || request.isCancelled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The bounded research export could not be copied.'),
        ),
      );
    } finally {
      if (identical(_researchExportRequest, request)) {
        _researchExportRequest = null;
        if (mounted) setState(() => _exportingResearch = false);
      }
    }
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
    final selected = await showModalBottomSheet<AppAppearance>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(
                'Appearance',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (
                    var index = 0;
                    index < AppAppearance.values.length;
                    index += 1
                  ) ...[
                    if (index > 0)
                      Divider(
                        height: 1,
                        indent: 16,
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.outlineVariant,
                      ),
                    ListTile(
                      title: Text(AppAppearance.values[index].label),
                      trailing: AppAppearance.values[index] == current
                          ? Icon(
                              Icons.check,
                              color: Theme.of(sheetContext).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(AppAppearance.values[index]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: .5,
    indent: 56,
    color: color.withValues(alpha: .7),
  );
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: resolved),
    );
  }
}

class _SettingsProgressIcon extends StatelessWidget {
  const _SettingsProgressIcon({this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: resolved),
      ),
    );
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
