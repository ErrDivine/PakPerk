import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/engagement/engagement_models.dart';
import 'package:pakperk/features/engagement/engagement_destination.dart';

void main() {
  test(
    'failed preference write then reminder change gets a new id and stable retry',
    () {
      const firstOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
      const changedOperationId = '018f47a6-4b56-7f4c-8c7a-e2656e820202';
      final current = NotificationPreferences(
        typeFrequencies: NotificationTypeFrequencies.defaults,
        quietHoursStart: '22:00:00',
        quietHoursEnd: '07:00:00',
        timezone: 'Asia/Shanghai',
        inAppEnabled: true,
        globalPause: false,
        dailyBudget: 5,
        revision: 1,
        updatedAt: DateTime.utc(2026, 8, 19),
      );
      final changed = current.copyWith(
        typeFrequencies: current.typeFrequencies.withFrequency(
          InAppNotificationType.userSelectedReminder,
          SubscriptionFrequency.daily,
        ),
      );
      final currentKey = notificationPreferencesOperationKey(current);
      final changedKey = notificationPreferencesOperationKey(changed);
      expect(changedKey, isNot(currentKey));

      // A failed write retains its operation ID. Changing the reminder
      // frequency is a different payload and must allocate a different ID;
      // retrying that unchanged payload must then reuse the new ID.
      final retainedIds = <String, String>{};
      final failedId = retainedIds.putIfAbsent(
        currentKey,
        () => firstOperationId,
      );
      final changedId = retainedIds.putIfAbsent(
        changedKey,
        () => changedOperationId,
      );
      final retryId = retainedIds.putIfAbsent(
        changedKey,
        () => throw StateError('Retry unexpectedly allocated an ID.'),
      );

      expect(failedId, firstOperationId);
      expect(changedId, changedOperationId);
      expect(retryId, changedOperationId);
    },
  );
}
