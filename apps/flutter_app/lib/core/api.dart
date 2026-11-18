import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth.dart';
import 'models.dart';
import 'user_store.dart';

/// Only a URL is baked into the build; no secrets. Override with --dart-define=API_URL=...
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8080');

/// Rebuilt on every sign-in/out; everything that watches it refetches, so no data outlives its session.
final apiProvider = Provider<Api>((ref) {
  final session = ref.watch(authProvider);
  return Api.create(
      token: session?.token,
      cache: session == null ? null : UserStore(ref.watch(prefsProvider), session.user.id),
      onUnauthorized: () {
        if (ref.mounted && ref.read(authProvider) != null) ref.read(authProvider.notifier).clear();
      },
    );
});

class Api {
  Api(this._dio, {this.cache});

  factory Api.create({String? token, UserStore? cache, void Function()? onUnauthorized}) {
    final dio = Dio(BaseOptions(
      baseUrl: apiUrl,
      connectTimeout: const Duration(seconds: 10),
      // Without these a request on a dead connection never ends (and would stall the outbox); a timeout counts as offline.
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ));
    dio.interceptors.add(InterceptorsWrapper(onError: (e, handler) {
      if (e.response?.statusCode == 401) onUnauthorized?.call();
      handler.next(e);
    }));
    return Api(dio, cache: cache);
  }

  final Dio _dio;
  final UserStore? cache;

  /// GET that keeps the response on the device and serves that copy when the API can't be reached.
  Future<(dynamic, bool offline)> _getCached(String path) async {
    try {
      final data = (await _dio.get(path)).data;
      await cache?.write('get:$path', data);
      return (data, false);
    } catch (e) {
      final saved = isOffline(e) ? cache?.read('get:$path') : null;
      if (saved == null) rethrow;
      return (saved, true);
    }
  }

  Future<Session> devLogin(String login) async =>
      Session.fromJson((await _dio.post('/auth/dev-login', data: {'login': login})).data);
  Future<void> logout() => _dio.post('/auth/logout');

  Future<({List<Workspace> items, bool offline})> workspaces() async {
    final (data, offline) = await _getCached('/workspaces');
    return (items: [for (final w in data) Workspace.fromJson(w)], offline: offline);
  }
  Future<void> createWorkspace(String name) => _dio.post('/workspaces', data: {'name': name});

  Future<Board> createBoard(String workspaceId, String name) async =>
      Board.fromJson((await _dio.post('/workspaces/$workspaceId/boards', data: {'name': name})).data);
  Future<Board> board(String id) async {
    final (data, offline) = await _getCached('/boards/$id');
    return Board.fromJson(data, offline: offline);
  }

  Future<void> addColumn(String boardId, String name) => _dio.post('/boards/$boardId/columns', data: {'name': name});
  Future<void> updateColumn(String id, {String? name, int? position}) =>
      _dio.patch('/columns/$id', data: {'name': ?name, 'position': ?position});
  Future<void> deleteColumn(String id) => _dio.delete('/columns/$id');

  Future<void> createTask(String boardId, {required String columnId, required String title, required String idempotencyKey}) =>
      _dio.post('/boards/$boardId/tasks',
          data: {'title': title, 'columnId': columnId}, options: Options(headers: {'idempotency-key': idempotencyKey}));
  Future<TaskDetail> task(String id) async => TaskDetail.fromJson((await _dio.get('/tasks/$id')).data);
  Future<void> updateTask(String id, {String? title, String? description, String? columnId, int? position}) =>
      _dio.patch('/tasks/$id', data: {'title': ?title, 'description': ?description, 'columnId': ?columnId, 'position': ?position});
  Future<void> deleteTask(String id) => _dio.delete('/tasks/$id');
}

/// No response at all: the API is down or unreachable (on web this includes CORS failures).
bool isOffline(Object e) => e is DioException && e.response == null && e.type != DioExceptionType.cancel;

String errorMessage(Object e) {
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) return data['message'];
    return e.message ?? 'Could not reach the server at $apiUrl';
  }
  return '$e';
}

/// One key per captured task; reused on retry so the server never creates a duplicate card.
String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
