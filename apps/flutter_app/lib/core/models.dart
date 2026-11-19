class User {
  User({required this.id, required this.login, required this.displayName});
  factory User.fromJson(Map<String, dynamic> j) =>
      User(id: j['id'], login: j['login'], displayName: j['displayName']);
  final String id, login, displayName;

  Map<String, dynamic> toJson() => {
    'id': id,
    'login': login,
    'displayName': displayName,
  };
}

class BoardRef {
  BoardRef({required this.id, required this.name});
  factory BoardRef.fromJson(Map<String, dynamic> j) =>
      BoardRef(id: j['id'], name: j['name']);
  final String id, name;
}

class Workspace {
  Workspace({required this.id, required this.name, required this.boards});
  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
    id: j['id'],
    name: j['name'],
    boards: [for (final b in j['boards']) BoardRef.fromJson(b)],
  );
  final String id, name;
  final List<BoardRef> boards;
}

class Task {
  Task({
    required this.id,
    required this.columnId,
    required this.title,
    required this.description,
    this.refinement,
    this.github,
  });
  factory Task.fromJson(Map<String, dynamic> j) => Task(
    id: j['id'],
    columnId: j['columnId'],
    title: j['title'],
    description: j['description'],
    refinement: j['refinement'],
    github: j['github'] == null ? null : TaskGitHub.fromJson(j['github']),
  );
  final String id, columnId, title, description;

  /// The card's AI state on the board: queued, running, ready, approved, failed, or null.
  final String? refinement;

  /// The card's issue and PR summary; null when nothing is synced (or the API predates GitHub sync).
  final TaskGitHub? github;

  Task copyWith({String? columnId}) => Task(
    id: id,
    columnId: columnId ?? this.columnId,
    title: title,
    description: description,
    refinement: refinement,
    github: github,
  );
}

class TaskGitHub {
  TaskGitHub({
    this.issueState,
    this.issueNumber,
    this.prs = 0,
    this.review,
    this.ci,
  });
  factory TaskGitHub.fromJson(Map<String, dynamic> j) => TaskGitHub(
    issueState: j['issue']?['state'],
    issueNumber: j['issue']?['number'],
    prs: j['prs'] ?? 0,
    review: j['review'],
    ci: j['ci'],
  );

  /// open or closed once created, otherwise pending or failed; null when there's no issue.
  final String? issueState;
  final int? issueNumber;

  /// Linked PRs.
  final int prs;

  /// Review of the most recently updated open PR: approved, changes_requested, review_required, none, or null.
  final String? review;

  /// Worst CI result across open PRs: success, failure, pending, none, or null.
  final String? ci;

  /// Still changing on GitHub's side, so the board keeps refreshing.
  bool get active => issueState == 'pending' || issueState == 'open';
}

class GitHubIssue {
  GitHubIssue.fromJson(Map<String, dynamic> j)
    : state = j['state'],
      number = j['number'],
      url = j['url'],
      issueState = j['issueState'],
      error = j['error'];

  /// pending, creating, failed, or created.
  final String state;
  final int? number;
  final String? url, error;

  /// open or closed, once created.
  final String? issueState;
}

class PullRequest {
  PullRequest.fromJson(Map<String, dynamic> j)
    : repository = j['repository'],
      number = j['number'],
      title = j['title'],
      url = j['url'],
      author = j['author'],
      state = j['state'],
      draft = j['draft'] == true,
      review = j['review'],
      ci = j['ci'];
  final String repository, title, url, state;
  final int number;
  final String? author, review, ci;
  final bool draft;
}

/// GET /tasks/:id/github: the task's issue and the PRs linked to it.
class TaskGitHubDetail {
  TaskGitHubDetail.fromJson(Map<String, dynamic> j)
    : issue = j['issue'] == null ? null : GitHubIssue.fromJson(j['issue']),
      prs = [for (final p in j['prs'] ?? const []) PullRequest.fromJson(p)];
  final GitHubIssue? issue;
  final List<PullRequest> prs;

  /// Still changing on GitHub's side, so the task page keeps refreshing.
  bool get active =>
      issue?.state == 'pending' ||
      issue?.issueState == 'open' ||
      prs.any((p) => p.state == 'open');
}

class BoardColumn {
  BoardColumn({required this.id, required this.name, required this.tasks});
  factory BoardColumn.fromJson(Map<String, dynamic> j) => BoardColumn(
    id: j['id'],
    name: j['name'],
    tasks: [for (final t in j['tasks']) Task.fromJson(t)],
  );
  final String id, name;
  final List<Task> tasks;
}

