import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/paper_resolution/paper_input_classifier.dart';
import '../../core/library/library_models.dart';
import '../../core/paper_resolution/paper_resolution_api.dart';
import '../../core/paper_resolution/paper_resolution_models.dart';
import '../../design_system/colors.dart';
import '../../design_system/motion.dart';
import '../../design_system/radii.dart';
import '../../design_system/spacing.dart';
import 'paper_import_controller.dart';
import 'paper_search_results.dart';

/// Presents the reusable account-scoped add-paper task.
///
/// The future completes only when the user confirms the success state with
/// Done. Interactive dismissal returns null. Callers that need an immediate
/// refresh signal can also use [onImported]. When supplied,
/// [accountScopeListenable] must publish null or a new generation as soon as
/// account authority changes; active transport work is then cancelled.
Future<PaperImportResult?> showAddPaperSheet({
  required BuildContext context,
  required PaperResolutionRemoteDataSource remote,
  required PaperImportAccountScope scope,
  PaperInputClassifier classifier = const PaperInputClassifier(),
  PaperImportOperationIdFactory? operationId,
  ValueChanged<PaperImportResult>? onImported,
  ValueChanged<PaperImportResult>? onOrganize,
  PaperImportLifecycleCallback? onLifecycle,
  ValueListenable<PaperImportAccountScope?>? accountScopeListenable,
  String initialInput = '',
  LibrarySaveSourceKind? initialSaveSourceKind,
  bool useRootNavigator = true,
  bool titleSearchEnabled = true,
  bool remindersAvailable = false,
}) async {
  final reducedMotion = platformPrefersReducedMotion(context);
  String? latestOperationId;
  var closedReported = false;
  void reportLifecycle(PaperImportLifecycleEvent event) {
    latestOperationId = event.operationId ?? latestOperationId;
    if (event.phase == PaperImportLifecyclePhase.closed) closedReported = true;
    onLifecycle?.call(event);
  }

  final result = await showModalBottomSheet<PaperImportResult>(
    context: context,
    useRootNavigator: useRootNavigator,
    useSafeArea: false,
    isScrollControlled: true,
    showDragHandle: false,
    enableDrag: true,
    isDismissible: true,
    requestFocus: true,
    barrierLabel: 'Dismiss Add paper',
    sheetAnimationStyle: AnimationStyle(
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.standard,
      reverseDuration: reducedMotion
          ? PakPerkMotion.instant
          : PakPerkMotion.quick,
    ),
    builder: (sheetContext) => _OwnedAddPaperSheet(
      remote: remote,
      scope: scope,
      classifier: classifier,
      operationId: operationId,
      onImported: onImported,
      onOrganize: onOrganize,
      onLifecycle: reportLifecycle,
      accountScopeListenable: accountScopeListenable,
      initialInput: initialInput,
      initialSaveSourceKind: initialSaveSourceKind,
      titleSearchEnabled: titleSearchEnabled,
      remindersAvailable: remindersAvailable,
    ),
  );
  if (!closedReported) {
    reportLifecycle(
      PaperImportLifecycleEvent(
        phase: PaperImportLifecyclePhase.closed,
        operationId: result?.item.lastOperationId ?? latestOperationId,
        result: result,
      ),
    );
  }
  return result;
}

class _OwnedAddPaperSheet extends StatefulWidget {
  const _OwnedAddPaperSheet({
    required this.remote,
    required this.scope,
    required this.classifier,
    required this.operationId,
    required this.onImported,
    required this.onOrganize,
    required this.onLifecycle,
    required this.accountScopeListenable,
    required this.initialInput,
    required this.initialSaveSourceKind,
    required this.titleSearchEnabled,
    required this.remindersAvailable,
  });

  final PaperResolutionRemoteDataSource remote;
  final PaperImportAccountScope scope;
  final PaperInputClassifier classifier;
  final PaperImportOperationIdFactory? operationId;
  final ValueChanged<PaperImportResult>? onImported;
  final ValueChanged<PaperImportResult>? onOrganize;
  final PaperImportLifecycleCallback? onLifecycle;
  final ValueListenable<PaperImportAccountScope?>? accountScopeListenable;
  final String initialInput;
  final LibrarySaveSourceKind? initialSaveSourceKind;
  final bool titleSearchEnabled;
  final bool remindersAvailable;

  @override
  State<_OwnedAddPaperSheet> createState() => _OwnedAddPaperSheetState();
}

