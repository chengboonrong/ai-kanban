import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth.dart';
import 'models.dart';

/// Only a URL is baked into the build; no secrets. Override with --dart-define=API_URL=...
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8080');

/// Rebuilt on every sign-in/out; everything that watches it refetches, so no data outlives its session.
final apiProvider = Provider<Api>((ref) => Api.create(
      token: ref.watch(authProvider)?.token,
      onUnauthorized: () {
        if (ref.mounted && ref.read(authProvider) != null) ref.read(authProvider.notifier).clear();
      },
    ));

class Api {
  Api(this._dio);

  factory Api.create({String? token, void Function()? onUnauthorized}) {
    final dio = Dio(BaseOptions(
      baseUrl: apiUrl,
      connectTimeout: const Duration(seconds: 10),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ));
    dio.interceptors.add(InterceptorsWrapper(onError: (e, handler) {
      if (e.response?.statusCode == 401) onUnauthorized?.call();
      handler.next(e);
    }));
    return Api(dio);
  }

  final Dio _dio;

  Future<Session> devLogin(String login) async =>
      Session.fromJson((await _dio.post('/auth/dev-login', data: {'login': login})).data);
  Future<void> logout() => _dio.post('/auth/logout');

  Future<List<Workspace>> workspaces() async =>
      [for (final w in (await _dio.get('/workspaces')).data) Workspace.fromJson(w)];
  Future<void> createWorkspace(String name) => _dio.post('/workspaces', data: {'name': name});

  Future<Board> createBoard(String workspaceId, String name) async =>
      Board.fromJson((await _dio.post('/workspaces/$workspaceId/boards', data: {'name': name})).data);
  Future<Board> board(String id) async => Board.fromJson((await _dio.get('/boards/$id')).data);

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
