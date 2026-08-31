import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/discovery/guest_discovery_preferences.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/feed/guest_category_onboarding.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'guest choices round-trip privately and corrupt data fails closed',
    () async {
      SharedPreferences.setMockInitialValues({
        guestDiscoveryPreferencesKey: '{"schema":2}',
      });
      final store = SharedPreferencesGuestDiscoveryPreferencesStore();

      expect(
        (await store.load()).onboardingComplete,
        isFalse,
        reason: 'unknown local schemas must not silently select a category',
      );

      final expected = GuestDiscoveryPreferences(
        onboardingComplete: true,
        categories: const ['cs.AI', 'cs.CL'],
      );
      await store.save(expected);

      final restored = await store.load();
      expect(restored.onboardingComplete, isTrue);
      expect(restored.categories, ['cs.AI', 'cs.CL']);
    },
  );

  test('controller publishes only persisted choices', () async {
    final store = _MemoryGuestStore();
    final controller = GuestDiscoveryPreferencesController(store);
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.state.loading, isFalse);
    expect(controller.state.preferences.onboardingComplete, isFalse);

    final saved = await controller.complete(const ['stat.ML']);
    expect(saved?.categories, ['stat.ML']);
    expect(controller.state.preferences.categories, ['stat.ML']);
    expect(store.value.categories, ['stat.ML']);
  });

  testWidgets(
    'category onboarding is explicit, bounded, scrollable, and motion-safe',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      List<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: PakPerkTheme.light(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async {
                      result = await showGuestCategoryOnboardingSheet(
                        context: context,
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not personalization'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsWidgets);

      for (final code in const ['cs.AI', 'cs.CL', 'cs.CV', 'cs.HC']) {
        final chip = find.byKey(ValueKey('guest-category-$code'));
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        tester.widget<FilterChip>(chip).onSelected!(true);
        await tester.pump();
      }
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('guest-category-cs.IR')),
            )
            .onSelected,
        isNull,
      );

      final continueButton = find.byKey(
        const ValueKey('guest-category-continue'),
      );
      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(result, ['cs.AI', 'cs.CL', 'cs.CV', 'cs.HC']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('guest can skip without selecting a category', (tester) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showGuestCategoryOnboardingSheet(
                  context: context,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final skip = find.byKey(const ValueKey('guest-category-skip'));
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    await tester.pumpAndSettle();

    expect(result, isEmpty);
  });
}

final class _MemoryGuestStore implements GuestDiscoveryPreferencesStore {
  GuestDiscoveryPreferences value = const GuestDiscoveryPreferences.initial();

  @override
  Future<GuestDiscoveryPreferences> load() async => value;

  @override
  Future<void> save(GuestDiscoveryPreferences preferences) async {
    value = preferences;
  }
}