class Board {
  Board({
    required this.id,
    required this.name,
    required this.columns,
    this.repository,
    this.waiting,
    this.offline = false,
  });
  factory Board.fromJson(Map<String, dynamic> j, {bool offline = false}) =>
      Board(
        id: j['id'],
        name: j['name'],
        repository: j['repository'],
        waiting: Waiting.fromJson(j['waiting']),
        columns: [for (final c in j['columns']) BoardColumn.fromJson(c)],
        offline: offline,
      );
  final String id, name;

  /// GitHub "owner/name" that refinements read; null until connected.
  final String? repository;

  /// Why the board's queued runs wait; null when none is queued.
  final Waiting? waiting;
  final List<BoardColumn> columns;

  /// True when this is the copy saved on the device because the API couldn't be reached.
  final bool offline;

  /// Local mirror of the server's move semantics, for optimistic drag-and-drop.
  Board withTaskMoved(Task task, String toColumnId, int toIndex) => Board(
    id: id,
    name: name,
    repository: repository,
    waiting: waiting,
    offline: offline,
    columns: [
      for (final c in columns)
        () {
          final tasks = c.tasks.where((t) => t.id != task.id).toList();
          if (c.id == toColumnId) {
            tasks.insert(
              toIndex.clamp(0, tasks.length),
              task.copyWith(columnId: toColumnId),
            );
          }
          return BoardColumn(id: c.id, name: c.name, tasks: tasks);
        }(),
    ],
  );

  Board withColumnMoved(int from, int to) {
    final cols = [...columns];
    cols.insert(to, cols.removeAt(from));
    return Board(
      id: id,
      name: name,
      repository: repository,
      waiting: waiting,
      columns: cols,
      offline: offline,
    );
  }
}

class Activity {
  Activity({
    required this.kind,
    required this.data,
    required this.actor,
    required this.createdAt,
  });
  factory Activity.fromJson(Map<String, dynamic> j) => Activity(
    kind: j['kind'],
    data: j['data'],
    actor: j['actor'],
    createdAt: DateTime.parse(j['createdAt']).toLocal(),
  );
  final String kind, actor;
  final Map<String, dynamic> data;
  final DateTime createdAt;
}

class TaskDetail {
  TaskDetail({required this.task, required this.activity});
  factory TaskDetail.fromJson(Map<String, dynamic> j) => TaskDetail(
    task: Task.fromJson(j),
    activity: [for (final a in j['activity']) Activity.fromJson(a)],
  );
  final Task task;
  final List<Activity> activity;
}

/// A task captured on this device that the server hasn't confirmed yet.
class Draft {
  Draft({
    required this.key,
    required this.boardId,
    required this.columnId,
    required this.title,
    this.error,
  });
  factory Draft.fromJson(Map<String, dynamic> j) => Draft(
    key: j['key'],
    boardId: j['boardId'],
    columnId: j['columnId'],
    title: j['title'],
    error: j['error'],
  );

  /// Idempotency key, minted at capture and reused on every retry.
  final String key;
  final String boardId, columnId, title;

  /// Set when the server rejected the draft; it won't be retried.
  final String? error;

  Map<String, dynamic> toJson() => {
    'key': key,
    'boardId': boardId,
    'columnId': columnId,
    'title': title,
    'error': ?error,
  };
  Draft withError(String message) => Draft(
    key: key,
    boardId: boardId,
    columnId: columnId,
    title: title,
    error: message,
  );
}

class AgentRun {
  AgentRun({
    required this.id,
    required this.state,
    this.repository = '',
    this.error,
    this.model,
    this.commitSha,
    this.attempt = 1,
    this.retryReason,
    this.harness = 'opencode',
    this.workerName,
  });
  factory AgentRun.fromJson(Map<String, dynamic> j) => AgentRun(
    id: j['id'],
    state: j['state'],
    repository: j['repository'] ?? '',
    error: j['error'],
    model: j['model'],
    commitSha: j['commitSha'],
    attempt: j['attempt'] ?? 1,
    retryReason: j['retryReason'],
    harness: j['harness'] ?? 'opencode',
    workerName: j['workerName'],
  );
  final String id, state, repository;
  final String? error, model, commitSha;

  /// 1 for the first try; the API retries a run whose worker vanished, up to 3 attempts in all.
  final int attempt;

  /// Why the previous attempt ended, on a retry.
  final String? retryReason;

  /// opencode or claude-code: the agent the claiming worker refines with (opencode while queued).
  final String harness;

  /// The worker's name, only when it is the viewer's own worker (names leak hostnames).
  final String? workerName;

  bool get active => state == 'queued' || state == 'running';

  String get harnessLabel =>
      harness == 'claude-code' ? 'Claude Code' : 'OpenCode';
}

