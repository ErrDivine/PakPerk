enum PreferredDiscoveryMode { recent, following, forYou, explore }

enum ResearchDiscoveryMode { focused, balanced, exploratory }

enum ResearchInterestSource { explicit, feedback, inferred }

enum ResearchTopicPolarity { positive, negative }

enum ResearchProfileResetScope { inferred, all }

final class ExplicitResearchCategory {
  const ExplicitResearchCategory({
    required this.category,
    required this.weight,
  });

  final String category;
  final double weight;

  Map<String, Object?> toJson() => {'category': category, 'weight': weight};
}

final class ResearchProfile {
  const ResearchProfile({
    required this.personalizationEnabled,
    required this.preferredDiscoveryMode,
    required this.discoveryMode,
    required this.briefSize,
    required this.recencyWeight,
    required this.noveltyWeight,
    required this.diversityWeight,
    required this.profileRevision,
    required this.createdAt,
    required this.updatedAt,
  });

  final bool personalizationEnabled;
  final PreferredDiscoveryMode preferredDiscoveryMode;
  final ResearchDiscoveryMode discoveryMode;
  final int briefSize;
  final double recencyWeight;
  final double noveltyWeight;
  final double diversityWeight;
  final int profileRevision;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ResearchProfile.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'personalization_enabled',
      'preferred_discovery_mode',
      'discovery_mode',
      'brief_size',
      'recency_weight',
      'novelty_weight',
      'diversity_weight',
      'profile_revision',
      'created_at',
      'updated_at',
      'queue_override',
    });
    final personalization = json['personalization_enabled'];
    final briefSize = json['brief_size'];
    final revision = json['profile_revision'];
    if (personalization is! bool ||
        briefSize is! int ||
        briefSize < 15 ||
        briefSize > 25 ||
        revision is! int ||
        revision < 0 ||
        json['queue_override'] != false) {
      throw const FormatException('Invalid research profile.');
    }
    return ResearchProfile(
      personalizationEnabled: personalization,
      preferredDiscoveryMode: _preferredMode(json['preferred_discovery_mode']),
      discoveryMode: _discoveryMode(json['discovery_mode']),
      briefSize: briefSize,
      recencyWeight: _weight(json['recency_weight']),
      noveltyWeight: _weight(json['novelty_weight']),
      diversityWeight: _weight(json['diversity_weight']),
      profileRevision: revision,
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'personalization_enabled': personalizationEnabled,
    'preferred_discovery_mode': _preferredWire(preferredDiscoveryMode),
    'discovery_mode': discoveryMode.name,
    'brief_size': briefSize,
    'recency_weight': recencyWeight,
    'novelty_weight': noveltyWeight,
    'diversity_weight': diversityWeight,
    'profile_revision': profileRevision,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'queue_override': false,
  };
}

final class ResearchProfilePatch {
  const ResearchProfilePatch({
    this.personalizationEnabled,
    this.preferredDiscoveryMode,
    this.discoveryMode,
    this.briefSize,
    this.recencyWeight,
    this.noveltyWeight,
    this.diversityWeight,
    this.explicitCategories,
  });

  final bool? personalizationEnabled;
  final PreferredDiscoveryMode? preferredDiscoveryMode;
  final ResearchDiscoveryMode? discoveryMode;
  final int? briefSize;
  final double? recencyWeight;
  final double? noveltyWeight;
  final double? diversityWeight;
  final List<ExplicitResearchCategory>? explicitCategories;

  Map<String, Object?> toJson(String operationId) => {
    'operation_id': operationId,
    if (personalizationEnabled != null)
      'personalization_enabled': personalizationEnabled,
    if (preferredDiscoveryMode != null)
      'preferred_discovery_mode': _preferredWire(preferredDiscoveryMode!),
    if (discoveryMode != null) 'discovery_mode': discoveryMode!.name,
    if (briefSize != null) 'brief_size': briefSize,
    if (recencyWeight != null) 'recency_weight': recencyWeight,
    if (noveltyWeight != null) 'novelty_weight': noveltyWeight,
    if (diversityWeight != null) 'diversity_weight': diversityWeight,
    if (explicitCategories != null)
      'explicit_categories': explicitCategories!
          .map((category) => category.toJson())
          .toList(growable: false),
  };
}

