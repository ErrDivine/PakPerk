import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/legal/legal_document_screen.dart';

void main() {
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
}

Future<void> _pump(
  WidgetTester tester, {
  required LegalDocumentLoader loader,
  required _Links links,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBuildConfigProvider.overrideWithValue(_config()),
        legalDocumentLoaderProvider.overrideWithValue(loader),
        externalLinkOpenerProvider.overrideWithValue(links),
      ],
      child: MaterialApp(
        home: LegalDocumentScreen(
          kind: LegalDocumentKind.privacy,
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AppBuildConfig _config() => AppBuildConfig.fromValues(const {
  'PAKPERK_PUBLIC_SITE_ORIGIN': 'https://public.test',
});

final class _Links implements ExternalLinkOpener {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}
