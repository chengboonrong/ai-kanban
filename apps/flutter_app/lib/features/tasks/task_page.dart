import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../agents/refinement.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Task')),
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
    final t = context.tokens;
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey(task.columnId),
          initialValue: task.columnId,
          decoration: const InputDecoration(labelText: 'Column'),
          items: [
            for (final c in widget.columns)
              DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: (id) =>
              id == null || id == task.columnId ? null : _move(id),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _description,
          minLines: 6,
          maxLines: 20,
          decoration: const InputDecoration(
            labelText: 'Description',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton(onPressed: _save, child: const Text('Save')),
            const Spacer(),
            TextButton.icon(
              onPressed: _delete,
              style: TextButton.styleFrom(foregroundColor: t.danger),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        ),
        const SizedBox(height: 32),
        RefinementPanel(
          boardId: widget.boardId,
          taskId: task.id,
          repository: widget.repository,
        ),
        GitHubPanel(boardId: widget.boardId, taskId: task.id),
      ],
    );
    final activity = _ActivityList(activity: widget.detail.activity);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 840) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: form,
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 340,
                child: ColoredBox(
                  color: t.paper3,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: activity,
                  ),
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [form, const SizedBox(height: 32), activity],
        );
      },
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
    'moved' => 'moved it from ${a.data['from']} to ${a.data['to']}',
    'updated' => [
      if (a.data['title'] case {'from': final from, 'to': final to})
        'renamed "$from" to "$to"',
      if (a.data['description'] == true) 'edited the description',
    ].join(' and '),
    _ => a.kind,
  };

  static String time(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)} ${_pad(t.hour)}:${_pad(t.minute)}';
  static String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final small = theme.textTheme.bodySmall!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(border: Border(bottom: t.inkRule)),
          child: Text('Activity', style: theme.textTheme.titleMedium),
        ),
        for (final a in activity.reversed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(border: Border(bottom: t.hairline)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${a.actor} ${describe(a)}',
                  style: small.copyWith(color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(time(a.createdAt), style: t.mono(small)),
              ],
            ),
          ),
      ],
    );
  }
}

/// A still outline of the page while the task loads: three fields, a button, and the rail.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget block(double height, {double? width, Color? color}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: color ?? t.paper3,
        borderRadius: BorderRadius.circular(Tokens.radiusControl),
      ),
    );
    final form = Padding(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              block(48),
              const SizedBox(height: 16),
              block(48),
              const SizedBox(height: 16),
              block(160),
              const SizedBox(height: 16),
              block(40, width: 88),
            ],
          ),
        ),
      ),
    );
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 840
            ? form
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: form),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 340,
                    child: ColoredBox(
                      color: t.paper3,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final w in [96.0, 220.0, 180.0]) ...[
                              block(14, width: w, color: t.rule),
                              const SizedBox(height: 16),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
