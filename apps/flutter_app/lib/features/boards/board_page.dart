import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../agents/refinement.dart';
import '../auth/auth.dart';
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
    final drafts = ref.watch(outboxProvider).where((d) => d.boardId == boardId);
    final theme = Theme.of(context);
    final t = context.tokens;

    Future<void> connect() async {
      final repo = await promptText(
        context,
        'GitHub repository (owner/name)',
        initial: board?.repository ?? '',
        action: 'Connect',
      );
      if (repo != null && context.mounted) {
        await runWithFeedback(context, () => notifier.setRepository(repo));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(board?.name ?? 'Board', overflow: TextOverflow.ellipsis),
        actions: [
          if (board != null)
            PopupMenuButton<String>(
              tooltip: 'Repository',
              icon: const Icon(Icons.link),
              onSelected: (choice) async {
                if (choice != 'disconnect') return connect();
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
          const SizedBox(width: 8),
        ],
      ),
      body: board != null
          ? Column(
              children: [
                _HeaderBlock(
                  board: board,
                  drafts: drafts.where((d) => d.error == null).length,
                  onConnect: connect,
                ),
                if (board.offline)
                  const _Notice(
                    icon: Icons.cloud_off_outlined,
                    text: 'Offline: showing the copy saved on this device. New tasks are sent when the connection is back.',
                  ),
                for (final d in drafts.where((d) => d.error != null))
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  errorMessage(async.error!),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium!.copyWith(color: t.muted),
                ),
              ),
            )
          : const _BoardSkeleton(),
    );
  }
}

/// The draft's header block: the repository the board refines against, and where its cards stand.
class _HeaderBlock extends StatelessWidget {
  const _HeaderBlock({
    required this.board,
    required this.drafts,
    required this.onConnect,
  });
  final Board board;
  final int drafts;
  final VoidCallback onConnect;

  static const _states = {
    'ready': 'Ready for review',
    'running': 'Refining',
    'queued': 'Waiting',
    'approved': 'Approved',
    'failed': 'Failed',
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tasks = [for (final c in board.columns) ...c.tasks];
    final counts = [
      for (final MapEntry(:key, :value) in _states.entries)
        if (tasks.where((task) => task.refinement == key).length case final n
            when n > 0)
          '$value: $n',
    ];
    return _HeaderRules(
      left: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Repository: '),
          if (board.repository case final repository?)
            Flexible(child: Text(repository, overflow: TextOverflow.ellipsis))
          else ...[
            Flexible(
              child: Text(
                'not connected',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: onConnect,
              child: const Text('Connect'),
            ),
          ],
        ],
      ),
      right: Text(
        counts.isEmpty ? 'Tasks: ${tasks.length + drafts}' : counts.join(' · '),
      ),
    );
  }
}

/// The header block's frame: a 2px ink rule above, a 1px ink rule below, mono lines between,
/// [left] at the start and [right] at the end (the next line down when they don't fit side by side).
class _HeaderRules extends StatelessWidget {
  const _HeaderRules({required this.left, required this.right});
  final Widget left, right;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: t.headRule, bottom: t.inkRule),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DefaultTextStyle.merge(
            style: t.mono(Theme.of(context).textTheme.bodyMedium!),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 24,
              children: [left, right],
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.paper3,
      shape: Border(bottom: t.hairline),
      child: ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(text),
        trailing: action,
      ),
    );
  }
}

/// Lane width: on phones one lane nearly fills the screen and its neighbour peeks in; elsewhere fixed.
double _laneWidth(BoxConstraints constraints) =>
    constraints.maxWidth < 600 ? constraints.maxWidth * 0.85 : 288.0;

const _laneGap = 16.0;
const _lanePadding = EdgeInsets.fromLTRB(16, 16, 0, 16);

