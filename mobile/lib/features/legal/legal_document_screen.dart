import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/feature_flags.dart';
import '../../core/providers.dart';

enum LegalDocumentKind {
  privacy('Privacy', 'assets/legal/privacy.md', '/privacy'),
  terms('Terms', 'assets/legal/terms.md', '/terms'),
  communityGuidelines(
    'Community guidelines',
    'assets/legal/community_guidelines.md',
    '/community-guidelines',
  ),
  support('Support', 'assets/legal/support.md', '/support'),
  accountDeletion(
    'Account deletion',
    'assets/legal/account_deletion.md',
    '/account-deletion',
  ),
  openSourceLicenses(
    'Open-source licenses',
    'assets/legal/open_source_licenses.md',
    '/open-source-licenses',
  );

  const LegalDocumentKind(this.title, this.assetPath, this.publicPath);

  final String title;
  final String assetPath;
  final String publicPath;
}

typedef LegalDocumentLoader = Future<String> Function(String assetPath);

final legalDocumentLoaderProvider = Provider<LegalDocumentLoader>(
  (ref) =>
      (path) => loadBundledLegalDocument(rootBundle, path),
);

final class LegalDocumentScreen extends ConsumerWidget {
  const LegalDocumentScreen({
    required this.kind,
    required this.onClose,
    super.key,
  });

  final LegalDocumentKind kind;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appBuildConfigProvider);
    final publishedUri = switch (kind) {
      LegalDocumentKind.support => config.supportUri,
      LegalDocumentKind.accountDeletion => config.accountDeletionUri,
      _ => config.legalUri(kind.publicPath),
    };
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close ${kind.title}',
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
        title: Text(kind.title),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<String>(
          future: ref.read(legalDocumentLoaderProvider)(kind.assetPath),
          builder: (context, snapshot) => ListView(
            key: ValueKey('legal-${kind.name}'),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children: [
              if (snapshot.hasData)
                MarkdownBody(
                  key: ValueKey('legal-${kind.name}-markdown'),
                  data: snapshot.data!,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        p: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(height: 1.5),
                      ),
                  onTapLink: (_, href, _) {
                    final uri = _safeLegalLink(href, config);
                    if (uri == null) return;
                    unawaited(ref.read(externalLinkOpenerProvider).open(uri));
                  },
                )
              else if (snapshot.hasError)
                const Text(
                  'The bundled policy could not be opened. Use the published '
                  'HTTPS page below.',
                )
              else
                const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: ValueKey('legal-${kind.name}-published'),
                onPressed: () =>
                    ref.read(externalLinkOpenerProvider).open(publishedUri),
                icon: const Icon(Icons.open_in_new),
                label: Text('Open published ${kind.title.toLowerCase()}'),
              ),
              const SizedBox(height: 8),
              Text(
                publishedUri.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> loadBundledLegalDocument(AssetBundle bundle, String path) async {
  final text = await bundle.loadString(path, cache: true);
  if (text.isEmpty || text.length > 64 * 1024 || text.contains('\u0000')) {
    throw const FormatException('Invalid bundled legal document.');
  }
  return text;
}

Uri? _safeLegalLink(String? href, AppBuildConfig config) {
  if (href == null || href.isEmpty || href.length > 2048) return null;
  final parsed = Uri.tryParse(href);
  if (parsed == null) return null;
  final resolved = parsed.hasScheme
      ? parsed
      : config.publicSiteOriginUri.resolveUri(parsed);
  final loopback =
      resolved.host == 'localhost' ||
      resolved.host == '127.0.0.1' ||
      resolved.host == '::1';
  final allowedScheme =
      resolved.scheme == 'https' ||
      (config.environment == AppEnvironment.development &&
          resolved.scheme == 'http' &&
          loopback);
  if (!allowedScheme || resolved.host.isEmpty || resolved.userInfo.isNotEmpty) {
    return null;
  }
  return resolved;
}
