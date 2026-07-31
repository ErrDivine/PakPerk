import 'account_api.dart';
import 'account_profile.dart';

final class AccountRepository {
  const AccountRepository(this._api);

  final AccountApi _api;

  Future<AccountProfile> getCurrent({required int expectedAuthEpoch}) async =>
      (await _api.getCurrent(expectedAuthEpoch: expectedAuthEpoch)).profile;

  Future<AccountProfile> update({
    required int expectedAuthEpoch,
    required int expectedProfileVersion,
    required AccountProfilePatch patch,
  }) async {
    final result = await _api.update(
      expectedAuthEpoch: expectedAuthEpoch,
      expectedProfileVersion: expectedProfileVersion,
      patch: patch,
    );
    return result.profile;
  }
}
