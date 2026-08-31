import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import '../api/request_cancellation.dart';
import 'discovery_search_models.dart';

abstract interface class DiscoverySearchRemoteDataSource {
  Future<DiscoverySearchSuggestions> suggestions({
    required String query,
    RequestCancellation? cancellation,
  });

  Future<DiscoverySearchPage> lookup({
    required String query,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  });

  Future<DiscoverySearchPage> explore({
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  });

  Future<List<DiscoverySavedSearch>> listSaved({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  Future<DiscoverySavedSearch> save({
    required String operationId,
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });

  /// Repeat-safely removes an account-owned saved query. The server returns
  /// the same success for an already-absent or foreign-scoped identifier.
  Future<void> deleteSaved({
    required String savedSearchId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  });
}

final class DiscoverySearchApi implements DiscoverySearchRemoteDataSource {
  const DiscoverySearchApi(this._dio);
  final Dio _dio;

  @override
  Future<DiscoverySearchSuggestions> suggestions({
    required String query,
    RequestCancellation? cancellation,
  }) {
    _validateQuery(query);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/search/suggestions',
        queryParameters: {'q': query},
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.optional,
          retry: AuthRetryPolicy.safe,
        ),
      );
      return DiscoverySearchSuggestions.fromJson(_map(response.data));
    });
  }

  @override
  Future<DiscoverySearchPage> lookup({
    required String query,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) {
    _validateQuery(query);
    _validatePage(cursor, limit);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/search/lookup',
        queryParameters: {
          'q': query,
          if (cursor != null) 'cursor': cursor,
          'limit': limit,
        },
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.optional,
          retry: AuthRetryPolicy.safe,
        ),
      );
      return DiscoverySearchPage.fromJson(_map(response.data), explore: false);
    });
  }

  @override
  Future<DiscoverySearchPage> explore({
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    String? cursor,
    int limit = 20,
    RequestCancellation? cancellation,
  }) {
    _validateQuery(query);
    _validatePage(cursor, limit);
    return _request(() async {
      final response = await _dio.post<Object?>(
        '/v1/search/explore',
        data: {
          'query': query,
          'filters': filters.toJson(),
          'sort': sort.name,
          'cursor': cursor,
          'limit': limit,
        },
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.optional,
          retry: AuthRetryPolicy.safe,
        ),
      );
      return DiscoverySearchPage.fromJson(_map(response.data), explore: true);
    });
  }

  @override
  Future<List<DiscoverySavedSearch>> listSaved({
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateAuthEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.get<Object?>(
        '/v1/search/saved',
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
      final json = _map(response.data);
      if (json.keys.toSet().difference({'items'}).isNotEmpty ||
          !json.containsKey('items') ||
          json['items'] is! List) {
        throw const FormatException('Invalid saved-search list.');
      }
      return List.unmodifiable(
        (json['items']! as List).map(
          (value) => DiscoverySavedSearch.fromJson(_map(value)),
        ),
      );
    });
  }

  @override
  Future<DiscoverySavedSearch> save({
    required String operationId,
    required String query,
    required DiscoverySearchFilters filters,
    required DiscoverySearchSort sort,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateUuid(operationId, 'operationId');
    _validateQuery(query);
    _validateAuthEpoch(expectedAuthEpoch);
    return _request(() async {
      final response = await _dio.post<Object?>(
        '/v1/search/saved',
        data: {
          'operation_id': operationId,
          'query': query,
          'filters': filters.toJson(),
          'sort': sort.name,
        },
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          expectedAuthEpoch: expectedAuthEpoch,
          headers: {'Idempotency-Key': operationId},
        ),
      );
      final json = _map(response.data);
      if (json.keys.toSet().difference({'saved_search'}).isNotEmpty ||
          !json.containsKey('saved_search')) {
        throw const FormatException('Invalid saved-search envelope.');
      }
      return DiscoverySavedSearch.fromJson(_map(json['saved_search']));
    });
  }

  @override
  Future<void> deleteSaved({
    required String savedSearchId,
    required int expectedAuthEpoch,
    RequestCancellation? cancellation,
  }) {
    _validateUuid(savedSearchId, 'savedSearchId');
    _validateAuthEpoch(expectedAuthEpoch);
    return _request(() async {
      await _dio.delete<void>(
        '/v1/search/saved/$savedSearchId',
        cancelToken: cancellation?.dioToken,
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
          expectedAuthEpoch: expectedAuthEpoch,
        ),
      );
    });
  }
}

Future<T> _request<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on DioException catch (error) {
    throw mapDioException(error);
  } on FormatException {
    throw _invalidResponse;
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected object.');
}

void _validateQuery(String query) {
  final normalized = query.trim();
  if (normalized.length < 2 || normalized.length > 300) {
    throw ArgumentError.value(query, 'query');
  }
}

void _validatePage(String? cursor, int limit) {
  if (limit < 1 || limit > 50) throw ArgumentError.value(limit, 'limit');
  if (cursor != null && (cursor.isEmpty || cursor.length > 512)) {
    throw ArgumentError.value(cursor, 'cursor');
  }
}

void _validateAuthEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _validateUuid(String value, String argumentName) {
  if (!_uuid.hasMatch(value)) throw ArgumentError.value(value, argumentName);
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The search service returned invalid data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
