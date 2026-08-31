import 'package:flutter/material.dart';

import '../../core/research_profiles/research_profile_models.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

final class ResearchProfileScreen extends StatelessWidget {
  const ResearchProfileScreen({
    required this.profile,
    required this.interests,
    required this.loading,
    required this.busy,
    required this.errorMessage,
    required this.onRetry,
    required this.onPersonalizationChanged,
    required this.onPreferredModeChanged,
    required this.onDiscoveryModeChanged,
    required this.onBriefSizeChanged,
    required this.onRecencyWeightChanged,
    required this.onNoveltyWeightChanged,
    required this.onDiversityWeightChanged,
    required this.onEditExplicitCategories,
    required this.onAddExplicitTopic,
    required this.onAddExplicitNegativeTopic,
    required this.onAddExplicitAuthor,
    required this.onDeleteExplicitTopic,
    required this.onDeleteExplicitAuthor,
    required this.onResetInferred,
    required this.onResetAll,
    required this.onExport,
    super.key,
  });

  final ResearchProfile? profile;
  final ResearchProfileInterests? interests;
  final bool loading;
  final bool busy;
  final String? errorMessage;
  final VoidCallback onRetry;
  final ValueChanged<bool> onPersonalizationChanged;
  final ValueChanged<PreferredDiscoveryMode> onPreferredModeChanged;
  final ValueChanged<ResearchDiscoveryMode> onDiscoveryModeChanged;
  final ValueChanged<int> onBriefSizeChanged;
  final ValueChanged<double> onRecencyWeightChanged;
  final ValueChanged<double> onNoveltyWeightChanged;
  final ValueChanged<double> onDiversityWeightChanged;
  final VoidCallback onEditExplicitCategories;
  final VoidCallback onAddExplicitTopic;
  final VoidCallback onAddExplicitNegativeTopic;
  final VoidCallback onAddExplicitAuthor;
  final ValueChanged<String> onDeleteExplicitTopic;
  final ValueChanged<String> onDeleteExplicitAuthor;
  final VoidCallback onResetInferred;
  final VoidCallback onResetAll;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final value = profile;
    final signals = interests;
    return Scaffold(
      appBar: AppBar(title: const Text('Research profile')),
      body: SafeArea(
        top: false,
        left: true,
        right: true,
        bottom: true,
        child: loading && value == null
            ? const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Loading research profile',
                ),
              )
            : value == null || signals == null
            ? _LoadFailure(message: errorMessage, onRetry: onRetry)
            : ListView(
                key: const ValueKey('research-profile-scroll-view'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(
                  PakPerkSpacing.lg,
                  PakPerkSpacing.sm,
                  PakPerkSpacing.lg,
                  PakPerkSpacing.xxl,
                ),
                children: [
                  const _BoundaryCard(),
                  if (signals.explicit.isEmpty) ...[
                    const SizedBox(height: PakPerkSpacing.md),
                    _OnboardingCard(
                      enabled: !busy,
                      onStart: onEditExplicitCategories,
                    ),
                  ],
                  const SizedBox(height: PakPerkSpacing.lg),
                  _SectionTitle(
                    title: 'Discovery settings',
                    subtitle:
                        'These settings apply only after To Read is confirmed empty.',
                  ),
                  const SizedBox(height: PakPerkSpacing.sm),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          key: const ValueKey(
                            'research-profile-personalization',
                          ),
                          title: const Text('Personalized discovery'),
                          subtitle: const Text(
                            'Use the separated signals shown below for future recommendations.',
                          ),
                          value: value.personalizationEnabled,
                          onChanged: busy ? null : onPersonalizationChanged,
                        ),
                        const Divider(height: 1),
                        const ListTile(
                          key: ValueKey('research-profile-early-for-you'),
                          leading: Icon(Icons.auto_awesome_outlined),
                          title: Text('How early For You works'),
                          subtitle: Text(
                            'Early For You relies on categories, topics, and authors you explicitly choose. It still waits until To Read is proven empty.',
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(PakPerkSpacing.md),
                          child:
                              DropdownButtonFormField<PreferredDiscoveryMode>(
                                key: const ValueKey(
                                  'research-profile-preferred-mode',
                                ),
                                initialValue: value.preferredDiscoveryMode,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Preferred recommendation mode',
                                ),
                                items: [
                                  for (final mode
                                      in PreferredDiscoveryMode.values)
                                    DropdownMenuItem(
                                      value: mode,
                                      child: Text(_preferredLabel(mode)),
                                    ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (next) {
                                        if (next != null) {
                                          onPreferredModeChanged(next);
                                        }
                                      },
                              ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            PakPerkSpacing.md,
                            0,
                            PakPerkSpacing.md,
                            PakPerkSpacing.md,
                          ),
                          child: DropdownButtonFormField<ResearchDiscoveryMode>(
                            key: const ValueKey(
                              'research-profile-discovery-mode',
                            ),
                            initialValue: value.discoveryMode,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Discovery breadth',
                            ),
                            items: [
                              for (final mode in ResearchDiscoveryMode.values)
                                DropdownMenuItem(
                                  value: mode,
                                  child: Text(_discoveryLabel(mode)),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (next) {
                                    if (next != null) {
                                      onDiscoveryModeChanged(next);
                                    }
                                  },
                          ),
                        ),
                        ListTile(
                          title: Text('Brief size · ${value.briefSize} papers'),
                          subtitle: Slider.adaptive(
                            key: const ValueKey('research-profile-brief-size'),
                            value: value.briefSize.toDouble(),
                            min: 15,
                            max: 25,
                            divisions: 10,
                            label: '${value.briefSize}',
                            onChanged: busy ? null : (_) {},
                            onChangeEnd: busy
                                ? null
                                : (next) => onBriefSizeChanged(next.round()),
                          ),
                        ),
                        const Divider(height: 1),
                        _PreferenceWeightSlider(
                          key: const ValueKey(
                            'research-profile-recency-weight',
                          ),
                          title: 'Recent work',
                          description:
                              'How strongly eligible discovery favors newer papers.',
                          value: value.recencyWeight,
                          enabled: !busy,
                          onChanged: onRecencyWeightChanged,
                        ),
                        _PreferenceWeightSlider(
                          key: const ValueKey(
                            'research-profile-novelty-weight',
                          ),
                          title: 'Novel directions',
                          description:
                              'How strongly eligible discovery favors less familiar ideas.',
                          value: value.noveltyWeight,
                          enabled: !busy,
                          onChanged: onNoveltyWeightChanged,
                        ),
                        _PreferenceWeightSlider(
                          key: const ValueKey(
                            'research-profile-diversity-weight',
                          ),
                          title: 'Varied results',
                          description:
                              'How strongly eligible discovery avoids a narrow result set.',
                          value: value.diversityWeight,
                          enabled: !busy,
                          onChanged: onDiversityWeightChanged,
                        ),
                      ],
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: PakPerkSpacing.sm),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        errorMessage!,
                        key: const ValueKey('research-profile-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: PakPerkSpacing.xl),
                  _InterestSection(
                    key: const ValueKey('research-profile-explicit'),
                    title: 'Explicit choices',
                    explanation: 'Topics and categories you chose directly.',
                    group: signals.explicit,
                    emptyLabel: 'You have not chosen any interests yet.',
                    onDeleteTopic: busy ? null : onDeleteExplicitTopic,
                    onDeleteAuthor: busy ? null : onDeleteExplicitAuthor,
                    action: Wrap(
                      spacing: PakPerkSpacing.xs,
                      runSpacing: PakPerkSpacing.xs,
                      children: [
                        FilledButton.tonalIcon(
                          key: const ValueKey(
                            'research-profile-edit-categories',
                          ),
                          onPressed: busy ? null : onEditExplicitCategories,
                          icon: const Icon(Icons.category_outlined),
                          label: const Text('Categories'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('research-profile-add-topic'),
                          onPressed: busy ? null : onAddExplicitTopic,
                          icon: const Icon(Icons.tag_outlined),
                          label: const Text('Add topic'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey(
                            'research-profile-add-negative-topic',
                          ),
                          onPressed: busy ? null : onAddExplicitNegativeTopic,
                          icon: const Icon(Icons.do_not_disturb_alt_outlined),
                          label: const Text('Avoid topic'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('research-profile-add-author'),
                          onPressed: busy ? null : onAddExplicitAuthor,
                          icon: const Icon(Icons.person_add_alt_outlined),
                          label: const Text('Add author'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.lg),
                  _InterestSection(
                    key: const ValueKey('research-profile-feedback'),
                    title: 'Feedback-derived',
                    explanation:
                        'Signals created from recommendation feedback you submitted.',
                    group: signals.feedback,
                    emptyLabel: 'No feedback-derived signals yet.',
                  ),
                  const SizedBox(height: PakPerkSpacing.lg),
                  _InterestSection(
                    key: const ValueKey('research-profile-inferred'),
                    title: 'Inferred',
                    explanation:
                        'System-inferred signals. These are never presented as choices you made.',
                    group: signals.inferred,
                    emptyLabel: 'No inferred signals yet.',
                    action: OutlinedButton.icon(
                      onPressed: busy ? null : onResetInferred,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Clear inferred signals'),
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.xl),
                  _SectionTitle(
                    title: 'Your data',
                    subtitle:
                        'Export the bounded profile snapshot or reset it. Reading queue and library data stay separate.',
                  ),
                  const SizedBox(height: PakPerkSpacing.sm),
                  Card(
                    child: Column(
                      children: [
                        const ListTile(
                          key: ValueKey('research-profile-retention'),
                          leading: Icon(Icons.schedule_outlined),
                          title: Text('Retention windows'),
                          subtitle: Text(
                            'Content-free recommendation events are kept for up to 90 days and raw recommendation feedback for up to 180 days. Explicit profile choices remain until you reset or delete your account.',
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          key: const ValueKey('research-profile-export'),
                          enabled: !busy,
                          leading: const Icon(Icons.download_outlined),
                          title: const Text('View profile export'),
                          subtitle: const Text(
                            'Excludes the operation ledger and raw interaction history.',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: busy ? null : onExport,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          key: const ValueKey('research-profile-reset-all'),
                          enabled: !busy,
                          leading: Icon(
                            Icons.delete_outline_rounded,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          title: Text(
                            'Reset research profile',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          subtitle: const Text(
                            'Clears profile signals and restores discovery defaults.',
                          ),
                          onTap: busy ? null : onResetAll,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

final class _BoundaryCard extends StatelessWidget {
  const _BoundaryCard();

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: const ListTile(
      leading: Icon(Icons.shield_outlined),
      title: Text('To Read stays in charge'),
      subtitle: Text(
        'This profile can shape recommendations only after the server proves your active queue is empty. It cannot override, reorder, or clear To Read.',
      ),
    ),
  );
}

final class _OnboardingCard extends StatelessWidget {
  const _OnboardingCard({required this.enabled, required this.onStart});

  final bool enabled;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(PakPerkSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Shape your discovery',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          const Text(
            'Start with categories you choose. Feedback and inferred signals remain separately labeled.',
          ),
          const SizedBox(height: PakPerkSpacing.md),
          FilledButton.icon(
            key: const ValueKey('research-profile-onboarding-start'),
            onPressed: enabled ? onStart : null,
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Choose interests'),
          ),
        ],
      ),
    ),
  );
}

final class _InterestSection extends StatelessWidget {
  const _InterestSection({
    required this.title,
    required this.explanation,
    required this.group,
    required this.emptyLabel,
    this.action,
    this.onDeleteTopic,
    this.onDeleteAuthor,
    super.key,
  });

  final String title;
  final String explanation;
  final ResearchInterestGroup group;
  final String emptyLabel;
  final Widget? action;
  final ValueChanged<String>? onDeleteTopic;
  final ValueChanged<String>? onDeleteAuthor;

  @override
  Widget build(BuildContext context) {
    final isEmpty = group.isEmpty;
    return Semantics(
      container: true,
      label: '$title interest signals',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(title: title, subtitle: explanation),
          const SizedBox(height: PakPerkSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(PakPerkSpacing.md),
              child: isEmpty
                  ? Text(emptyLabel)
                  : Wrap(
                      spacing: PakPerkSpacing.xs,
                      runSpacing: PakPerkSpacing.xs,
                      children: [
                        for (final category in group.categories)
                          Chip(
                            label: Text(category.category),
                            avatar: const Icon(Icons.tag),
                          ),
                        for (final topic in group.topics)
                          InputChip(
                            key: ValueKey(
                              'research-profile-topic-${topic.topicId}',
                            ),
                            label: Text(
                              topic.polarity == ResearchTopicPolarity.negative
                                  ? 'Avoid ${topic.userAlias ?? topic.label}'
                                  : topic.userAlias ?? topic.label,
                            ),
                            avatar: Icon(
                              topic.polarity == ResearchTopicPolarity.negative
                                  ? Icons.do_not_disturb_alt_outlined
                                  : Icons.tag,
                            ),
                            deleteButtonTooltipMessage: onDeleteTopic == null
                                ? null
                                : 'Remove explicit ${topic.polarity.name} topic ${topic.userAlias ?? topic.label}',
                            onDeleted: onDeleteTopic == null
                                ? null
                                : () => onDeleteTopic!(topic.topicId),
                          ),
                        for (final author in group.authors)
                          InputChip(
                            key: ValueKey(
                              'research-profile-author-${author.authorKey}',
                            ),
                            label: Text(author.displayName),
                            avatar: const Icon(Icons.person_outline),
                            deleteButtonTooltipMessage: onDeleteAuthor == null
                                ? null
                                : 'Remove explicit author ${author.displayName}',
                            onDeleted: onDeleteAuthor == null
                                ? null
                                : () => onDeleteAuthor!(author.authorKey),
                          ),
                      ],
                    ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: PakPerkSpacing.sm),
            Align(alignment: Alignment.centerLeft, child: action),
          ],
        ],
      ),
    );
  }
}

final class _PreferenceWeightSlider extends StatefulWidget {
  const _PreferenceWeightSlider({
    required this.title,
    required this.description,
    required this.value,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String description;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  State<_PreferenceWeightSlider> createState() =>
      _PreferenceWeightSliderState();
}

final class _PreferenceWeightSliderState
    extends State<_PreferenceWeightSlider> {
  late double _value = widget.value;

  @override
  void didUpdateWidget(covariant _PreferenceWeightSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        (!oldWidget.enabled && widget.enabled && _value != widget.value)) {
      _value = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_value * 100).round();
    return Semantics(
      container: true,
      label: '${widget.title}, $percent percent. ${widget.description}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PakPerkSpacing.md,
          PakPerkSpacing.sm,
          PakPerkSpacing.md,
          PakPerkSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.title} · $percent%',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: PakPerkSpacing.xxs),
            Text(
              widget.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Slider.adaptive(
              value: _value,
              min: 0,
              max: 1,
              divisions: 10,
              label: '$percent%',
              onChanged: widget.enabled
                  ? (value) => setState(() => _value = value)
                  : null,
              onChangeEnd: widget.enabled ? widget.onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      const SizedBox(height: PakPerkSpacing.xxs),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

final class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(PakPerkSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_search_outlined, size: 44),
          const SizedBox(height: PakPerkSpacing.sm),
          Text(
            message ?? 'Your research profile is temporarily unavailable.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: PakPerkSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: PakPerkSizes.minimumInteractive,
            ),
            child: FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ),
        ],
      ),
    ),
  );
}

String _preferredLabel(PreferredDiscoveryMode value) => switch (value) {
  PreferredDiscoveryMode.recent => 'Recent',
  PreferredDiscoveryMode.following => 'Following',
  PreferredDiscoveryMode.forYou => 'For You',
  PreferredDiscoveryMode.explore => 'Explore',
};

String _discoveryLabel(ResearchDiscoveryMode value) => switch (value) {
  ResearchDiscoveryMode.focused => 'Focused',
  ResearchDiscoveryMode.balanced => 'Balanced',
  ResearchDiscoveryMode.exploratory => 'Exploratory',
};
