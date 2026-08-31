import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const guestDiscoveryPreferencesKey = 'pakperk.guest.discovery.preferences.v1';

/// Private, device-local guest choices. These values are never account profile
/// fields and never leave the existing public feed query boundary.
final class GuestDiscoveryPreferences {
  GuestDiscoveryPreferences({
    required this.onboardingComplete,
    Iterable<String> categories = const [],
  }) : categories = _normalizeCategories(categories);

  const GuestDiscoveryPreferences.initial()
    : onboardingComplete = false,
      categories = const [];

  final bool onboardingComplete;
  final List<String> categories;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'onboarding_complete': onboardingComplete,
    'categories': categories,
  };

  factory GuestDiscoveryPreferences.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(const {
          'schema',
          'onboarding_complete',
          'categories',
        }).isNotEmpty ||
        json['schema'] != 1 ||
        json['onboarding_complete'] is! bool ||
        json['categories'] is! List ||
        (json['categories']! as List).any((value) => value is! String)) {
      throw const FormatException('Invalid guest discovery preferences.');
    }
    return GuestDiscoveryPreferences(
      onboardingComplete: json['onboarding_complete']! as bool,
      categories: (json['categories']! as List).cast<String>(),
    );
  }
}

abstract interface class GuestDiscoveryPreferencesStore {
  Future<GuestDiscoveryPreferences> load();

  Future<void> save(GuestDiscoveryPreferences preferences);
}

final class SharedPreferencesGuestDiscoveryPreferencesStore
    implements GuestDiscoveryPreferencesStore {
  SharedPreferencesGuestDiscoveryPreferencesStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<GuestDiscoveryPreferences> load() async {
    final raw = (await _preferences()).getString(guestDiscoveryPreferencesKey);
    if (raw == null) return const GuestDiscoveryPreferences.initial();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const GuestDiscoveryPreferences.initial();
      }
      return GuestDiscoveryPreferences.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } on Object {
      // Corrupt local preference data must not block the public guest feed.
      return const GuestDiscoveryPreferences.initial();
    }
  }

  @override
  Future<void> save(GuestDiscoveryPreferences preferences) async {
    final written = await (await _preferences()).setString(
      guestDiscoveryPreferencesKey,
      jsonEncode(preferences.toJson()),
    );
    if (!written) {
      throw StateError('Guest discovery preferences could not be saved.');
    }
  }
}

List<String> _normalizeCategories(Iterable<String> values) {
  final categories = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (!_category.hasMatch(value)) {
      throw ArgumentError.value(raw, 'categories', 'Invalid arXiv category.');
    }
    if (seen.add(value.toLowerCase())) categories.add(value);
    if (categories.length > 4) {
      throw ArgumentError.value(values, 'categories', 'Too many categories.');
    }
  }
  return List.unmodifiable(categories);
}

final _category = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]{0,31}$');