class _OwnedAddPaperSheetState extends State<_OwnedAddPaperSheet> {
  late final PaperImportController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PaperImportController(
      remote: widget.remote,
      scope: widget.accountScopeListenable == null
          ? widget.scope
          : widget.accountScopeListenable!.value,
      classifier: widget.classifier,
      operationId: widget.operationId,
      titleSearchEnabled: widget.titleSearchEnabled,
      initialSaveSourceKind: widget.initialSaveSourceKind,
    );
    widget.accountScopeListenable?.addListener(_handleAccountScopeChange);
    if (widget.initialInput.isNotEmpty) {
      _controller.updateInput(widget.initialInput);
    }
  }

  @override
  void didUpdateWidget(_OwnedAddPaperSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountScopeListenable != widget.accountScopeListenable) {
      oldWidget.accountScopeListenable?.removeListener(
        _handleAccountScopeChange,
      );
      widget.accountScopeListenable?.addListener(_handleAccountScopeChange);
    }
    _handleAccountScopeChange();
  }

  @override
  void dispose() {
    widget.accountScopeListenable?.removeListener(_handleAccountScopeChange);
    _controller.dispose();
    super.dispose();
  }

  void _handleAccountScopeChange() {
    _controller.updateScope(
      widget.accountScopeListenable == null
          ? widget.scope
          : widget.accountScopeListenable!.value,
    );
  }

  @override
  Widget build(BuildContext context) => AddPaperSheet(
    controller: _controller,
    onImported: widget.onImported,
    onOrganize: widget.onOrganize,
    onLifecycle: widget.onLifecycle,
    remindersAvailable: widget.remindersAvailable,
  );
}

/// The reusable sheet body. It can also be embedded in a route or test host.
///
/// The caller owns [controller]. Supplying [onDismiss] and [onDone] makes the
/// body navigation-agnostic; otherwise it pops the nearest Navigator.
class AddPaperSheet extends StatefulWidget {
  const AddPaperSheet({
    required this.controller,
    this.onImported,
    this.onOrganize,
    this.onLifecycle,
    this.onDismiss,
    this.onDone,
    this.autofocus = true,
    this.remindersAvailable = false,
    super.key,
  });

  final PaperImportController controller;
  final ValueChanged<PaperImportResult>? onImported;
  final ValueChanged<PaperImportResult>? onOrganize;
  final PaperImportLifecycleCallback? onLifecycle;
  final VoidCallback? onDismiss;
  final ValueChanged<PaperImportResult>? onDone;
  final bool autofocus;
  final bool remindersAvailable;

  @override
  State<AddPaperSheet> createState() => _AddPaperSheetState();
}

