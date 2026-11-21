import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:smart_latex/smart_latex.dart';

import '../../core/models/introduction.dart';
import '../../core/providers.dart';
import '../../l10n/ui.dart';
import '../document_reader/reader_interaction_state.dart';

class StructuredIntroductionBody extends ConsumerWidget {
  const StructuredIntroductionBody({
    required this.introduction,
    required this.readerKey,
    required this.onOpenPdf,
    this.onOpenCitation,
    super.key,
  });
  final PaperIntroduction introduction;
  final String readerKey;
  final VoidCallback onOpenPdf;
  final ValueChanged<IntroductionCitation>? onOpenCitation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget markdown(String text, {bool compact = false}) => MarkdownBody(
      data: text,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: compact
            ? Theme.of(context).textTheme.bodyMedium
            : Theme.of(context).textTheme.bodyLarge,
        a: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
      inlineSyntaxes: [_MathSyntax()],
      builders: {'latex': _MathBuilder()},
      onTapLink: (text, href, _) {
        final key = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (key.isNotEmpty &&
            (Uri.tryParse(href ?? '')?.fragment.startsWith('bib') ?? false)) {
          for (final citation in introduction.paragraphs.expand(
            (p) => p.citations,
          )) {
            final marker = citation.marker.toLowerCase().replaceAll(
              RegExp(r'[^a-z0-9]'),
              '',
            );
            if (marker.contains(key) &&
                citation.isNavigable &&
                onOpenCitation != null) {
              onOpenCitation!(citation);
              return;
            }
          }
        }
        final uri = Uri.tryParse(href ?? '');
        if (uri?.scheme == 'https' && uri?.host == 'arxiv.org') {
          ref.read(externalLinkOpenerProvider).open(uri!);
        }
      },
    );
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in introduction.sourceBlocks) ...[
          switch (block.kind) {
            'figure' => Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (block.vectorHtml != null)
                      if (Platform.isAndroid)
                        LayoutBuilder(
                          builder: (context, constraints) => SizedBox(
                            height:
                                constraints.maxWidth / block.aspectRatio + 12,
                            child: IgnorePointer(
                              child: AndroidView(
                                viewType: 'app.pakperk/figure',
                                layoutDirection: TextDirection.ltr,
                                creationParams: {
                                  'html': block.vectorHtml,
                                  'zoom': false,
                                },
                                creationParamsCodec:
                                    const StandardMessageCodec(),
                              ),
                            ),
                          ),
                        )
                      else
                        TextButton(
                          onPressed: onOpenPdf,
                          child: const UiText('View figure in original PDF'),
                        ),
                    if (block.images.isEmpty && block.vectorHtml == null)
                      TextButton(
                        onPressed: onOpenPdf,
                        child: const UiText('View figure in original PDF'),
                      ),
                    for (final uri in block.images)
                      InkWell(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => Dialog.fullscreen(
                            child: Scaffold(
                              appBar: AppBar(title: const UiText('Figure')),
                              body: InteractiveViewer(
                                minScale: 1,
                                maxScale: 8,
                                child: Center(child: Image.network(uri)),
                              ),
                            ),
                          ),
                        ),
                        child: Image.network(
                          uri,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) =>
                              progress == null
                              ? child
                              : const SizedBox(
                                  height: 140,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                          errorBuilder: (_, _, _) => TextButton.icon(
                            onPressed: onOpenPdf,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const UiText('View figure in original PDF'),
                          ),
                        ),
                      ),
                    if (block.text.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      markdown(block.text, compact: true),
                    ],
                    const SizedBox(height: 4),
                    if (block.vectorHtml != null && Platform.isAndroid)
                      TextButton.icon(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => Dialog.fullscreen(
                            child: _VectorFigurePage(html: block.vectorHtml!),
                          ),
                        ),
                        icon: const Icon(Icons.fullscreen),
                        label: const UiText('Enlarge figure'),
                      )
                    else if (block.images.isNotEmpty)
                      const UiText(
                        'Tap figure to zoom',
                        style: TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
            'table' => Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (block.text.isNotEmpty) ...[
                      markdown(block.text, compact: true),
                      const SizedBox(height: 10),
                    ],
                    if (block.rows.isNotEmpty)
                      Listener(
                        onPointerDown: (_) => ref
                            .read(
                              readerInteractionControllerProvider(
                                readerKey,
                              ).notifier,
                            )
                            .setActive(ReaderInteractionKind.tablePan, true),
                        onPointerUp: (_) => ref
                            .read(
                              readerInteractionControllerProvider(
                                readerKey,
                              ).notifier,
                            )
                            .setActive(ReaderInteractionKind.tablePan, false),
                        onPointerCancel: (_) => ref
                            .read(
                              readerInteractionControllerProvider(
                                readerKey,
                              ).notifier,
                            )
                            .setActive(ReaderInteractionKind.tablePan, false),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Table(
                            defaultColumnWidth: const FixedColumnWidth(128),
                            border: TableBorder.all(
                              color: colors.outlineVariant,
                            ),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            children: [
                              for (
                                var index = 0;
                                index < block.rows.length;
                                index++
                              )
                                TableRow(
                                  decoration: BoxDecoration(
                                    color: index == 0
                                        ? colors.surfaceContainerHighest
                                        : null,
                                  ),
                                  children: [
                                    for (final cell in block.rows[index])
                                      Padding(
                                        padding: const EdgeInsets.all(10),
                                        child: markdown(cell, compact: true),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                    const UiText(
                      'Swipe table sideways to see all columns',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            'equation' => SmartMath(
              block.text,
              display: true,
              style: Theme.of(context).textTheme.bodyLarge,
              errorBuilder: (_, content) => Text(content),
            ),
            'heading' => Text(
              block.text,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _ => markdown(block.text),
          },
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _VectorFigurePage extends StatefulWidget {
  const _VectorFigurePage({required this.html});
  final String html;
  @override
  State<_VectorFigurePage> createState() => _VectorFigurePageState();
}

class _VectorFigurePageState extends State<_VectorFigurePage> {
  MethodChannel? _channel;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const UiText('Figure'),
      leading: IconButton(
        tooltip: uiString(context, 'Close'),
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
      actions: [
        IconButton(
          tooltip: uiString(context, 'Zoom out'),
          onPressed: () => _channel?.invokeMethod<void>('zoomOut'),
          icon: const Icon(Icons.zoom_out),
        ),
        IconButton(
          tooltip: uiString(context, 'Zoom in'),
          onPressed: () => _channel?.invokeMethod<void>('zoomIn'),
          icon: const Icon(Icons.zoom_in),
        ),
      ],
    ),
    body: AndroidView(
      viewType: 'app.pakperk/figure',
      layoutDirection: TextDirection.ltr,
      creationParams: {'html': widget.html, 'zoom': true},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) =>
          _channel = MethodChannel('app.pakperk/figure/$id'),
    ),
  );
}

class _MathSyntax extends md.InlineSyntax {
  _MathSyntax() : super(r'\$([^$\n]+)\$');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('latex', match[1]!));
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text.rich(
    TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: IntrinsicWidth(
            child: SmartMath(
              element.textContent,
              style: preferredStyle ?? parentStyle,
              errorBuilder: (_, content) =>
                  Text(content, style: preferredStyle ?? parentStyle),
            ),
          ),
        ),
      ],
    ),
  );
}
