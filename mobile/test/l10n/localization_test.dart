import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/app/theme.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/settings/public_settings_screen.dart';
import 'package:pakperk/features/paper_notes/paper_notes_screen.dart';
import 'package:pakperk/features/paper_notes/paper_notes_store.dart';
import 'package:pakperk/l10n/language_controller.dart';
import 'package:pakperk/l10n/zh.dart';
import '../support/fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('Settings switches Chinese and English and retains the choice', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          featureFlagsProvider.overrideWithValue(const FeatureFlags.disabled()),
          localStoreProvider.overrideWithValue(MemoryLocalStore()),
        ],
        child: Consumer(
          builder: (context, ref, _) => MaterialApp(
            locale: ref.watch(languageControllerProvider),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: buildPakPerkTheme(),
            home: const PublicSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(find.text('设置', findRichText: true), findsOneWidget);
    expect(find.text('外观', findRichText: true), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('pakperk.language.v1'),
      'zh',
    );
    final restored = LanguageController();
    await tester.pumpAndSettle();
    expect(restored.state.languageCode, 'zh');
    restored.dispose();
    await tester.tap(find.byKey(const ValueKey('appearance-setting')));
    await tester.pumpAndSettle();
    expect(find.text('深色', findRichText: true), findsOneWidget);
    await tester.tap(find.text('深色', findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese notebook keeps English paper and UTF-8 freeform pages', (
    tester,
  ) async {
    const text = '中文研究笔记：低秩适配，效果很好。\n自由输入 English 与符号 😀。';
    final store = SharedPreferencesPaperNotesStore(paper: samplePaper);
    await store.write(
      samplePaper.arxivBaseId,
      const PaperNotes(pages: [text, '第二页：后续实验']),
    );
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: buildPakPerkTheme(),
          home: PaperNotesScreen(paper: samplePaper, store: store),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('我的笔记', findRichText: true), findsOneWidget);
    expect(find.text('新建一页', findRichText: true), findsOneWidget);
    expect(find.text(samplePaper.title), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('paper-notes-editor')))
          .controller!
          .text,
      text,
    );
    await tester.tap(find.text('第 2 页', findRichText: true));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('paper-notes-editor')))
          .controller!
          .text,
      '第二页：后续实验',
    );
    expect((await store.read(samplePaper.arxivBaseId)).pages.first, text);
    expect(tester.takeException(), isNull);
  });
  test('dynamic UI wording preserves embedded paper and note content', () {
    expect(chineseUi('Page 3'), '第 3 页');
    expect(
      chineseUi('2 pages · 2106.09685\n自由笔记 English'),
      '2 页 · 2106.09685\n自由笔记 English',
    );
    expect(chineseUi('arXiv'), 'arXiv');
    expect(chineseUi(samplePaper.title), samplePaper.title);
  });
}
