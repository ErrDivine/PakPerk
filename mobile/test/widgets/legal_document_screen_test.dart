import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/legal/legal_document_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled community rules contain the complete first-post disclosure',
    () async {
      final policy = await loadBundledLegalDocument(
        rootBundle,
        LegalDocumentKind.communityGuidelines.assetPath,
      );

      for (final requiredText in const [
        'comments are public',
        'sexual exploitation',
        'copyright abuse',
        '[Pakperk support and moderation](/support)',
        'Use **Report comment**',
        '**Report user**',
        'Use **Block user**',
        'does not block anyone',
      ]) {
        expect(policy, contains(requiredText));
      }
    },
  );

  test('bundled terms keep reports and blocks distinct', () async {
    final terms = await loadBundledLegalDocument(
      rootBundle,
      LegalDocumentKind.terms.assetPath,
    );

    for (final requiredText in const [
      '**Report comment**',
      '**Report user**',
      '**Block user**',
      'does not itself hide content or create a block',
    ]) {
      expect(terms, contains(requiredText));
    }
  });

  test(
    'release configs match the versions declared by bundled policies',
    () async {
      final terms = await loadBundledLegalDocument(
        rootBundle,
        LegalDocumentKind.terms.assetPath,
      );
      final guidelines = await loadBundledLegalDocument(
        rootBundle,
        LegalDocumentKind.communityGuidelines.assetPath,
      );
      expect(_publicationVersion(terms), bundledTermsDocumentVersion);
      expect(
        _publicationVersion(guidelines),
        bundledCommunityGuidelinesDocumentVersion,
      );

      for (final flavor in ['dev', 'staging', 'prod']) {
        final config =
            jsonDecode(await File('config/$flavor.json').readAsString())
                as Map<String, Object?>;
        expect(
          config['PAKPERK_TERMS_DOCUMENT_VERSION'],
          bundledTermsDocumentVersion,
          reason: flavor,
        );
        expect(
          config['PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION'],
          bundledCommunityGuidelinesDocumentVersion,
          reason: flavor,
        );
        for (final key in const [
          'PAKPERK_DEEP_READER_ENABLED',
          'PAKPERK_PAPER_PASSPORT_ENABLED',
          'PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED',
          'PAKPERK_READING_CHECKPOINTS_ENABLED',
          'PAKPERK_ANNOTATIONS_ENABLED',
          'PAKPERK_EVIDENCE_CARDS_ENABLED',
          'PAKPERK_RESEARCH_MEMORY_ENABLED',
          'PAKPERK_VERSION_DIFF_ENABLED',
          'PAKPERK_ASSISTANT_V2_ENABLED',
        ]) {
          expect(config[key], 'false', reason: '$flavor: $key');
        }
      }
    },
  );

  testWidgets('renders selectable Markdown and audits link opening', (
    tester,
  ) async {
    final links = _Links();
    await _pump(
      tester,
      loader: (_) async =>
          '# Privacy\n\n[Published details](https://docs.pakperk.app/privacy)\n\n'
          '[Unsafe](javascript:alert(1))',
      links: links,
    );

    final markdown = tester.widget<MarkdownBody>(
      find.byKey(const ValueKey('legal-privacy-markdown')),
    );
    expect(markdown.selectable, isTrue);

    await tester.tap(find.text('Published details'));
    await tester.pump();
    expect(links.opened, [Uri.parse('https://docs.pakperk.app/privacy')]);

    await tester.tap(find.text('Unsafe'));
    await tester.pump();
    expect(links.opened, hasLength(1));
  });

  testWidgets('asset failure retains the validated published fallback', (
    tester,
  ) async {
    final links = _Links();
    await _pump(
      tester,
      loader: (_) => Future<String>.error(StateError('missing asset')),
      links: links,
    );

    expect(
      find.text(
        'The bundled policy could not be opened. Use the published HTTPS '
        'page below.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('legal-privacy-published')));
    await tester.pump();
    expect(links.opened, [Uri.parse('https://public.test/privacy')]);
  });

  testWidgets(
    'a mislabeled acceptance document fails closed to the published page',
    (tester) async {
      final links = _Links();
      await _pump(
        tester,
        loader: (_) async => '# Terms\n\nPublication version: 2026-08-01.\n',
        links: links,
        kind: LegalDocumentKind.terms,
      );

      expect(find.byKey(const ValueKey('legal-terms-markdown')), findsNothing);
      expect(
        find.textContaining('bundled policy could not be opened'),
        findsOneWidget,
      );
    },
  );

  for (final environment in const [
    ('staging', 'https://staging.pakperk.app'),
    ('production', 'https://pakperk.app'),
  ]) {
    testWidgets(
      'bundled support route follows the ${environment.$1} public origin',
      (tester) async {
        final links = _Links();
        await _pump(
          tester,
          loader: (_) async =>
              '# Community guidelines\n\n'
              'Publication version: '
              '$bundledCommunityGuidelinesDocumentVersion.\n\n'
              '[Pakperk support and moderation](/support)',
          links: links,
          kind: LegalDocumentKind.communityGuidelines,
          config: _productionLikeConfig(
            environment: environment.$1,
            publicOrigin: environment.$2,
          ),
        );

        await tester.tap(find.text('Pakperk support and moderation'));
        await tester.pump();

        expect(links.opened, [Uri.parse('${environment.$2}/support')]);
      },
    );
  }
}

String _publicationVersion(String document) {
  final matches = RegExp(
    r'^Publication version: (\d{4}-\d{2}-\d{2})[.]$',
    multiLine: true,
  ).allMatches(document).toList(growable: false);
  expect(matches, hasLength(1));
  return matches.single.group(1)!;
}

Future<void> _pump(
  WidgetTester tester, {
  required LegalDocumentLoader loader,
  required _Links links,
  LegalDocumentKind kind = LegalDocumentKind.privacy,
  AppBuildConfig? config,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBuildConfigProvider.overrideWithValue(config ?? _config()),
        legalDocumentLoaderProvider.overrideWithValue(loader),
        externalLinkOpenerProvider.overrideWithValue(links),
      ],
      child: MaterialApp(
        home: LegalDocumentScreen(kind: kind, onClose: () {}),
      ),
    ),
  );
  final markdown = find.byKey(ValueKey('legal-${kind.name}-markdown'));
  final fallback = find.text(
    'The bundled policy could not be opened. Use the published HTTPS '
    'page below.',
  );
  await tester.pump();
  for (
    var attempt = 0;
    attempt < 100 && markdown.evaluate().isEmpty && fallback.evaluate().isEmpty;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    markdown.evaluate().isNotEmpty || fallback.evaluate().isNotEmpty,
    isTrue,
    reason: 'the legal document must reach a terminal load state',
  );
}

AppBuildConfig _config() => AppBuildConfig.fromValues(const {
  'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://public.test',
});

AppBuildConfig _productionLikeConfig({
  required String environment,
  required String publicOrigin,
}) => AppBuildConfig.fromValues({
  'PAKPERK_ENV': environment,
  'PAKPERK_API_BASE_URL': '$publicOrigin/api',
  'PAKPERK_FULLTEXT_POLICY': 'strict',
  'PAKPERK_PUBLIC_SITE_ORIGIN': publicOrigin,
  'PAKPERK_TELEMETRY_ENDPOINT': '$publicOrigin/v1/logs',
});

final class _Links implements ExternalLinkOpener {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}
