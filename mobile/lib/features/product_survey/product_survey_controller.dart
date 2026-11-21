import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';

class SurveyQuestion {
  const SurveyQuestion(this.id, this.text, {this.canSkip = false});
  final String id;
  final String text;
  final bool canSkip;
}

const surveyQuestions = [
  SurveyQuestion('overall', 'How has PakPerk been for you so far?'),
  SurveyQuestion(
    'discovery',
    'How is it finding papers you want to read?',
    canSkip: true,
  ),
  SurveyQuestion('reading', 'How comfortable are the text size and layout?'),
  SurveyQuestion(
    'figures',
    'How clearly do pictures, tables, and formulas show up?',
    canSkip: true,
  ),
  SurveyQuestion(
    'translation',
    'How has word lookup and translation worked for you?',
    canSkip: true,
  ),
  SurveyQuestion(
    'notes',
    'How is taking notes and finding them again?',
    canSkip: true,
  ),
  SurveyQuestion(
    'navigation',
    'How easy is it to move around and find things?',
  ),
  SurveyQuestion('speed', 'How has the app been for speed and smoothness?'),
];

final productSurveyProvider = ChangeNotifierProvider<ProductSurveyController>((
  ref,
) {
  return ProductSurveyController(
    read: () async => (await SharedPreferences.getInstance()).getString(
      ProductSurveyController.storageKey,
    ),
    write: (value) async {
      final saved = await (await SharedPreferences.getInstance()).setString(
        ProductSurveyController.storageKey,
        value,
      );
      if (!saved) throw StateError('Survey draft could not be saved');
    },
    send: (payload) => ref.read(apiClientProvider).submitProductSurvey(payload),
  );
});

/// Foreground time is monotonic; a requested reminder uses wall-clock time.
/// Only an explicit submission sends answers. Drafts stay on this device.
class ProductSurveyController extends ChangeNotifier {
  ProductSurveyController({
    required Future<String?> Function() read,
    required this.write,
    required this.send,
    DateTime Function()? now,
    Duration Function()? elapsed,
  }) : now = now ?? DateTime.now {
    final stopwatch = Stopwatch()..start();
    this.elapsed = elapsed ?? (() => stopwatch.elapsed);
    ready = _load(read);
  }

  static const storageKey = 'pakperk.product-survey.v1';
  static const invitationDelay = Duration(minutes: 15);
  final Future<void> Function(String) write;
  final Future<void> Function(Map<String, dynamic>) send;
  final DateTime Function() now;
  late final Duration Function() elapsed;
  late final Future<void> ready;
  Future<void> _writes = Future.value();
  Duration _used = Duration.zero;
  Duration? _foregroundSince;
  Duration _lastCheckpoint = Duration.zero;
  DateTime? _remindAt;
  String _status = 'waiting';
  bool _loaded = false;
  bool _disposed = false;
  bool _active = false;
  bool _wasDue = false;
  Timer? _draftTimer;
  final Map<String, int?> _answers = {};
  String _suggestions = '';
  Map<String, dynamic>? _pending;
  bool sending = false;
  bool saveFailed = false;
  bool submitFailed = false;

  Map<String, int?> get answers => Map.unmodifiable(_answers);
  String get suggestions => _suggestions;
  bool get completed => _status == 'completed';
  bool get locked => sending || _pending != null;
  bool get isLoaded => _loaded;
  int get answeredCount => _answers.length;
  Duration get used =>
      _used +
      (_foregroundSince == null
          ? Duration.zero
          : elapsed() - _foregroundSince!);
  bool get invitationDue =>
      _loaded &&
      _active &&
      _status == 'waiting' &&
      (_remindAt == null
          ? used >= invitationDelay
          : !now().isBefore(_remindAt!));
  String? get firstUnanswered {
    for (final question in surveyQuestions) {
      if (!_answers.containsKey(question.id)) return question.id;
    }
    return null;
  }

