import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/models.dart';
import 'package:ai_kanban/core/user_store.dart';
import 'package:ai_kanban/features/agents/refinement.dart';
import 'package:ai_kanban/features/boards/board_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves [answers] in turn (the last one from then on) and counts the calls. The run's live events never arrive
/// unless [events] is set, which is answered once.
class _FakeApi extends Api {
  _FakeApi(this.answers, {this.boardWaiting, this.events}) : super(Dio());
  _FakeApi.one(Map<String, dynamic> json) : this([json]);
  final List<Map<String, dynamic>> answers;
  final Map<String, dynamic>? boardWaiting;
  ({String state, List<RunEvent> events})? events;
  var refinements = 0;

  @override
  Future<Refinement> refinement(String taskId) async =>
      Refinement.fromJson(answers[min(refinements++, answers.length - 1)]);

  @override
  Future<({String state, List<RunEvent> events})> runEvents(
    String runId,
    int after,
  ) async {
    final page = events;
    events = null;
    return page ??
        await Completer<({String state, List<RunEvent> events})>().future;
  }

  @override
  Future<Board> board(String id) async => Board(
    id: id,
    name: 'B',
    repository: 'acme/web',
    waiting: Waiting.fromJson(boardWaiting),
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

/// Signed in as [login]; ann connected the board's repository.
Future<SharedPreferences> _signedIn(String login) async {
  SharedPreferences.setMockInitialValues({
    'session': jsonEncode({
      'token': 'x',
      'user': {'id': 'u-$login', 'login': login, 'displayName': login},
    }),
  });
  return SharedPreferences.getInstance();
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

Map<String, dynamic> _waiting(String reason) => {
  'reason': reason,
  'connector': reason == 'no_connector' ? null : 'ann',
};

Map<String, dynamic> _queued(String reason) => {
  'run': _run('queued'),
  'spec': null,
  'waiting': _waiting(reason),
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

/// The panel on a page of its own, with a Workers page to go to.
Future<void> _pumpPanel(
  WidgetTester tester,
  Object json, {
  String viewer = 'bob',
}) async {
  final api = json is _FakeApi
      ? json
      : _FakeApi.one(json as Map<String, dynamic>);
  final prefs = await _signedIn(viewer);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(
                body: SingleChildScrollView(
                  child: RefinementPanel(
                    boardId: 'b',
                    taskId: 't',
                    repository: 'acme/web',
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/workers',
              builder: (_, _) => const Text('Workers page'),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpBoard(
  WidgetTester tester,
  _FakeApi api,
  String viewer,
) async {
  final prefs = await _signedIn(viewer);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
      ],
      child: const MaterialApp(home: BoardPage(boardId: 'b')),
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
      (
        'no_connector',
        'Connect the repository again on this board to have it refined',
      ),
    ]) {
      testWidgets(reason, (tester) async {
        await _pumpPanel(tester, _queued(reason));
        expect(find.text(text), findsOneWidget);
        expect(find.text('Workers'), findsNothing);
      });
    }

    for (final (reason, text) in [
      ('no_worker_online', 'None of your workers is online'),
      ('repository_not_listed', "Your workers don't list acme/web"),
      ('busy', 'Your workers are busy with another task'),
    ]) {
      testWidgets('$reason, to the connector, with a way to the Workers page', (
        tester,
      ) async {
        await _pumpPanel(tester, _queued(reason), viewer: 'ann');
        expect(find.text(text), findsOneWidget);
        await tester.tap(find.text('Workers'));
        await tester.pumpAndSettle();
        expect(find.text('Workers page'), findsOneWidget);
      });
    }

    testWidgets('rechecks every 5 s while queued, then stops', (tester) async {
      final api = _FakeApi([
        _queued('no_worker_online'),
        _queued('busy'),
        {'run': _run('running'), 'spec': null, 'waiting': null},
      ]);
      await _pumpPanel(tester, api);
      expect(find.text('No worker of ann is online'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(
        find.text("ann's workers are busy with another task"),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(
        find.text('Refining against acme/web with OpenCode…'),
        findsOneWidget,
      );
      expect(api.refinements, 3);

      await tester.pump(const Duration(seconds: 20));
      expect(api.refinements, 3);
    });

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

  group('the queued card shows the board\'s waiting reason', () {
    for (final (viewer, reason, text) in [
      ('bob', 'repository_not_listed', "ann's workers don't list acme/web"),
      ('ann', 'repository_not_listed', "Your workers don't list acme/web"),
      (
        'ann',
        'no_connector',
        'Connect the repository again on this board to have it refined',
      ),
    ]) {
      testWidgets('$reason to $viewer', (tester) async {
        final api = _FakeApi([_queued(reason)], boardWaiting: _waiting(reason));
        await _pumpBoard(tester, api, viewer);
        expect(find.text(text), findsOneWidget);
        expect(find.text('Waiting for a worker'), findsNothing);
        expect(
          find.text('Workers'),
          viewer == 'ann' && reason != 'no_connector'
              ? findsOneWidget
              : findsNothing,
        );
        expect(api.refinements, 0); // the board carries it: no request per card
      });
    }
  });

  testWidgets('shows the worker and agent as soon as the run starts', (
    tester,
  ) async {
    final api = _FakeApi(
      [
        _queued('busy'),
        {
          'run': _run(
            'running',
            more: {'harness': 'claude-code', 'workerName': 'My Mac'},
          ),
          'spec': null,
          'waiting': null,
        },
      ],
      events: (state: 'running', events: const []),
    );
    await _pumpPanel(tester, api);
    await tester.pump(); // the events say running: the refinement reloads
    await tester.pump();
    expect(
      find.text('Refining against acme/web with Claude Code on My Mac…'),
      findsOneWidget,
    );
    expect(api.refinements, 2);
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

  testWidgets('the third attempt is the last try', (tester) async {
    await _pumpPanel(tester, {
      'run': _run(
        'running',
        more: {'attempt': 3, 'retryReason': 'the worker was stopped'},
      ),
      'spec': null,
      'waiting': null,
    });
    expect(
      find.text('Last try (attempt 3 of 3): the worker was stopped'),
      findsOneWidget,
    );
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