final class ResearchProfileCategory {
  const ResearchProfileCategory({
    required this.category,
    required this.weight,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  final String category;
  final double weight;
  final ResearchInterestSource source;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ResearchProfileCategory.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'category',
      'weight',
      'source',
      'created_at',
      'updated_at',
    });
    return ResearchProfileCategory(
      category: _bounded(json['category'], 32),
      weight: _weight(json['weight']),
      source: _source(json['source']),
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'category': category,
    'weight': weight,
    'source': source.name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class ResearchProfileTopic {
  const ResearchProfileTopic({
    required this.topicId,
    required this.canonicalKey,
    required this.label,
    required this.sourceVocabulary,
    required this.polarity,
    required this.strength,
    required this.source,
    required this.userAlias,
    required this.explanationSourceId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String topicId;
  final String canonicalKey;
  final String label;
  final String sourceVocabulary;
  final ResearchTopicPolarity polarity;
  final double strength;
  final ResearchInterestSource source;
  final String? userAlias;
  final String? explanationSourceId;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ResearchProfileTopic.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'topic_id',
      'canonical_key',
      'label',
      'source_vocabulary',
      'polarity',
      'strength',
      'source',
      'user_alias',
      'explanation_source_id',
      'created_at',
      'updated_at',
    });
    return ResearchProfileTopic(
      topicId: _uuid(json['topic_id']),
      canonicalKey: _bounded(json['canonical_key'], 160),
      label: _bounded(json['label'], 160),
      sourceVocabulary: _bounded(json['source_vocabulary'], 64),
      polarity: switch (json['polarity']) {
        'positive' => ResearchTopicPolarity.positive,
        'negative' => ResearchTopicPolarity.negative,
        _ => throw const FormatException('Invalid topic polarity.'),
      },
      strength: _weight(json['strength']),
      source: _source(json['source']),
      userAlias: _optionalBounded(json['user_alias'], 160),
      explanationSourceId: json['explanation_source_id'] == null
          ? null
          : _uuid(json['explanation_source_id']),
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'topic_id': topicId,
    'canonical_key': canonicalKey,
    'label': label,
    'source_vocabulary': sourceVocabulary,
    'polarity': polarity.name,
    'strength': strength,
    'source': source.name,
    'user_alias': userAlias,
    'explanation_source_id': explanationSourceId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class ResearchProfileAuthor {
  const ResearchProfileAuthor({
    required this.authorKey,
    required this.displayName,
    required this.source,
    required this.explanationSourceId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String authorKey;
  final String displayName;
  final ResearchInterestSource source;
  final String? explanationSourceId;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ResearchProfileAuthor.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'author_key',
      'display_name',
      'source',
      'explanation_source_id',
      'created_at',
      'updated_at',
    });
    return ResearchProfileAuthor(
      authorKey: _bounded(json['author_key'], 200),
      displayName: _bounded(json['display_name'], 200),
      source: _source(json['source']),
      explanationSourceId: json['explanation_source_id'] == null
          ? null
          : _uuid(json['explanation_source_id']),
      createdAt: _timestamp(json['created_at']),
      updatedAt: _timestamp(json['updated_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'author_key': authorKey,
    'display_name': displayName,
    'source': source.name,
    'explanation_source_id': explanationSourceId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class ResearchInterestGroup {
  const ResearchInterestGroup({
    required this.categories,
    required this.topics,
    required this.authors,
  });

  final List<ResearchProfileCategory> categories;
  final List<ResearchProfileTopic> topics;
  final List<ResearchProfileAuthor> authors;

  factory ResearchInterestGroup.fromJson(
    Map<String, dynamic> json, {
    required ResearchInterestSource expectedSource,
  }) {
    _exactKeys(json, const {'categories', 'topics', 'authors'});
    final categories = _list(json['categories'])
        .map((value) => ResearchProfileCategory.fromJson(_map(value)))
        .toList(growable: false);
    final topics = _list(json['topics'])
        .map((value) => ResearchProfileTopic.fromJson(_map(value)))
        .toList(growable: false);
    final authors = _list(json['authors'])
        .map((value) => ResearchProfileAuthor.fromJson(_map(value)))
        .toList(growable: false);
    if ([...categories, ...topics, ...authors].any(
      (item) => switch (item) {
        ResearchProfileCategory value => value.source != expectedSource,
        ResearchProfileTopic value => value.source != expectedSource,
        ResearchProfileAuthor value => value.source != expectedSource,
        _ => true,
      },
    )) {
      throw const FormatException('Interest source crossed group boundary.');
    }
    return ResearchInterestGroup(
      categories: List.unmodifiable(categories),
      topics: List.unmodifiable(topics),
      authors: List.unmodifiable(authors),
    );
  }

  bool get isEmpty => categories.isEmpty && topics.isEmpty && authors.isEmpty;

  Map<String, Object?> toJson() => {
    'categories': categories.map((value) => value.toJson()).toList(),
    'topics': topics.map((value) => value.toJson()).toList(),
    'authors': authors.map((value) => value.toJson()).toList(),
  };
}

final class ResearchProfileInterests {
  const ResearchProfileInterests({
    required this.profileRevision,
    required this.explicit,
    required this.feedback,
    required this.inferred,
  });

  final int profileRevision;
  final ResearchInterestGroup explicit;
  final ResearchInterestGroup feedback;
  final ResearchInterestGroup inferred;

  factory ResearchProfileInterests.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'profile_revision',
      'explicit',
      'feedback',
      'inferred',
    });
    final revision = json['profile_revision'];
    if (revision is! int || revision < 0) {
      throw const FormatException('Invalid interest revision.');
    }
    return ResearchProfileInterests(
      profileRevision: revision,
      explicit: ResearchInterestGroup.fromJson(
        _map(json['explicit']),
        expectedSource: ResearchInterestSource.explicit,
      ),
      feedback: ResearchInterestGroup.fromJson(
        _map(json['feedback']),
        expectedSource: ResearchInterestSource.feedback,
      ),
      inferred: ResearchInterestGroup.fromJson(
        _map(json['inferred']),
        expectedSource: ResearchInterestSource.inferred,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'profile_revision': profileRevision,
    'explicit': explicit.toJson(),
    'feedback': feedback.toJson(),
    'inferred': inferred.toJson(),
  };
}

final class ResearchProfileExport {
  const ResearchProfileExport({
    required this.exportedAt,
    required this.profile,
    required this.interests,
  });

  final DateTime exportedAt;
  final ResearchProfile profile;
  final ResearchProfileInterests interests;

  factory ResearchProfileExport.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const {
      'schema_version',
      'exported_at',
      'profile',
      'interests',
      'operation_ledger_included',
      'raw_interaction_history_included',
    });
    if (json['schema_version'] != 1 ||
        json['operation_ledger_included'] != false ||
        json['raw_interaction_history_included'] != false) {
      throw const FormatException('Invalid research profile export.');
    }
    final profile = ResearchProfile.fromJson(_map(json['profile']));
    final interests = ResearchProfileInterests.fromJson(
      _map(json['interests']),
    );
    if (profile.profileRevision != interests.profileRevision) {
      throw const FormatException('Profile export revisions disagree.');
    }
    return ResearchProfileExport(
      exportedAt: _timestamp(json['exported_at']),
      profile: profile,
      interests: interests,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'exported_at': exportedAt.toUtc().toIso8601String(),
    'profile': profile.toJson(),
    'interests': interests.toJson(),
    'operation_ledger_included': false,
    'raw_interaction_history_included': false,
  };
}

PreferredDiscoveryMode _preferredMode(Object? value) => switch (value) {
  'recent' => PreferredDiscoveryMode.recent,
  'following' => PreferredDiscoveryMode.following,
  'for_you' => PreferredDiscoveryMode.forYou,
  'explore' => PreferredDiscoveryMode.explore,
  _ => throw const FormatException('Invalid preferred discovery mode.'),
};

String _preferredWire(PreferredDiscoveryMode value) => switch (value) {
  PreferredDiscoveryMode.forYou => 'for_you',
  _ => value.name,
};

ResearchDiscoveryMode _discoveryMode(Object? value) => switch (value) {
  'focused' => ResearchDiscoveryMode.focused,
  'balanced' => ResearchDiscoveryMode.balanced,
  'exploratory' => ResearchDiscoveryMode.exploratory,
  _ => throw const FormatException('Invalid discovery mode.'),
};

ResearchInterestSource _source(Object? value) => switch (value) {
  'explicit' => ResearchInterestSource.explicit,
  'feedback' => ResearchInterestSource.feedback,
  'inferred' => ResearchInterestSource.inferred,
  _ => throw const FormatException('Invalid interest source.'),
};

double _weight(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw const FormatException('Invalid interest weight.');
  }
  return value.toDouble();
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

List<Object?> _list(Object? value) {
  if (value is! List || value.length > 512) {
    throw const FormatException('Invalid interest list.');
  }
  return List<Object?>.from(value);
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.difference(expected).isNotEmpty ||
      expected.difference(actual).isNotEmpty) {
    throw const FormatException('Unexpected response shape.');
  }
}

String _bounded(Object? value, int maximumLength) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximumLength ||
      value.runes.any((rune) => rune < 0x20)) {
    throw const FormatException('Invalid text.');
  }
  return value;
}

String? _optionalBounded(Object? value, int maximumLength) =>
    value == null ? null : _bounded(value, maximumLength);

String _uuid(Object? value) {
  final text = _bounded(value, 36).toLowerCase();
  if (!_uuidPattern.hasMatch(text)) {
    throw const FormatException('Invalid UUID.');
  }
  return text;
}

DateTime _timestamp(Object? value) {
  final raw = _bounded(value, 64);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !raw.endsWith('Z')) {
    throw const FormatException('Invalid timestamp.');
  }
  return parsed.toUtc();
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
