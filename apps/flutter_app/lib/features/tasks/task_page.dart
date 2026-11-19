import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/glyphs.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../agents/refinement.dart';
import '../agents/workers.dart';
import '../boards/board_page.dart';
import '../github/github.dart';

final taskProvider = FutureProvider.autoDispose.family<TaskDetail, String>(
  (ref, id) => ref.watch(apiProvider).task(id),
);

class TaskPage extends ConsumerWidget {
  const TaskPage({super.key, required this.boardId, required this.taskId});
  final String boardId, taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(taskProvider(taskId));
    final board = ref.watch(boardProvider(boardId)).value;
    final theme = Theme.of(context);
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(
        title: board == null
            ? const Text('Task')
            : Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: board.name),
                    if (board.repository case final repository?)
                      TextSpan(
                        text: '   $repository',
                        style: t
                            .mono(theme.textTheme.bodyMedium!)
                            .copyWith(color: t.muted),
                      ),
                  ],
                ),
                style: theme.textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
        actions: const [_WorkerKey(), SizedBox(width: 12)],
      ),
      body: switch (detail) {
        AsyncValue(:final value?) when board != null => _TaskEditor(
          key: ValueKey(taskId),
          boardId: boardId,
          detail: value,
          columns: board.columns,
          repository: board.repository,
        ),
        AsyncValue(:final error?) => Center(child: Text(errorMessage(error))),
        _ => const _Skeleton(),
      },
    );
  }
}

class _TaskEditor extends ConsumerStatefulWidget {
  const _TaskEditor({
    super.key,
    required this.boardId,
    required this.detail,
    required this.columns,
    this.repository,
  });
  final String boardId;
  final String? repository;
  final TaskDetail detail;
  final List<BoardColumn> columns;

  @override
  ConsumerState<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<_TaskEditor> {
  late final _title = TextEditingController(text: widget.detail.task.title);
  late final _description = TextEditingController(
    text: widget.detail.task.description,
  );

  Task get task => widget.detail.task;

  void _refresh() {
    ref.invalidate(taskProvider(task.id));
    ref.invalidate(boardProvider(widget.boardId));
  }

  Future<void> _save() => runWithFeedback(context, () async {
    final title = _title.text.trim();
    if (title.isEmpty) throw 'Title cannot be empty';
    await ref
        .read(apiProvider)
        .updateTask(task.id, title: title, description: _description.text);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
    }
  });

