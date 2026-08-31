import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pakperk/core/api/api_exception.dart';
import 'package:pakperk/core/library/library_models.dart';
import 'package:pakperk/core/library/library_v2_api.dart';
import 'package:pakperk/core/library/library_v2_models.dart';

import '../support/fakes.dart';

void main() {
  test('v2 snapshot and ordered change feed use the exact routes', () async {
    final adapter = _LibraryV2Adapter();
    final api = LibraryV2Api(_dio(adapter));

    final items = await api.listItems(
      expectedAuthEpoch: 4,
      state: LibraryItemState.readNext,
      listId: _listId,
      tagId: _tagId,
      cursor: 'cursor',
      limit: 25,
    );
    expect(items.items.single.item.state, LibraryItemState.inbox);
    expect(adapter.requests.single.queryParameters, {
      'state': 'read_next',
      'list_id': _listId,
      'tag_id': _tagId,
      'cursor': 'cursor',
      'limit': 25,
    });

    final lists = await api.lists(expectedAuthEpoch: 4);
    final tags = await api.tags(expectedAuthEpoch: 4);
    final changes = await api.changes(afterRevision: 40, expectedAuthEpoch: 4);
    expect(lists.items.single.name, 'Methods');
    expect(tags.items.single.name, 'Evaluation');
    expect(changes.items.single.revision, 41);
    expect(
      adapter.requests.map((request) => request.path),
      containsAll([
        '/v1/library/items',
        '/v1/library/lists',
        '/v1/library/tags',
        '/v1/library/changes',
      ]),
    );
  });

  test(
    'all v2 mutations preserve the operation id and exact body shapes',
    () async {
      final adapter = _LibraryV2Adapter();
      final api = LibraryV2Api(_dio(adapter));

      await api.putItem(
        paperId: samplePaper.paperId,
        operationId: _operationId,
        state: LibraryItemState.readNext,
        privateNote: 'Compare proofs',
        saveSourceKind: LibrarySaveSourceKind.titleSearch,
        reminderAt: DateTime.parse('2026-09-03T07:30:00+08:00'),
        expectedAuthEpoch: 4,
      );
      await api.deleteItem(
        paperId: samplePaper.paperId,
        operationId: _operationId,
        expectedAuthEpoch: 4,
      );
      await api.createList(
        operationId: _operationId,
        listId: _listId,
        name: 'Methods',
        description: null,
        sortOrder: 0,
        expectedAuthEpoch: 4,
      );
      await api.updateList(
        operationId: _operationId,
        listId: _listId,
        name: 'Methods',
        description: 'Core papers',
        sortOrder: 2,
        expectedAuthEpoch: 4,
      );
      await api.deleteList(
        operationId: _operationId,
        listId: _listId,
        expectedAuthEpoch: 4,
      );
      await api.putListItem(
        operationId: _operationId,
        listId: _listId,
        paperId: samplePaper.paperId,
        positionRank: 3,
        note: null,
        expectedAuthEpoch: 4,
      );
      await api.deleteListItem(
        operationId: _operationId,
        listId: _listId,
        paperId: samplePaper.paperId,
        expectedAuthEpoch: 4,
      );
      await api.createTag(
        operationId: _operationId,
        tagId: _tagId,
        name: 'Evaluation',
        expectedAuthEpoch: 4,
      );
      await api.updateTag(
        operationId: _operationId,
        tagId: _tagId,
        name: 'Evaluation',
        expectedAuthEpoch: 4,
      );
      await api.deleteTag(
        operationId: _operationId,
        tagId: _tagId,
        expectedAuthEpoch: 4,
      );
      await api.putItemTag(
        operationId: _operationId,
        paperId: samplePaper.paperId,
        tagId: _tagId,
        expectedAuthEpoch: 4,
      );
      await api.deleteItemTag(
        operationId: _operationId,
        paperId: samplePaper.paperId,
        tagId: _tagId,
        expectedAuthEpoch: 4,
      );

      for (final request in adapter.requests) {
        expect(request.headers['Idempotency-Key'], _operationId);
      }
      expect(adapter.requests.map((request) => request.method), [
        'PUT',
        'DELETE',
        'POST',
        'PATCH',
        'DELETE',
        'PUT',
        'DELETE',
        'POST',
        'PATCH',
        'DELETE',
        'PUT',
        'DELETE',
      ]);
      expect(jsonDecode(adapter.bodies.first), {
        'operation_id': _operationId,
        'state': 'read_next',
        'private_note': 'Compare proofs',
        'save_source_kind': 'title_search',
        'reminder_at': '2026-09-02T23:30:00.000Z',
      });
      expect(adapter.bodies[1], isEmpty);
      expect(jsonDecode(adapter.bodies[5]), {
        'operation_id': _operationId,
        'position_rank': 3,
        'note': null,
      });
      expect(adapter.bodies[10], isEmpty);
    },
  );

  test(
    'closed response schemas reject unknown fields and unknown changes',
    () async {
      for (final mode in const ['unknown_field', 'unknown_change']) {
        final api = LibraryV2Api(_dio(_LibraryV2Adapter(malformed: mode)));
        await expectLater(
          mode == 'unknown_field'
              ? api.listItems(expectedAuthEpoch: 4)
              : api.changes(afterRevision: 40, expectedAuthEpoch: 4),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INVALID_API_RESPONSE',
            ),
          ),
        );
      }
    },
  );

  test('future save provenance remains nullable and never becomes Other', () {
    final json = Map<String, dynamic>.from(_item())
      ..['save_source_kind'] = 'future_source';
    expect(LibraryV2Item.fromJson(json).saveSourceKind, isNull);
  });
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.pakperk.app'))
      ..httpClientAdapter = adapter;

