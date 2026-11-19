import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/agents/workers.dart';
import '../features/auth/auth.dart';
import '../features/auth/login_page.dart';
import '../features/boards/board_page.dart';
import '../features/boards/home_page.dart';
import '../features/boards/members.dart';
import '../features/tasks/task_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authChanged = ValueNotifier(0);
  ref.listen(authProvider, (_, _) => authChanged.value++);
  ref.onDispose(authChanged.dispose);

  return GoRouter(
    refreshListenable: authChanged,
    redirect: (context, state) =>
        authRedirect(signedIn: ref.read(authProvider) != null, uri: state.uri),
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: '/invite/:token',
        builder: (_, s) => InvitePage(token: s.pathParameters['token']!),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => const HomePage(),
        routes: [
          GoRoute(path: 'workers', builder: (_, _) => const WorkersPage()),
          GoRoute(
            path: 'boards/:boardId',
            builder: (_, s) => BoardPage(boardId: s.pathParameters['boardId']!),
            routes: [
              GoRoute(
                path: 'tasks/:taskId',
                builder: (_, s) => TaskPage(
                  boardId: s.pathParameters['boardId']!,
                  taskId: s.pathParameters['taskId']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Signed out, every route goes to /login. An invite link rides along as `from` and is where sign-in (dev or
/// GitHub) lands; only invite paths are kept, so the next person to sign in never lands on someone else's board.
String? authRedirect({required bool signedIn, required Uri uri}) {
  final atLogin = uri.path == '/login';
  if (!signedIn) {
    if (atLogin) return null;
    return uri.path.startsWith('/invite/')
        ? Uri(path: '/login', queryParameters: {'from': uri.path}).toString()
        : '/login';
  }
  if (!atLogin) return null;
  final from = uri.queryParameters['from'];
  return from != null && from.startsWith('/invite/') ? from : '/';
}
