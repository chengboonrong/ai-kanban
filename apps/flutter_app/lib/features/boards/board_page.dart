import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';
import '../github/github.dart';
import '../tasks/outbox.dart';

class BoardNotifier extends AsyncNotifier<Board> {
  BoardNotifier(this.boardId);
  final String boardId;

  Api get _api => ref.read(apiProvider);
  int _mutations = 0, _inFlight = 0;
  Timer? _poll;
  Duration? _pollDelay;

  @override
  Future<Board> build() async {
    _poll?.cancel(); // the notifier object outlives a rebuild
    _poll = null;
    ref.onDispose(() => _poll?.cancel());
    final board = await ref.watch(apiProvider).board(boardId);
    _watchRuns(board);
    return board;
  }

  /// While a card is being refined, refresh every few seconds so its badge follows the worker;
  /// while an issue is being created or is open, every 30 s so linked PRs, CI and reviews show up.
  void _watchRuns(Board board) {
    final tasks = board.columns.expand((c) => c.tasks);
    final Duration delay;
    if (tasks.any(
      (t) => t.refinement == 'queued' || t.refinement == 'running',
    )) {
      delay = const Duration(seconds: 5);
    } else if (tasks.any((t) => t.github?.active ?? false)) {
      delay = const Duration(seconds: 30);
    } else {
      return;
    }
    // A pending poll that is due as soon (or sooner) is enough; a slower one gives way to the faster one.
    if (_poll != null && _pollDelay! <= delay) return;
    _poll?.cancel();
    _pollDelay = delay;
    _poll = Timer(delay, () async {
      _poll = null;
      final before = _mutations;
      try {
        final board = await _api.board(boardId);
        // Never overwrite an optimistic move or a newer refresh; the mutation's own refresh reschedules polling.
        if (ref.mounted && _inFlight == 0 && before == _mutations) {
          state = AsyncData(board);
        }
      } catch (_) {
        // Offline for now; keep polling from what's on screen.
      }
      // Re-arm from whatever is on screen; a no-op when a mutation's refresh already did.
      if (!ref.mounted) return;
      if (state.value case final b?) _watchRuns(b);
    });
  }

  /// Runs [action], then replaces local state with the server's board (also undoing a failed optimistic move).
  Future<void> _mutate(Future<void> Function() action) async {
    final mutation = ++_mutations;
    _inFlight++;
    try {
      await action();
    } finally {
      try {
        final board = await _api.board(boardId);
        if (mutation == _mutations) {
          state = AsyncData(
            board,
          ); // a later mutation (and its refresh) supersedes this one
          _watchRuns(board);
        }
      } catch (_) {
        // No server and no saved copy: keep what's on screen; the action's own error is what the caller reports.
      } finally {
        _inFlight--;
      }
    }
  }

  Future<void> moveTask(Task task, String toColumnId, int toIndex) {
    if (state.value case final board?) {
      state = AsyncData(board.withTaskMoved(task, toColumnId, toIndex));
    }
    return _mutate(
      () => _api.updateTask(task.id, columnId: toColumnId, position: toIndex),
    );
  }

  Future<void> moveColumn(int from, int to) {
    final board = state.value;
    if (board == null || from == to) return Future.value();
    state = AsyncData(board.withColumnMoved(from, to));
    return _mutate(
      () => _api.updateColumn(board.columns[from].id, position: to),
    );
  }

  Future<void> reload() => _mutate(() async {});
  Future<void> setRepository(String? repository) =>
      _mutate(() => _api.setRepository(boardId, repository));
  Future<void> addColumn(String name) =>
      _mutate(() => _api.addColumn(boardId, name));
  Future<void> renameColumn(String id, String name) =>
      _mutate(() => _api.updateColumn(id, name: name));
  Future<void> deleteColumn(String id) => _mutate(() => _api.deleteColumn(id));
}

// autoDispose: a board lives only while a screen shows it, so the previous user's board can't linger after sign-out.
final boardProvider = AsyncNotifierProvider.autoDispose
    .family<BoardNotifier, Board, String>(BoardNotifier.new);

class BoardPage extends ConsumerWidget {
  const BoardPage({super.key, required this.boardId});
  final String boardId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(boardProvider(boardId));
    final board = async.value;
    final notifier = ref.read(boardProvider(boardId).notifier);