class _AddPaperSheetState extends State<AddPaperSheet> {
  late final TextEditingController _textController;
  final FocusNode _inputFocus = FocusNode(debugLabel: 'add-paper-input');
  String? _reportedOperationId;
  String? _latestOperationId;
  String? _activeOperationId;
  String? _lastLifecycleFingerprint;
  bool _closedReported = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: widget.controller.state.input,
    );
    widget.controller.addListener(_handleControllerChange);
    _handleControllerChange();
  }

  @override
  void didUpdateWidget(AddPaperSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChange);
    widget.controller.addListener(_handleControllerChange);
    _syncTextFromController();
    _reportedOperationId = null;
    _latestOperationId = null;
    _activeOperationId = null;
    _lastLifecycleFingerprint = null;
    _closedReported = false;
    _handleControllerChange();
  }

  @override
  void dispose() {
    _emitClosed();
    widget.controller.removeListener(_handleControllerChange);
    _textController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reducedMotion = platformPrefersReducedMotion(context);
    final availableHeight =
        media.size.height - media.viewInsets.bottom - media.viewPadding.top;
    final maximumHeight = availableHeight > 0
        ? availableHeight
        : media.size.height;
    final theme = Theme.of(context);

    return AnimatedPadding(
      key: const ValueKey('add-paper-keyboard-padding'),
      duration: reducedMotion ? PakPerkMotion.instant : PakPerkMotion.crossFade,
      curve: PakPerkMotion.enter,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        key: const ValueKey('add-paper-safe-area'),
        top: false,
        left: true,
        right: true,
        bottom: true,
        minimum: const EdgeInsets.only(bottom: PakPerkSpacing.xs),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maximumHeight),
          child: Material(
            color:
                theme.bottomSheetTheme.modalBackgroundColor ??
                context.pakPerkColors.raisedPaper,
            shape:
                theme.bottomSheetTheme.shape ??
                const RoundedRectangleBorder(borderRadius: PakPerkRadii.sheet),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              label: 'Add paper modal sheet',
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, child) => _buildContent(
                  context,
                  widget.controller.state,
                  reducedMotion,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    PaperImportState state,
    bool reducedMotion,
  ) {
    final inputEnabled =
        state.phase != PaperImportPhase.importing &&
        state.phase != PaperImportPhase.succeeded &&
        state.phase != PaperImportPhase.unavailable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AddPaperDragHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PakPerkSpacing.lg,
            0,
            PakPerkSpacing.xs,
            PakPerkSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  namesRoute: true,
                  child: Text(
                    'Add a paper',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('add-paper-close'),
                tooltip: 'Close Add paper',
                onPressed: _dismiss,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PakPerkSpacing.lg),
          child: TextField(
            key: const ValueKey('add-paper-input'),
            controller: _textController,
            focusNode: _inputFocus,
            autofocus: widget.autofocus,
            enabled: inputEnabled,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.text,
            onChanged: widget.controller.updateInput,
            onSubmitted: (_) => _submitFromKeyboard(state),
            scrollPadding: const EdgeInsets.only(bottom: 120),
            decoration: InputDecoration(
              labelText: 'Paste an arXiv link or search by paper title',
              hintText: 'https://arxiv.org/abs/…',
              helperText: widget.controller.titleSearchEnabled
                  ? 'You can also enter an arXiv ID. Titles search '
                        'automatically after you pause.'
                  : 'Title search is unavailable. Paste an arXiv link or ID.',
              prefixIcon: const Icon(Icons.add_link_rounded),
              suffixIcon: _textController.text.isEmpty || !inputEnabled
                  ? null
                  : IconButton(
                      key: const ValueKey('add-paper-clear'),
                      tooltip: 'Clear paper entry',
                      onPressed: widget.controller.clear,
                      icon: const Icon(Icons.clear_rounded),
                    ),
            ),
          ),
        ),
        const SizedBox(height: PakPerkSpacing.sm),
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            key: const ValueKey('add-paper-scroll-view'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(
              PakPerkSpacing.lg,
              0,
              PakPerkSpacing.lg,
              PakPerkSpacing.md,
            ),
            child: AnimatedSwitcher(
              key: const ValueKey('add-paper-state-switcher'),
              duration: reducedMotion
                  ? PakPerkMotion.instant
                  : PakPerkMotion.crossFade,
              switchInCurve: PakPerkMotion.enter,
              switchOutCurve: PakPerkMotion.exit,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _stateBody(context, state),
            ),
          ),
        ),
        _BottomAction(
          state: state,
          onSubmit: () => unawaited(widget.controller.submit()),
          onDone: state.result == null ? null : () => _finish(state.result!),
          onOrganize: state.result == null || widget.onOrganize == null
              ? null
              : () => _organize(state.result!),
          remindersAvailable: widget.remindersAvailable,
        ),
      ],
    );
  }

  Widget _stateBody(BuildContext context, PaperImportState state) {
    return switch (state.phase) {
      PaperImportPhase.unavailable => const _InfoPanel(
        key: ValueKey('add-paper-unavailable'),
        icon: Icons.lock_outline_rounded,
        title: 'Account verification required',
        message: 'Close this sheet, verify your account, and try again.',
      ),
      PaperImportPhase.idle => _InfoPanel(
        key: ValueKey('add-paper-idle'),
        icon: Icons.auto_stories_outlined,
        title: 'Add directly or search',
        message: widget.controller.titleSearchEnabled
            ? 'Paste a canonical arXiv link or ID to add it directly. '
                  'A paper title shows candidates for you to choose.'
            : 'Paste a canonical arXiv link or ID to add it directly.',
      ),
      PaperImportPhase.ready => _ExactReadyPanel(
        key: const ValueKey('add-paper-ready'),
        identifier: state.classification!.identifier!.queryId,
      ),
      PaperImportPhase.waitingForSearch => const _InfoPanel(
        key: ValueKey('add-paper-waiting'),
        icon: Icons.search_rounded,
        title: 'Ready to search',
        message: 'Searching begins after a short pause in typing.',
      ),
      PaperImportPhase.searching => const _ProgressPanel(
        key: ValueKey('add-paper-searching'),
        semanticsLabel: 'Searching arXiv for matching papers',
        message: 'Searching arXiv…',
      ),
      PaperImportPhase.choosingCandidate => PaperSearchResults(
        key: const ValueKey('add-paper-results'),
        candidates: state.candidates,
        selectedArxivId: state.selectedArxivId,
        onSelected: widget.controller.selectCandidate,
      ),
      PaperImportPhase.importing => _ProgressPanel(
        key: const ValueKey('add-paper-importing'),
        semanticsLabel: 'Adding paper to To Read',
        message: 'Adding ${state.placeholder?.label ?? 'this paper'}…',
      ),
      PaperImportPhase.succeeded => _SuccessPanel(
        key: const ValueKey('add-paper-succeeded'),
        result: state.result!,
      ),
      PaperImportPhase.failed => Column(
        key: const ValueKey('add-paper-failed'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FailurePanel(
            failure: state.failure!,
            onRetry: state.failure!.retryable
                ? () => unawaited(widget.controller.retry())
                : null,
          ),
          if (state.candidates.isNotEmpty) ...[
            const SizedBox(height: PakPerkSpacing.md),
            PaperSearchResults(
              candidates: state.candidates,
              selectedArxivId: state.selectedArxivId,
              onSelected: widget.controller.selectCandidate,
            ),
          ],
        ],
      ),
    };
  }

  void _submitFromKeyboard(PaperImportState state) {
    if (state.canSubmit) {
      unawaited(widget.controller.submit());
    } else if (state.isTitle && !state.busy) {
      unawaited(widget.controller.searchNow());
    }
  }

  void _handleControllerChange() {
    _syncTextFromController();
    final state = widget.controller.state;
    _emitStateLifecycle(state);
    final result = state.result;
    final operationId = result?.item.lastOperationId;
    if (result == null || operationId == _reportedOperationId) return;
    _reportedOperationId = operationId;
    widget.onImported?.call(result);
  }

  void _emitStateLifecycle(PaperImportState state) {
    final event = switch (state.phase) {
      PaperImportPhase.importing => PaperImportLifecycleEvent(
        phase: PaperImportLifecyclePhase.importing,
        operationId: state.placeholder!.operationId,
        placeholder: state.placeholder,
      ),
      PaperImportPhase.failed => PaperImportLifecycleEvent(
        phase: PaperImportLifecyclePhase.failed,
        operationId: state.placeholder?.operationId,
        placeholder: state.placeholder,
        failure: state.failure,
      ),
      PaperImportPhase.succeeded => PaperImportLifecycleEvent(
        phase: PaperImportLifecyclePhase.succeeded,
        operationId: state.result!.item.lastOperationId,
        result: state.result,
      ),
      _ => null,
    };
    final abandonedOperationId = _activeOperationId;
    if (abandonedOperationId != null &&
        event?.operationId != abandonedOperationId) {
      widget.onLifecycle?.call(
        PaperImportLifecycleEvent(
          phase: PaperImportLifecyclePhase.cancelled,
          operationId: abandonedOperationId,
        ),
      );
      _activeOperationId = null;
      _lastLifecycleFingerprint = null;
    }
    if (event == null) return;
    final fingerprint =
        '${event.phase.name}\u0000${event.operationId ?? ''}'
        '\u0000${event.failure?.code ?? ''}';
    if (fingerprint == _lastLifecycleFingerprint) return;
    _lastLifecycleFingerprint = fingerprint;
    _latestOperationId = event.operationId ?? _latestOperationId;
    switch (event.phase) {
      case PaperImportLifecyclePhase.importing:
        _activeOperationId = event.operationId;
      case PaperImportLifecyclePhase.failed:
        _activeOperationId = event.failure?.retryable ?? false
            ? event.operationId
            : null;
      case PaperImportLifecyclePhase.succeeded ||
          PaperImportLifecyclePhase.cancelled ||
          PaperImportLifecyclePhase.closed:
        _activeOperationId = null;
    }
    widget.onLifecycle?.call(event);
  }

  void _emitClosed() {
    if (_closedReported) return;
    _closedReported = true;
    _activeOperationId = null;
    widget.onLifecycle?.call(
      PaperImportLifecycleEvent(
        phase: PaperImportLifecyclePhase.closed,
        operationId: _latestOperationId,
        result: widget.controller.state.result,
      ),
    );
  }

  void _syncTextFromController() {
    final input = widget.controller.state.input;
    if (_textController.text == input) return;
    _textController.value = TextEditingValue(
      text: input,
      selection: TextSelection.collapsed(offset: input.length),
    );
  }

  void _dismiss() {
    _emitClosed();
    final callback = widget.onDismiss;
    if (callback != null) {
      callback();
      return;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator?.canPop() ?? false) navigator!.pop();
  }

  void _finish(PaperImportResult result) {
    _emitClosed();
    final callback = widget.onDone;
    if (callback != null) {
      callback(result);
      return;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator?.canPop() ?? false) navigator!.pop(result);
  }

  void _organize(PaperImportResult result) {
    widget.onOrganize?.call(result);
    _finish(result);
  }
}