  Future<void> _move(String columnId) => runWithFeedback(context, () async {
    await ref
        .read(boardProvider(widget.boardId).notifier)
        .moveTask(task, columnId, 1 << 30);
    ref.invalidate(taskProvider(task.id));
  });

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete "${task.title}"?') || !mounted) return;
    await runWithFeedback(context, () async {
      await ref.read(apiProvider).deleteTask(task.id);
      ref.invalidate(boardProvider(widget.boardId));
      if (mounted) context.go('/boards/${widget.boardId}');
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final quiet = TextButton.styleFrom(
      foregroundColor: t.ink2,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    final column = widget.columns
        .where((c) => c.id == task.columnId)
        .firstOrNull;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wide;
        final gutter = wide ? 48.0 : 16.0;
        // The spec column: capped and centred in the space beside the rail. The pinned bar spans that space,
        // its seam edge to edge, and indents its buttons to the column's edge.
        final room = constraints.maxWidth - (wide ? _rail : 0);
        final indent =
            (room - _column).clamp(0.0, double.infinity) / 2 + gutter;
        Widget measured(Widget child) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _column),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: child,
            ),
          ),
        );
        final edits = [
          TextButton(onPressed: _save, style: quiet, child: const Text('Save')),
          TextButton.icon(
            onPressed: _delete,
            style: quiet,
            icon: const GlyphIcon(Glyph.delete, size: 18),
            label: const Text('Delete'),
          ),
        ];
        final doc = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  // Pulled left by its own padding so the title's first letter sits on the column edge.
                  child: Transform.translate(
                    offset: const Offset(-12, 0),
                    child: Semantics(
                      label: 'Title',
                      child: TextField(
                        controller: _title,
                        maxLines: null,
                        style: MediaQuery.sizeOf(context).width < 600
                            ? theme.textTheme.headlineSmall
                            : theme.textTheme.displaySmall,
                        decoration: InputDecoration(
                          hintText: 'Title',
                          fillColor: t.paper,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              Tokens.radiusControl,
                            ),
                            borderSide: const BorderSide(
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _ColumnTag(
                    name: column?.name ?? '',
                    columns: widget.columns,
                    current: task.columnId,
                    onMove: _move,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // The brief: one muted line under the title, editable in place like it.
            Transform.translate(
              offset: const Offset(-12, 0),
              child: Semantics(
                label: 'Description',
                child: TextField(
                  controller: _description,
                  minLines: 1,
                  maxLines: 20,
                  style: theme.textTheme.bodyLarge?.copyWith(color: t.muted),
                  decoration: InputDecoration(
                    hintText: 'Description',
                    fillColor: t.paper,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Tokens.radiusControl),
                      borderSide: const BorderSide(color: Colors.transparent),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Save at the column edge, the destructive Delete at the far end; both quiet, and off the title's row
            // so the title keeps the column's width. Each is pulled out by its own padding so the labels sit on the
            // column's edges, under the title and the column menu.
            Row(
              children: [
                Transform.translate(
                  offset: const Offset(-8, 0),
                  child: edits.first,
                ),
                const Spacer(),
                Transform.translate(
                  offset: const Offset(8, 0),
                  child: edits.last,
                ),
              ],
            ),
            const SizedBox(height: 16),
            RefinementPanel(
              boardId: widget.boardId,
              taskId: task.id,
              repository: widget.repository,
              pinnedBar: true,
            ),
            GitHubPanel(boardId: widget.boardId, taskId: task.id),
            if (!wide) ...[
              const SizedBox(height: 48),
              _ActivityList(activity: widget.detail.activity),
            ],
          ],
        );
        final main = Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(vertical: wide ? 32 : 24),
                child: measured(doc),
              ),
            ),
            RefinementBar(
              boardId: widget.boardId,
              taskId: task.id,
              repository: widget.repository,
              padding: EdgeInsets.symmetric(horizontal: indent, vertical: 12),
            ),
          ],
        );
        if (!wide) return main;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: main),
            Container(
              width: _rail,
              decoration: BoxDecoration(
                color: t.paper3,
                border: Border(left: t.hairline),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
                child: _ActivityList(activity: widget.detail.activity),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Wide enough for the spec column beside the activity rail (a landscape tablet included).
const _wide = 1000.0;
const _rail = 360.0;

/// The spec column's cap, gutters included; prose inside keeps a 680px measure.
const _column = 900.0;

/// The task's column as a small pill; opening it moves the task to another column.
class _ColumnTag extends StatelessWidget {
  const _ColumnTag({
    required this.name,
    required this.columns,
    required this.current,
    required this.onMove,
  });
  final String name, current;
  final List<BoardColumn> columns;
  final ValueChanged<String> onMove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MenuAnchor(
      menuChildren: [
        for (final c in columns)
          MenuItemButton(
            onPressed: c.id == current ? null : () => onMove(c.id),
            child: Text(c.name),
          ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: 'Column',
        child: TextButton.icon(
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          iconAlignment: IconAlignment.end,
          icon: const GlyphIcon(Glyph.expand, size: 16),
          label: Text(name),
          style:
              TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.only(left: 8, right: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: Theme.of(context).textTheme.labelMedium,
                shape: const StadiumBorder(),
              ).copyWith(
                side: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.focused)
                      ? BorderSide(color: t.focus, width: 2)
                      : t.hairline,
                ),
              ),
        ),
      ),
    );
  }
}

/// The bar's right key: green while one of the viewer's workers is online, grey otherwise.
class _WorkerKey extends ConsumerWidget {
  const _WorkerKey();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workers = ref.watch(workersProvider).value;
    if (workers == null || workers.isEmpty) return const SizedBox.shrink();
    final t = context.tokens;
    final online = workers.any((w) => w.state != 'offline');
    return IconButton(
      tooltip: online ? 'Worker online' : 'Workers offline',
      onPressed: () => context.push('/workers'),
      icon: GlyphKey(
        online ? Glyph.worker : Glyph.workerOff,
        color: online ? t.green : t.idle,
        size: 28,
        motion: online ? GlyphMotion.once : GlyphMotion.still,
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.activity});
  final List<Activity> activity;

  static String describe(Activity a) => switch (a.kind) {
    'created' => 'created this in ${a.data['column']}',
    'refinement_requested' => 'asked the AI to refine this',
    'spec_ready' => 'received AI spec v${a.data['version']}',
    'spec_approved' => 'approved spec v${a.data['version']}',
    'refinement_failed' => 'saw a refinement fail: ${a.data['error']}',
    'github_issue_created' =>
      'saw GitHub issue${a.data['number'] == null ? '' : ' #${a.data['number']}'} created',
    'github_issue_imported' => 'imported GitHub issue #${a.data['number']}',
    'github_comment_posted' =>
      'saw spec v${a.data['version']} posted on the GitHub issue',
    'moved' => 'moved it from ${a.data['from']} to ${a.data['to']}',
    'updated' => [
      if (a.data['title'] case {'from': final from, 'to': final to})
        'renamed "$from" to "$to"',
      if (a.data['description'] == true) 'edited the description',
    ].join(' and '),
    _ => a.kind,
  };

  /// The event's key: blue for the AI's reading and writing, green once approved, red on failure, grey at rest.
  static (Glyph, Color, Color?) look(Activity a, Tokens t) => switch (a.kind) {
    'created' => (Glyph.add, t.ink, null),
    'refinement_requested' => (Glyph.refine, t.blue, null),
    'spec_ready' => (Glyph.spec, t.blue, null),
    'spec_approved' => (Glyph.approve, t.green, null),
    'refinement_failed' => (Glyph.failed, t.danger, null),
    'github_issue_created' => (Glyph.github, t.ink, null),
    'github_issue_imported' => (Glyph.github, t.ink, null),
    'github_comment_posted' => (Glyph.comment, t.green, null),
    'moved' => (Glyph.board, t.idle, t.ink),
    'updated' => (Glyph.edit, t.idle, t.ink),
    _ => (Glyph.activity, t.idle, t.ink),
  };

  static String time(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)} ${_pad(t.hour)}:${_pad(t.minute)}';
  static String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final body = theme.textTheme.bodyMedium!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Activity', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final (i, a) in activity.reversed.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                switch (look(a, t)) {
                  (final glyph, final colour, final ink) => SquareKey(
                    glyph,
                    color: colour,
                    ink: ink,
                    size: 26,
                  ),
                },
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a.actor} ${describe(a)}',
                        // The newest event is set a little heavier.
                        style: i == 0
                            ? body.copyWith(fontWeight: FontWeight.w600)
                            : body,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        time(a.createdAt),
                        style: t.mono(theme.textTheme.bodySmall!),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A still outline of the page while the task loads: title, brief, the screen strip, a few rows, and the rail.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget bar(double height, {double? width, double radius = 4}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: t.rule,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wide;
          final doc = Padding(
            padding: wide
                ? const EdgeInsets.fromLTRB(48, 32, 48, 0)
                : const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                // The loaded column's content width (900 less its gutters), so nothing shifts as it loads.
                constraints: BoxConstraints(maxWidth: wide ? 804 : 868),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(30, width: 360),
                    const SizedBox(height: 12),
                    bar(16, width: 240),
                    const SizedBox(height: 48),
                    bar(64, radius: Tokens.radiusScreen),
                    const SizedBox(height: 28),
                    bar(12, width: 240),
                    const SizedBox(height: 8),
                    bar(12, width: 180),
                    const SizedBox(height: 12),
                    bar(1),
                  ],
                ),
              ),
            ),
          );
          if (!wide) return doc;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: doc),
              Container(
                width: _rail,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: t.paper3,
                  border: Border(left: t.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final w in [96.0, 220.0, 180.0]) ...[
                      bar(14, width: w),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
