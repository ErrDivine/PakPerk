import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/models/chat.dart';

class PaperChatSheet extends StatefulWidget {
  const PaperChatSheet({
    required this.state,
    required this.enabled,
    required this.onClose,
    required this.onSend,
    super.key,
  });

  final ChatStateView state;
  final bool enabled;
  final VoidCallback onClose;
  final ValueChanged<String> onSend;

  @override
  State<PaperChatSheet> createState() => _PaperChatSheetState();
}

class _PaperChatSheetState extends State<PaperChatSheet> {
  final TextEditingController _composer = TextEditingController();

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Material(
      elevation: 12,
      color: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Semantics(
                header: true,
                child: ListTile(
                  title: const Text('Ask this paper'),
                  subtitle: const Text(
                    'Answers use indexed sections from this paper only.',
                  ),
                  trailing: IconButton(
                    tooltip: 'Close paper chat',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: widget.state.restoring
                    ? const Center(child: CircularProgressIndicator())
                    : widget.state.messages.isEmpty
                    ? const _EmptyChat()
                    : ListView.separated(
                        reverse: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: widget.state.messages.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, reverseIndex) {
                          final index =
                              widget.state.messages.length - 1 - reverseIndex;
                          return _ChatBubble(
                            message: widget.state.messages[index],
                          );
                        },
                      ),
              ),
              if (widget.state.sending)
                Semantics(
                  liveRegion: true,
                  label: 'Thinking and searching the paper.',
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Expanded(child: Text('Searching later sections…')),
                      ],
                    ),
                  ),
                ),
              if (widget.state.errorMessage != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      widget.state.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              _SheetComposer(
                controller: _composer,
                enabled:
                    widget.enabled &&
                    !widget.state.restoring &&
                    !widget.state.sending,
                onSend: _send,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send() {
    final message = _composer.text.trim();
    if (message.isEmpty) return;
    _composer.clear();
    widget.onSend(message);
  }
}

class ChatStateView {
  const ChatStateView({
    required this.messages,
    required this.restoring,
    required this.sending,
    this.errorMessage,
  });

  final List<ChatMessage> messages;
  final bool restoring;
  final bool sending;
  final String? errorMessage;
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Ask about methods, results, experiments, or limitations. '
          'If the indexed evidence is insufficient, Pakperk will say so.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == ChatRole.user;
    return Semantics(
      label: '${user ? 'You' : 'Pakperk'}: ${message.content}',
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: user
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (user)
                  Text(message.content)
                else
                  MarkdownBody(
                    data: sanitizeChatMarkdown(message.content),
                    selectable: true,
                    onTapLink: (_, __, ___) {
                      // Model-authored links are intentionally inert. The only
                      // external actions in this demo use trusted arXiv URLs.
                    },
                    sizedImageBuilder: (_) => const Text(
                      '[remote image omitted]',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                if (message.insufficientEvidence) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Evidence in the indexed paper sections was limited.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
                if (message.evidence.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'SOURCES',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final source in message.evidence)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.menu_book, size: 16),
                          label: Text(source.badgeLabel),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetComposer extends StatelessWidget {
  const _SheetComposer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              maxLength: 500,
              textInputAction: TextInputAction.send,
              onSubmitted: enabled ? (_) => onSend() : null,
              decoration: const InputDecoration(
                hintText: 'Ask about this paper…',
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send question',
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

String sanitizeChatMarkdown(String value) {
  return value
      .replaceAll(
        RegExp(r'!\[[^\]]*\]\([^)]*\)', multiLine: true),
        '[remote image omitted]',
      )
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]*\)', multiLine: true),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'<[^>]*>', multiLine: true), '')
      .replaceAll(RegExp(r'(?:javascript|data):', caseSensitive: false), '');
}
