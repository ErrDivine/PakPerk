import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_exception.dart';
import 'comment_models.dart';
import 'comment_repository.dart';

final class CommentThreadState {
  const CommentThreadState({
    this.items = const [],
    this.nextCursor,
    this.draft = '',
    this.loadingInitial = true,
    this.refreshing = false,
    this.loadingMore = false,
    this.sending = false,
    this.creationDisabled = false,
    this.showingCached = false,
    this.initialLoadSettled = false,
    this.draftValidationPending = false,
    this.draftInputIssue,
    this.errorMessage,
  });

  final List<PaperComment> items;
  final String? nextCursor;
  final String draft;
  final bool loadingInitial;
  final bool refreshing;
  final bool loadingMore;
  final bool sending;
  final bool creationDisabled;
  final bool showingCached;
  final bool initialLoadSettled;
  final bool draftValidationPending;
  final String? draftInputIssue;
  final String? errorMessage;

  CommentThreadState copyWith({
    List<PaperComment>? items,
    Object? nextCursor = _unset,
    String? draft,
    bool? loadingInitial,
    bool? refreshing,
    bool? loadingMore,
    bool? sending,
    bool? creationDisabled,
    bool? showingCached,
    bool? initialLoadSettled,
    bool? draftValidationPending,
    Object? draftInputIssue = _unset,
    Object? errorMessage = _unset,
  }) => CommentThreadState(
    items: items ?? this.items,
    nextCursor: identical(nextCursor, _unset)
        ? this.nextCursor
        : nextCursor as String?,
    draft: draft ?? this.draft,
    loadingInitial: loadingInitial ?? this.loadingInitial,
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    sending: sending ?? this.sending,
    creationDisabled: creationDisabled ?? this.creationDisabled,
    showingCached: showingCached ?? this.showingCached,
    initialLoadSettled: initialLoadSettled ?? this.initialLoadSettled,
    draftValidationPending:
        draftValidationPending ?? this.draftValidationPending,
    draftInputIssue: identical(draftInputIssue, _unset)
        ? this.draftInputIssue
        : draftInputIssue as String?,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
  );
}

final class CommentThreadController extends StateNotifier<CommentThreadState> {
  CommentThreadController({
    required CommentRepository repository,
    required String paperId,
    required CommentViewerScope viewer,
  }) : _repository = repository,
       _paperId = paperId,
       _viewer = viewer,
       super(const CommentThreadState());

  final CommentRepository _repository;
  final String _paperId;
  final CommentViewerScope _viewer;
  int _generation = 0;
  int _draftInputRevision = 0;
  Future<void>? _draftWrite;
  String? _queuedDraft;

  Future<void> load() async {
    if (!mounted) return;
    final generation = ++_generation;
    final cached = await _repository.loadCachedFirstPage(
      paperId: _paperId,
      viewer: _viewer,
    );
    if (!_current(generation)) return;
    if (cached != null) {
      state = state.copyWith(
        items: cached.items,
        nextCursor: cached.nextCursor,
        loadingInitial: false,
        showingCached: true,
      );
    }
    if ((_viewer.accountId, _viewer.authEpoch) case (
      final accountId?,
      final authEpoch?,
    )) {
      try {
        final draft = await _repository.loadDraft(
          accountId: accountId,
          authEpoch: authEpoch,
          paperId: _paperId,
        );
        if (!_current(generation)) return;
        // A database read started during initial hydration must never replace
        // text the user has already entered. The screen intentionally keeps a
        // non-empty visible composer when state changes, so applying a stale
        // database value here could otherwise make Send submit text different
        // from what is visible.
        if (_draftInputRevision == 0) {
          final draftBody = draft?.body ?? '';
          final draftInputIssue = validateCommentDraftInput(draftBody);
          state = state.copyWith(
            draft: draftBody,
            draftValidationPending:
                draftBody.isNotEmpty && draftInputIssue == null,
            draftInputIssue: draftInputIssue,
          );
        }
      } on CommentScopeChanged {
        return;
      } on Object {
        if (_current(generation)) {
          state = state.copyWith(
            errorMessage: 'Your saved draft could not be read.',
          );
        }
      }
    }
    if (_viewer.cacheOnly) {
      _settleRetainedLocal(generation);
      return;
    }
    await refresh(generation: generation);
  }

