import 'dart:async';

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/models.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/agents/refinement.dart';
import 'package:ai_kanban/features/boards/board_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one refinement; the run's live events never arrive, so the view shows what the refinement says.
class _FakeApi extends Api {
  _FakeApi(this.json) : super(Dio());
  final Map<String, dynamic> json;

  @override
  Future<Refinement> refinement(String taskId) async =>
      Refinement.fromJson(json);

  @override
  Future<({String state, List<RunEvent> events})> runEvents(
    String runId,
    int after,
  ) => Completer<({String state, List<RunEvent> events})>().future;

  @override
  Future<Board> board(String id) async => Board(
    id: id,
    name: 'B',
    repository: 'acme/web',
    columns: [
      BoardColumn(
        id: 'c',
        name: 'Todo',
        tasks: [
          Task(
            id: 't',
            columnId: 'c',
            title: 'Add login',
            description: '',
            refinement: 'queued',
          ),
        ],
      ),
    ],
  );
}

Map<String, dynamic> _run(
  String state, {
  Map<String, dynamic> more = const {},
}) => {
  'id': 'r',
  'state': state,
  'repository': 'acme/web',
  'attempt': 1,
  'retryReason': null,
  'harness': 'opencode',
  'workerName': null,
  ...more,
};

Map<String, dynamic> _queued(String reason) => {
  'run': _run('queued'),
  'spec': null,
  'waiting': {'reason': reason, 'connector': 'ann'},
};

const _spec = {
  'id': 's',
  'version': 2,
  'commitSha': 'abcdef1234567890',
  'approvedAt': null,
  'content': {
    'title': 'Connect GitHub',
    'summary': 'S',
    'requirements': <String>[],
    'acceptanceCriteria': <String>[],
    'evidence': <Map<String, dynamic>>[],
    'ambiguities': <String>[],
    'approach': <String>[],
    'readiness': 80,
  },
};

Future<void> _pumpPanel(WidgetTester tester, Map<String, dynamic> json) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(_FakeApi(json))],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RefinementPanel(
              boardId: 'b',
              taskId: 't',
              repository: 'acme/web',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('waiting reason on the task page', () {
    for (final (reason, text) in [
      ('no_worker_online', 'No worker of ann is online'),
      ('repository_not_listed', "ann's workers don't list acme/web"),
      ('busy', "ann's workers are busy with another task"),
    ]) {
      testWidgets(reason, (tester) async {
        await _pumpPanel(tester, _queued(reason));
        expect(find.text(text), findsOneWidget);
      });
    }

    testWidgets('falls back to the generic line without a reason', (
      tester,
    ) async {
      await _pumpPanel(tester, {
        'run': _run('queued'),
        'spec': null,
        'waiting': null,
      });
      expect(
        find.text('Waiting for the worker of whoever connected acme/web…'),
        findsOneWidget,
      );
    });
  });

  testWidgets('the queued card shows the waiting reason', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          apiProvider.overrideWithValue(
            _FakeApi(_queued('repository_not_listed')),
          ),
        ],
        child: const MaterialApp(home: BoardPage(boardId: 'b')),
      ),
    );
    await tester.pump(); // board loads
    await tester.pump(); // the card's refinement loads
    expect(find.text("ann's workers don't list acme/web"), findsOneWidget);
    expect(find.text('Waiting for a worker'), findsNothing);
  });

  testWidgets('a retried run says which attempt, why, and on which worker', (
    tester,
  ) async {
    await _pumpPanel(tester, {
      'run': _run(
        'running',
        more: {
          'attempt': 2,
          'retryReason': 'the worker stopped responding',
          'workerName': 'My Mac',
        },
      ),
      'spec': null,
      'waiting': null,
    });
    expect(
      find.text('Refining against acme/web with OpenCode on My Mac…'),
      findsOneWidget,
    );
    expect(
      find.text('Retrying (attempt 2 of 3): the worker stopped responding'),
      findsOneWidget,
    );
  });

  testWidgets('a first attempt shows no retry line', (tester) async {
    await _pumpPanel(tester, {
      'run': _run('running'),
      'spec': null,
      'waiting': null,
    });
    expect(
      find.text('Refining against acme/web with OpenCode…'),
      findsOneWidget,
    );
    expect(find.textContaining('Retrying'), findsNothing);
  });

  for (final (harness, label) in [
    ('opencode', 'OpenCode'),
    ('claude-code', 'Claude Code'),
  ]) {
    testWidgets('the spec names the harness that wrote it: $label', (
      tester,
    ) async {
      await _pumpPanel(tester, {
        'run': _run(
          'succeeded',
          more: {'harness': harness, 'workerName': 'My Mac'},
        ),
        'spec': _spec,
        'waiting': null,
      });
      expect(
        find.text('Version 2 · commit abcdef1 · $label on My Mac'),
        findsOneWidget,
      );
    });
  }
}
