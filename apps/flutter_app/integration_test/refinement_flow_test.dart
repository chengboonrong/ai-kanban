// Drives the real app against a running API (cd services/api && npm run dev). The test plays the worker over HTTP,
// so it needs no model: it checks the app's side of the protocol, not the Refiner.
//   macOS: fvm flutter test integration_test/refinement_flow_test.dart -d macos
//   web:   see board_flow_test.dart, with this file as --target
import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/auth/auth.dart';
import 'package:ai_kanban/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect a repository, watch a refinement run live, approve the spec', (tester) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final repository = 'acme/web-$stamp';
    const title = 'Add GitHub login to settings';

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const App()));
    await tester.pumpAndSettle();

    // Progress bars animate forever, so wait for what should appear instead of for the UI to settle.
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
    }

    Future<void> prompt(String text) async {
      await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), text);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await tester.pump();
    }

    await tester.enterText(find.byType(TextField), 'it-$stamp');
    await tester.tap(find.text('Sign in (dev)'));
    await waitFor(find.text('New workspace'));
    await tester.tap(find.text('New workspace'));
    await waitFor(find.byType(AlertDialog));
    await prompt('Integration');
    await waitFor(find.text('New board'));
    await tester.tap(find.text('New board'));
    await waitFor(find.byType(AlertDialog));
    await prompt('Roadmap');
    await waitFor(find.text('Backlog'));

    await tester.tap(find.byTooltip('Repository'));
    await waitFor(find.text('Connect repository…'));
    await tester.tap(find.text('Connect repository…'));
    await waitFor(find.byType(AlertDialog));
    await prompt(repository);
    await waitFor(find.text(repository));

    await tester.enterText(find.widgetWithText(TextField, 'Add a task…').first, title);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(find.text('Waiting for a worker'));

    await tester.tap(find.text(title));
    await waitFor(find.textContaining('Waiting for the worker of whoever connected $repository'));

    // Play the worker: register as this user, claim the run, report progress, then deliver a spec.
    final http = Dio(BaseOptions(baseUrl: apiUrl, headers: {'authorization': 'Bearer ${container.read(authProvider)!.token}'}));
    final workerToken = (await tester.runAsync(() => http.post('/workers', data: {'name': 'Test worker'})))!.data['token'];
    final worker = Dio(BaseOptions(baseUrl: apiUrl, headers: {'authorization': 'Bearer $workerToken'}));
    final run = (await tester.runAsync(() => worker.post('/worker/claim', data: {'repositories': [repository]})))!.data;
    await tester.runAsync(() => worker.post('/worker/runs/${run['id']}/events', data: {
          'events': [
            {'kind': 'tool', 'data': {'tool': 'read', 'target': 'lib/settings.dart', 'ok': true}},
          ],
        }));
    await waitFor(find.text('read lib/settings.dart'));

    await tester.runAsync(() => worker.post('/worker/runs/${run['id']}/complete', data: {
          'model': 'opencode/deepseek-v4.1-flash-free',
          'commitSha': 'a' * 40,
          'spec': {
            'title': 'Connect GitHub from settings',
            'summary': 'Let people connect their GitHub account from the settings page.',
            'requirements': ['A Connect GitHub button on settings'],
            'acceptanceCriteria': ['Clicking it starts the device flow'],
            'evidence': [
              {'path': 'lib/settings.dart', 'startLine': 1, 'endLine': 20, 'note': 'The settings page', 'verified': true},
            ],
            'ambiguities': ['Should signing out disconnect GitHub?'],
            'approach': ['Add the button', 'Call the auth service'],
            'readiness': 70,
          },
        }));
    await waitFor(find.text('Connect GitHub from settings'));
    expect(find.text('lib/settings.dart:1-20'), findsOneWidget);
    expect(find.text('• Should signing out disconnect GitHub?'), findsOneWidget);

    await tester.ensureVisible(find.text('Approve spec'));
    await tester.pump();
    await tester.tap(find.text('Approve spec'));
    await waitFor(find.text('Approved'));
    expect(find.text('Approve spec'), findsNothing);

    await tester.pageBack();
    await waitFor(find.text('Spec approved'));
  });
}