class RunEvent {
  RunEvent({required this.id, required this.kind, required this.data});
  factory RunEvent.fromJson(Map<String, dynamic> j) =>
      RunEvent(id: j['id'], kind: j['kind'], data: j['data']);
  final int id;
  final String kind;
  final Map<String, dynamic> data;
}

class Evidence {
  Evidence({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.note,
    required this.verified,
  });
  factory Evidence.fromJson(Map<String, dynamic> j) => Evidence(
    path: j['path'],
    startLine: j['startLine'],
    endLine: j['endLine'],
    note: j['note'],
    verified: j['verified'] == true,
  );
  final String path, note;
  final int startLine, endLine;

  /// The worker found these lines in the checkout.
  final bool verified;
}

/// One version of the AI-written spec; the shape is packages/contracts/refined-spec.schema.json.
class Spec {
  Spec.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      version = j['version'],
      commitSha = j['commitSha'],
      approved = j['approvedAt'] != null,
      title = j['content']['title'],
      summary = j['content']['summary'],
      requirements = List<String>.from(j['content']['requirements']),
      acceptanceCriteria = List<String>.from(
        j['content']['acceptanceCriteria'],
      ),
      evidence = [
        for (final e in j['content']['evidence']) Evidence.fromJson(e),
      ],
      ambiguities = List<String>.from(j['content']['ambiguities']),
      approach = List<String>.from(j['content']['approach']),
      readiness = j['content']['readiness'];
  final String id, title, summary;
  final String? commitSha;
  final int version, readiness;
  final bool approved;
  final List<String> requirements, acceptanceCriteria, ambiguities, approach;
  final List<Evidence> evidence;
}

/// A reviewer's comments on one spec version, sent with "Refine again" for the Refiner to address in the next.
class SpecFeedback {
  SpecFeedback(this.specVersion, {this.general, this.items = const []});
  final int specVersion;

  /// About the spec as a whole.
  final String? general;

  /// [section] is the spec field (summary, acceptanceCriteria, requirements, ambiguities, approach, evidence) and
  /// [index] the item's position in it; a comment on an open question is its answer.
  final List<({String section, int index, String comment})> items;

  /// The general note counts as one, as the API counts it.
  int get count => items.length + (general == null ? 0 : 1);

  Map<String, dynamic> toJson() => {
    'specVersion': specVersion,
    'general': ?general,
    if (items.isNotEmpty)
      'items': [
        for (final i in items)
          {'section': i.section, 'index': i.index, 'comment': i.comment},
      ],
  };
}

class Refinement {
  Refinement.fromJson(Map<String, dynamic> j)
    : run = j['run'] == null ? null : AgentRun.fromJson(j['run']),
      spec = j['spec'] == null ? null : Spec.fromJson(j['spec']),
      waiting = Waiting.fromJson(j['waiting']);
  final AgentRun? run;
  final Spec? spec;
  final Waiting? waiting;
}

/// Why a queued run isn't picked up, judged from the workers of whoever connected the board's repository.
class Waiting {
  Waiting({required this.reason, this.connector});
  static Waiting? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : Waiting(reason: j['reason'], connector: j['connector']);

  /// no_connector, no_worker_online, repository_not_listed or busy.
  final String reason;

  /// Login of whoever connected the board's repository; their workers are the ones that can take the run.
  final String? connector;

  /// The viewer's own workers are the ones it waits for.
  bool mine(String? viewer) => connector != null && connector == viewer;

  /// The reason in words, or null for one this app doesn't know.
  String? describe({required String? viewer, required String? repository}) {
    // Nobody connected it (or that account is gone), so no worker can ever take the run.
    if (reason == 'no_connector' || connector == null) {
      return 'Connect the repository again on this board to have it refined';
    }
    final mine = this.mine(viewer);
    final whose = mine ? 'Your workers' : "$connector's workers";
    return switch (reason) {
      'no_worker_online' =>
        mine
            ? 'None of your workers is online'
            : 'No worker of $connector is online',
      'repository_not_listed' => "$whose don't list $repository",
      'busy' => '$whose are busy with another task',
      _ => null,
    };
  }
}

class Worker {
  Worker.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'],
      repositories = List<String>.from(j['repositories'] ?? const []),
      lastSeenAt = j['lastSeenAt'] == null
          ? null
          : DateTime.parse(j['lastSeenAt']).toLocal(),
      state = j['state'],
      currentTask = j['currentTask']?['title'];
  final String id, name;
  final List<String> repositories;

  /// Null until the worker first calls in.
  final DateTime? lastSeenAt;

  /// busy (running a job), online (seen in the last 30 s) or offline.
  final String state;

  /// Title of the task it is refining, while busy.
  final String? currentTask;
}
