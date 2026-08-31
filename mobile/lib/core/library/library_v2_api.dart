import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'library_models.dart';
import 'library_v2_models.dart';

abstract interface class LibraryV2RemoteDataSource {
  Future<LibraryV2ItemsPage> listItems({
    required int expectedAuthEpoch,
    LibraryItemState? state,
    String? listId,
    String? tagId,
    String? cursor,
    int limit = 100,
  });

  Future<LibraryV2NamedPage<LibraryV2List>> lists({
    required int expectedAuthEpoch,
  });

  Future<LibraryV2NamedPage<LibraryV2Tag>> tags({
    required int expectedAuthEpoch,
  });

  Future<LibraryV2ChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  });

  Future<LibraryV2Mutation<LibraryV2Item>> putItem({
    required String paperId,
    required String operationId,
    required LibraryItemState state,
    required String? privateNote,
    required LibrarySaveSourceKind? saveSourceKind,
    required DateTime? reminderAt,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2Item>> deleteItem({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2List>> createList({
    required String operationId,
    required String listId,
    required String name,
    required String? description,
    required int sortOrder,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2List>> updateList({
    required String operationId,
    required String listId,
    required String name,
    required String? description,
    required int sortOrder,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2List>> deleteList({
    required String operationId,
    required String listId,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2ListItem>> putListItem({
    required String operationId,
    required String listId,
    required String paperId,
    required int positionRank,
    required String? note,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2ListItem>> deleteListItem({
    required String operationId,
    required String listId,
    required String paperId,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2Tag>> createTag({
    required String operationId,
    required String tagId,
    required String name,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2Tag>> updateTag({
    required String operationId,
    required String tagId,
    required String name,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2Tag>> deleteTag({
    required String operationId,
    required String tagId,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2ItemTag>> putItemTag({
    required String operationId,
    required String paperId,
    required String tagId,
    required int expectedAuthEpoch,
  });

  Future<LibraryV2Mutation<LibraryV2ItemTag>> deleteItemTag({
    required String operationId,
    required String paperId,
    required String tagId,
    required int expectedAuthEpoch,
  });
}

final class LibraryV2Api implements LibraryV2RemoteDataSource {
  const LibraryV2Api(this._dio);

  final Dio _dio;

  @override
  Future<LibraryV2ItemsPage> listItems({
    required int expectedAuthEpoch,
    LibraryItemState? state,
    String? listId,
    String? tagId,
    String? cursor,
    int limit = 100,
  }) async {
    _validateAuthEpoch(expectedAuthEpoch);
    _validateLimit(limit);
    _optionalUuid(listId, 'listId');
    _optionalUuid(tagId, 'tagId');
    if (cursor != null && (cursor.isEmpty || cursor.length > 512)) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid cursor.');
    }
    return _read(() async {
      final response = await _dio.get<Object?>(
        '/v1/library/items',
        queryParameters: {
          if (state != null) 'state': state.storageValue,
          if (listId != null) 'list_id': listId,
          if (tagId != null) 'tag_id': tagId,
          if (cursor != null) 'cursor': cursor,
          'limit': limit,
        },
        options: _options(expectedAuthEpoch, safe: true),
      );
      return LibraryV2ItemsPage.fromJson(_jsonMap(response.data));
    });
  }

  @override
  Future<LibraryV2NamedPage<LibraryV2List>> lists({
    required int expectedAuthEpoch,
  }) {
    _validateAuthEpoch(expectedAuthEpoch);
    return _read(() async {
      final response = await _dio.get<Object?>(
        '/v1/library/lists',
        options: _options(expectedAuthEpoch, safe: true),
      );
      return _namedPage(_jsonMap(response.data), LibraryV2List.fromJson);
    });
  }

  @override
  Future<LibraryV2NamedPage<LibraryV2Tag>> tags({
    required int expectedAuthEpoch,
  }) {
    _validateAuthEpoch(expectedAuthEpoch);
    return _read(() async {
      final response = await _dio.get<Object?>(
        '/v1/library/tags',
        options: _options(expectedAuthEpoch, safe: true),
      );
      return _namedPage(_jsonMap(response.data), LibraryV2Tag.fromJson);
    });
  }

  @override
  Future<LibraryV2ChangesPage> changes({
    required int afterRevision,
    required int expectedAuthEpoch,
    int limit = 100,
  }) {
    _validateAuthEpoch(expectedAuthEpoch);
    _validateLimit(limit);
    if (afterRevision < 0) {
      throw ArgumentError.value(afterRevision, 'afterRevision');
    }
    return _read(() async {
      final response = await _dio.get<Object?>(
        '/v1/library/changes',
        queryParameters: {'after_revision': afterRevision, 'limit': limit},
        options: _options(expectedAuthEpoch, safe: true),
      );
      return LibraryV2ChangesPage.fromJson(
        _jsonMap(response.data),
        afterRevision: afterRevision,
      );
    });
  }

  @override
  Future<LibraryV2Mutation<LibraryV2Item>> putItem({
    required String paperId,
    required String operationId,
    required LibraryItemState state,
    required String? privateNote,
    required LibrarySaveSourceKind? saveSourceKind,
    required DateTime? reminderAt,
    required int expectedAuthEpoch,
  }) {
    _validateText(privateNote, 'privateNote', maximumLength: 500);
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.put<Object?>(
        '/v1/library/papers/${_uuidPath(paperId, 'paperId')}',
        data: {
          'operation_id': operationId,
          'state': state.storageValue,
          'private_note': privateNote,
          'save_source_kind': saveSourceKind?.wireValue,
          'reminder_at': reminderAt?.toUtc().toIso8601String(),
        },
        options: options,
      ),
      key: 'item',
      decode: LibraryV2Item.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2Item>> deleteItem({
    required String paperId,
    required String operationId,
    required int expectedAuthEpoch,
  }) => _mutation(
    expectedAuthEpoch: expectedAuthEpoch,
    operationId: operationId,
    invoke: (options) => _dio.delete<Object?>(
      '/v1/library/papers/${_uuidPath(paperId, 'paperId')}',
      options: options,
    ),
    key: 'item',
    decode: LibraryV2Item.fromJson,
  );

  @override
  Future<LibraryV2Mutation<LibraryV2List>> createList({
    required String operationId,
    required String listId,
    required String name,
    required String? description,
    required int sortOrder,
    required int expectedAuthEpoch,
  }) {
    _validateRequiredText(name, 'name', maximumLength: 100);
    _validateText(description, 'description', maximumLength: 500);
    _validateUuid(listId, 'listId');
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.post<Object?>(
        '/v1/library/lists',
        data: {
          'operation_id': operationId,
          'id': listId,
          'name': name,
          'description': description,
          'sort_order': sortOrder,
        },
        options: options,
      ),
      key: 'list',
      decode: LibraryV2List.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2List>> updateList({
    required String operationId,
    required String listId,
    required String name,
    required String? description,
    required int sortOrder,
    required int expectedAuthEpoch,
  }) {
    _validateRequiredText(name, 'name', maximumLength: 100);
    _validateText(description, 'description', maximumLength: 500);
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.patch<Object?>(
        '/v1/library/lists/${_uuidPath(listId, 'listId')}',
        data: {
          'operation_id': operationId,
          'name': name,
          'description': description,
          'sort_order': sortOrder,
        },
        options: options,
      ),
      key: 'list',
      decode: LibraryV2List.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2List>> deleteList({
    required String operationId,
    required String listId,
    required int expectedAuthEpoch,
  }) => _deleteNamed(
    path: '/v1/library/lists/${_uuidPath(listId, 'listId')}',
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    key: 'list',
    decode: LibraryV2List.fromJson,
  );

  @override
  Future<LibraryV2Mutation<LibraryV2ListItem>> putListItem({
    required String operationId,
    required String listId,
    required String paperId,
    required int positionRank,
    required String? note,
    required int expectedAuthEpoch,
  }) {
    _validateText(note, 'note', maximumLength: 500);
    final path = _listItemPath(listId, paperId);
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.put<Object?>(
        path,
        data: {
          'operation_id': operationId,
          'position_rank': positionRank,
          'note': note,
        },
        options: options,
      ),
      key: 'list_item',
      decode: LibraryV2ListItem.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2ListItem>> deleteListItem({
    required String operationId,
    required String listId,
    required String paperId,
    required int expectedAuthEpoch,
  }) => _deleteNamed(
    path: _listItemPath(listId, paperId),
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    key: 'list_item',
    decode: LibraryV2ListItem.fromJson,
  );

  @override
  Future<LibraryV2Mutation<LibraryV2Tag>> createTag({
    required String operationId,
    required String tagId,
    required String name,
    required int expectedAuthEpoch,
  }) {
    _validateRequiredText(name, 'name', maximumLength: 60);
    _validateUuid(tagId, 'tagId');
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.post<Object?>(
        '/v1/library/tags',
        data: {'operation_id': operationId, 'id': tagId, 'name': name},
        options: options,
      ),
      key: 'tag',
      decode: LibraryV2Tag.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2Tag>> updateTag({
    required String operationId,
    required String tagId,
    required String name,
    required int expectedAuthEpoch,
  }) {
    _validateRequiredText(name, 'name', maximumLength: 60);
    return _mutation(
      expectedAuthEpoch: expectedAuthEpoch,
      operationId: operationId,
      invoke: (options) => _dio.patch<Object?>(
        '/v1/library/tags/${_uuidPath(tagId, 'tagId')}',
        data: {'operation_id': operationId, 'name': name},
        options: options,
      ),
      key: 'tag',
      decode: LibraryV2Tag.fromJson,
    );
  }

  @override
  Future<LibraryV2Mutation<LibraryV2Tag>> deleteTag({
    required String operationId,
    required String tagId,
    required int expectedAuthEpoch,
  }) => _deleteNamed(
    path: '/v1/library/tags/${_uuidPath(tagId, 'tagId')}',
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    key: 'tag',
    decode: LibraryV2Tag.fromJson,
  );

  @override
  Future<LibraryV2Mutation<LibraryV2ItemTag>> putItemTag({
    required String operationId,
    required String paperId,
    required String tagId,
    required int expectedAuthEpoch,
  }) => _mutation(
    expectedAuthEpoch: expectedAuthEpoch,
    operationId: operationId,
    invoke: (options) =>
        _dio.put<Object?>(_itemTagPath(paperId, tagId), options: options),
    key: 'item_tag',
    decode: LibraryV2ItemTag.fromJson,
  );

  @override
  Future<LibraryV2Mutation<LibraryV2ItemTag>> deleteItemTag({
    required String operationId,
    required String paperId,
    required String tagId,
    required int expectedAuthEpoch,
  }) => _deleteNamed(
    path: _itemTagPath(paperId, tagId),
    operationId: operationId,
    expectedAuthEpoch: expectedAuthEpoch,
    key: 'item_tag',
    decode: LibraryV2ItemTag.fromJson,
  );

  Future<LibraryV2Mutation<T>> _deleteNamed<T>({
    required String path,
    required String operationId,
    required int expectedAuthEpoch,
    required String key,
    required T Function(Map<String, dynamic>) decode,
  }) => _mutation(
    expectedAuthEpoch: expectedAuthEpoch,
    operationId: operationId,
    invoke: (options) => _dio.delete<Object?>(path, options: options),
    key: key,
    decode: decode,
  );

  Future<LibraryV2Mutation<T>> _mutation<T>({
    required int expectedAuthEpoch,
    required String operationId,
    required Future<Response<Object?>> Function(Options options) invoke,
    required String key,
    required T Function(Map<String, dynamic>) decode,
  }) {
    _validateAuthEpoch(expectedAuthEpoch);
    _validateUuid(operationId, 'operationId');
    return _read(() async {
      final response = await invoke(
        _options(expectedAuthEpoch, operationId: operationId),
      );
      final json = _jsonMap(response.data);
      if (json.keys.toSet().difference({key, 'replayed'}).isNotEmpty ||
          !json.containsKey(key) ||
          !json.containsKey('replayed') ||
          json['replayed'] is! bool) {
        throw const FormatException('Invalid mutation envelope.');
      }
      return LibraryV2Mutation(
        value: decode(_jsonMap(json[key])),
        replayed: json['replayed']! as bool,
      );
    });
  }

  Options _options(
    int expectedAuthEpoch, {
    bool safe = false,
    String? operationId,
  }) => pakPerkRequestOptions(
    auth: RequestAuthPolicy.required,
    retry: safe ? AuthRetryPolicy.safe : AuthRetryPolicy.idempotencyProtected,
    expectedAuthEpoch: expectedAuthEpoch,
    headers: operationId == null ? null : {'Idempotency-Key': operationId},
  );
}

Future<T> _read<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on DioException catch (error) {
    throw mapDioException(error);
  } on FormatException {
    throw _invalidResponse;
  }
}

LibraryV2NamedPage<T> _namedPage<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic>) decode,
) {
  if (json.keys.toSet().difference({'items', 'sync_revision'}).isNotEmpty ||
      !json.containsKey('items') ||
      !json.containsKey('sync_revision')) {
    throw const FormatException('Invalid named list envelope.');
  }
  final raw = json['items'];
  final revision = json['sync_revision'];
  if (raw is! List || revision is! int || revision < 0) {
    throw const FormatException('Invalid named list envelope.');
  }
  final items = raw
      .map((value) => decode(_jsonMap(value)))
      .toList(growable: false);
  return LibraryV2NamedPage(
    items: List.unmodifiable(items),
    syncRevision: revision,
  );
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected a JSON object.');
}

void _validateLimit(int value) {
  if (value < 1 || value > 100) throw ArgumentError.value(value, 'limit');
}

void _validateAuthEpoch(int value) {
  if (value < 0) throw ArgumentError.value(value, 'expectedAuthEpoch');
}

void _validateUuid(String value, String name) {
  if (!_uuid.hasMatch(value)) throw ArgumentError.value(value, name);
}

void _optionalUuid(String? value, String name) {
  if (value != null) _validateUuid(value, name);
}

String _uuidPath(String value, String name) {
  _validateUuid(value, name);
  return Uri.encodeComponent(value);
}

String _listItemPath(String listId, String paperId) =>
    '/v1/library/lists/${_uuidPath(listId, 'listId')}/papers/'
    '${_uuidPath(paperId, 'paperId')}';

String _itemTagPath(String paperId, String tagId) =>
    '/v1/library/papers/${_uuidPath(paperId, 'paperId')}/tags/'
    '${_uuidPath(tagId, 'tagId')}';

void _validateRequiredText(
  String value,
  String name, {
  required int maximumLength,
}) {
  if (value.isEmpty) throw ArgumentError.value(value, name);
  _validateText(value, name, maximumLength: maximumLength);
}

void _validateText(String? value, String name, {required int maximumLength}) {
  if (value != null &&
      (value.length > maximumLength ||
          value.runes.any((rune) => rune < 0x20 && rune != 0x0a))) {
    throw ArgumentError.value(value, name);
  }
}

const _invalidResponse = ApiException(
  code: 'INVALID_API_RESPONSE',
  message: 'The library service returned invalid v2 data.',
  retryable: true,
  statusCode: 502,
);

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-'
  r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
