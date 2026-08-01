import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/build_info.dart';

class PhaseOnePlaceholderScreen extends StatelessWidget {
  const PhaseOnePlaceholderScreen({
    required this.title,
    required this.message,
    required this.icon,
    this.onClose,
    this.closeTooltip = 'Back',
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: onClose == null
            ? null
            : IconButton(
                tooltip: closeTooltip,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 52),
                  const SizedBox(height: 18),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PublicSettingsScreen extends StatelessWidget {
  const PublicSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('public-settings-list'),
          children: [
            const ListTile(
              leading: Icon(Icons.contrast_outlined),
              title: Text('Appearance'),
              subtitle: Text('Follows the device light or dark setting'),
            ),
            const ListTile(
              leading: Icon(Icons.motion_photos_off_outlined),
              title: Text('Reduced motion'),
              subtitle: Text('Follows the device accessibility setting'),
            ),
            const ListTile(
              leading: Icon(Icons.storage_outlined),
              title: Text('Cache'),
              subtitle: Text(
                'Detailed cache controls arrive with the production cache',
              ),
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
}
