import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/models/chat.dart';
import 'package:pakperk/features/chat/chat_sheet.dart';

void main() {
  test('chat markdown sanitizer removes active remote content', () {
    final sanitized = sanitizeChatMarkdown(
      '<script>alert(1)</script> '
      '![tracking](https://example.com/pixel.png) '
      '[unsafe](javascript:alert(1)) '
      '[data](data:text/html,bad)',
    );

    expect(sanitized, isNot(contains('<script>')));
    expect(sanitized, isNot(contains('https://example.com/pixel.png')));
    expect(sanitized.toLowerCase(), isNot(contains('javascript:')));
    expect(sanitized.toLowerCase(), isNot(contains('data:')));
    expect(sanitized, contains('[remote image omitted]'));
  });

  testWidgets('assistant answer renders compact source badges', (tester) async {
    final message = ChatMessage(
      id: 'message-1',
      role: ChatRole.assistant,
      content: 'The model uses **self-attention**.',
      createdAt: DateTime.utc(2026, 7, 29),
      evidence: const [
        ChatEvidence(
          sectionKind: 'method',
          sectionHeading: '3 Method',
          pageStart: 4,
          pageEnd: 6,
          chunkId: 'chunk-1',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: PaperChatSheet(
              state: ChatStateView(
                messages: [message],
                restoring: false,
                sending: false,
              ),
              enabled: true,
              onClose: () {},
              onSend: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('3 Method, pp. 4–6'), findsOneWidget);
  });
}
