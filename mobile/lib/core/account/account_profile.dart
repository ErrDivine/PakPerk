enum AccountStatus { active, suspended, deletionPending, deleted }

final class AccountProfile {
  AccountProfile({
    required this.id,
    required this.status,
    required this.profileVersion,
    required this.currentTermsVersion,
    required this.termsCurrent,
    required this.createdAt,
    required this.updatedAt,
    this.handle,
    this.displayName,
    this.termsVersion,
    this.termsAcceptedAt,
  }) {
    if (!_uuid.hasMatch(id) || profileVersion <= 0) {
      throw const FormatException('Invalid account profile identity.');
    }
  }

  factory AccountProfile.fromJson(Map<String, dynamic> json) {
    if (json.length != _profileKeys.length ||
        json.keys.any((key) => !_profileKeys.contains(key))) {
      throw const FormatException('Invalid account profile fields.');
    }
    final status = switch (json['status']) {
      'active' => AccountStatus.active,
      'suspended' => AccountStatus.suspended,
      'deletion_pending' => AccountStatus.deletionPending,
      'deleted' => AccountStatus.deleted,
      _ => throw const FormatException('Invalid account status.'),
    };
    final termsCurrent = json['terms_current'];
    if (termsCurrent is! bool) {
      throw const FormatException('Invalid account terms state.');
    }
    final profile = AccountProfile(
      id: _requiredString(json, 'id'),
      handle: _optionalHandle(json, 'handle'),
      displayName: _optionalDisplayName(json, 'display_name'),
      status: status,
      profileVersion: _requiredPositiveInt(json, 'profile_version'),
      termsVersion: _optionalTermsVersion(json, 'terms_version'),
      termsAcceptedAt: _optionalTime(json, 'terms_accepted_at'),
      currentTermsVersion: _requiredTermsVersion(json, 'current_terms_version'),
      termsCurrent: termsCurrent,
      createdAt: _requiredTime(json, 'created_at'),
      updatedAt: _requiredTime(json, 'updated_at'),
    );
    if (json['profile_complete'] != profile.isProfileComplete) {
      throw const FormatException('Inconsistent profile completeness.');
    }
    final hasTermsVersion = profile.termsVersion != null;
    final hasTermsTime = profile.termsAcceptedAt != null;
    final calculatedTermsCurrent =
        hasTermsVersion &&
        hasTermsTime &&
        profile.termsVersion == profile.currentTermsVersion;
    if (hasTermsVersion != hasTermsTime ||
        profile.termsCurrent != calculatedTermsCurrent ||
        profile.updatedAt.isBefore(profile.createdAt)) {
      throw const FormatException('Inconsistent account profile state.');
    }
    return profile;
  }

  final String id;
  final String? handle;
  final String? displayName;
  final AccountStatus status;
  final int profileVersion;
  final String? termsVersion;
  final DateTime? termsAcceptedAt;
  final String currentTermsVersion;
  final bool termsCurrent;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isProfileComplete => isActive && handle != null && termsCurrent;
  bool get isActive => status == AccountStatus.active;

  @override
  String toString() =>
      'AccountProfile(status: $status, profileVersion: $profileVersion, '
      'profileComplete: $isProfileComplete, termsCurrent: $termsCurrent)';
}

final class AccountProfilePatch {
  const AccountProfilePatch({
    this.handle,
    this.displayName = const ProfileField.omitted(),
    this.acceptTermsVersion,
  });

  final String? handle;
  final ProfileField<String> displayName;
  final String? acceptTermsVersion;

  bool get isEmpty =>
      handle == null && displayName.isOmitted && acceptTermsVersion == null;

  Map<String, Object?> toJson() => {
    if (handle != null) 'handle': handle,
    if (!displayName.isOmitted) 'display_name': displayName.value,
    if (acceptTermsVersion != null) 'accept_terms_version': acceptTermsVersion,
  };
}

final class ProfileField<T> {
  const ProfileField.omitted() : _present = false, value = null;
  const ProfileField.clear() : _present = true, value = null;
  const ProfileField.value(T this.value) : _present = true;

  final bool _present;
  final T? value;

  bool get isOmitted => !_present;
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-'
  r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

const _profileKeys = <String>{
  'id',
  'handle',
  'display_name',
  'status',
  'profile_version',
  'profile_complete',
  'terms_version',
  'terms_accepted_at',
  'current_terms_version',
  'terms_current',
  'created_at',
  'updated_at',
};

final _handle = RegExp(r'^[a-z0-9_]{3,30}$');
final _termsVersion = RegExp(r'^[A-Za-z0-9._:-]{1,64}$');

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > 2048) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

String? _optionalHandle(Map<String, dynamic> json, String key) {
  final value = _optionalString(json, key);
  if (value != null && !_handle.hasMatch(value)) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

String? _optionalDisplayName(Map<String, dynamic> json, String key) {
  final value = _optionalString(json, key);
  if (value != null &&
      (value.runes.length > 80 || value.runes.any(_unsafeDisplayRune))) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

bool _unsafeDisplayRune(int rune) =>
    rune <= 0x1f ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x061c ||
    (rune >= 0x200b && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x2069) ||
    rune == 0xfeff;

String _requiredTermsVersion(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  if (!_termsVersion.hasMatch(value)) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

String? _optionalTermsVersion(Map<String, dynamic> json, String key) {
  final value = _optionalString(json, key);
  if (value != null && !_termsVersion.hasMatch(value)) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

int _requiredPositiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) {
    throw FormatException('Invalid account field: $key.');
  }
  return value;
}

DateTime _requiredTime(Map<String, dynamic> json, String key) {
  final value = DateTime.tryParse(_requiredString(json, key));
  if (value == null) throw FormatException('Invalid account field: $key.');
  return value.toUtc();
}

DateTime? _optionalTime(Map<String, dynamic> json, String key) {
  final raw = _optionalString(json, key);
  if (raw == null) return null;
  final value = DateTime.tryParse(raw);
  if (value == null) throw FormatException('Invalid account field: $key.');
  return value.toUtc();
}
