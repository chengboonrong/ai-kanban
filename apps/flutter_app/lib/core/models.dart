class User {
  User({required this.id, required this.login, required this.displayName});
  factory User.fromJson(Map<String, dynamic> j) => User(id: j['id'], login: j['login'], displayName: j['displayName']);
  final String id, login, displayName;

  Map<String, dynamic> toJson() => {'id': id, 'login': login, 'displayName': displayName};
}

class BoardRef {
  BoardRef({required this.id, required this.name});
  factory BoardRef.fromJson(Map<String, dynamic> j) => BoardRef(id: j['id'], name: j['name']);
  final String id, name;
}

class Workspace {
  Workspace({required this.id, required this.name, required this.boards});
  factory Workspace.fromJson(Map<String, dynamic> j) =>
      Workspace(id: j['id'], name: j['name'], boards: [for (final b in j['boards']) BoardRef.fromJson(b)]);
  final String id, name;
  final List<BoardRef> boards;
}

class Task {
  Task({required this.id, required this.columnId, required this.title, required this.description});
  factory Task.fromJson(Map<String, dynamic> j) =>
      Task(id: j['id'], columnId: j['columnId'], title: j['title'], description: j['description']);
  final String id, columnId, title, description;

  Task copyWith({String? columnId}) => Task(id: id, columnId: columnId ?? this.columnId, title: title, description: description);
}

class BoardColumn {
  BoardColumn({required this.id, required this.name, required this.tasks});
  factory BoardColumn.fromJson(Map<String, dynamic> j) =>
      BoardColumn(id: j['id'], name: j['name'], tasks: [for (final t in j['tasks']) Task.fromJson(t)]);
  final String id, name;
  final List<Task> tasks;
}

class Board {
  Board({required this.id, required this.name, required this.columns, this.offline = false});
  factory Board.fromJson(Map<String, dynamic> j, {bool offline = false}) => Board(
      id: j['id'], name: j['name'], columns: [for (final c in j['columns']) BoardColumn.fromJson(c)], offline: offline);
  final String id, name;
  final List<BoardColumn> columns;

  /// True when this is the copy saved on the device because the API couldn't be reached.
  final bool offline;

  /// Local mirror of the server's move semantics, for optimistic drag-and-drop.
  Board withTaskMoved(Task task, String toColumnId, int toIndex) => Board(id: id, name: name, offline: offline, columns: [
        for (final c in columns)
          () {
            final tasks = c.tasks.where((t) => t.id != task.id).toList();
            if (c.id == toColumnId) tasks.insert(toIndex.clamp(0, tasks.length), task.copyWith(columnId: toColumnId));
            return BoardColumn(id: c.id, name: c.name, tasks: tasks);
          }(),
      ]);

  Board withColumnMoved(int from, int to) {
    final cols = [...columns];
    cols.insert(to, cols.removeAt(from));
    return Board(id: id, name: name, columns: cols, offline: offline);
  }
}

class Activity {
  Activity({required this.kind, required this.data, required this.actor, required this.createdAt});
  factory Activity.fromJson(Map<String, dynamic> j) =>
      Activity(kind: j['kind'], data: j['data'], actor: j['actor'], createdAt: DateTime.parse(j['createdAt']).toLocal());
  final String kind, actor;
  final Map<String, dynamic> data;
  final DateTime createdAt;
}

class TaskDetail {
  TaskDetail({required this.task, required this.activity});
  factory TaskDetail.fromJson(Map<String, dynamic> j) =>
      TaskDetail(task: Task.fromJson(j), activity: [for (final a in j['activity']) Activity.fromJson(a)]);
  final Task task;
  final List<Activity> activity;
}

/// A task captured on this device that the server hasn't confirmed yet.
class Draft {
  Draft({required this.key, required this.boardId, required this.columnId, required this.title, this.error});
  factory Draft.fromJson(Map<String, dynamic> j) =>
      Draft(key: j['key'], boardId: j['boardId'], columnId: j['columnId'], title: j['title'], error: j['error']);

  /// Idempotency key, minted at capture and reused on every retry.
  final String key;
  final String boardId, columnId, title;

  /// Set when the server rejected the draft; it won't be retried.
  final String? error;

  Map<String, dynamic> toJson() => {'key': key, 'boardId': boardId, 'columnId': columnId, 'title': title, 'error': ?error};
  Draft withError(String message) => Draft(key: key, boardId: boardId, columnId: columnId, title: title, error: message);
}