  Future<void> refresh({int? generation}) async {
    if (!mounted) return;
    final activeGeneration = generation ?? ++_generation;
    if (_viewer.cacheOnly) {
      _settleRetainedLocal(activeGeneration);
      return;
    }
    state = state.copyWith(
      refreshing: state.items.isNotEmpty,
      loadingInitial: state.items.isEmpty,
      errorMessage: null,
    );
    try {
      final page = await _repository.refreshFirstPage(
        paperId: _paperId,
        viewer: _viewer,
      );
      if (!_current(activeGeneration)) return;
      state = state.copyWith(
        items: page.items,
        nextCursor: page.nextCursor,
        loadingInitial: false,
        refreshing: false,
        showingCached: false,
        initialLoadSettled: true,
      );
    } on CommentScopeChanged {
      return;
    } on ApiException catch (error) {
      if (!_current(activeGeneration)) return;
      state = state.copyWith(
        loadingInitial: false,
        refreshing: false,
        initialLoadSettled: true,
        errorMessage: error.isOffline && state.items.isNotEmpty
            ? 'Offline · showing saved comments'
            : error.message,
      );
    } on Object {
      if (!_current(activeGeneration)) return;
      state = state.copyWith(
        loadingInitial: false,
        refreshing: false,
        initialLoadSettled: true,
        errorMessage: 'Comments could not be refreshed.',
      );
    }
  }

  Future<void> loadMore() async {
    if (!mounted) return;
    if (_viewer.cacheOnly) {
      state = state.copyWith(nextCursor: null, loadingMore: false);
      return;
    }
    final cursor = state.nextCursor;
    if (cursor == null || state.loadingMore) return;
    final generation = _generation;
    state = state.copyWith(loadingMore: true, errorMessage: null);
    try {
      final page = await _repository.loadPage(
        paperId: _paperId,
        viewer: _viewer,
        cursor: cursor,
      );
      if (!_current(generation)) return;
      final ids = state.items.map((item) => item.id).toSet();
      final appended = page.items.where((item) => ids.add(item.id));
      state = state.copyWith(
        items: [...state.items, ...appended],
        nextCursor: page.nextCursor,
        loadingMore: false,
      );
    } on CommentScopeChanged {
      return;
    } on ApiException catch (error) {
      if (_current(generation)) {
        state = state.copyWith(loadingMore: false, errorMessage: error.message);
      }
    } on Object {
      if (_current(generation)) {
        state = state.copyWith(
          loadingMore: false,
          errorMessage: 'More comments could not be loaded.',
        );
      }
    }
  }

  void _settleRetainedLocal(int generation) {
    if (!_current(generation)) return;
    state = state.copyWith(
      nextCursor: null,
      loadingInitial: false,
      refreshing: false,
      loadingMore: false,
      initialLoadSettled: true,
      errorMessage:
          state.errorMessage ??
          (state.items.isEmpty
              ? 'Account verification unavailable · reconnect to refresh comments.'
              : 'Account verification unavailable · showing saved comments.'),
    );
  }

