import '../../l10n/ui.dart';
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

final class LegalDocumentScreen extends ConsumerStatefulWidget {
  const LegalDocumentScreen({
    required this.kind,
    required this.onClose,
    super.key,
  });

  final LegalDocumentKind kind;
  final VoidCallback onClose;

  @override
  ConsumerState<LegalDocumentScreen> createState() =>
      _LegalDocumentScreenState();
}

final class _LegalDocumentScreenState
    extends ConsumerState<LegalDocumentScreen> {
  LegalDocumentKind? _loadedKind;
  LegalDocumentLoader? _loadedWith;
  String? _loadedVersion;
  String? _loadedLanguage;
  Future<String>? _document;

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appBuildConfigProvider);
    final language = Localizations.localeOf(context).languageCode;
    final loader = ref.watch(legalDocumentLoaderProvider);
    final expectedVersion = switch (widget.kind) {
      LegalDocumentKind.terms => config.termsDocumentVersion,
      LegalDocumentKind.communityGuidelines =>
        config.communityGuidelinesDocumentVersion,
      _ => null,
    };
    if (_loadedKind != widget.kind ||
        !identical(_loadedWith, loader) ||
        _loadedVersion != expectedVersion ||
        _loadedLanguage != language) {
      _loadedKind = widget.kind;
      _loadedWith = loader;
      _loadedVersion = expectedVersion;
      _loadedLanguage = language;
      _document = _loadVersionBoundDocument(
        loader,
        widget.kind,
        config,
        language,
      );
    }
    final publishedUri = switch (widget.kind) {
      LegalDocumentKind.support => config.supportUri,
      LegalDocumentKind.accountDeletion => config.accountDeletionUri,
      _ => config.legalUri(widget.kind.publicPath),
    };
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: uiString(context, 'Close ${widget.kind.title}'),
          onPressed: widget.onClose,
          icon: const Icon(Icons.close),
        ),
        title: UiText(widget.kind.title),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<String>(
          future: _document,
          builder: (context, snapshot) => ListView(
            key: ValueKey('legal-${widget.kind.name}'),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children: [
              if (snapshot.hasData)
                MarkdownBody(
                  key: ValueKey('legal-${widget.kind.name}-markdown'),
                  data: language == 'zh'
                      ? snapshot.data!.replaceAll(
                          'Publication version: ',
                          '发布日期：',
                        )
                      : snapshot.data!,
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
                const UiText(
                  'The bundled policy could not be opened. Use the published '
                  'HTTPS page below.',
                )
              else
                const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: ValueKey('legal-${widget.kind.name}-published'),
                onPressed: () =>
                    ref.read(externalLinkOpenerProvider).open(publishedUri),
                icon: const Icon(Icons.open_in_new),
                label: UiText(
                  'Open published ${widget.kind.title.toLowerCase()}',
                ),
              ),
              const SizedBox(height: 8),
              UiText(
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

Future<String> _loadVersionBoundDocument(
  LegalDocumentLoader loader,
  LegalDocumentKind kind,
  AppBuildConfig config,
  String language,
) async {
  final path = language == 'zh'
      ? kind.assetPath.replaceFirst('assets/legal/', 'assets/legal/zh/')
      : kind.assetPath;
  final text = await loader(path);
  final expectedVersion = switch (kind) {
    LegalDocumentKind.terms => config.termsDocumentVersion,
    LegalDocumentKind.communityGuidelines =>
      config.communityGuidelinesDocumentVersion,
    _ => null,
  };
  if (expectedVersion == null) return text;
  final marker = 'Publication version: $expectedVersion.';
  final markerCount = RegExp(
    '^${RegExp.escape(marker)}\$',
    multiLine: true,
  ).allMatches(text).length;
  if (markerCount != 1) {
    throw const FormatException(
      'Bundled legal document does not match the configured version.',
    );
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