class _BoardView extends StatelessWidget {
  const _BoardView({required this.board, required this.notifier});
  final Board board;
  final BoardNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _laneWidth(constraints);
        return ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          padding: _lanePadding,
          itemCount: board.columns.length,
          onReorderItem: (from, to) =>
              runWithFeedback(context, () => notifier.moveColumn(from, to)),
          // A lifted lane: one soft shadow, no animated elevation.
          proxyDecorator: (child, _, _) => Material(
            color: t.paper,
            elevation: 3,
            shadowColor: t.ink.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(Tokens.radiusCard),
            child: child,
          ),
          itemBuilder: (context, i) => Padding(
            key: ValueKey(board.columns[i].id),
            padding: const EdgeInsets.only(right: _laneGap),
            child: SizedBox(
              width: width,
              child: _ColumnView(
                board: board,
                index: i,
                notifier: notifier,
                cardWidth: width - 16,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Loading: the board's shape at rest (header block, lanes, rows) in rule-coloured bars, nothing moving.
class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget bar(double height, [double? width]) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: t.rule,
        borderRadius: BorderRadius.circular(Tokens.radiusControl),
      ),
    );
    return ExcludeSemantics(
      child: Column(
        children: [
          _HeaderRules(left: bar(12, 200), right: bar(12, 160)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: _lanePadding,
                children: [
                  for (final rows in const [3, 2, 3, 2])
                    Container(
                      width: _laneWidth(constraints),
                      margin: const EdgeInsets.only(right: _laneGap),
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      decoration: BoxDecoration(
                        color: t.paper3,
                        borderRadius: BorderRadius.circular(Tokens.radiusCard),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 48,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 24),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: bar(12, 96),
                              ),
                            ),
                          ),
                          for (var i = 0; i < rows; i++)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: bar(56),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
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
    final t = context.tokens;
    void move(Task task, int toIndex) => runWithFeedback(
      context,
      () => notifier.moveTask(task, column.id, toIndex),
    );

    // The lane is a paper3 side field and one full-height drop target (tests look the lane up by this
    // Card); it takes a faint red tint only while a card hovers over its open ground.
    return DragTarget<Task>(
      onAcceptWithDetails: (d) => move(d.data, column.tasks.length),
      builder: (context, candidates, _) => Card(
        color: candidates.isEmpty
            ? t.paper3
            : t.accentSoft.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.radiusCard),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: SizedBox(
                        width: 32,
                        height: 48,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: t.muted,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            column.name,
                            style: theme.textTheme.titleSmall!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${column.tasks.length + pending.length}',
                          style: t.mono(
                            theme.textTheme.labelMedium!.copyWith(
                              color: t.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz),
                    iconColor: t.muted,
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
            ),
            // Fills the lane so the whole lane takes drops. Each card owns the 8px gap above it, where
            // a 2px ink line marks the drop point; the capture field follows the last card.
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
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
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Divider(
                            height: 8,
                            thickness: 2,
                            color: over.any((t) => t?.id != task.id)
                                ? t.ink
                                : Colors.transparent,
                          ),
                          _TaskCard(board: board, task: task, width: cardWidth),
                        ],
                      ),
                    ),
                  for (final d in pending)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.fromBorderSide(t.hairline),
                        borderRadius: BorderRadius.circular(
                          Tokens.radiusControl,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              d.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium!.copyWith(
                                fontWeight: FontWeight.w600,
                                color: t.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: 'Saved on this device, waiting to sync',
                            child: Icon(
                              Icons.cloud_upload_outlined,
                              size: 16,
                              color: t.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  _AddTaskField(boardId: board.id, columnId: column.id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends ConsumerStatefulWidget {
  const _TaskCard({
    required this.board,
    required this.task,
    required this.width,
  });
  final Board board;
  final Task task;
  final double width;

  @override
  ConsumerState<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<_TaskCard> {
  bool _focused = false, _hovered = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final theme = Theme.of(context);
    final t = context.tokens;
    final board = widget.board;
    final viewer = ref.watch(authProvider)?.user.login;
    final chip = switch (task.refinement) {
      'running' => ('Refining…', StatusTone.quiet),
      'ready' => ('Spec ready for review', StatusTone.neutral),
      'approved' => ('Spec approved', StatusTone.good),
      'failed' => ('Refinement failed', StatusTone.bad),
      _ => null,
    };
    final body = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // Queued: why it waits, in one quiet line, and the way to the Workers page when it's yours to fix.
          if (task.refinement == 'queued')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.hourglass_empty, size: 14, color: t.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      board.waiting?.describe(
                            viewer: viewer,
                            repository: board.repository,
                          ) ??
                          'Waiting for a worker',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (board.waiting?.mine(viewer) ?? false)
                    const WorkersButton(),
                ],
              ),
            ),
          if (chip case (final label, final tone))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: StatusChip(label: label, tone: tone),
            ),
          if (task.github case final github?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GitHubBadge(github: github),
            ),
        ],
      ),
    );
    final radius = BorderRadius.circular(Tokens.radiusControl);
    Widget sheet(BorderSide side, Widget child) => Material(
      color: t.paper2, // in front of the lane's paper3 field, in both themes
      animationDuration: Tokens.durMicro,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: radius, side: side),
      child: child,
    );
    // A white row on the lane: the border goes ink on hover; keyboard focus is the theme's 2px ring, alone.
    final card = sheet(
      _focused
          ? BorderSide(color: t.focus, width: 2)
          : _hovered
          ? t.inkRule
          : t.hairline,
      InkWell(
        onTap: () => context.go('/boards/${board.id}/tasks/${task.id}'),
        onFocusChange: (v) => setState(() => _focused = v),
        onHover: (v) => setState(() => _hovered = v),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: body,
      ),
    );
    // The one lifted thing on the board: the card in hand, at full strength, on a soft offset shadow.
    final feedback = Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: t.ink.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: SizedBox(width: widget.width, child: sheet(t.hairline, body)),
      ),
    );
    // The slot it left: an empty outline the same size as the task.
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.fromBorderSide(t.hairline),
      ),
      child: Opacity(opacity: 0, child: body),
    );
    // Touch devices need a long press so vertical scrolling still works; mouse users drag directly.
    final touch = switch (theme.platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return touch
        ? LongPressDraggable<Task>(
            data: task,
            feedback: feedback,
            childWhenDragging: placeholder,
            child: card,
          )
        : Draggable<Task>(
            data: task,
            feedback: feedback,
            childWhenDragging: placeholder,
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
    final t = context.tokens;
    // A quiet well at the lane's foot; the theme supplies the hairline and the 2px focus ring.
    return TextField(
      controller: _controller,
      focusNode: _focus,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: 'Add a task…',
        fillColor: Colors.transparent,
        suffixIcon: IconButton(
          tooltip: 'Add task',
          icon: Icon(Icons.add, color: t.muted),
          onPressed: _submit,
        ),
      ),
    );
  }
}
