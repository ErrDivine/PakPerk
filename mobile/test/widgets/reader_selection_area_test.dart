import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/widgets/reader_selection_area.dart';

void main() {
  test(
    'prefers installed dictionary and retains native actions and callback',
    () {
      var invoked = false;
      final copy = ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () {},
      );
      final alternative = ContextMenuButtonItem(
        label: '百度翻译',
        onPressed: () {},
      );
      final dictionary = ContextMenuButtonItem(
        label: '有道词典',
        onPressed: () => invoked = true,
      );
      final result = readerSelectionMenuItems([
        copy,
        alternative,
        dictionary,
      ], translateLabel: '翻译');
      expect(result.first.label, '翻译');
      result.first.onPressed!();
      expect(invoked, isTrue);
      expect(result.skip(1), [copy, alternative]);
      expect(readerSelectionMenuItems([copy], translateLabel: '翻译'), [copy]);
    },
  );

  testWidgets(
    'pager receives touch swipes while its text still accepts touch and mouse selection',
    (tester) async {
      const first = 'Language models learn from text.';
      const second = 'Exact document selection';
      final controller = PageController();
      addTearDown(controller.dispose);
      String? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: controller,
              children: [
                ReaderSelectionArea(
                  onSelectionChanged: (content) =>
                      selection = content?.plainText,
                  child: const Center(child: Text(first)),
                ),
                ReaderPageSelectionArea(
                  onSelectionChanged: (content) =>
                      selection = content?.plainText,
                  child: const Center(child: Text(second)),
                ),
              ],
            ),
          ),
        ),
      );
      final firstStart = tester.getTopLeft(find.text(first));
      await tester.longPressAt(firstStart + const Offset(12, 8));
      await tester.pumpAndSettle();
      expect(selection, 'Language');
      expect(controller.page, 0);

      await tester.tapAt(firstStart + const Offset(120, 8));
      await tester.pumpAndSettle();
      await tester.fling(find.text(first), const Offset(-360, 0), 1200);
      await tester.pumpAndSettle();
      expect(controller.page, 1);

      final secondStart = tester.getTopLeft(find.text(second));
      final mouse = await tester.startGesture(
        secondStart + const Offset(1, 8),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(100, 0));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(selection, startsWith('Exact'));
      expect(controller.page, 1);

      await tester.fling(find.text(second), const Offset(360, 0), 1200);
      await tester.pumpAndSettle();
      expect(controller.page, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Chinese menu sends selected English text to Android translator',
    (tester) async {
      MethodCall? request;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.processText,
        (call) async {
          if (call.method == 'ProcessText.queryTextActions') {
            return {'youdao': '有道词典'};
          }
          request = call;
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.processText,
          null,
        );
      });
      final selections = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: Center(
              child: ReaderSelectionArea(
                onSelectionChanged: (content) =>
                    selections.add(content?.plainText),
                child: const Text('Language models learn from text.'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final start = tester.getTopLeft(
        find.text('Language models learn from text.'),
      );
      await tester.longPressAt(start + const Offset(15, 8));
      await tester.pumpAndSettle();
      expect(selections.last, 'Language');
      expect(find.text('翻译'), findsOneWidget);
      await tester.tap(find.text('翻译'));
      await tester.pumpAndSettle();
      expect(request?.method, 'ProcessText.processTextAction');
      expect(request?.arguments, ['youdao', 'Language', true]);
      await tester.tapAt(start + const Offset(140, 8));
      await tester.pumpAndSettle();
      expect(selections.last, isEmpty);
      await tester.longPressAt(start + const Offset(15, 8));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('翻译'));
      await tester.pumpAndSettle();
      expect(request?.arguments, [
        'youdao',
        'Language models learn from text.',
        true,
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
