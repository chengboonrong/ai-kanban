import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'core/user_store.dart';
import 'features/auth/auth.dart';
import 'features/tasks/outbox.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final sessions = SessionStore(prefs, secureStorage);
  final session = await sessions.load();
  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        sessionStoreProvider.overrideWithValue(sessions),
        initialSessionProvider.overrideWithValue(session),
      ],
      child: const App(),
    ),
  );
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
      outboxProvider,
      (_, _) {},
    ); // keep the outbox (and its retry timer) alive on every screen
    return MaterialApp.router(
      title: 'AI Kanban',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
