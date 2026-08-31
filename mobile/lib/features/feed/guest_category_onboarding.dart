import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discovery/guest_discovery_preferences.dart';
import '../../design_system/motion.dart';
import '../../design_system/sizes.dart';
import '../../design_system/spacing.dart';

final guestDiscoveryPreferencesStoreProvider =
    Provider<GuestDiscoveryPreferencesStore>(
      (_) => SharedPreferencesGuestDiscoveryPreferencesStore(),
    );

final guestDiscoveryPreferencesControllerProvider =
    StateNotifierProvider.autoDispose<
      GuestDiscoveryPreferencesController,
      GuestDiscoveryPreferencesState
    >((ref) {
      final controller = GuestDiscoveryPreferencesController(
        ref.watch(guestDiscoveryPreferencesStoreProvider),
      );
      unawaited(controller.load());
      return controller;
    });

final class GuestDiscoveryPreferencesState {
  const GuestDiscoveryPreferencesState({
    this.preferences = const GuestDiscoveryPreferences.initial(),
    this.loading = true,
    this.saving = false,
    this.errorMessage,
  });

  final GuestDiscoveryPreferences preferences;
  final bool loading;
  final bool saving;
  final String? errorMessage;

  GuestDiscoveryPreferencesState copyWith({
    GuestDiscoveryPreferences? preferences,
    bool? loading,
    bool? saving,
    String? errorMessage,
    bool clearError = false,
  }) => GuestDiscoveryPreferencesState(
    preferences: preferences ?? this.preferences,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final class GuestDiscoveryPreferencesController
    extends StateNotifier<GuestDiscoveryPreferencesState> {
  GuestDiscoveryPreferencesController(this._store)
    : super(const GuestDiscoveryPreferencesState());

  final GuestDiscoveryPreferencesStore _store;
  var _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final preferences = await _store.load();
      if (!mounted || generation != _generation) return;
      state = GuestDiscoveryPreferencesState(
        preferences: preferences,
        loading: false,
      );
    } on Object {
      if (!mounted || generation != _generation) return;
      state = const GuestDiscoveryPreferencesState(
        loading: false,
        errorMessage:
            'Category choices could not be loaded. Public Recent remains available.',
      );
    }
  }

  Future<GuestDiscoveryPreferences?> complete(Iterable<String> categories) =>
      _save(
        GuestDiscoveryPreferences(
          onboardingComplete: true,
          categories: categories,
        ),
      );

  Future<GuestDiscoveryPreferences?> _save(
    GuestDiscoveryPreferences preferences,
  ) async {
    if (state.saving) return null;
    final generation = ++_generation;
    state = state.copyWith(saving: true, clearError: true);
    try {
      await _store.save(preferences);
      if (!mounted || generation != _generation) return null;
      state = GuestDiscoveryPreferencesState(
        preferences: preferences,
        loading: false,
      );
      return preferences;
    } on Object {
      if (!mounted || generation != _generation) return null;
      state = state.copyWith(
        loading: false,
        saving: false,
        errorMessage:
            'Category choices could not be saved. Public Recent remains available.',
      );
      return null;
    }
  }

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
  }
}

final class GuestCategoryOption {
  const GuestCategoryOption(this.code, this.label);

  final String code;
  final String label;
}

const guestCategoryOptions = <GuestCategoryOption>[
  GuestCategoryOption('cs.AI', 'Artificial intelligence'),
  GuestCategoryOption('cs.CL', 'Language'),
  GuestCategoryOption('cs.CV', 'Computer vision'),
  GuestCategoryOption('cs.HC', 'Human–computer interaction'),
  GuestCategoryOption('cs.IR', 'Information retrieval'),
  GuestCategoryOption('cs.LG', 'Machine learning'),
  GuestCategoryOption('stat.ML', 'Statistical learning'),
  GuestCategoryOption('q-bio.NC', 'Neurons and cognition'),
];

Future<List<String>?> showGuestCategoryOnboardingSheet({
  required BuildContext context,
  Iterable<String> initialSelection = const [],
}) {
  final reducedMotion = platformPrefersReducedMotion(context);
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: false,
    barrierLabel: 'Choose public research categories',
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (_) =>
        GuestCategoryOnboardingSheet(initialSelection: initialSelection),
  );
}

