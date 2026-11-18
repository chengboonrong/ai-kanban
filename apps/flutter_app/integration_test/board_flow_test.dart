// Drives the real app against a running API (cd services/api && npm run dev).
//   macOS: fvm flutter test integration_test/board_flow_test.dart -d macos
//   web:   chromedriver --port=4444 &  then
//          fvm flutter drive --driver test_driver/integration_test.dart --target integration_test/board_flow_test.dart -d web-server --browser-name chrome --headless
import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/router.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:ai_kanban/features/tasks/outbox.dart';
import 'package:ai_kanban/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'create a board, capture a five-word task, move it between columns',
    (tester) async {
      final login = 'it-${DateTime.now().microsecondsSinceEpoch}';
      const title = 'Add GitHub login to settings';

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear(); // start signed out with no saved data
      final container = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const App()),
      );
      await tester.pumpAndSettle();

      Future<void> settle() async {
        // Network calls complete outside the fake clock; give them real time, then let frames settle.
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }

      Future<void> prompt(String text) async {
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          text,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(FilledButton),
          ),
        );
        await settle();
      }

      await tester.enterText(find.byType(TextField), login);
      await tester.tap(find.text('Sign in (dev)'));
      await settle();

      // The session is saved on the device: a fresh start (new container, same storage) is still signed in.
      final restarted = ProviderContainer(
        overrides: [prefsProvider.overrideWithValue(prefs)],
      );
      expect(restarted.read(authProvider)?.user.login, login);
      restarted.dispose();

      await tester.tap(find.text('New workspace'));
      await settle();
      await prompt('Integration');
      await tester.tap(find.text('New board'));
      await settle();
      await prompt('Roadmap');
      expect(find.text('Backlog'), findsOneWidget);
      expect(find.text('Todo'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Add a task…').first,
        title,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle();
      expect(find.text(title), findsOneWidget);

      // Drag the card onto the "Todo" column.
      final card = tester.getCenter(find.text(title));
      final todo = tester.getCenter(find.text('Todo'));
      final gesture = await tester.startGesture(card);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(todo + const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      await settle();

      final api = container.read(apiProvider);
      expect(
        container.read(outboxProvider),
        isEmpty,
        reason: 'the captured task was sent',
      );
      final boards = (await tester.runAsync(api.workspaces))!
          .items
          .single
          .boards;
      final board = (await tester.runAsync(() => api.board(boards.single.id)))!;
      expect(
        board.columns.firstWhere((c) => c.name == 'Backlog').tasks,
        isEmpty,
      );
      expect(
        board.columns.firstWhere((c) => c.name == 'Todo').tasks.single.title,
        title,
      );

      // The detail page shows the move in the activity history.
      await tester.tap(find.text(title));
      await settle();
      expect(
        find.textContaining('moved it from Backlog to Todo'),
        findsOneWidget,
      );

      // Signing out and in as someone else must not show the previous user's cached data.
      container.read(routerProvider).go('/');
      await settle();
      await tester.tap(find.byTooltip('Sign out'));
      await settle();
      await tester.enterText(find.byType(TextField), '$login-b');
      await tester.tap(find.text('Sign in (dev)'));
      await settle();
      expect(find.text('Create a workspace to get started.'), findsOneWidget);
      expect(find.text('Integration'), findsNothing);
    },
  );
}
