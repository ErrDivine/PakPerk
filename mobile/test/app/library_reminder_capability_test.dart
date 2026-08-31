import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/app/feature_flags.dart';
import 'package:pakperk/core/providers.dart';
import 'package:pakperk/features/library/library_destination.dart';

void main() {
  test(
    'reminder selection requires the independent notification capability',
    () {
      ProviderContainer container({required bool notificationsEnabled}) {
        final value = ProviderContainer(
          overrides: [
            featureFlagsProvider.overrideWithValue(
              FeatureFlags(
                accounts: true,
                library: true,
                comments: false,
                openingMotion: false,
                libraryV2Enabled: true,
                subscriptionsEnabled: notificationsEnabled,
                notificationsEnabled: notificationsEnabled,
              ),
            ),
          ],
        );
        addTearDown(value.dispose);
        return value;
      }

      final rolledBack = container(
        notificationsEnabled: false,
      ).read(libraryEditorCapabilitiesProvider);
      expect(rolledBack.canEdit, isTrue);
      expect(rolledBack.reminders, isFalse);

      final enabled = container(
        notificationsEnabled: true,
      ).read(libraryEditorCapabilitiesProvider);
      expect(enabled.reminders, isTrue);
    },
  );
}
