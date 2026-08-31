import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/account_providers.dart';
import '../../app/library_providers.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/request_cancellation.dart';
import '../../core/document/passport_api.dart';
import '../../core/models/paper.dart';
import '../../core/models/paper_passport.dart';
import '../../core/providers.dart';
import '../paper_reader/paper_processing_controller.dart';

final passportFeedbackRemoteDataSourceProvider =
    Provider<PassportFeedbackRemoteDataSource>(
      (ref) => PassportApi(ref.watch(pakPerkDioProvider)),
    );

final passportReadRemoteDataSourceProvider =
    Provider<PassportReadRemoteDataSource>(
      (ref) => PassportApi(ref.watch(pakPerkDioProvider)),
    );

/// Public Passport reads stay anonymous, but this opaque local key still
/// invalidates in-flight display work whenever the app's account epoch or
/// identity phase changes.
final passportViewerScopeProvider = Provider<String>((ref) {
  final anonymousSessionId = ref.watch(anonymousSessionIdProvider);
  if (!ref.watch(featureFlagsProvider).accounts) {
    return 'public:$anonymousSessionId';
  }
  final session = ref.watch(authSessionProvider);
  return '${session.epoch}:${session.phase.name}:'
      '${session.accountId ?? ''}:$anonymousSessionId';
});

final class AbstractPassportArgs {
  const AbstractPassportArgs({
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.viewerScope,
  });

  final String paperId;
  final String versionKey;
  final int generation;
  final String viewerScope;

  @override
  bool operator ==(Object other) =>
      other is AbstractPassportArgs &&
      other.paperId == paperId &&
      other.versionKey == versionKey &&
      other.generation == generation &&
      other.viewerScope == viewerScope;

  @override
  int get hashCode => Object.hash(paperId, versionKey, generation, viewerScope);
}

enum AbstractPassportPhase { idle, loading, ready, failed }

final class AbstractPassportState {
  const AbstractPassportState({
    this.phase = AbstractPassportPhase.idle,
    this.passport,
    this.message,
  });

  final AbstractPassportPhase phase;
  final PaperPassport? passport;
  final String? message;
}

final abstractPassportControllerProvider = StateNotifierProvider.autoDispose
    .family<
      AbstractPassportController,
      AbstractPassportState,
      AbstractPassportArgs
    >((ref, args) {
      return AbstractPassportController(
        args: args,
        source: ref.watch(passportReadRemoteDataSourceProvider),
        scopeIsCurrent: () =>
            ref.read(passportViewerScopeProvider) == args.viewerScope,
      );
    });

final class AbstractPassportController
    extends StateNotifier<AbstractPassportState> {
  AbstractPassportController({
    required this.args,
    required PassportReadRemoteDataSource source,
    required PassportScopeFence scopeIsCurrent,
  }) : _source = source,
       _scopeIsCurrent = scopeIsCurrent,
       super(const AbstractPassportState());

  final AbstractPassportArgs args;
  final PassportReadRemoteDataSource _source;
  final PassportScopeFence _scopeIsCurrent;
  RequestCancellation? _request;
  Future<void>? _flight;
  int _serial = 0;

  Future<void> load() {
    final active = _flight;
    if (active != null) return active;
    late final Future<void> flight;
    flight = _load().whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
    });
    _flight = flight;
    return flight;
  }

  Future<void> _load() async {
    if (!_scopeIsCurrent()) return;
    if (!isValidPassportUuid(args.paperId) || args.generation <= 0) {
      throw StateError('Abstract Passport scope is invalid.');
    }
    final serial = ++_serial;
    _request?.cancel('Superseded abstract Passport request.');
    final cancellation = RequestCancellation();
    _request = cancellation;
    state = const AbstractPassportState(phase: AbstractPassportPhase.loading);
    try {
      final passport = await _source.fetchPassport(
        paperId: args.paperId,
        expectedVersionKey: args.versionKey,
        expectedGeneration: args.generation,
        cancellation: cancellation,
      );
      if (!mounted || serial != _serial || !_scopeIsCurrent()) return;
      if (passport.paperId != args.paperId ||
          passport.generation != args.generation ||
          !passportVersionMatchesVersionKey(passport, args.versionKey) ||
          !passport.isDisplayable) {
        throw const FormatException('Stale abstract Passport.');
      }
      state = AbstractPassportState(
        phase: AbstractPassportPhase.ready,
        passport: passport,
      );
    } on ApiException catch (error) {
      if (error.cancelled ||
          !mounted ||
          serial != _serial ||
          !_scopeIsCurrent()) {
        return;
      }
      state = AbstractPassportState(
        phase: AbstractPassportPhase.failed,
        message: error.isOffline
            ? 'The prepared Passport needs a connection on this device.'
            : 'The prepared Passport is temporarily unavailable.',
      );
    } on Object {
      if (!mounted || serial != _serial || !_scopeIsCurrent()) return;
      state = const AbstractPassportState(
        phase: AbstractPassportPhase.failed,
        message: 'The prepared Passport could not be verified.',
      );
    } finally {
      if (identical(_request, cancellation)) _request = null;
    }
  }

  @override
  void dispose() {
    _serial += 1;
    _request?.cancel('Abstract Passport controller disposed.');
    super.dispose();
  }
}

