import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth.dart';
import 'models.dart';
import 'user_store.dart';

/// Only a URL is baked into the build; no secrets. Override with --dart-define=API_URL=...
const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:8080',
);

/// Rebuilt on every sign-in/out; everything that watches it refetches, so no data outlives its session.
final apiProvider = Provider<Api>((ref) {
  final session = ref.watch(authProvider);
  return Api.create(
    token: session?.token,
    cache: session == null
        ? null
        : UserStore(ref.watch(prefsProvider), session.user.id),
    onUnauthorized: () {
      if (ref.mounted && ref.read(authProvider) != null) {
        ref.read(authProvider.notifier).clear();
      }
    },
  );
});

class GithubDevice {
  const GithubDevice({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });
  final String deviceCode, userCode, verificationUri;
  final int interval, expiresIn; // seconds
}

class Api {
  Api(this._dio, {this.cache});

  factory Api.create({
    String? token,
    UserStore? cache,
    void Function()? onUnauthorized,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: apiUrl,
        connectTimeout: const Duration(seconds: 10),
        // Without these a request on a dead connection never ends (and would stall the outbox); a timeout counts as offline.
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {if (token != null) 'authorization': 'Bearer $token'},
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (e, handler) {
          if (e.response?.statusCode == 401) onUnauthorized?.call();
          handler.next(e);
        },
      ),
    );
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

  Future<Session> devLogin(String login) async => Session.fromJson(
    (await _dio.post('/auth/dev-login', data: {'login': login})).data,
  );
  Future<void> logout() => _dio.post('/auth/logout');

  /// How the server signs people in: 'dev', 'github' or 'none'.
  Future<String> health() async =>
      (await _dio.get('/health')).data['auth'] as String;

  Future<GithubDevice> githubDevice() async {
    final d = (await _dio.post('/auth/github/device')).data;
    return GithubDevice(
      deviceCode: d['deviceCode'],
      userCode: d['userCode'],
      verificationUri: d['verificationUri'],
      interval: d['interval'],
      expiresIn: d['expiresIn'],
    );
  }

  /// One poll. `session` when signed in; `failed` is the message to show when the code expired or was denied (start
  /// again); otherwise still pending, so ask again after `interval` seconds.
  Future<({Session? session, int interval, String? failed})> githubToken(
    String deviceCode,
    int interval,
  ) async {
    try {
      final r = await _dio.post(
        '/auth/github/token',
        data: {'deviceCode': deviceCode},
      );
      if (r.statusCode == 202) {
        return (
          session: null,
          interval: r.data['interval'] as int,
          failed: null,
        );
      }
      return (
        session: Session.fromJson(r.data),
        interval: interval,
        failed: null,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 400) {
        return (session: null, interval: interval, failed: errorMessage(e));
      }
      rethrow;
    }
  }

  Future<({List<Workspace> items, bool offline})> workspaces() async {
    final (data, offline) = await _getCached('/workspaces');
    return (
      items: [for (final w in data) Workspace.fromJson(w)],
      offline: offline,
    );
  }

  Future<void> createWorkspace(String name) =>
      _dio.post('/workspaces', data: {'name': name});

  Future<Board> createBoard(String workspaceId, String name) async =>
      Board.fromJson(
        (await _dio.post(
          '/workspaces/$workspaceId/boards',
          data: {'name': name},
        )).data,
      );
  Future<Board> board(String id) async {
    final (data, offline) = await _getCached('/boards/$id');
    return Board.fromJson(data, offline: offline);
  }

  Future<void> setRepository(String boardId, String? repository) =>
      _dio.patch('/boards/$boardId', data: {'repository': repository});

  Future<void> addColumn(String boardId, String name) =>
      _dio.post('/boards/$boardId/columns', data: {'name': name});
  Future<void> updateColumn(String id, {String? name, int? position}) =>
      _dio.patch('/columns/$id', data: {'name': ?name, 'position': ?position});
  Future<void> deleteColumn(String id) => _dio.delete('/columns/$id');

