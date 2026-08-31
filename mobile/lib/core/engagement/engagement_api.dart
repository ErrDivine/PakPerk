import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import 'engagement_models.dart';

abstract interface class EngagementRemoteDataSource {
  Future<ReadingBrief?> currentBrief({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ReadingBrief> createBrief({
    required String operationId,
    required EngagementRecommendationMode? recommendationMode,
    required String? category,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<ReadingBrief> updateBriefProgress({
    required String briefId,
    required String operationId,
    required int expectedProgressRevision,
    required int position,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<List<Subscription>> subscriptions({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<Subscription> createSubscription({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<Subscription> updateSubscription({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<Subscription> deleteSubscription({
    required String operationId,
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<List<InAppNotification>> notifications({
    required int expectedAuthEpoch,
    int limit = 25,
    RequestCancellation? cancellation,
  });

  Future<int> markNotificationRead({
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<int> dismissNotification({
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<int> markAllNotificationsRead({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<NotificationPreferences> notificationPreferences({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<NotificationPreferences> updateNotificationPreferences({
    required String operationId,
    required NotificationPreferences preferences,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class EngagementApi implements EngagementRemoteDataSource {
  const EngagementApi(this._dio);

  final Dio _dio;

  @override
  Future<ReadingBrief?> currentBrief({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _authEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/me/reading-briefs/current',
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      final json = _envelope(response.data, 'brief');
      return json == null ? null : ReadingBrief.fromJson(_map(json));
    });
  }

  @override
  Future<ReadingBrief> createBrief({
    required String operationId,
    required EngagementRecommendationMode? recommendationMode,
    required String? category,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _mutation(operationId, expectedAuthEpoch);
    final normalizedCategory = category?.trim();
    if (normalizedCategory != null &&
        (normalizedCategory.isEmpty || normalizedCategory.length > 32)) {
      throw ArgumentError.value(category, 'category');
    }
    return _briefMutation(
      () => _dio.post<Object?>(
        '/v1/me/reading-briefs',
        data: {
          'operation_id': operationId,
          if (recommendationMode != null)
            'recommendation_mode': recommendationMode.wireValue,
          'category': normalizedCategory,
        },
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(operationId, expectedAuthEpoch),
      ),
    );
  }

  @override
  Future<ReadingBrief> updateBriefProgress({
    required String briefId,
    required String operationId,
    required int expectedProgressRevision,
    required int position,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _uuid(briefId, 'briefId');
    _mutation(operationId, expectedAuthEpoch);
    if (expectedProgressRevision < 1 || position < 0 || position > 25) {
      throw ArgumentError('Invalid reading-brief progress.');
    }
    return _briefMutation(
      () => _dio.post<Object?>(
        '/v1/me/reading-briefs/$briefId/progress',
        data: {
          'operation_id': operationId,
          'expected_progress_revision': expectedProgressRevision,
          'position': position,
        },
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(operationId, expectedAuthEpoch),
      ),
    );
  }

  @override
  Future<List<Subscription>> subscriptions({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _authEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/subscriptions',
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      final json = _map(response.data);
      _exactKeys(json, const {'items'});
      final items = json['items'];
      if (items is! List || items.length > 100) {
        throw const FormatException('Invalid subscription list.');
      }
      return List.unmodifiable(
        items.map((value) => Subscription.fromJson(_map(value))),
      );
    });
  }

  @override
  Future<Subscription> createSubscription({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _subscriptionMutation(
    operationId: operationId,
    id: id,
    kind: kind,
    key: key,
    label: label,
    savedSearchId: savedSearchId,
    frequency: frequency,
    expectedAuthEpoch: expectedAuthEpoch,
    request: (data, options) => _dio.post<Object?>(
      '/v1/subscriptions',
      data: {...data, 'id': id},
      cancelToken: cancellation?.dioToken,
      options: options,
    ),
  );

  @override
  Future<Subscription> updateSubscription({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _subscriptionMutation(
    operationId: operationId,
    id: id,
    kind: kind,
    key: key,
    label: label,
    savedSearchId: savedSearchId,
    frequency: frequency,
    expectedAuthEpoch: expectedAuthEpoch,
    request: (data, options) => _dio.patch<Object?>(
      '/v1/subscriptions/$id',
      data: data,
      cancelToken: cancellation?.dioToken,
      options: options,
    ),
  );

  @override
  Future<Subscription> deleteSubscription({
    required String operationId,
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _uuid(id, 'id');
    _mutation(operationId, expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.delete<Object?>(
        '/v1/subscriptions/$id',
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(operationId, expectedAuthEpoch),
      );
      return Subscription.fromJson(
        _map(_envelope(response.data, 'subscription')),
      );
    });
  }

  @override
  Future<List<InAppNotification>> notifications({
    required int expectedAuthEpoch,
    int limit = 25,
    RequestCancellation? cancellation,
  }) {
    _authEpoch(expectedAuthEpoch);
    if (limit < 1 || limit > 50) throw ArgumentError.value(limit, 'limit');
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/notifications',
        queryParameters: {'limit': limit},
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      final json = _map(response.data);
      _exactKeys(json, const {'items'});
      final items = json['items'];
      if (items is! List || items.length > limit) {
        throw const FormatException('Invalid notification list.');
      }
      return List.unmodifiable(
        items.map((value) => InAppNotification.fromJson(_map(value))),
      );
    });
  }

  @override
  Future<int> markNotificationRead({
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _notificationMutation(
    '/v1/notifications/${_uuid(id, 'id')}/read',
    expectedAuthEpoch,
    cancellation,
  );

  @override
  Future<int> dismissNotification({
    required String id,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _notificationMutation(
    '/v1/notifications/${_uuid(id, 'id')}/dismiss',
    expectedAuthEpoch,
    cancellation,
  );

  @override
  Future<int> markAllNotificationsRead({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) => _notificationMutation(
    '/v1/notifications/read-all',
    expectedAuthEpoch,
    cancellation,
  );

  @override
  Future<NotificationPreferences> notificationPreferences({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _authEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/notification-preferences',
        cancelToken: cancellation?.dioToken,
        options: _readOptions(expectedAuthEpoch),
      );
      return NotificationPreferences.fromJson(
        _map(_envelope(response.data, 'preferences')),
      );
    });
  }

  @override
  Future<NotificationPreferences> updateNotificationPreferences({
    required String operationId,
    required NotificationPreferences preferences,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _mutation(operationId, expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.put<Object?>(
        '/v1/notification-preferences',
        data: preferences.updateJson(operationId),
        cancelToken: cancellation?.dioToken,
        options: _mutationOptions(operationId, expectedAuthEpoch),
      );
      return NotificationPreferences.fromJson(
        _map(_envelope(response.data, 'preferences')),
      );
    });
  }

  Future<ReadingBrief> _briefMutation(
    Future<Response<Object?>> Function() action,
  ) => _request(() async {
    final response = await action();
    return ReadingBrief.fromJson(_map(_envelope(response.data, 'brief')));
  });

  Future<Subscription> _subscriptionMutation({
    required String operationId,
    required String id,
    required SubscriptionKind kind,
    required String key,
    required String label,
    required String? savedSearchId,
    required SubscriptionFrequency frequency,
    required int expectedAuthEpoch,
    required Future<Response<Object?>> Function(
      Map<String, Object?> data,
      Options options,
    )
    request,
  }) {
    _uuid(id, 'id');
    _mutation(operationId, expectedAuthEpoch);
    final normalizedKey = _bounded(key, 'key');
    final normalizedLabel = _bounded(label, 'label');
    if (savedSearchId != null) _uuid(savedSearchId, 'savedSearchId');
    if ((kind == SubscriptionKind.savedQuery) != (savedSearchId != null)) {
      throw ArgumentError('Saved-query identity does not match kind.');
    }
    return _request(() async {
      final response = await request({
        'operation_id': operationId,
        'kind': kind.wireValue,
        'key': normalizedKey,
        'label': normalizedLabel,
        'saved_search_id': savedSearchId,
        'frequency': frequency.name,
      }, _mutationOptions(operationId, expectedAuthEpoch));
      return Subscription.fromJson(
        _map(_envelope(response.data, 'subscription')),
      );
    });
  }

  Future<int> _notificationMutation(
    String path,
    int expectedAuthEpoch,
    RequestCancellation? cancellation,
  ) {
    _authEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.post<Object?>(
        path,
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.never,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      final affected = _envelope(response.data, 'affected');
      if (affected is! int || affected < 0) {
        throw const FormatException('Invalid notification mutation.');
      }
      return affected;
    });
  }
}

Options _readOptions(int expectedAuthEpoch) => pakPerkRequestOptions(
  auth: RequestAuthPolicy.required,
  retry: AuthRetryPolicy.safe,
  expectedAuthEpoch: expectedAuthEpoch,
);

Options _mutationOptions(String operationId, int expectedAuthEpoch) =>
    pakPerkRequestOptions(
      auth: RequestAuthPolicy.required,
      retry: AuthRetryPolicy.idempotencyProtected,
      expectedAuthEpoch: expectedAuthEpoch,
      headers: {'Idempotency-Key': operationId},
    );

Future<T> _request<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on DioException catch (error) {
    throw mapDioException(error);
  } on FormatException {
    throw _invalidResponse;
  }
}

Object? _envelope(Object? value, String key) {
  final json = _map(value);
  _exactKeys(json, {key});
  return json[key];
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Unexpected response fields.');
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

String _bounded(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 160) {
    throw ArgumentError.value(value, name);
  }
  return normalized;
}

void _authEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _mutation(String operationId, int expectedAuthEpoch) {
  _uuid(operationId, 'operationId');
  _authEpoch(expectedAuthEpoch);
}

String _uuid(String value, String name) {
  if (!_uuidPattern.hasMatch(value)) throw ArgumentError.value(value, name);
  return value;
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The reading updates service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