final class PassportControllerArgs {
  const PassportControllerArgs.authenticated({
    required this.accountId,
    required this.authEpoch,
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.passportId,
    required this.viewerScope,
  }) : anonymousSessionId = null;

  const PassportControllerArgs.anonymous({
    required this.anonymousSessionId,
    required this.paperId,
    required this.versionKey,
    required this.generation,
    required this.passportId,
    required this.viewerScope,
  }) : accountId = null,
       authEpoch = null;

  final String? accountId;
  final int? authEpoch;
  final String? anonymousSessionId;
  final String paperId;
  final String versionKey;
  final int generation;
  final String passportId;
  final String viewerScope;

  bool get authenticated => accountId != null && authEpoch != null;

  @override
  bool operator ==(Object other) =>
      other is PassportControllerArgs &&
      other.accountId == accountId &&
      other.authEpoch == authEpoch &&
      other.anonymousSessionId == anonymousSessionId &&
      other.paperId == paperId &&
      other.versionKey == versionKey &&
      other.generation == generation &&
      other.passportId == passportId &&
      other.viewerScope == viewerScope;

  @override
  int get hashCode => Object.hash(
    accountId,
    authEpoch,
    anonymousSessionId,
    paperId,
    versionKey,
    generation,
    passportId,
    viewerScope,
  );
}

enum PassportFeedbackPhase { idle, submitting, succeeded, failed }

final class PassportFeedbackState {
  const PassportFeedbackState({
    this.phase = PassportFeedbackPhase.idle,
    this.receipt,
    this.message,
  });

  final PassportFeedbackPhase phase;
  final PassportFeedbackReceipt? receipt;
  final String? message;

  bool get isSubmitting => phase == PassportFeedbackPhase.submitting;
}

final passportControllerProvider = StateNotifierProvider.autoDispose
    .family<PassportController, PassportFeedbackState, PassportControllerArgs>(
      (ref, args) => PassportController(
        args: args,
        source: ref.watch(passportFeedbackRemoteDataSourceProvider),
        scopeIsCurrent: () {
          if (ref.read(passportViewerScopeProvider) != args.viewerScope) {
            return false;
          }
          final generation = ref
              .read(
                paperProcessingControllerProvider(
                  PaperVersionKey(
                    paperId: args.paperId,
                    arxivId: args.versionKey,
                  ),
                ),
              )
              .processing
              ?.generation;
          if (generation != args.generation) return false;
          if (!args.authenticated) {
            return ref.read(anonymousSessionIdProvider) ==
                args.anonymousSessionId;
          }
          final scope = ref.read(verifiedLibraryScopeProvider);
          return scope?.accountId == args.accountId &&
              scope?.authEpoch == args.authEpoch &&
              generation == args.generation;
        },
      ),
    );

typedef PassportScopeFence = bool Function();
typedef PassportOperationIdFactory = String Function();

