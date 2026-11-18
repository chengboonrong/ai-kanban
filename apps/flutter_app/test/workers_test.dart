import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/models.dart';
import 'package:ai_kanban/features/agents/workers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends Api {
  _FakeApi(this.items) : super(Dio());
  List<Map<String, dynamic>> items;
  final deleted = <String>[];

  @override
  Future<List<Worker>> workers() async => [
    for (final w in items) Worker.fromJson(w),
  ];

  @override
  Future<({String code, DateTime expiresAt})> pairWorker() async =>
      (code: 'ABCDE-FGHJK', expiresAt: DateTime(2026, 11, 19, 14, 32));

  @override
  Future<void> deleteWorker(String id) async {
    deleted.add(id);
    items = items.where((w) => w['id'] != id).toList();
  }
}

Map<String, dynamic> _worker(
  String id,
  String state, {
  String? lastSeenAt,
  Map<String, dynamic>? currentTask,
  List<String> repositories = const ['acme/web'],
}) => {
  'id': id,
  'name': 'Mac $id',
  'repositories': repositories,
  'lastSeenAt': lastSeenAt,
  'createdAt': '2026-11-18T10:00:00Z',
  'state': state,
  'currentTask': currentTask,
};

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: WorkersPage()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('lists each worker with its state and repositories', (
    tester,
  ) async {
    final seen = DateTime.now()
        .subtract(const Duration(minutes: 7))
        .toUtc()
        .toIso8601String();
    await _pump(
      tester,
      _FakeApi([
        _worker('1', 'online', lastSeenAt: DateTime.now().toIso8601String()),
        _worker(
          '2',
          'busy',
          currentTask: {'id': 't', 'title': 'Add login'},
          repositories: ['acme/web', 'acme/api'],
        ),
        _worker('3', 'offline', lastSeenAt: seen, repositories: []),
        _worker('4', 'offline'),
      ]),
    );
    expect(find.text('Mac 1'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Online'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Busy on "Add login"'), findsOneWidget);
    expect(
      find.widgetWithText(Chip, 'Offline · last seen 7 min ago'),
      findsOneWidget,
    );
    expect(find.widgetWithText(Chip, 'Offline · never seen'), findsOneWidget);
    expect(find.text('acme/web, acme/api'), findsOneWidget);
    expect(find.text('No repositories allowed yet'), findsOneWidget);
  });

  testWidgets('says how to start with no workers', (tester) async {
    await _pump(tester, _FakeApi([]));
    expect(find.textContaining('No workers yet'), findsOneWidget);
    expect(find.text('Connect a worker'), findsOneWidget);
  });

  testWidgets('shows the code, its expiry and the command, and copies it', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
        }
        return null;
      },
    );
    await _pump(tester, _FakeApi([]));
    await tester.tap(find.text('Connect a worker'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingDialog), findsOneWidget);
    expect(find.text('ABCDE-FGHJK'), findsOneWidget);
    expect(find.text('npm run connect -- ABCDE-FGHJK'), findsOneWidget);
    expect(find.text('Works once. Expires at 2:32 PM.'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy command'));
    await tester.pump();
    expect(copied, 'npm run connect -- ABCDE-FGHJK');
    expect(find.text('Command copied'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(PairingDialog), findsNothing);
  });

  testWidgets('removes a worker only after confirmation', (tester) async {
    final api = _FakeApi([_worker('1', 'online')]);
    await _pump(tester, api);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remove Mac 1?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(api.deleted, ['1']);
    expect(find.text('Mac 1'), findsNothing);
  });
}