    return Scaffold(
      appBar: AppBar(
        title: ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(board?.name ?? 'Board', overflow: TextOverflow.ellipsis),
          subtitle: board?.repository == null
              ? null
              : Text(board!.repository!, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          if (board != null)
            PopupMenuButton<String>(
              tooltip: 'Repository',
              icon: const Icon(Icons.link),
              onSelected: (choice) async {
                if (choice == 'disconnect') {
                  if (await confirm(
                        context,
                        'Disconnect ${board.repository}? New cards won\'t be refined.',
                        action: 'Disconnect',
                      ) &&
                      context.mounted) {
                    await runWithFeedback(
                      context,
                      () => notifier.setRepository(null),
                    );
                  }
                  return;
                }
                final repo = await promptText(
                  context,
                  'GitHub repository (owner/name)',
                  initial: board.repository ?? '',
                  action: 'Connect',
                );
                if (repo != null && context.mounted) {
                  await runWithFeedback(
                    context,
                    () => notifier.setRepository(repo),
                  );
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'connect',
                  child: Text(
                    board.repository == null
                        ? 'Connect repository…'
                        : 'Change repository…',
                  ),
                ),
                if (board.repository != null)
                  const PopupMenuItem(
                    value: 'disconnect',
                    child: Text('Disconnect repository'),
                  ),
              ],
            ),
          IconButton(
            tooltip: 'Add column',
            icon: const Icon(Icons.view_column_outlined),
            onPressed: () async {
              final name = await promptText(
                context,
                'New column',
                action: 'Add',
              );
              if (name != null && context.mounted) {
                await runWithFeedback(context, () => notifier.addColumn(name));
              }
            },
          ),
        ],
      ),
      body: board != null
          ? Column(
              children: [
                if (board.offline)
                  const _Notice(
                    icon: Icons.cloud_off,
                    text: 'Offline: showing the copy saved on this device. New tasks are sent when the connection is back.',
                  ),
                for (final d
                    in ref
                        .watch(outboxProvider)
                        .where((d) => d.boardId == boardId && d.error != null))
                  _Notice(
                    icon: Icons.error_outline,
                    text: 'Couldn\'t save "${d.title}": ${d.error}',
                    action: TextButton(
                      onPressed: () =>
                          ref.read(outboxProvider.notifier).discard(d),
                      child: const Text('Discard'),
                    ),
                  ),
                Expanded(
                  child: _BoardView(board: board, notifier: notifier),
                ),
              ],
            )
          : async.hasError
          ? Center(child: Text(errorMessage(async.error!)))
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(text),
      trailing: action,
    ),
  );
}

class _BoardView extends StatelessWidget {
  const _BoardView({required this.board, required this.notifier});
  final Board board;
  final BoardNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Phones: one column nearly fills the screen and its neighbour peeks in. Desktop/web: fixed-width lanes.
        final width = constraints.maxWidth < 600
            ? constraints.maxWidth * 0.85
            : 300.0;
        return ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.all(8),
          itemCount: board.columns.length,
          onReorderItem: (from, to) =>
              runWithFeedback(context, () => notifier.moveColumn(from, to)),
          itemBuilder: (context, i) => SizedBox(
            key: ValueKey(board.columns[i].id),
            width: width,
            child: _ColumnView(
              board: board,
              index: i,
              notifier: notifier,
              cardWidth: width - 24,
            ),
          ),
        );
      },
    );
  }
}

class _ColumnView extends ConsumerWidget {
  const _ColumnView({
    required this.board,
    required this.index,
    required this.notifier,
    required this.cardWidth,
  });
  final Board board;
  final int index;
  final BoardNotifier notifier;
  final double cardWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final column = board.columns[index];
    final pending = ref
        .watch(outboxProvider)
        .where((d) => d.columnId == column.id && d.error == null);
    final theme = Theme.of(context);
    void move(Task task, int toIndex) => runWithFeedback(
      context,
      () => notifier.moveTask(task, column.id, toIndex),
    );

