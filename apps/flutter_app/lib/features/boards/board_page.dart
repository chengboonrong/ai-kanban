import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';

class BoardNotifier extends AsyncNotifier<Board> {
  BoardNotifier(this.boardId);
  final String boardId;

  Api get _api => ref.read(apiProvider);

  @override
  Future<Board> build() => ref.watch(apiProvider).board(boardId);

  /// Runs [action], then replaces local state with the server's board (also undoing a failed optimistic move).
  Future<void> _mutate(Future<void> Function() action) async {
    try {
      await action();
    } finally {
      try {
        state = AsyncData(await _api.board(boardId));
      } catch (_) {
        // Keep the last good board on screen; the action's own error is what the caller reports.
      }
    }
  }

  Future<void> moveTask(Task task, String toColumnId, int toIndex) {
    if (state.value case final board?) state = AsyncData(board.withTaskMoved(task, toColumnId, toIndex));
    return _mutate(() => _api.updateTask(task.id, columnId: toColumnId, position: toIndex));
  }

  Future<void> moveColumn(int from, int to) {
    final board = state.value;
    if (board == null || from == to) return Future.value();
    state = AsyncData(board.withColumnMoved(from, to));
    return _mutate(() => _api.updateColumn(board.columns[from].id, position: to));
  }

  Future<void> addTask(String columnId, String title, String idempotencyKey) =>
      _mutate(() => _api.createTask(boardId, columnId: columnId, title: title, idempotencyKey: idempotencyKey));
  Future<void> addColumn(String name) => _mutate(() => _api.addColumn(boardId, name));
  Future<void> renameColumn(String id, String name) => _mutate(() => _api.updateColumn(id, name: name));
  Future<void> deleteColumn(String id) => _mutate(() => _api.deleteColumn(id));
}

final boardProvider = AsyncNotifierProvider.family<BoardNotifier, Board, String>(BoardNotifier.new);

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
        title: Text(board?.name ?? 'Board'),
        actions: [
          IconButton(
            tooltip: 'Add column',
            icon: const Icon(Icons.view_column_outlined),
            onPressed: () async {
              final name = await promptText(context, 'New column', action: 'Add');
              if (name != null && context.mounted) await runWithFeedback(context, () => notifier.addColumn(name));
            },
          ),
        ],
      ),
      body: board != null
          ? _BoardView(board: board, notifier: notifier)
          : async.hasError
              ? Center(child: Text(errorMessage(async.error!)))
              : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _BoardView extends StatelessWidget {
  const _BoardView({required this.board, required this.notifier});
  final Board board;
  final BoardNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Phones: one column nearly fills the screen and its neighbour peeks in. Desktop/web: fixed-width lanes.
      final width = constraints.maxWidth < 600 ? constraints.maxWidth * 0.85 : 300.0;
      return ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.all(8),
        itemCount: board.columns.length,
        onReorderItem: (from, to) => runWithFeedback(context, () => notifier.moveColumn(from, to)),
        itemBuilder: (context, i) => SizedBox(
          key: ValueKey(board.columns[i].id),
          width: width,
          child: _ColumnView(board: board, index: i, notifier: notifier, cardWidth: width - 24),
        ),
      );
    });
  }
}

class _ColumnView extends StatelessWidget {
  const _ColumnView({required this.board, required this.index, required this.notifier, required this.cardWidth});
  final Board board;
  final int index;
  final BoardNotifier notifier;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final column = board.columns[index];
    final theme = Theme.of(context);
    void move(Task task, int toIndex) => runWithFeedback(context, () => notifier.moveTask(task, column.id, toIndex));

    return DragTarget<Task>(
      onAcceptWithDetails: (d) => move(d.data, column.tasks.length),
      builder: (context, candidates, _) => Card(
        margin: const EdgeInsets.all(4),
        color: candidates.isEmpty ? theme.colorScheme.surfaceContainerLow : theme.colorScheme.secondaryContainer,
        child: Column(children: [
          Row(children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator, size: 20)),
            ),
            Expanded(child: Text(column.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
            Text('${column.tasks.length}', style: theme.textTheme.labelMedium),
            PopupMenuButton<String>(
              onSelected: (choice) async {
                if (choice == 'rename') {
                  final name = await promptText(context, 'Rename column', initial: column.name);
                  if (name != null && context.mounted) await runWithFeedback(context, () => notifier.renameColumn(column.id, name));
                } else if (await confirm(context, 'Delete column "${column.name}"?') && context.mounted) {
                  await runWithFeedback(context, () => notifier.deleteColumn(column.id));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final (i, task) in column.tasks.indexed)
                DragTarget<Task>(
                  onWillAcceptWithDetails: (d) => d.data.id != task.id,
                  onAcceptWithDetails: (d) {
                    // Drop before this card; positions are counted without the dragged card.
                    final from = column.tasks.indexWhere((t) => t.id == d.data.id);
                    move(d.data, from != -1 && from < i ? i - 1 : i);
                  },
                  builder: (context, over, _) => Column(children: [
                    if (over.isNotEmpty) Divider(thickness: 3, color: theme.colorScheme.primary),
                    _TaskCard(boardId: board.id, task: task, width: cardWidth),
                  ]),
                ),
            ]),
          ),
          Padding(padding: const EdgeInsets.all(8), child: _AddTaskField(boardId: board.id, columnId: column.id)),
        ]),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.boardId, required this.task, required this.width});
  final String boardId;
  final Task task;
  final double width;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      child: ListTile(
        title: Text(task.title),
        onTap: () => context.go('/boards/$boardId/tasks/${task.id}'),
      ),
    );
    final feedback = Material(elevation: 6, borderRadius: BorderRadius.circular(12), child: SizedBox(width: width, child: card));
    final dimmed = Opacity(opacity: 0.4, child: card);
    // Touch devices need a long press so vertical scrolling still works; mouse users drag directly.
    final touch = switch (Theme.of(context).platform) { TargetPlatform.android || TargetPlatform.iOS => true, _ => false };
    return touch
        ? LongPressDraggable<Task>(data: task, feedback: feedback, childWhenDragging: dimmed, child: card)
        : Draggable<Task>(data: task, feedback: feedback, childWhenDragging: dimmed, child: card);
  }
}

/// Quick capture: type a title, press Enter. The idempotency key survives failures so a retry can't duplicate the card.
class _AddTaskField extends ConsumerStatefulWidget {
  const _AddTaskField({required this.boardId, required this.columnId});
  final String boardId, columnId;

  @override
  ConsumerState<_AddTaskField> createState() => _AddTaskFieldState();
}

class _AddTaskFieldState extends ConsumerState<_AddTaskField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _key = newIdempotencyKey();
  bool _busy = false;

  Future<void> _submit() async {
    final title = _controller.text.trim();
    if (title.isEmpty || _busy) return;
    setState(() => _busy = true);
    await runWithFeedback(context, () async {
      await ref.read(boardProvider(widget.boardId).notifier).addTask(widget.columnId, title, _key);
      _controller.clear();
      _key = newIdempotencyKey();
    });
    if (mounted) {
      setState(() => _busy = false);
      _focus.requestFocus();
    }
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
      readOnly: _busy,
      onChanged: (_) => _key = newIdempotencyKey(), // a different title is a different task
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: 'Add a task…',
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(tooltip: 'Add task', icon: const Icon(Icons.add), onPressed: _busy ? null : _submit),
      ),
    );
  }
}