final class GuestCategoryOnboardingSheet extends StatefulWidget {
  const GuestCategoryOnboardingSheet({
    this.initialSelection = const [],
    super.key,
  });

  final Iterable<String> initialSelection;

  @override
  State<GuestCategoryOnboardingSheet> createState() =>
      _GuestCategoryOnboardingSheetState();
}

final class _GuestCategoryOnboardingSheetState
    extends State<GuestCategoryOnboardingSheet> {
  late final Set<String> _selected = widget.initialSelection.toSet();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Semantics(
      container: true,
      scopesRoute: true,
      namesRoute: true,
      label: 'Choose public research categories',
      explicitChildNodes: true,
      child: SafeArea(
        top: false,
        left: true,
        right: true,
        bottom: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * .88),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              PakPerkSpacing.lg,
              PakPerkSpacing.lg,
              PakPerkSpacing.lg,
              media.viewInsets.bottom + PakPerkSpacing.lg,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      'What would you like to see?',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.xs),
                  Text(
                    'Choose up to four public arXiv categories, or skip. '
                    'This stays on this device and is not personalization.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: PakPerkSpacing.lg),
                  Wrap(
                    spacing: PakPerkSpacing.xs,
                    runSpacing: PakPerkSpacing.xs,
                    children: [
                      for (final option in guestCategoryOptions)
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: PakPerkSizes.minimumInteractive,
                          ),
                          child: FilterChip(
                            key: ValueKey('guest-category-${option.code}'),
                            selected: _selected.contains(option.code),
                            label: Text('${option.label} · ${option.code}'),
                            onSelected:
                                _selected.length < 4 ||
                                    _selected.contains(option.code)
                                ? (selected) => setState(() {
                                    if (selected) {
                                      _selected.add(option.code);
                                    } else {
                                      _selected.remove(option.code);
                                    }
                                  })
                                : null,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: PakPerkSpacing.lg),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: FilledButton(
                      key: const ValueKey('guest-category-continue'),
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(_orderedSelection(_selected)),
                      child: const Text('Show selected categories'),
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.xs),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PakPerkSizes.minimumInteractive,
                    ),
                    child: TextButton(
                      key: const ValueKey('guest-category-skip'),
                      onPressed: () =>
                          Navigator.of(context).pop(const <String>[]),
                      child: const Text('Skip for now'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class GuestCategorySelector extends StatelessWidget {
  const GuestCategorySelector({
    required this.categories,
    required this.activeCategory,
    required this.onSelected,
    required this.onManage,
    super.key,
  });

  final List<String> categories;
  final String? activeCategory;
  final ValueChanged<String?> onSelected;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('guest-category-selector'),
    container: true,
    label: categories.isEmpty
        ? 'No public category filter selected'
        : 'Public category filter ${activeCategory ?? 'all recent'}',
    explicitChildNodes: true,
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: PakPerkSpacing.md),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: ChoiceChip(
                key: const ValueKey('guest-category-all'),
                selected: activeCategory == null,
                label: const Text('All recent'),
                onSelected: (_) => onSelected(null),
              ),
            ),
            for (final category in categories) ...[
              const SizedBox(width: PakPerkSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PakPerkSizes.minimumInteractive,
                ),
                child: ChoiceChip(
                  key: ValueKey('guest-category-filter-$category'),
                  selected: activeCategory == category,
                  label: Text(category),
                  onSelected: (_) => onSelected(category),
                ),
              ),
            ],
            const SizedBox(width: PakPerkSpacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: PakPerkSizes.minimumInteractive,
              ),
              child: TextButton.icon(
                key: const ValueKey('guest-category-manage'),
                onPressed: onManage,
                icon: const Icon(Icons.tune_rounded),
                label: Text(categories.isEmpty ? 'Choose categories' : 'Edit'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

List<String> _orderedSelection(Set<String> selected) => [
  for (final option in guestCategoryOptions)
    if (selected.contains(option.code)) option.code,
];