const _operationId = '018f47a6-4b56-7f4c-8c7a-e2656e820201';
const _listId = '018f47a6-4b56-7f4c-8c7a-e2656e820301';
const _tagId = '018f47a6-4b56-7f4c-8c7a-e2656e820401';

Map<String, Object?> _item({bool removed = false}) => {
  'paper_id': samplePaper.paperId,
  'state': 'inbox',
  'private_note': null,
  'save_source_kind': 'other',
  'reminder_at': null,
  'saved_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'reviewed_at': null,
  'archived_at': null,
  'removed': removed,
  'removed_at': removed ? '2026-08-19T10:01:00Z' : null,
  'revision': 41,
  'last_operation_id': _operationId,
};

Map<String, Object?> _list() => {
  'id': _listId,
  'name': 'Methods',
  'description': null,
  'sort_order': 0,
  'revision': 41,
  'deleted_at': null,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'last_operation_id': _operationId,
};

Map<String, Object?> _tag() => {
  'id': _tagId,
  'name': 'Evaluation',
  'revision': 41,
  'deleted_at': null,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'last_operation_id': _operationId,
};

Map<String, Object?> _listItem() => {
  'list_id': _listId,
  'paper_id': samplePaper.paperId,
  'position_rank': 0,
  'note': null,
  'revision': 41,
  'deleted_at': null,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'last_operation_id': _operationId,
};

Map<String, Object?> _itemTag() => {
  'paper_id': samplePaper.paperId,
  'tag_id': _tagId,
  'revision': 41,
  'deleted_at': null,
  'created_at': '2026-08-19T10:00:00Z',
  'updated_at': '2026-08-19T10:01:00Z',
  'last_operation_id': _operationId,
};

final class _LibraryV2Adapter implements HttpClientAdapter {
  _LibraryV2Adapter({this.malformed});

  final String? malformed;
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    final Object response = switch ((options.method, options.path)) {
      ('GET', '/v1/library/items') => {
        'items': [
          {
            'item': _item()
              ..addAll(
                malformed == 'unknown_field'
                    ? const {'future_authority': true}
                    : const {},
              ),
            'paper': samplePaper.toJson(),
          },
        ],
        'next_cursor': null,
        'sync_revision': 41,
      },
      ('GET', '/v1/library/lists') => {
        'items': [_list()],
        'sync_revision': 41,
      },
      ('GET', '/v1/library/tags') => {
        'items': [_tag()],
        'sync_revision': 41,
      },
      ('GET', '/v1/library/changes') => {
        'items': malformed == 'unknown_change'
            ? [
                {'entity': 'shared_list', 'list': _list()},
              ]
            : [
                {'entity': 'list', 'list': _list()},
              ],
        'next_after_revision': 41,
        'has_more': false,
        'sync_revision': 41,
      },
      (final method, final path)
          when (method == 'PUT' || method == 'DELETE') &&
              path == '/v1/library/papers/${samplePaper.paperId}' =>
        {'item': _item(removed: options.method == 'DELETE'), 'replayed': false},
      ('POST', '/v1/library/lists') => {'list': _list(), 'replayed': false},
      (final method, final path)
          when (method == 'PATCH' || method == 'DELETE') &&
              path == '/v1/library/lists/$_listId' =>
        {'list': _list(), 'replayed': false},
      (final method, final path)
          when (method == 'PUT' || method == 'DELETE') &&
              path ==
                  '/v1/library/lists/$_listId/papers/${samplePaper.paperId}' =>
        {'list_item': _listItem(), 'replayed': false},
      ('POST', '/v1/library/tags') => {'tag': _tag(), 'replayed': false},
      (final method, final path)
          when (method == 'PATCH' || method == 'DELETE') &&
              path == '/v1/library/tags/$_tagId' =>
        {'tag': _tag(), 'replayed': false},
      (final method, final path)
          when (method == 'PUT' || method == 'DELETE') &&
              path ==
                  '/v1/library/papers/${samplePaper.paperId}/tags/$_tagId' =>
        {'item_tag': _itemTag(), 'replayed': false},
      _ => throw StateError('${options.method} ${options.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
