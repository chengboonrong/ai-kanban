import 'package:ai_kanban/core/api.dart';
import 'package:ai_kanban/core/models.dart';
import 'package:ai_kanban/features/github/github.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one board with task 't' and whatever GitHub state [detail] holds.
class _FakeApi extends Api {
  _FakeApi(this.onBoard, this.detail) : super(Dio());
  final Task onBoard;
  Map<String, dynamic> detail;
  int reads = 0, retries = 0, commentRetries = 0;
  Map<String, dynamic>? afterRetry;

  /// Open issues by page, for the import dialog.
  Map<int, ({List<RepoIssue> issues, bool more})> pages = {};

  @override
  Future<({List<RepoIssue> issues, bool more})> repoIssues(
    String boardId, {
    int page = 1,
  }) async => pages[page]!;

  @override
  Future<void> retryComment(String taskId) async {
    commentRetries++;
    detail = afterRetry!;
  }

  @override
  Future<Board> board(String id) async => Board(
    id: id,
    name: 'B',
    columns: [
      BoardColumn(id: 'c', name: 'C', tasks: [onBoard]),
    ],
  );

  @override
  Future<TaskGitHubDetail> github(String taskId) async {
    reads++;
    return TaskGitHubDetail.fromJson(detail);
  }

  @override
  Future<void> retryGitHub(String taskId) async {
    retries++;
    detail = afterRetry!;
  }
}

Task _task({String? refinement = 'approved', TaskGitHub? github}) => Task(
  id: 't',
  columnId: 'c',
  title: 'T',
  description: '',
  refinement: refinement,
  github: github,
);

const _created = {
  'state': 'created',
  'number': 12,
  'url': 'https://github.com/o/r/issues/12',
  'issueState': 'open',
};

Future<void> _pumpPanel(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GitHubPanel(boardId: 'b', taskId: 't'),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // board loads
  await tester.pump(); // GitHub state loads
}

Future<void> _pumpBadge(WidgetTester tester, Map<String, dynamic> json) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GitHubBadge(github: TaskGitHub.fromJson(json))),
      ),
    );