  Future<void> _load(Future<String?> Function() read) async {
    try {
      final raw = await read();
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _used = Duration(milliseconds: (data['used_ms'] as num?)?.toInt() ?? 0);
        _status =
            [
              'waiting',
              'accepted',
              'declined',
              'completed',
            ].contains(data['status'])
            ? data['status'] as String
            : 'waiting';
        _remindAt = DateTime.tryParse(data['remind_at'] as String? ?? '');
        _suggestions = data['suggestions'] as String? ?? '';
        final answers = data['answers'] as Map<String, dynamic>? ?? {};
        for (final question in surveyQuestions) {
          final value = answers[question.id];
          if (answers.containsKey(question.id) &&
              ((value is int && value >= 1 && value <= 5) ||
                  (value == null && question.canSkip))) {
            _answers[question.id] = value as int?;
          }
        }
        _pending = (data['pending'] as Map<String, dynamic>?);
      }
    } catch (_) {
      saveFailed = true;
    }
    if (_disposed) return;
    _loaded = true;
    _lastCheckpoint = elapsed();
    if (_active) _foregroundSince = elapsed();
    notifyListeners();
  }

  void setForeground(bool active) {
    if (_active == active) return;
    if (_foregroundSince != null) {
      _used = used;
      _foregroundSince = null;
    }
    _active = active;
    if (_loaded && active) _foregroundSince = elapsed();
    if (_loaded && !active) unawaited(flush());
  }

  void tick() {
    if (!_loaded || _disposed) return;
    final due = invitationDue;
    if (due != _wasDue) {
      _wasDue = due;
      notifyListeners();
    }
    if (_active && elapsed() - _lastCheckpoint >= const Duration(seconds: 30)) {
      _lastCheckpoint = elapsed();
      unawaited(flush());
    }
  }

  Future<void> choose(String choice) async {
    await ready;
    if (_disposed) return;
    if (choice == 'later') {
      _status = 'waiting';
      _remindAt = now().add(invitationDelay);
    } else {
      _status = choice == 'accept' ? 'accepted' : 'declined';
      _remindAt = null;
    }
    _wasDue = false;
    notifyListeners();
    await flush();
  }

  void answer(SurveyQuestion question, int? value) {
    if (locked || completed || !_loaded) return;
    if (value == null && !question.canSkip) return;
    if (value != null && (value < 1 || value > 5)) return;
    _answers[question.id] = value;
    _draftChanged();
  }

  void suggest(String value) {
    if (locked || completed || !_loaded) return;
    _suggestions = value;
    _draftChanged();
  }

  void _draftChanged() {
    submitFailed = false;
    notifyListeners();
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(flush()),
    );
  }

  Future<bool> flush() async {
    if (!_loaded) return false;
    _draftTimer?.cancel();
    final value = jsonEncode({
      'used_ms': used.inMilliseconds,
      'status': _status,
      'remind_at': _remindAt?.toIso8601String(),
      'answers': _answers,
      'suggestions': _suggestions,
      'pending': _pending,
    });
    var success = true;
    _writes = _writes.then((_) => write(value)).catchError((Object _) {
      success = false;
    });
    await _writes;
    if (!_disposed && saveFailed == success) {
      saveFailed = !success;
      notifyListeners();
    }
    return success;
  }

  Future<bool> submit(String locale) async {
    if (!_loaded || sending || completed || firstUnanswered != null) {
      return false;
    }
    sending = true;
    submitFailed = false;
    _pending ??= {
      'response_id': const Uuid().v4(),
      'survey_version': 1,
      'locale': locale == 'zh' ? 'zh' : 'en',
      'ratings': Map<String, int?>.of(_answers),
      'suggestions': _suggestions.trim(),
    };
    notifyListeners();
    try {
      // Persist the submission ID before sending, so retrying is idempotent.
      if (!await flush()) throw StateError('Could not save submission');
      await send(Map<String, dynamic>.of(_pending!));
      if (_disposed) return true;
      _status = 'completed';
      _pending = null;
      await flush();
      return true;
    } catch (_) {
      if (!_disposed) submitFailed = true;
      return false;
    } finally {
      if (!_disposed) {
        sending = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    unawaited(flush());
    _disposed = true;
    _draftTimer?.cancel();
    super.dispose();
  }
}
