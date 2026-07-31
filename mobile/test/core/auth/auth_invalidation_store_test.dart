import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('invalidation guard persists only a non-secret boolean', () async {
    const first = SharedPreferencesAuthInvalidationStore();
    await first.markInvalidated();

    const restarted = SharedPreferencesAuthInvalidationStore();
    expect(await restarted.isInvalidated(), isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), {
      SharedPreferencesAuthInvalidationStore.defaultKey,
    });
    expect(
      preferences.getBool(SharedPreferencesAuthInvalidationStore.defaultKey),
      isTrue,
    );
    expect(
      preferences.get(SharedPreferencesAuthInvalidationStore.defaultKey),
      isA<bool>(),
    );

    await restarted.clearInvalidation();
    expect(await first.isInvalidated(), isFalse);
    expect(preferences.getKeys(), isEmpty);
  });
}