void main() {
  group('GitHub section', () {
    testWidgets('stays hidden until the spec is approved', (tester) async {
      final api = _FakeApi(_task(refinement: 'ready'), {'issue': null});
      await _pumpPanel(tester, api);
      expect(find.text('GitHub'), findsNothing);
      expect(api.reads, 0);
    });

    testWidgets(
      'shows a pending issue, then the created one after the 15 s refresh',
      (tester) async {
        final api = _FakeApi(_task(github: TaskGitHub(issueState: 'pending')), {
          'issue': {'state': 'pending'},
          'prs': [],
        });
        await _pumpPanel(tester, api);
        expect(find.text('GitHub'), findsOneWidget);
        expect(find.text('Creating issue…'), findsOneWidget);

        api.detail = {'issue': _created, 'prs': []};
        await tester.pump(const Duration(seconds: 15));
        await tester.pump();
        expect(api.reads, 2);
        expect(find.text('Creating issue…'), findsNothing);
        expect(find.text('Issue #12'), findsOneWidget);
        expect(
          find.textContaining('No linked pull requests yet'),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows a failed issue\'s error and retries it', (tester) async {
      final api =
          _FakeApi(_task(github: TaskGitHub(issueState: 'failed')), {
              'issue': {
                'state': 'failed',
                'error': 'Issues are disabled on o/r',
              },
              'prs': [],
            })
            ..afterRetry = {
              'issue': {'state': 'pending'},
              'prs': [],
            };
      await _pumpPanel(tester, api);
      expect(find.text('Couldn\'t create the issue'), findsOneWidget);
      expect(find.text('Issues are disabled on o/r'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await tester.pump();
      expect(api.retries, 1);
      expect(find.text('Creating issue…'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('lists linked PRs with state, draft, review and CI chips', (
      tester,
    ) async {
      final api = _FakeApi(
        _task(github: TaskGitHub(issueState: 'open', prs: 2)),
        {
          'issue': _created,
          'prs': [
            {
              'repository': 'o/r',
              'number': 34,
              'title': 'Add login',
              'url': 'https://github.com/o/r/pull/34',
              'author': 'ann',
              'state': 'open',
              'draft': true,
              'review': 'changes_requested',
              'ci': 'failure',
              'updatedAt': '2026-11-18T10:00:00Z',
            },
            {
              'repository': 'o/r',
              'number': 35,
              'title': 'Fix logout',
              'url': 'https://github.com/o/r/pull/35',
              'author': 'bob',
              'state': 'merged',
              'draft': false,
              'review': 'approved',
              'ci': 'success',
              'updatedAt': '2026-11-18T09:00:00Z',
            },
          ],
        },
      );
      await _pumpPanel(tester, api);
      expect(find.text('Issue #12'), findsOneWidget);
      expect(find.text('Add login'), findsOneWidget);
      expect(find.text('o/r#34 by ann'), findsOneWidget);
      for (final chip in [
        'Open',
        'Draft',
        'Changes requested',
        'CI failing',
        'Merged',
        'Approved',
        'CI passing',
      ]) {
        expect(find.widgetWithText(Chip, chip), findsOneWidget, reason: chip);
      }
      expect(find.textContaining('No linked pull requests'), findsNothing);
    });
  });

  group('imported issue', () {
    final imported = {..._created, 'origin': 'imported'};

    testWidgets('says where it came from and links the posted spec comment', (
      tester,
    ) async {
      final api = _FakeApi(
        _task(
          refinement: 'running',
          github: TaskGitHub(issueState: 'open', issueNumber: 12),
        ),
        {
          'issue': imported,
          'comment': {
            'state': 'posted',
            'version': 2,
            'url': 'https://github.com/o/r/issues/12#issuecomment-7',
            'error': null,
          },
          'prs': [],
        },
      );
      await _pumpPanel(tester, api);
      expect(find.text('Imported from #12'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, 'Spec v2 posted on the issue'),
        findsOneWidget,
      );
    });

    testWidgets('shows a failed spec comment\'s error and retries it', (
      tester,
    ) async {
      final api =
          _FakeApi(_task(github: TaskGitHub(issueState: 'open')), {
              'issue': imported,
              'comment': {
                'state': 'failed',
                'version': 1,
                'url': null,
                'error': 'the GitHub App isn\'t allowed to comment',
              },
              'prs': [],
            })
            ..afterRetry = {
              'issue': imported,
              'comment': {'state': 'pending', 'version': 1},
              'prs': [],
            };
      await _pumpPanel(tester, api);
      expect(find.text('Couldn\'t post spec v1 on the issue'), findsOneWidget);
      expect(
        find.text('the GitHub App isn\'t allowed to comment'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await tester.pump();
      expect([api.commentRetries, api.retries], [1, 0]);
      expect(find.text('Posting spec v1 on the issue…'), findsOneWidget);
    });
  });

  testWidgets(
    'the import dialog lists open issues, filters them, loads more and returns the one tapped',
    (tester) async {
      RepoIssue issue(int n, String title, {bool onBoard = false}) =>
          RepoIssue.fromJson({
            'number': n,
            'title': title,
            'author': 'ann',
            'onBoard': onBoard,
            'taskId': null,
          });
      final api = _FakeApi(_task(), {})
        ..pages = {
          1: (
            issues: [
              issue(3, 'Crash on start'),
              issue(1, 'Login fails', onBoard: true),
            ],
            more: true,
          ),
          // #1 slid down onto page 2 as well: listed once.
          2: (
            issues: [
              issue(1, 'Login fails', onBoard: true),
              issue(7, 'Dark mode'),
            ],
            more: false,
          ),
        };
      int? picked;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    picked = await pickIssueToImport(context, 'b'),
                child: const Text('Import'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(find.text('Crash on start'), findsOneWidget);
      expect(find.text('#3 by ann'), findsOneWidget);
      expect(find.text('Already a card'), findsOneWidget);

      await tester.tap(
        find.text('Login fails'),
      ); // already a card: nothing happens
      await tester.pumpAndSettle();
      expect(find.text('Import a GitHub issue'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'More'));
      await tester.pumpAndSettle();
      expect(find.text('Dark mode'), findsOneWidget);
      expect(find.text('Login fails'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'More'), findsNothing);

      await tester.enterText(find.byType(TextField), 'dark');
      await tester.pump();
      expect(find.text('Crash on start'), findsNothing);
      await tester.tap(find.text('Dark mode'));
      await tester.pumpAndSettle();
      expect(picked, 7);
      expect(find.text('Import a GitHub issue'), findsNothing);
    },
  );

  group('card badge', () {
    testWidgets(
      'shows the issue number and PR count coloured by the worst state',
      (tester) async {
        await _pumpBadge(tester, {
          'issue': {
            'number': 12,
            'url': 'https://github.com/o/r/issues/12',
            'state': 'open',
          },
          'prs': 2,
          'review': 'changes_requested',
          'ci': 'success',
        });
        expect(find.text('#12'), findsOneWidget);
        expect(find.text('2 PRs'), findsOneWidget);
        expect(
          find.byTooltip(
            'Issue #12, open, 2 linked pull requests, CI passing, Changes requested',
          ),
          findsOneWidget,
        );
        final error = Theme.of(tester.element(find.text('2 PRs')))
            .colorScheme
            .error;
        expect(tester.widget<Text>(find.text('2 PRs')).style?.color, error);
      },
    );

    testWidgets('describes a pending issue', (tester) async {
      await _pumpBadge(tester, {
        'issue': {'state': 'pending'},
        'prs': 0,
        'review': null,
        'ci': null,
      });
      expect(find.byTooltip('Creating the GitHub issue'), findsOneWidget);
      expect(find.textContaining('PR'), findsNothing);
    });

    testWidgets('is empty with nothing on GitHub', (tester) async {
      await _pumpBadge(tester, {'issue': null, 'prs': 0});
      expect(find.byType(Tooltip), findsNothing);
    });
  });
}