    return DragTarget<Task>(
      onAcceptWithDetails: (d) => move(d.data, column.tasks.length),
      builder: (context, candidates, _) => Card(
        margin: const EdgeInsets.all(4),
        color: candidates.isEmpty
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.secondaryContainer,
        child: Column(
          children: [
            Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator, size: 20),
                  ),
                ),
                Expanded(
                  child: Text(
                    column.name,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${column.tasks.length + pending.length}',
                  style: theme.textTheme.labelMedium,
                ),
                PopupMenuButton<String>(
                  onSelected: (choice) async {
                    if (choice == 'rename') {
                      final name = await promptText(
                        context,
                        'Rename column',
                        initial: column.name,
                      );
                      if (name != null && context.mounted) {
                        await runWithFeedback(
                          context,
                          () => notifier.renameColumn(column.id, name),
                        );
                      }
                    } else if (await confirm(
                          context,
                          'Delete column "${column.name}"?',
                        ) &&
                        context.mounted) {
                      await runWithFeedback(
                        context,
                        () => notifier.deleteColumn(column.id),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final (i, task) in column.tasks.indexed)
                    DragTarget<Task>(
                      onAcceptWithDetails: (d) {
                        if (d.data.id == task.id) {
                          return; // dropped back on itself: stay put
                        }
                        // Drop before this card; positions are counted without the dragged card.
                        final from = column.tasks.indexWhere(
                          (t) => t.id == d.data.id,
                        );
                        move(d.data, from != -1 && from < i ? i - 1 : i);
                      },
                      builder: (context, over, _) => Column(
                        children: [
                          if (over.any((t) => t?.id != task.id))
                            Divider(
                              thickness: 3,
                              color: theme.colorScheme.primary,
                            ),
                          _TaskCard(
                            boardId: board.id,
                            task: task,
                            width: cardWidth,
                          ),
                        ],
                      ),
                    ),
                  for (final d in pending)
                    Card(
                      child: ListTile(
                        title: Text(d.title),
                        trailing: const Tooltip(
                          message: 'Saved on this device, waiting to sync',
                          child: Icon(Icons.cloud_upload_outlined),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: _AddTaskField(boardId: board.id, columnId: column.id),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.boardId,
    required this.task,
    required this.width,
  });
  final String boardId;
  final Task task;
  final double width;

  @override
  Widget build(BuildContext context) {
    final status = switch (task.refinement) {
      'queued' => (Icons.hourglass_empty, 'Waiting for a worker'),
      'running' => (Icons.auto_awesome, 'Refining…'),
      'ready' => (Icons.rate_review_outlined, 'Spec ready for review'),
      'approved' => (Icons.verified_outlined, 'Spec approved'),
      'failed' => (Icons.error_outline, 'Refinement failed'),
      _ => null,
    };
    final card = Card(
      child: ListTile(
        title: Text(task.title),
        subtitle: status == null && task.github == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (status != null)
                    Row(
                      children: [
                        Icon(status.$1, size: 14),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            status.$2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  if (task.github case final github?)
                    GitHubBadge(github: github),
                ],
              ),
        onTap: () => context.go('/boards/$boardId/tasks/${task.id}'),
      ),
    );
    final feedback = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: width, child: card),
    );
    final dimmed = Opacity(opacity: 0.4, child: card);
    // Touch devices need a long press so vertical scrolling still works; mouse users drag directly.
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return touch
        ? LongPressDraggable<Task>(
            data: task,
            feedback: feedback,
            childWhenDragging: dimmed,
            child: card,
          )
        : Draggable<Task>(
            data: task,
            feedback: feedback,
            childWhenDragging: dimmed,
            child: card,
          );
  }
}

/// Quick capture: type a title, press Enter. The task is saved on the device at once and synced in the background.
class _AddTaskField extends ConsumerStatefulWidget {
  const _AddTaskField({required this.boardId, required this.columnId});
  final String boardId, columnId;

  @override
  ConsumerState<_AddTaskField> createState() => _AddTaskFieldState();
}

class _AddTaskFieldState extends ConsumerState<_AddTaskField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  Future<void> _submit() async {
    final title = _controller.text.trim();
    if (title.isEmpty) return;
    await runWithFeedback(context, () async {
      await ref
          .read(outboxProvider.notifier)
          .add(
            boardId: widget.boardId,
            columnId: widget.columnId,
            title: title,
          );
      _controller.clear();
    });
    if (mounted) _focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: 'Add a task…',
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: 'Add task',
          icon: const Icon(Icons.add),
          onPressed: _submit,
        ),
      ),
    );
  }
}
