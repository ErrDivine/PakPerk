import 'package:flutter/material.dart';
import '../../core/library/library_models.dart';

/// Reports pending local changes without initiating remote writes.
class LibrarySyncStatusButton extends StatelessWidget {
  const LibrarySyncStatusButton({
    required this.pendingCount,
    this.issue,
    super.key,
  });
  final int pendingCount;
  final LibrarySyncIssue? issue;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('library-sync-status'),
    tooltip: '$pendingCount library changes waiting to sync',
    icon: Badge(
      label: Text('$pendingCount'),
      child: const Icon(Icons.cloud_upload_outlined),
    ),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync status'),
        content: Text(
          '$pendingCount library changes waiting to sync. '
          'Your changes are saved on this device. '
          'They have not yet synced to your account on the server.'
          '${issue == null ? '' : '\n\n${issue!.message}'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}
