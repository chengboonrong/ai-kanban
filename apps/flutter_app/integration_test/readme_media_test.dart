// Regenerates the README screenshots and demo video. Skipped unless CAPTURE_MEDIA is set; run tool/readme_media.sh.
// Frames come from the app's own render tree (not a screen recording), so nothing else on screen is captured.
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
const fps = 15;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README media', skip: !capture, (tester) async {
    final out = Directory('${Directory.systemTemp.path}/readme_media');
    if (out.existsSync()) out.deleteSync(recursive: true);
    Directory('${out.path}/video').createSync(recursive: true);
    debugPrint('MEDIA_DIR=${out.path}');

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    // Start from a clean "demo" account and a signed-out app.
    final demo = (await tester.runAsync(() => Api.create().devLogin('demo')))!;
    final http = Dio(BaseOptions(baseUrl: apiUrl, headers: {'authorization': 'Bearer ${demo.token}'}));
    await tester.runAsync(() async {
      for (final ws in (await http.get('/workspaces')).data) {
        await http.delete('/workspaces/${ws['id']}');
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);

    final boundary = GlobalKey();
    final cursor = ValueNotifier<Offset?>(null);
    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(fit: StackFit.expand, children: [
          UncontrolledProviderScope(container: container, child: const App()),
          ValueListenableBuilder(
            valueListenable: cursor,
            builder: (_, p, _) => p == null
                ? const SizedBox.shrink()
                : Positioned(left: p.dx, top: p.dy, child: const IgnorePointer(child: CustomPaint(size: Size(14, 22), painter: _Cursor()))),
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    Future<List<int>> snap(double pixelRatio) async {
      final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await ro.toImage(pixelRatio: pixelRatio);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
    }

    var frameNo = 0;
    Future<void> frame([int copies = 1]) async {
      await tester.pump(const Duration(milliseconds: 1000 ~/ fps));
      final png = await snap(1);
      for (var i = 0; i < copies; i++) {
        File('${out.path}/video/${(frameNo++).toString().padLeft(5, '0')}.png').writeAsBytesSync(png);
      }
    }

    Future<void> play(double seconds) async {
      for (var i = 0; i < seconds * fps; i++) {
        await frame();
      }
    }

    Future<void> hold(double seconds) => frame((seconds * fps).round());

    Future<void> network() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    var pos = const Offset(900, 600);
    Future<void> moveTo(Offset target) async {
      for (var i = 1; i <= 10; i++) {
        cursor.value = Offset.lerp(pos, target, Curves.easeInOut.transform(i / 10));
        await frame();
      }
      pos = target;
    }

    Future<void> click(Finder f) async {
      await moveTo(tester.getCenter(f));
      await frame(2);
      await tester.tapAt(pos);
      await network();
      await play(0.5);
    }

    Future<void> type(Finder field, String text) async {
      await moveTo(tester.getCenter(field));
      for (var i = 1; i <= text.length; i++) {
        await tester.enterText(field, text.substring(0, i));
        await frame();
      }
    }

    Future<void> capture(Finder column, String title) async {
      final field = find.descendant(of: column, matching: find.widgetWithText(TextField, 'Add a task…'));
      await type(field, title);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await network();
      await play(0.4);
    }

    Finder lane(String name) => find.ancestor(of: find.text(name), matching: find.byType(Card)).last;
    final dialogField = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

    // --- Demo video ---
    cursor.value = pos;
    await hold(0.6);
    await type(find.byType(TextField), 'demo');
    await click(find.text('Sign in (dev)'));
    await hold(0.6);

    await click(find.text('New workspace'));
    await type(dialogField, 'Acme');
    await click(find.text('Create'));
    await click(find.text('New board'));
    await type(dialogField, 'Mobile app');
    await click(find.text('Create'));
    await play(0.5);

    await capture(lane('Backlog'), 'Add GitHub login to settings');
    await capture(lane('Backlog'), 'Export board as CSV');
    await capture(lane('Todo'), 'Show PR status on cards');
    await hold(0.5);

    // Drag the first card to "In Progress".
    await moveTo(tester.getCenter(find.text('Add GitHub login to settings')));
    final gesture = await tester.startGesture(pos);
    await frame();
    final target = tester.getCenter(find.text('In Progress')) + const Offset(0, 120);
    final from = pos;
    for (var i = 1; i <= 20; i++) {
      final p = Offset.lerp(from, target, Curves.easeInOut.transform(i / 20))!;
      await gesture.moveTo(p);
      cursor.value = p;
      await frame();
    }
    await gesture.up();
    pos = target;
    await network();
    await play(0.6);
    await hold(0.6);

    await click(find.text('Add GitHub login to settings'));
    await play(0.4);
    await hold(2.5);

    // --- Screenshots, with a fuller board ---
    cursor.value = null;
    final boardId = (await tester.runAsync(() async => (await http.get('/workspaces')).data[0]['boards'][0]['id'] as String))!;
    await tester.runAsync(() async {
      final board = (await http.get('/boards/$boardId')).data;
      final cols = {for (final c in board['columns']) c['name']: c['id']};
      final login = board['columns'][2]['tasks'][0]['id'];
      await http.patch('/tasks/$login', data: {
        'description': 'Let people connect their GitHub account from Settings so boards can link repositories.\n\n'
            'Acceptance: a Connect GitHub button starts sign-in; the connected account and a Disconnect action show afterwards.',
      });
      for (final (col, title) in [
        ('Backlog', 'Offline capture on Android'),
        ('Todo', 'Keyboard shortcut for quick capture'),
        ('In Progress', 'Empty state for new boards'),
        ('Done', 'Board activity history'),
        ('Done', 'Drag tasks between columns'),
      ]) {
        await http.post('/boards/$boardId/tasks', data: {'title': title, 'columnId': cols[col]});
      }
    });

    Future<void> screenshot(String name) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.runAsync(() => container.read(boardProvider(boardId).notifier).reload());
      await network();
      await tester.pumpAndSettle();
      File('${out.path}/$name.png').writeAsBytesSync(await snap(2));
    }

    final router = container.read(routerProvider);
    final taskId = (await tester.runAsync(() async => (await http.get('/boards/$boardId')).data['columns'][2]['tasks'][0]['id'] as String))!;
    router.go('/boards/$boardId'); // leave the task page so it reloads with the description added above
    await screenshot('board');
    router.go('/boards/$boardId/tasks/$taskId');
    await screenshot('task-detail');
    router.go('/boards/$boardId');
    tester.view.physicalSize = const Size(390, 844);
    await screenshot('board-phone');
    debugPrint('MEDIA_FRAMES=$frameNo');
  });
}

/// A plain arrow pointer, so the demo shows where clicks and drags happen.
class _Cursor extends CustomPainter {
  const _Cursor();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 17)
      ..lineTo(4.5, 13)
      ..lineTo(7.5, 20)
      ..lineTo(10, 19)
      ..lineTo(7, 12.5)
      ..lineTo(12.5, 12.5)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(path, Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(_Cursor oldDelegate) => false;
}
