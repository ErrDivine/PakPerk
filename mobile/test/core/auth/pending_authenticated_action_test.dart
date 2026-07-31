import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/auth/auth.dart';

void main() {
  test('pending authenticated action is replaced and taken exactly once', () {
    final controller = PendingAuthenticatedActionController<_TestAction>();
    addTearDown(controller.dispose);
    const first = _TestAction('first');
    const replacement = _TestAction('replacement');

    controller.replace(first);
    controller.replace(replacement);

    expect(controller.take(), same(replacement));
    expect(controller.state, isNull);
    expect(controller.take(), isNull);
  });

  test('clear drops the in-memory action without execution', () {
    final controller = PendingAuthenticatedActionController<_TestAction>();
    addTearDown(controller.dispose);
    controller.replace(const _TestAction('profile-update'));

    controller.clear();

    expect(controller.take(), isNull);
  });
}

final class _TestAction implements PendingAuthenticatedAction {
  const _TestAction(this.actionType);

  @override
  final String actionType;
}
