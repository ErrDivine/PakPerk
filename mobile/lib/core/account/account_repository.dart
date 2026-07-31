import 'account_api.dart';
import 'account_profile.dart';

final class AccountRepository {
  const AccountRepository(this._api);

  final AccountApi _api;

  Future<AccountProfile> getCurrent() async =>
      (await _api.getCurrent()).profile;

  Future<AccountProfile> update({
    required int expectedProfileVersion,
    required AccountProfilePatch patch,
  }) async {
    final result = await _api.update(
      expectedProfileVersion: expectedProfileVersion,
      patch: patch,
    );
    return result.profile;
  }
}
