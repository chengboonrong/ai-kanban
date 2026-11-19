// Regenerates the README's AI refinement screenshots (docs/media/refine-*.png). Skipped unless CAPTURE_MEDIA is set;
// run tool/readme_media.sh. The runs and specs are sample data posted by a test worker, not model output.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/router.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/boards/board_page.dart';
import 'package:ai_kanban/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const capture = bool.fromEnvironment('CAPTURE_MEDIA');
const repo = 'acme/mobile-app';

Map<String, dynamic> _spec({
  required String title,
  required String summary,
  required List<String> requirements,
  required List<String> criteria,
  required List<Map<String, dynamic>> evidence,
  List<String> questions = const [],
  List<String> approach = const [],
  required int readiness,
}) => {
  'title': title,
  'summary': summary,
  'requirements': requirements,
  'acceptanceCriteria': criteria,
  'evidence': evidence,
  'ambiguities': questions,
  'approach': approach,
  'readiness': readiness,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README refinement media', skip: !capture, (tester) async {
    final out = Directory('${Directory.systemTemp.path}/readme_refine');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    debugPrint('MEDIA_DIR=${out.path}');
    void size(double w, double h) {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(w * 2, h * 2);
    }

    size(1280, 800);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    // Live glyphs loop while work runs; reduced motion holds them still so frames settle.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final user = (await tester.runAsync(() => Api.create().devLogin('demo')))!;
    final http = Dio(
      BaseOptions(
        baseUrl: apiUrl,
        headers: {'authorization': 'Bearer ${user.token}'},
      ),
    );
    late String boardId, specId, approvedId, failedId, runningId, runningRun;
    late Dio worker;
    await tester.runAsync(() async {
      for (final ws in (await http.get('/workspaces')).data) {
        await http.delete('/workspaces/${ws['id']}');
      }
      final ws = (await http.post('/workspaces', data: {'name': 'Acme'})).data;
      boardId = (await http.post(
        '/workspaces/${ws['id']}/boards',
        data: {'name': 'Mobile app'},
      )).data['id'];
      final full = (await http.get('/boards/$boardId')).data;
      final cols = {for (final c in full['columns']) c['name']: c['id']};
      Future<String> task(String col, String title, [String? brief]) async {
        final id =
            (await http.post(
                  '/boards/$boardId/tasks',
                  data: {'title': title, 'columnId': cols[col]},
                )).data['id']
                as String;
        if (brief != null) {
          await http.patch('/tasks/$id', data: {'description': brief});
        }
        return id;
      }

      // Cards made before the repository is linked are never refined.
      await task('Backlog', 'Export board as CSV');
      await task('Done', 'Board activity history');
      await task('Done', 'Drag tasks between columns');
      await http.patch('/boards/$boardId', data: {'repository': repo});

      final code = (await http.post('/workers/pairing')).data['code'];
      final token = (await Dio(BaseOptions(baseUrl: apiUrl)).post(
        '/workers/pair',
        data: {'code': code, 'name': 'studio-mac'},
      )).data['token'];
      worker = Dio(
        BaseOptions(
          baseUrl: apiUrl,
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      // One queued run at a time, so each claim takes the card just made.
      Future<String> claim() async =>
          (await worker.post(
                '/worker/claim',
                data: {
                  'repositories': [repo],
                },
              )).data['id']
              as String;
      Future<void> events(String run, List<(String, String)> tools) =>
          worker.post(
            '/worker/runs/$run/events',
            data: {
              'events': [
                for (final (tool, target) in tools)
                  {
                    'kind': 'tool',
                    'data': {'tool': tool, 'target': target, 'ok': true},
                  },
              ],
            },
          );
      const commit = '3f9c2ab7d41e09b5c2a8f6e1d3b7a9c0e4f2d816';

      specId = await task(
        'Todo',
        'Retry photo uploads after network loss',
        'Uploads fail silently on flaky wifi. Retry them.',
      );
      var run = await claim();
      await events(run, [('read', 'lib/upload/queue.dart'), ('grep', 'retry')]);
      await worker.post(
        '/worker/runs/$run/complete',
        data: {
          'model': 'opencode/deepseek-v4.1-flash-free',
          'commitSha': commit,
          'spec': _spec(
            title: 'Retry failed photo uploads with backoff',
            summary:
                'Queue failed photo uploads on device and retry them with backoff when the connection returns, '
                'without duplicating photos on the server.',
            requirements: [
              'Failed uploads MUST be kept in the on-device queue until they succeed or the user removes them.',
              'Retries SHOULD wait for connectivity instead of polling.',
              'Each upload MUST carry an idempotency key so a retried photo is stored once.',
            ],
            criteria: [
              'A failed upload is queued, not dropped.',
              'Retries back off 2 s, 4 s, 8 s, up to 5 attempts.',
              'A photo retried after a timeout is stored once.',
            ],
            evidence: [
              {
                'path': 'lib/upload/queue.dart',
                'startLine': 41,
                'endLine': 88,
                'note': 'The upload queue drops a job when the request throws.',
                'verified': true,
              },
              {
                'path': 'lib/upload/api_client.dart',
                'startLine': 112,
                'endLine': 130,
                'note': 'Uploads send no idempotency key.',
                'verified': true,
              },
              {
                'path': 'test/upload/queue_test.dart',
                'startLine': 1,
                'endLine': 60,
                'note': 'No test covers a failed upload.',
                'verified': false,
              },
            ],
            questions: [
              'Should retries run while the app is in the background?',
              'Is 5 attempts enough on cellular?',
            ],
            approach: [
              'Persist failed jobs in the queue with an attempt count.',
              'Send an idempotency key with each upload.',
              'Retry on the connectivity stream with exponential backoff.',
            ],
            readiness: 72,
          ),
        },
      );

      approvedId = await task(
        'In Progress',
        'Add GitHub login to settings',
        'Let people connect their GitHub account from Settings.',
      );
      run = await claim();
      await worker.post(
        '/worker/runs/$run/complete',
        data: {
          'model': 'opencode/deepseek-v4.1-flash-free',
          'commitSha': commit,
          'spec': _spec(
            title: 'Connect a GitHub account from Settings',
            summary: 'Add a Connect GitHub action to Settings that signs in and shows the connected account.',
            requirements: [
              'The account MUST show once connected, with a Disconnect action.',
            ],
            criteria: ['Connect starts GitHub sign-in.'],
            evidence: [
              {
                'path': 'lib/settings/settings_page.dart',
                'startLine': 12,
                'endLine': 40,
                'note': 'Settings lists account rows.',
                'verified': true,
              },
            ],
            readiness: 90,
          ),
        },
      );
      final approved = (await http.get('/tasks/$approvedId/refinement'))
          .data['spec']['id'];
      await http.post('/specs/$approved/approve');

      failedId = await task(
        'Backlog',
        'Offline capture on Android',
        'Capture tasks with no connection and send them later.',
      );
      run = await claim();
      await events(run, [('read', 'android/app/build.gradle')]);
      await worker.post(
        '/worker/runs/$run/fail',
        data: {
          'error': 'opencode exited with code 1: the model provider returned 429 (rate limited)',
        },
      );

      runningId = await task(
        'In Progress',
        'Compress photos before upload',
        'Large photos take minutes on cellular. Shrink them first.',
      );
      runningRun = await claim();
      await events(runningRun, [
        ('read', 'lib/upload/queue.dart'),
        ('grep', 'compress'),
        ('read', 'lib/camera/capture.dart'),
        ('glob', 'lib/**/image*.dart'),
      ]);

      // Made last and left unclaimed: it waits for a worker.
      await task('Todo', 'Keyboard shortcut for quick capture');
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final container = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs)],
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: UncontrolledProviderScope(
          container: container,
          child: const App(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> network() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await network();
      final ro =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = (await tester.runAsync(() async {
        final image = await ro.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      File('${out.path}/$name.png').writeAsBytesSync(png);
    }

    await tester.enterText(find.byType(TextField).first, 'demo');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await network();
    final router = container.read(routerProvider);
    router.go('/boards/$boardId');
    await tester.runAsync(
      () => container.read(boardProvider(boardId).notifier).reload(),
    );
    await shot('refine-board');

    // Keep the running run's lease fresh, then show it.
    await tester.runAsync(
      () => worker.post(
        '/worker/runs/$runningRun/events',
        data: {
          'events': [
            {
              'kind': 'tool',
              'data': {
                'tool': 'read',
                'target': 'lib/upload/image_codec.dart',
                'ok': true,
              },
            },
          ],
        },
      ),
    );
    router.go('/boards/$boardId/tasks/$runningId');
    await shot('refine-running');

    router.go('/boards/$boardId/tasks/$specId');
    await shot('refine-spec');
    await network();
    Scrollable.ensureVisible(
      tester.element(find.text('Open questions')),
      alignment: 0.02,
    );
    await shot('refine-evidence');

    router.go('/boards/$boardId/tasks/$failedId');
    await shot('refine-failed');

    size(390, 844);
    router.go('/boards/$boardId/tasks/$specId');
    await shot('refine-spec-phone');
  });
}
