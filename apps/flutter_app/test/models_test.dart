import 'package:ai_kanban/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Task t(String id, String col) =>
      Task(id: id, columnId: col, title: id, description: '');
  final board = Board(
    id: 'b',
    name: 'B',
    columns: [
      BoardColumn(
        id: 'todo',
        name: 'Todo',
        tasks: [t('a', 'todo'), t('b', 'todo'), t('c', 'todo')],
      ),
      BoardColumn(id: 'done', name: 'Done', tasks: [t('d', 'done')]),
    ],
  );
  List<List<String>> ids(Board b) => [
    for (final c in b.columns) [for (final t in c.tasks) t.id],
  ];

  test('moves a task to another column at a clamped index', () {
    final moved = board.withTaskMoved(board.columns[0].tasks[0], 'done', 99);
    expect(ids(moved), [
      ['b', 'c'],
      ['d', 'a'],
    ]);
    expect(moved.columns[1].tasks.last.columnId, 'done');
  });

  test('reorders within a column', () {
    expect(ids(board.withTaskMoved(board.columns[0].tasks[2], 'todo', 0)), [
      ['c', 'a', 'b'],
      ['d'],
    ]);
  });

  test('reorders columns', () {
    expect(
      [for (final c in board.withColumnMoved(1, 0).columns) c.id],
      ['done', 'todo'],
    );
  });

  test('a task from an API without GitHub sync has no github summary', () {
    final base = {'id': 't', 'columnId': 'c', 'title': 'T', 'description': ''};
    expect(Task.fromJson(base).github, isNull);
    expect(Task.fromJson({...base, 'github': null}).github, isNull);
  });

  test('the board keeps polling while an issue is pending or an open issue has PRs', () {
    TaskGitHub gh(Map<String, dynamic>? issue, int prs) =>
        TaskGitHub.fromJson({'issue': issue, 'prs': prs});
    expect(gh({'state': 'pending'}, 0).active, isTrue);
    expect(gh({'number': 1, 'url': 'u', 'state': 'open'}, 1).active, isTrue);
    expect(
      gh({'number': 1, 'url': 'u', 'state': 'open'}, 0).active,
      isTrue,
    ); // a first PR may link
    expect(gh({'number': 1, 'url': 'u', 'state': 'closed'}, 1).active, isFalse);
    expect(gh({'state': 'failed'}, 0).active, isFalse);
    expect(gh(null, 0).active, isFalse);
  });
}
