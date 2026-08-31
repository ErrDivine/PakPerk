import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/research_profiles/research_profile_models.dart';
import 'package:pakperk/design_system/theme.dart';
import 'package:pakperk/features/research_profiles/research_profile_screen.dart';

void main() {
  testWidgets(
    'explicit, feedback, and inferred signals stay visibly separate',
    (tester) async {
      await _pump(tester);

      expect(find.text('To Read stays in charge'), findsOneWidget);
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('research-profile-early-for-you')),
        350,
        scrollable: scrollable,
      );
      expect(
        find.textContaining('relies on categories, topics, and authors'),
        findsOneWidget,
      );
      for (final entry in const [
        ('research-profile-explicit', 'cs.AI'),
        ('research-profile-feedback', 'cs.CL'),
        ('research-profile-inferred', 'cs.IR'),
      ]) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(entry.$1)),
          350,
          scrollable: scrollable,
        );
        expect(find.text(entry.$2), findsOneWidget);
      }
      expect(
        find.textContaining('never presented as choices you made'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('research-profile-retention')),
        350,
        scrollable: scrollable,
      );
      expect(find.textContaining('up to 90 days'), findsOneWidget);
      expect(find.textContaining('up to 180 days'), findsOneWidget);
    },
  );

  testWidgets('narrow Dynamic Type layout remains scrollable and actionable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      media: const MediaQueryData(
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('research-profile-export')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('research-profile-export')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('only explicit topic and author chips expose removal controls', (
    tester,
  ) async {
    final deletedTopics = <String>[];
    final deletedAuthors = <String>[];
    await _pump(
      tester,
      onDeleteTopic: deletedTopics.add,
      onDeleteAuthor: deletedAuthors.add,
    );
    final scrollable = _profileScrollable();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('research-profile-add-topic')),
      160,
      scrollable: scrollable,
    );
    expect(find.byKey(const ValueKey('research-profile-add-author')), findsOne);

    final explicitTopic = tester.widget<InputChip>(
      find.byKey(
        const ValueKey(
          'research-profile-topic-10000000-0000-4000-8000-000000000001',
        ),
      ),
    );
    final explicitAuthor = tester.widget<InputChip>(
      find.byKey(const ValueKey('research-profile-author-author-explicit')),
    );
    explicitTopic.onDeleted!();
    explicitAuthor.onDeleted!();
    expect(deletedTopics, ['10000000-0000-4000-8000-000000000001']);
    expect(deletedAuthors, ['author-explicit']);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('research-profile-feedback')),
      120,
      scrollable: scrollable,
    );
    expect(
      tester
          .widget<InputChip>(
            find.byKey(
              const ValueKey(
                'research-profile-topic-20000000-0000-4000-8000-000000000002',
              ),
            ),
          )
          .onDeleted,
      isNull,
    );
    expect(
      tester
          .widget<InputChip>(
            find.byKey(
              const ValueKey('research-profile-author-author-feedback'),
            ),
          )
          .onDeleted,
      isNull,
    );
  });

  testWidgets(
    'weight controls commit bounded values and negative topic is explicit',
    (tester) async {
      double? recency;
      double? novelty;
      double? diversity;
      var addNegativeCalls = 0;
      await _pump(
        tester,
        onRecencyWeightChanged: (value) => recency = value,
        onNoveltyWeightChanged: (value) => novelty = value,
        onDiversityWeightChanged: (value) => diversity = value,
        onAddNegativeTopic: () => addNegativeCalls += 1,
      );
      final scrollable = _profileScrollable();

      for (final entry in [
        (const ValueKey('research-profile-recency-weight'), .7, () => recency),
        (const ValueKey('research-profile-novelty-weight'), .2, () => novelty),
        (
          const ValueKey('research-profile-diversity-weight'),
          .6,
          () => diversity,
        ),
      ]) {
        final control = find.byKey(entry.$1);
        await tester.scrollUntilVisible(control, 160, scrollable: scrollable);
        final slider = tester.widget<Slider>(
          find.descendant(of: control, matching: find.byType(Slider)),
        );
        slider.onChanged!(entry.$2);
        slider.onChangeEnd!(entry.$2);
        await tester.pump();
        expect(entry.$3(), entry.$2);
      }

      final recencyControl = find.byKey(
        const ValueKey('research-profile-recency-weight'),
      );
      await tester.scrollUntilVisible(
        recencyControl,
        -160,
        scrollable: scrollable,
      );
      final recencySlider = tester.widget<Slider>(
        find.descendant(of: recencyControl, matching: find.byType(Slider)),
      );
      recencySlider.onChanged!(.7);
      recencySlider.onChangeEnd!(.7);
      await tester.pump();
      expect(find.text('Recent work · 70%'), findsOneWidget);

      await _pump(
        tester,
        busy: true,
        onRecencyWeightChanged: (value) => recency = value,
        onNoveltyWeightChanged: (value) => novelty = value,
        onDiversityWeightChanged: (value) => diversity = value,
        onAddNegativeTopic: () => addNegativeCalls += 1,
      );
      expect(find.text('Recent work · 70%'), findsOneWidget);
      await _pump(
        tester,
        onRecencyWeightChanged: (value) => recency = value,
        onNoveltyWeightChanged: (value) => novelty = value,
        onDiversityWeightChanged: (value) => diversity = value,
        onAddNegativeTopic: () => addNegativeCalls += 1,
      );
      expect(
        find.text('Recent work · 40%'),
        findsOneWidget,
        reason: 'a failed update must return to the canonical profile value',
      );

      final addNegative = find.byKey(
        const ValueKey('research-profile-add-negative-topic'),
      );
      await _scrollFromTopUntilHitTestable(tester, addNegative, scrollable);
      await tester.tap(addNegative.hitTestable());
      expect(addNegativeCalls, 1);
      expect(find.text('Avoid noisy topic'), findsOneWidget);
    },
  );
}

