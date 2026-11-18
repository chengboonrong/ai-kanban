import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/auth.dart';
import '../features/auth/login_page.dart';
import '../features/boards/board_page.dart';
import '../features/boards/home_page.dart';
import '../features/tasks/task_page.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authChanged = ValueNotifier(0);
  ref.listen(authProvider, (_, _) => authChanged.value++);
  ref.onDispose(authChanged.dispose);

  return GoRouter(
    refreshListenable: authChanged,
    redirect: (context, state) {
      final signedIn = ref.read(authProvider) != null;
      final atLogin = state.matchedLocation == '/login';
      if (!signedIn) return atLogin ? null : '/login';
      return atLogin ? '/' : null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/', builder: (_, _) => const HomePage(), routes: [
        GoRoute(
          path: 'boards/:boardId',
          builder: (_, s) => BoardPage(boardId: s.pathParameters['boardId']!),
          routes: [
            GoRoute(
              path: 'tasks/:taskId',
              builder: (_, s) => TaskPage(boardId: s.pathParameters['boardId']!, taskId: s.pathParameters['taskId']!),
            ),
          ],
        ),
      ]),
    ],
  );
});