  Future<void> saveDraft(String body) async {
    if (!mounted) return;
    _draftInputRevision += 1;
    final issue = validateCommentDraftInput(body);
    if (issue != null) {
      state = state.copyWith(
        draftValidationPending: false,
        draftInputIssue: issue,
      );
      return;
    }
    final previousIssue = state.draftInputIssue;
    state = previousIssue != null && state.errorMessage == previousIssue
        ? state.copyWith(
            draft: body,
            draftValidationPending: body.isNotEmpty,
            draftInputIssue: null,
            errorMessage: null,
          )
        : state.copyWith(
            draft: body,
            draftValidationPending: body.isNotEmpty,
            draftInputIssue: null,
          );
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null) return;
    await _persistDraft(accountId, authEpoch, body);
  }

  void completeDraftValidation({required String body, required String? issue}) {
    if (!mounted || state.draft != body) return;
    final rawIssue = validateCommentDraftInput(body);
    if (rawIssue != null) return;
    final effectiveIssue = body.isEmpty ? null : issue;
    final previousIssue = state.draftInputIssue;
    state = previousIssue != null && state.errorMessage == previousIssue
        ? state.copyWith(
            draftValidationPending: false,
            draftInputIssue: effectiveIssue,
            errorMessage: null,
          )
        : state.copyWith(
            draftValidationPending: false,
            draftInputIssue: effectiveIssue,
          );
  }

  Future<PaperComment?> send() async {
    if (!mounted) return null;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null || state.sending) return null;
    final draftInputIssue = state.draftInputIssue;
    if (draftInputIssue != null) {
      state = state.copyWith(errorMessage: draftInputIssue);
      return null;
    }
    final analysis = analyzeCommentBody(state.draft);
    if (analysis.issue case final issue?) {
      state = state.copyWith(
        draftValidationPending: false,
        draftInputIssue: issue,
        errorMessage: issue,
      );
      return null;
    }
    final submittedBody = state.draft;
    final submittedRevision = _draftInputRevision;
    state = state.copyWith(
      sending: true,
      draftValidationPending: false,
      draftInputIssue: null,
      errorMessage: null,
    );
    try {
      await _draftWrite;
      if (!mounted) return null;
      final currentDraftInputIssue = state.draftInputIssue;
      if (currentDraftInputIssue != null) {
        state = state.copyWith(
          sending: false,
          errorMessage: currentDraftInputIssue,
        );
        return null;
      }
      final comment = await _repository.create(
        accountId: accountId,
        authEpoch: authEpoch,
        paperId: _paperId,
        body: submittedBody,
      );
      if (!mounted) return null;
      final inputUnchanged = _draftInputRevision == submittedRevision;
      final newerDraft = inputUnchanged ? '' : state.draft;
      final items = [
        comment,
        ...state.items.where((item) => item.id != comment.id),
      ];
      state = state.copyWith(
        items: items,
        draft: newerDraft,
        sending: false,
        draftValidationPending: inputUnchanged
            ? false
            : state.draftValidationPending,
        draftInputIssue: inputUnchanged ? null : state.draftInputIssue,
      );
      if (newerDraft.isNotEmpty) {
        await _persistDraft(accountId, authEpoch, newerDraft);
      }
      await _cacheCurrentSafely(items);
      return comment;
    } on CommentScopeChanged {
      if (mounted) state = state.copyWith(sending: false);
      return null;
    } on ApiException catch (error) {
      if (!mounted) return null;
      final creationDisabled =
          error.statusCode == 503 && error.code == 'FEATURE_DISABLED';
      state = state.copyWith(
        sending: false,
        creationDisabled: state.creationDisabled || creationDisabled,
        errorMessage: creationDisabled ? null : error.message,
      );
      return null;
    } on Object {
      if (!mounted) return null;
      state = state.copyWith(
        sending: false,
        errorMessage: 'Your draft was kept. The comment was not sent.',
      );
      return null;
    }
  }

  Future<bool> edit(PaperComment comment, String body) async {
    if (!mounted) return false;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null) return false;
    try {
      final updated = await _repository.edit(
        accountId: accountId,
        authEpoch: authEpoch,
        comment: comment,
        body: body,
      );
      if (!mounted) return false;
      final items = state.items
          .map((item) => item.id == comment.id ? updated : item)
          .toList(growable: false);
      state = state.copyWith(items: items, errorMessage: null);
      await _cacheCurrentSafely(items);
      return true;
    } on CommentScopeChanged {
      return false;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        errorMessage: error.code == 'COMMENT_EDIT_CONFLICT'
            ? 'This comment changed elsewhere. Refresh before editing again.'
            : error.message,
      );
      return false;
    } on Object {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: 'The comment could not be edited.');
      return false;
    }
  }

  Future<bool> delete(PaperComment comment) async {
    if (!mounted) return false;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null) return false;
    try {
      await _repository.delete(
        accountId: accountId,
        authEpoch: authEpoch,
        comment: comment,
      );
      if (!mounted) return false;
      final items = state.items
          .where((item) => item.id != comment.id)
          .toList(growable: false);
      state = state.copyWith(items: items, errorMessage: null);
      await _cacheCurrentSafely(items);
      return true;
    } on CommentScopeChanged {
      return false;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: error.message);
      return false;
    } on Object {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: 'The comment could not be deleted.');
      return false;
    }
  }

  Future<bool> report({
    required String commentId,
    required CommentReportReason reason,
    String? detail,
  }) async {
    if (!mounted) return false;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null) return false;
    try {
      await _repository.report(
        accountId: accountId,
        authEpoch: authEpoch,
        commentId: commentId,
        reason: reason,
        detail: detail,
      );
      if (!mounted) return false;
      state = state.copyWith(errorMessage: null);
      return true;
    } on CommentScopeChanged {
      return false;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: error.message);
      return false;
    } on Object {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: 'The report could not be sent.');
      return false;
    }
  }

  Future<bool> reportUser({
    required String userId,
    required CommentReportReason reason,
    String? detail,
  }) async {
    if (!mounted) return false;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null || userId == accountId) {
      return false;
    }
    try {
      await _repository.reportUser(
        accountId: accountId,
        authEpoch: authEpoch,
        reportedUserId: userId,
        reason: reason,
        detail: detail,
      );
      if (!mounted) return false;
      state = state.copyWith(errorMessage: null);
      return true;
    } on CommentScopeChanged {
      return false;
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: error.message);
      return false;
    } on Object {
      if (!mounted) return false;
      state = state.copyWith(
        errorMessage: 'The user report could not be sent.',
      );
      return false;
    }
  }

  Future<bool> block(CommentAuthor author) async {
    if (!mounted) return false;
    final accountId = _viewer.accountId;
    final authEpoch = _viewer.authEpoch;
    if (accountId == null || authEpoch == null) return false;
    final previous = state.items;
    final visible = previous
        .where((item) => item.author.id != author.id)
        .toList(growable: false);
    state = state.copyWith(items: visible, errorMessage: null);
    try {
      await _repository.block(
        accountId: accountId,
        authEpoch: authEpoch,
        author: author,
      );
      if (!mounted) return false;
      await _cacheCurrentSafely(visible);
      return true;
    } on CommentScopeChanged {
      if (mounted) state = state.copyWith(items: previous);
      return false;
    } on CommentLocalBlockNotPersisted {
      if (!mounted) return false;
      state = state.copyWith(
        items: previous,
        errorMessage:
            'The block could not be saved on this device. The author remains visible.',
      );
      return false;
    } on ApiException catch (error) {
      // Keep the local safety filter. The durable unconfirmed block retries
      // during reconciliation; never re-expose the author on network failure.
      if (!mounted) return false;
      state = state.copyWith(errorMessage: error.message);
      return false;
    } on Object {
      if (!mounted) return false;
      state = state.copyWith(
        errorMessage:
            'The author remains hidden on this device and will retry.',
      );
      return false;
    }
  }

  PaperComment? commentById(String id) =>
      state.items.where((item) => item.id == id).firstOrNull;

  void dismissError() {
    if (mounted) state = state.copyWith(errorMessage: null);
  }

  Future<void> _cacheCurrent(List<PaperComment> items) =>
      _repository.cacheVisibleFirstPage(
        paperId: _paperId,
        viewer: _viewer,
        page: CommentPage(
          items: items.take(50).toList(growable: false),
          nextCursor: null,
        ),
      );

  Future<void> _cacheCurrentSafely(List<PaperComment> items) async {
    try {
      await _cacheCurrent(items);
    } on Object {
      // The canonical mutation and durable block/draft state already won.
      // A later refresh can repair this bounded read-through cache.
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _persistDraft(
    String accountId,
    int authEpoch,
    String body,
  ) async {
    _queuedDraft = body;
    await (_draftWrite ??= _drainDraftWrites(accountId, authEpoch));
  }

  Future<void> _drainDraftWrites(String accountId, int authEpoch) async {
    while (_queuedDraft != null) {
      final body = _queuedDraft!;
      _queuedDraft = null;
      try {
        await _repository.saveDraft(
          accountId: accountId,
          authEpoch: authEpoch,
          paperId: _paperId,
          body: body,
        );
      } on CommentScopeChanged {
        _queuedDraft = null;
        break;
      } on Object {
        if (mounted) {
          state = state.copyWith(
            errorMessage: 'Your draft could not be saved on this device.',
          );
        }
      }
    }
    _draftWrite = null;
  }
}

final class MyCommentsState {
  const MyCommentsState({
    this.items = const [],
    this.nextCursor,
    this.loading = true,
    this.loadingMore = false,
    this.errorMessage,
  });

  final List<PaperComment> items;
  final String? nextCursor;
  final bool loading;
  final bool loadingMore;
  final String? errorMessage;

  MyCommentsState copyWith({
    List<PaperComment>? items,
    Object? nextCursor = _unset,
    bool? loading,
    bool? loadingMore,
    Object? errorMessage = _unset,
  }) => MyCommentsState(
    items: items ?? this.items,
    nextCursor: identical(nextCursor, _unset)
        ? this.nextCursor
        : nextCursor as String?,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
  );
}

final class MyCommentsController extends StateNotifier<MyCommentsState> {
  MyCommentsController({
    required CommentRepository repository,
    required VerifiedCommentScope scope,
  }) : _repository = repository,
       _scope = scope,
       super(const MyCommentsState());

  final CommentRepository _repository;
  final VerifiedCommentScope _scope;

  Future<void> load({bool more = false}) async {
    if (!mounted) return;
    if (more && (state.loadingMore || state.nextCursor == null)) return;
    state = state.copyWith(
      loading: !more,
      loadingMore: more,
      errorMessage: null,
    );
    try {
      final page = await _repository.listMyComments(
        accountId: _scope.accountId,
        authEpoch: _scope.authEpoch,
        cursor: more ? state.nextCursor : null,
      );
      if (!mounted) return;
      final existing = more ? state.items : const <PaperComment>[];
      final ids = existing.map((item) => item.id).toSet();
      state = state.copyWith(
        items: [...existing, ...page.items.where((item) => ids.add(item.id))],
        nextCursor: page.nextCursor,
        loading: false,
        loadingMore: false,
      );
    } on CommentScopeChanged {
      return;
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        errorMessage: error.message,
      );
    } on Object {
      if (!mounted) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        errorMessage: 'Your comments could not be loaded.',
      );
    }
  }
}

const _unset = Object();