Finder _profileScrollable() => find.descendant(
  of: find.byKey(const ValueKey('research-profile-scroll-view')),
  matching: find.byType(Scrollable),
);

Future<void> _scrollFromTopUntilHitTestable(
  WidgetTester tester,
  Finder target,
  Finder scrollable,
) async {
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  for (var attempt = 0; attempt < 30; attempt += 1) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    await tester.drag(scrollable, const Offset(0, -100));
    await tester.pump();
  }
  fail('The target did not become tappable after scrolling.');
}

Future<void> _pump(
  WidgetTester tester, {
  MediaQueryData media = const MediaQueryData(),
  bool busy = false,
  ValueChanged<String>? onDeleteTopic,
  ValueChanged<String>? onDeleteAuthor,
  ValueChanged<double>? onRecencyWeightChanged,
  ValueChanged<double>? onNoveltyWeightChanged,
  ValueChanged<double>? onDiversityWeightChanged,
  VoidCallback? onAddNegativeTopic,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PakPerkTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: media.textScaler,
            disableAnimations: media.disableAnimations,
          ),
          child: ResearchProfileScreen(
            profile: _profile,
            interests: _interests,
            loading: false,
            busy: busy,
            errorMessage: null,
            onRetry: () {},
            onPersonalizationChanged: (_) {},
            onPreferredModeChanged: (_) {},
            onDiscoveryModeChanged: (_) {},
            onBriefSizeChanged: (_) {},
            onRecencyWeightChanged: onRecencyWeightChanged ?? (_) {},
            onNoveltyWeightChanged: onNoveltyWeightChanged ?? (_) {},
            onDiversityWeightChanged: onDiversityWeightChanged ?? (_) {},
            onEditExplicitCategories: () {},
            onAddExplicitTopic: () {},
            onAddExplicitNegativeTopic: onAddNegativeTopic ?? () {},
            onAddExplicitAuthor: () {},
            onDeleteExplicitTopic: onDeleteTopic ?? (_) {},
            onDeleteExplicitAuthor: onDeleteAuthor ?? (_) {},
            onResetInferred: () {},
            onResetAll: () {},
            onExport: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

final _profile = ResearchProfile(
  personalizationEnabled: true,
  preferredDiscoveryMode: PreferredDiscoveryMode.forYou,
  discoveryMode: ResearchDiscoveryMode.balanced,
  briefSize: 20,
  recencyWeight: .4,
  noveltyWeight: .3,
  diversityWeight: .3,
  profileRevision: 3,
  createdAt: DateTime.utc(2026, 8, 19, 10),
  updatedAt: DateTime.utc(2026, 8, 19, 12),
);

final _interests = ResearchProfileInterests(
  profileRevision: 3,
  explicit: _group(ResearchInterestSource.explicit, 'cs.AI'),
  feedback: _group(ResearchInterestSource.feedback, 'cs.CL'),
  inferred: _group(ResearchInterestSource.inferred, 'cs.IR'),
);

ResearchInterestGroup _group(ResearchInterestSource source, String category) =>
    ResearchInterestGroup(
      categories: [
        ResearchProfileCategory(
          category: category,
          weight: .8,
          source: source,
          createdAt: DateTime.utc(2026, 8, 19, 10),
          updatedAt: DateTime.utc(2026, 8, 19, 12),
        ),
      ],
      topics: [
        ResearchProfileTopic(
          topicId: switch (source) {
            ResearchInterestSource.explicit =>
              '10000000-0000-4000-8000-000000000001',
            ResearchInterestSource.feedback =>
              '20000000-0000-4000-8000-000000000002',
            ResearchInterestSource.inferred =>
              '30000000-0000-4000-8000-000000000003',
          },
          canonicalKey: 'topic-${source.name}',
          label: '${source.name} topic',
          sourceVocabulary: 'test',
          polarity: ResearchTopicPolarity.positive,
          strength: .8,
          source: source,
          userAlias: null,
          explanationSourceId: null,
          createdAt: DateTime.utc(2026, 8, 19, 10),
          updatedAt: DateTime.utc(2026, 8, 19, 12),
        ),
        if (source == ResearchInterestSource.explicit)
          ResearchProfileTopic(
            topicId: '10000000-0000-4000-8000-000000000009',
            canonicalKey: 'noisy-topic',
            label: 'noisy topic',
            sourceVocabulary: 'test',
            polarity: ResearchTopicPolarity.negative,
            strength: .8,
            source: source,
            userAlias: null,
            explanationSourceId: null,
            createdAt: DateTime.utc(2026, 8, 19, 10),
            updatedAt: DateTime.utc(2026, 8, 19, 12),
          ),
      ],
      authors: [
        ResearchProfileAuthor(
          authorKey: 'author-${source.name}',
          displayName: '${source.name} author',
          source: source,
          explanationSourceId: null,
          createdAt: DateTime.utc(2026, 8, 19, 10),
          updatedAt: DateTime.utc(2026, 8, 19, 12),
        ),
      ],
    );