final class PassportController extends StateNotifier<PassportFeedbackState> {
  PassportController({
    required this.args,
    required PassportFeedbackRemoteDataSource source,
    required PassportScopeFence scopeIsCurrent,
    PassportOperationIdFactory operationId = _newOperationId,
  }) : _source = source,
       _scopeIsCurrent = scopeIsCurrent,
       _operationId = operationId,
       super(const PassportFeedbackState());

  final PassportControllerArgs args;
  final PassportFeedbackRemoteDataSource _source;
  final PassportScopeFence _scopeIsCurrent;
  final PassportOperationIdFactory _operationId;
  RequestCancellation? _request;
  _FeedbackAttempt? _retryAttempt;
  int _serial = 0;

  Future<void> submit({
    required PassportField? field,
    required PassportFeedbackType feedbackType,
    required String? detail,
  }) async {
    if (state.isSubmitting || !_scopeIsCurrent()) return;
    if (!isValidPassportUuid(args.paperId) ||
        !isValidPassportUuid(args.passportId) ||
        args.generation <= 0 ||
        (args.authEpoch != null && args.authEpoch! < 0) ||
        (args.authenticated == (args.anonymousSessionId != null))) {
      throw StateError('Passport feedback scope is invalid.');
    }
    if (field != null &&
        (!field.serverValidated || !isValidPassportUuid(field.id))) {
      throw StateError('Only a verified Passport field can receive feedback.');
    }
    final normalizedDetail = normalizePassportFeedbackDetail(detail);
    final fingerprint = [
      args.passportId,
      field?.id ?? '',
      feedbackType.wireValue,
      normalizedDetail ?? '',
    ].join('\u0000');
    final previous = _retryAttempt;
    final attempt = previous?.fingerprint == fingerprint
        ? previous!
        : _FeedbackAttempt(
            fingerprint: fingerprint,
            operationId: _operationId().toLowerCase(),
          );
    if (!isValidPassportUuid(attempt.operationId)) {
      throw StateError('Passport feedback operation id is invalid.');
    }
    _retryAttempt = attempt;
    final serial = ++_serial;
    _request?.cancel('Superseded Passport feedback request.');
    final cancellation = RequestCancellation();
    _request = cancellation;
    state = const PassportFeedbackState(
      phase: PassportFeedbackPhase.submitting,
      message: 'Sending correction…',
    );
    try {
      final receipt = await _source.submitFeedback(
        paperId: args.paperId,
        passportId: args.passportId,
        fieldId: field?.id,
        feedbackType: feedbackType,
        detail: normalizedDetail,
        operationId: attempt.operationId,
        expectedAuthEpoch: args.authEpoch,
        anonymousSessionId: args.anonymousSessionId,
        cancellation: cancellation,
      );
      if (!mounted || serial != _serial || !_scopeIsCurrent()) return;
      _retryAttempt = null;
      state = PassportFeedbackState(
        phase: PassportFeedbackPhase.succeeded,
        receipt: receipt,
        message: receipt.replayed
            ? 'Correction already received.'
            : 'Correction received for review.',
      );
    } on ApiException catch (error) {
      if (error.cancelled ||
          !mounted ||
          serial != _serial ||
          !_scopeIsCurrent()) {
        return;
      }
      state = PassportFeedbackState(
        phase: PassportFeedbackPhase.failed,
        message: error.code == 'STALE_PASSPORT'
            ? 'This Passport changed. Close it and reopen the current version.'
            : error.isOffline
            ? 'Reconnect to send this correction.'
            : 'The correction could not be sent. Try again.',
      );
    } on Object {
      if (!mounted || serial != _serial || !_scopeIsCurrent()) return;
      state = const PassportFeedbackState(
        phase: PassportFeedbackPhase.failed,
        message: 'The correction could not be sent. Try again.',
      );
    } finally {
      if (identical(_request, cancellation)) _request = null;
    }
  }

  void clearStatus() {
    if (state.isSubmitting) return;
    state = const PassportFeedbackState();
  }

  @override
  void dispose() {
    _serial += 1;
    _request?.cancel('Passport feedback controller disposed.');
    super.dispose();
  }
}

final class _FeedbackAttempt {
  const _FeedbackAttempt({
    required this.fingerprint,
    required this.operationId,
  });

  final String fingerprint;
  final String operationId;
}

String _newOperationId() => const Uuid().v7();
