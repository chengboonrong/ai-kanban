import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:ai_kanban/features/tasks/outbox.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure.dart';

/// Records createTask calls; [next] decides each call's outcome.
class FakeApi extends Api {
  FakeApi() : super(Dio());
  final sent = <(String title, String key)>[];
  Object? Function(String title) next = (_) => null;

  @override
  Future<void> createTask(
    String boardId, {
    required String columnId,
    required String title,
    required String idempotencyKey,
  }) async {
    final failure = next(title);
    if (failure != null) throw failure;
    sent.add((title, idempotencyKey));
  }
}

final _req = RequestOptions(path: '/boards/b/tasks');
final offline = DioException.connectionError(
  requestOptions: _req,
  reason: 'down',
);
final rejected = DioException(
  requestOptions: _req,
  response: Response(
    requestOptions: _req,
    statusCode: 400,
    data: {'message': 'columnId is not on this board'},
  ),
);

const session = {
  'token': 't',
  'user': {'id': 'u1', 'login': 'ann', 'displayName': 'ann'},
};

Future<ProviderContainer> start(FakeApi api) async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionStoreProvider.overrideWithValue(SessionStore(prefs, FakeSecure())),
      initialSessionProvider.overrideWithValue(Session.fromJson(session)),
      apiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a task captured offline survives a restart and is sent once, with its original key', () async {
    final api = FakeApi()..next = (_) => offline;
    final first = await start(api);
    final outbox = first.read(outboxProvider.notifier);
    await outbox.add(
      boardId: 'b',
      columnId: 'c',
      title: 'Add GitHub login to settings',
    );
    await outbox.flush();
    expect(api.sent, isEmpty);
    final key = first.read(outboxProvider).single.key;
    first.dispose(); // app closed while offline

    api.next = (_) => null; // back online
    final second = await start(api);
    expect(
      second.read(outboxProvider).single.key,
      key,
      reason: 'draft restored from the device',
    );
    await second.read(outboxProvider.notifier).flush();
    expect(api.sent, [('Add GitHub login to settings', key)]);
    expect(second.read(outboxProvider), isEmpty);
  });

  test(
    'a rejected draft keeps its error and does not block later drafts',
    () async {
      final api = FakeApi()..next = (title) => title == 'bad' ? rejected : null;
      final c = await start(api);
      final outbox = c.read(outboxProvider.notifier);
      await outbox.add(boardId: 'b', columnId: 'gone', title: 'bad');
      await outbox.add(boardId: 'b', columnId: 'c', title: 'good');
      await outbox.flush();
      expect(api.sent.map((s) => s.$1), ['good']);
      expect(
        c.read(outboxProvider).single.error,
        'columnId is not on this board',
      );
      await outbox.discard(c.read(outboxProvider).single);
      expect(c.read(outboxProvider), isEmpty);
    },
  );

  test('a session that ends mid-send keeps the remaining drafts and sends nothing with the old token', () async {
    final api = FakeApi();
    final c = await start(api);
    final outbox = c.read(outboxProvider.notifier);
    api.next = (_) => offline;
    for (final title in ['one', 'two', 'three']) {
      await outbox.add(boardId: 'b', columnId: 'c', title: title);
    }
    await outbox.flush();
    api.next = (title) {
      if (title == 'one') {
        c
            .read(authProvider.notifier)
            .clear(); // session expires while 'one' is in flight
      }
      return null;
    };
    await outbox.flush();
    expect(api.sent.map((s) => s.$1), [
      'one',
    ], reason: 'stopped once the session ended');
    final saved = (await SharedPreferences.getInstance()).getString(
      'u:u1:outbox',
    )!;
    expect(
      [for (final d in jsonDecode(saved)) d['title']],
      ['one', 'two', 'three'],
      reason: "kept for the next sign-in; 'one' is resent with the same key and the server returns the existing task",
    );
  });

  test('board reads fall back to the saved copy only when offline, and only for the same user', () async {
    final adapter = _Adapter();
    final prefs = await SharedPreferences.getInstance();
    Api apiFor(String user) => Api(
      Dio(BaseOptions(baseUrl: 'http://api'))..httpClientAdapter = adapter,
      cache: UserStore(prefs, user),
    );

    expect((await apiFor('u1').board('b')).offline, isFalse);
    adapter.online = false;
    final saved = await apiFor('u1').board('b');
    expect((saved.offline, saved.name), (true, 'Roadmap'));
    await expectLater(apiFor('u2').board('b'), throwsA(isA<DioException>()));
  });
}

class _Adapter implements HttpClientAdapter {
  bool online = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!online) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'down',
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'id': 'b', 'name': 'Roadmap', 'columns': []}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