class _AddPaperDragHandle extends StatelessWidget {
  const _AddPaperDragHandle();

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('add-paper-drag-handle'),
    container: true,
    label: 'Drag handle',
    hint: 'Swipe down to dismiss Add paper',
    excludeSemantics: true,
    child: SizedBox(
      height: 28,
      child: Center(
        child: Container(
          width: 36,
          height: 5,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: .42),
            borderRadius: BorderRadius.circular(PakPerkRadii.pill),
          ),
        ),
      ),
    ),
  );
}

class _BottomAction extends StatelessWidget {
  const _BottomAction({
    required this.state,
    required this.onSubmit,
    required this.onDone,
    required this.onOrganize,
    required this.remindersAvailable,
  });

  final PaperImportState state;
  final VoidCallback onSubmit;
  final VoidCallback? onDone;
  final VoidCallback? onOrganize;
  final bool remindersAvailable;

  @override
  Widget build(BuildContext context) {
    if (state.phase == PaperImportPhase.unavailable ||
        (state.phase == PaperImportPhase.failed &&
            !(state.failure?.retryable ?? false))) {
      return const SizedBox(height: PakPerkSpacing.xs);
    }
    final (label, action) = switch (state.phase) {
      PaperImportPhase.succeeded => ('Done', onDone),
      PaperImportPhase.ready => ('Add to To Read', onSubmit),
      PaperImportPhase.choosingCandidate when state.selectedCandidate != null =>
        ('Add selected paper', onSubmit),
      PaperImportPhase.importing => ('Adding…', null),
      PaperImportPhase.searching ||
      PaperImportPhase.waitingForSearch => ('Searching…', null),
      PaperImportPhase.failed => ('Try again above', null),
      _ => ('Add to To Read', null),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.pakPerkColors.raisedPaper,
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: .08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PakPerkSpacing.lg,
          PakPerkSpacing.sm,
          PakPerkSpacing.lg,
          PakPerkSpacing.sm,
        ),
        child: state.phase == PaperImportPhase.succeeded && onOrganize != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('add-paper-organize'),
                    onPressed: onOrganize,
                    icon: Icon(
                      remindersAvailable
                          ? Icons.alarm_add_outlined
                          : Icons.tune_rounded,
                    ),
                    label: Text(
                      remindersAvailable
                          ? 'Organize or remind'
                          : 'Organize paper',
                    ),
                  ),
                  const SizedBox(height: PakPerkSpacing.sm),
                  OutlinedButton(
                    key: const ValueKey('add-paper-done'),
                    onPressed: onDone,
                    child: const Text('Done'),
                  ),
                ],
              )
            : FilledButton(
                key: const ValueKey('add-paper-primary-action'),
                onPressed: action,
                child: Text(label),
              ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: PakPerkSpacing.sm),
    child: Column(
      children: [
        Icon(
          icon,
          size: 30,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: PakPerkSpacing.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: PakPerkSpacing.xs),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

class _ExactReadyPanel extends StatelessWidget {
  const _ExactReadyPanel({required this.identifier, super.key});

  final String identifier;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Ready to add arXiv paper $identifier',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              color: context.pakPerkColors.success,
            ),
            const SizedBox(width: PakPerkSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ready to add',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: PakPerkSpacing.xxs),
                  Text(
                    'arXiv $identifier',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.semanticsLabel,
    required this.message,
    super.key,
  });

  final String semanticsLabel;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: semanticsLabel,
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: PakPerkSpacing.xl),
      child: Column(
        children: [
          const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: PakPerkSpacing.md),
          Text(message, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    ),
  );
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.failure, required this.onRetry});

  final PaperImportFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: '${failure.title}. ${failure.message}',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: PakPerkRadii.input,
      ),
      child: Padding(
        padding: const EdgeInsets.all(PakPerkSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              failure.title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: PakPerkSpacing.xs),
            Text(
              failure.message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: PakPerkSpacing.sm),
              FilledButton.tonalIcon(
                key: const ValueKey('add-paper-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _SuccessPanel extends StatelessWidget {
  const _SuccessPanel({required this.result, super.key});

  final PaperImportResult result;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: '${result.paper.title} added to To Read',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: PakPerkSpacing.lg),
      child: Column(
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 42,
            color: context.pakPerkColors.success,
          ),
          const SizedBox(height: PakPerkSpacing.sm),
          Text(
            'Added to To Read',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: PakPerkSpacing.xs),
          Text(
            result.paper.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}
