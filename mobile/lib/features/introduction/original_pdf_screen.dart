import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/ui.dart';

/// Render original pages on Android; no OCR or text reordering is involved.
class OriginalPdfScreen extends StatefulWidget {
  const OriginalPdfScreen({required this.uri, this.initialPage = 1, super.key});
  final Uri uri;
  final int initialPage;
  @override
  State<OriginalPdfScreen> createState() => _OriginalPdfScreenState();
}

class _OriginalPdfScreenState extends State<OriginalPdfScreen> {
  static const _channel = MethodChannel('app.pakperk/original_pdf');
  final _cancel = CancelToken();
  final _client = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );
  final _transform = TransformationController();
  String? _path;
  int _page = 1;
  int _count = 0;
  Uint8List? _image;
  bool _busy = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancel.cancel();
    _client.close(force: true);
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    File? partial;
    try {
      if (widget.uri.scheme != 'https' ||
          widget.uri.host != 'arxiv.org' ||
          !widget.uri.path.startsWith('/pdf/')) {
        throw const FormatException('Invalid PDF URL');
      }
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}/original-pdfs',
      );
      await directory.create(recursive: true);
      final key = sha256.convert(widget.uri.toString().codeUnits).toString();
      final file = File('${directory.path}/$key.pdf');
      if (!await file.exists()) {
        partial = File('${file.path}.partial');
        final response = await _client.get<ResponseBody>(
          widget.uri.toString(),
          options: Options(responseType: ResponseType.stream),
          cancelToken: _cancel,
        );
        final sink = partial.openWrite();
        var length = 0;
        try {
          await for (final chunk in response.data!.stream) {
            length += chunk.length;
            if (length > 64 * 1024 * 1024) {
              throw const FormatException('PDF too large');
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        final prefix = await partial
            .openRead(0, 5)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        if (String.fromCharCodes(prefix) != '%PDF-') {
          throw const FormatException('Invalid PDF response');
        }
        await partial.rename(file.path);
        partial = null;
      }
      _path = file.path;
      _count = (await _channel.invokeMethod<int>('pageCount', {
        'path': _path,
      }))!;
      _page = widget.initialPage.clamp(1, _count);
      await _render();
    } catch (_) {
      if (partial != null && await partial.exists()) await partial.delete();
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  Future<void> _render() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final image = await _channel.invokeMethod<Uint8List>('render', {
        'path': _path,
        'page': _page - 1,
        'width': 1800,
      });
      if (!mounted) return;
      _transform.value = Matrix4.identity();
      setState(() {
        _image = image;
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const UiText('Original PDF'),
      actions: [
        IconButton(
          tooltip: uiString(context, 'Zoom out'),
          onPressed: _image == null ? null : () => _zoom(1 / 1.5),
          icon: const Icon(Icons.zoom_out),
        ),
        IconButton(
          tooltip: uiString(context, 'Zoom in'),
          onPressed: _image == null ? null : () => _zoom(1.5),
          icon: const Icon(Icons.zoom_in),
        ),
      ],
    ),
    body: _failed
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const UiText('Could not load the original PDF.'),
                TextButton(onPressed: _load, child: const UiText('Retry')),
              ],
            ),
          )
        : Stack(
            children: [
              if (_image != null)
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: 8,
                    child: Center(
                      child: Image.memory(
                        _image!,
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              if (_busy) const Center(child: CircularProgressIndicator()),
            ],
          ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: uiString(context, 'Previous page'),
              onPressed: !_busy && _page > 1
                  ? () {
                      _page--;
                      _render();
                    }
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$_page / $_count'),
                  const UiText(
                    'Pinch to zoom · drag to move',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: uiString(context, 'Next page'),
              onPressed: !_busy && _page < _count
                  ? () {
                      _page++;
                      _render();
                    }
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    ),
  );

  void _zoom(double factor) {
    final scale = (_transform.value.getMaxScaleOnAxis() * factor).clamp(
      1.0,
      8.0,
    );
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1);
  }
}