  Future<void> createTask(
    String boardId, {
    required String columnId,
    required String title,
    required String idempotencyKey,
  }) => _dio.post(
    '/boards/$boardId/tasks',
    data: {'title': title, 'columnId': columnId},
    options: Options(headers: {'idempotency-key': idempotencyKey}),
  );
  Future<TaskDetail> task(String id) async =>
      TaskDetail.fromJson((await _dio.get('/tasks/$id')).data);
  Future<void> updateTask(
    String id, {
    String? title,
    String? description,
    String? columnId,
    int? position,
  }) => _dio.patch(
    '/tasks/$id',
    data: {
      'title': ?title,
      'description': ?description,
      'columnId': ?columnId,
      'position': ?position,
    },
  );
  Future<void> deleteTask(String id) => _dio.delete('/tasks/$id');

  Future<Refinement> refinement(String taskId) async =>
      Refinement.fromJson((await _dio.get('/tasks/$taskId/refinement')).data);

  /// With [feedback], the next version addresses its comments; 409 once that version is no longer the latest.
  Future<void> refine(String taskId, {SpecFeedback? feedback}) => _dio.post(
    '/tasks/$taskId/runs',
    data: feedback == null ? null : {'feedback': feedback.toJson()},
  );
  Future<void> cancelRun(String runId) => _dio.post('/runs/$runId/cancel');
  Future<void> approveSpec(String specId) =>
      _dio.post('/specs/$specId/approve');

  Future<List<Worker>> workers() async => [
    for (final w in (await _dio.get('/workers')).data) Worker.fromJson(w),
  ];

  /// A one-time code the worker's `connect` command trades for its token.
  Future<({String code, DateTime expiresAt})> pairWorker() async {
    final data = (await _dio.post('/workers/pairing')).data;
    return (
      code: data['code'] as String,
      expiresAt: DateTime.parse(data['expiresAt']).toLocal(),
    );
  }

  Future<void> deleteWorker(String id) => _dio.delete('/workers/$id');

  Future<TaskGitHubDetail> github(String taskId) async =>
      TaskGitHubDetail.fromJson((await _dio.get('/tasks/$taskId/github')).data);

  /// Re-queues a failed issue, or creates the missing one; 409 once the issue exists.
  Future<void> retryGitHub(String taskId) =>
      _dio.post('/tasks/$taskId/github/retry');

  /// Re-queues the failed spec comment on an imported issue.
  Future<void> retryComment(String taskId) =>
      _dio.post('/tasks/$taskId/github/comment/retry');

  /// A page of the board repository's open issues, most recently updated first; [more] when there may be another.
  Future<({List<RepoIssue> issues, bool more})> repoIssues(
    String boardId, {
    int page = 1,
  }) async {
    final data = (await _dio.get(
      '/boards/$boardId/github/issues',
      queryParameters: {'page': page},
    )).data;
    return (
      issues: [for (final i in data['issues']) RepoIssue.fromJson(i)],
      more: data['more'] == true,
    );
  }

  /// Makes a card from the issue; 409 when it is already on a board.
  Future<void> importIssue(String boardId, int number) =>
      _dio.post('/boards/$boardId/github/import', data: {'number': number});

  /// Long-poll: the server answers when there are events after [after], when the run ends, or after ~20s.
  Future<({String state, List<RunEvent> events})> runEvents(
    String runId,
    int after,
  ) async {
    final data = (await _dio.get(
      '/runs/$runId/events',
      queryParameters: {'after': after},
      options: Options(receiveTimeout: const Duration(seconds: 45)),
    )).data;
    return (
      state: data['state'] as String,
      events: [for (final e in data['events']) RunEvent.fromJson(e)],
    );
  }
}

/// No response at all: the API is down or unreachable (on web this includes CORS failures).
bool isOffline(Object e) =>
    e is DioException &&
    e.response == null &&
    e.type != DioExceptionType.cancel;

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
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
