import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/account/account.dart';

void main() {
  test(
    'decodes a complete profile only with an active handle and current terms',
    () {
      final profile = AccountProfile.fromJson(
        _profileJson(
          handle: 'ada_reader',
          termsVersion: '2026-07',
          termsAcceptedAt: '2026-07-30T12:00:00Z',
          termsCurrent: true,
          profileComplete: true,
        ),
      );

      expect(profile.isProfileComplete, isTrue);
      expect(profile.createdAt.isUtc, isTrue);
      expect(profile.toString(), isNot(contains(profile.id)));
      expect(profile.toString(), isNot(contains('ada_reader')));
    },
  );

  test('accepts the API bootstrap profile including comment eligibility', () {
    final profile = AccountProfile.fromJson(_profileJson());
    expect(profile.isActive, isTrue);
    expect(profile.profileVersion, 1);
    expect(profile.handle, isNull);
    expect(profile.isProfileComplete, isFalse);
    expect(profile.canParticipateInComments, isFalse);
  });

  test('validates required comment eligibility against profile and policies', () {
    final complete = _profileJson(
      handle: 'ada_reader',
      termsVersion: '2026-07',
      termsAcceptedAt: '2026-07-30T10:00:00Z',
      termsCurrent: true,
      communityGuidelinesVersion: '2026-07',
      communityGuidelinesAcceptedAt: '2026-07-30T10:00:00Z',
      communityGuidelinesCurrent: true,
      profileComplete: true,
      commentProfileComplete: true,
    );
    expect(AccountProfile.fromJson(complete).canParticipateInComments, isTrue);
    final missing = _profileJson()..remove('comment_profile_complete');
    for (final invalid in [
      missing,
      _profileJson(commentProfileComplete: null),
      _profileJson(commentProfileComplete: 'false'),
      _profileJson(commentProfileComplete: 0),
      _profileJson(commentProfileComplete: true),
      {...complete, 'comment_profile_complete': false},
    ]) {
      expect(() => AccountProfile.fromJson(invalid), throwsFormatException);
    }
  });

  test('rejects unknown fields and inconsistent derived state', () {
    expect(
      () => AccountProfile.fromJson({..._profileJson(), 'subject': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => AccountProfile.fromJson(_profileJson(profileComplete: true)),
      throwsFormatException,
    );
    expect(
      () => AccountProfile.fromJson(
        _profileJson(
          termsVersion: '2026-07',
          termsAcceptedAt: null,
          termsCurrent: false,
        ),
      ),
      throwsFormatException,
    );
    expect(
      () =>
          AccountProfile.fromJson(_profileJson(termsCurrent: 'yes' as dynamic)),
      throwsFormatException,
    );
  });

  test('profile patch preserves omitted, null, and value semantics', () {
    expect(const AccountProfilePatch(handle: 'ada_reader').toJson(), {
      'handle': 'ada_reader',
    });
    expect(
      const AccountProfilePatch(displayName: ProfileField.clear()).toJson(),
      {'display_name': null},
    );
    expect(
      const AccountProfilePatch(
        displayName: ProfileField.value('Ada'),
        acceptTermsVersion: '2026-07',
      ).toJson(),
      {'display_name': 'Ada', 'accept_terms_version': '2026-07'},
    );
  });
}

Map<String, dynamic> _profileJson({
  Object? handle,
  Object? displayName,
  Object? termsVersion,
  Object? termsAcceptedAt,
  Object? termsCurrent = false,
  Object? communityGuidelinesVersion,
  Object? communityGuidelinesAcceptedAt,
  Object? communityGuidelinesCurrent = false,
  Object? profileComplete = false,
  Object? commentProfileComplete = false,
}) => <String, dynamic>{
  'id': '018f47a6-4b56-7f4c-8c7a-e2656e820001',
  'handle': handle,
  'display_name': displayName,
  'status': 'active',
  'profile_version': 1,
  'profile_complete': profileComplete,
  'terms_version': termsVersion,
  'terms_accepted_at': termsAcceptedAt,
  'current_terms_version': '2026-07',
  'terms_current': termsCurrent,
  'community_guidelines_version': communityGuidelinesVersion,
  'community_guidelines_accepted_at': communityGuidelinesAcceptedAt,
  'current_community_guidelines_version': '2026-07',
  'community_guidelines_current': communityGuidelinesCurrent,
  'comment_profile_complete': commentProfileComplete,
  'created_at': '2026-07-30T10:00:00Z',
  'updated_at': '2026-07-30T11:00:00Z',
};
