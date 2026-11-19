import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';
import '../auth/auth.dart';
import '../boards/board_page.dart';

/// Rechecked every 5 s while the run is queued, since why it waits changes as workers come and go.
/// A failed fetch is rechecked too, so an outage doesn't stop it for good.
final refinementProvider = FutureProvider.autoDispose
    .family<Refinement, String>((ref, taskId) async {
      Refinement? r;
      try {
        return r = await ref.watch(apiProvider).refinement(taskId);
      } finally {
        if (ref.mounted && (r == null || r.run?.state == 'queued')) {
          final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
          ref.onDispose(timer.cancel);
        }
      }
    });

/// Next to a line saying a run waits on the viewer's own workers: where they can be checked.
class WorkersButton extends StatelessWidget {
  const WorkersButton({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    onPressed: () => context.push('/workers'),
    child: const Text('Workers'),
  );
}

typedef RunProgress = ({String state, List<RunEvent> events});

/// Everything a run has reported so far, kept current by long-polling until the run ends.
final runEventsProvider = StreamProvider.autoDispose
    .family<RunProgress, String>((ref, runId) async* {
      final api = ref.watch(apiProvider);
      final events = <RunEvent>[];
      var disposed = false;
      ref.onDispose(
        () => disposed = true,
      ); // the offline retry below never yields, so it must notice on its own
      while (!disposed) {
        try {
          final page = await api.runEvents(
            runId,
            events.isEmpty ? 0 : events.last.id,
          );
          events.addAll(page.events);
          yield (state: page.state, events: List.unmodifiable(events));
          if (page.state != 'queued' && page.state != 'running') return;
        } catch (e) {
          final serverError =
              e is DioException && (e.response?.statusCode ?? 0) >= 500;
          if (!isOffline(e) && !serverError) rethrow;
          await Future<void>.delayed(
            const Duration(seconds: 3),
          ); // keep watching once the API is back
        }
      }
    });

/// A comment's place in a spec: the field and the item's position in it.
typedef CommentKey = (String section, int index);

/// The general note, kept with the item comments.
const _general = ('general', 0);

/// The order the spec shows its sections in, which the comments are sent in too.
const _sections = [
  'summary',
  'acceptanceCriteria',
  'requirements',
  'ambiguities',
  'approach',
  'evidence',
];

/// The task's AI spec: request a refinement, follow it live, then review, comment on or approve the result.
class RefinementPanel extends ConsumerStatefulWidget {
  const RefinementPanel({
    super.key,
    required this.boardId,
    required this.taskId,
    required this.repository,
  });
  final String boardId, taskId;
  final String? repository;

  @override
  ConsumerState<RefinementPanel> createState() => _RefinementPanelState();
}

class _RefinementPanelState extends ConsumerState<RefinementPanel> {
  // ponytail: comments live in this state, lost on navigation; persist drafts if people ask.
  String? _commentsOn; // the id of the spec version the comments are about
  final _comments = <CommentKey, String>{};

  void _refresh() {
    ref.invalidate(refinementProvider(widget.taskId));
    ref.invalidate(boardProvider(widget.boardId));
  }

  /// Comments start over with each spec version: they quote its items.
  void _edit(Spec spec, VoidCallback change) => setState(() {
    if (_commentsOn != spec.id) _comments.clear();
    _commentsOn = spec.id;
    change();
  });

  Future<void> _comment(Spec spec, CommentKey key, String title) async {
    final text = await promptText(
      context,
      title,
      initial: _commentsOn == spec.id ? _comments[key] ?? '' : '',
      action: 'Add',
      maxLength: key == _general ? 4000 : 2000,
    );
    if (text != null && mounted) _edit(spec, () => _comments[key] = text);
  }

  /// What "Refine again" sends: null without comments, or once the spec was approved.
  SpecFeedback? _feedback(Spec? spec) {
    if (spec == null || spec.approved || spec.id != _commentsOn) return null;
    final items = _comments.keys.where((k) => k != _general).toList()
      ..sort(
        (a, b) => a.$1 == b.$1
            ? a.$2 - b.$2
            : _sections.indexOf(a.$1) - _sections.indexOf(b.$1),
      );
    final feedback = SpecFeedback(
      spec.version,
      general: _comments[_general],
      items: [
        for (final k in items)
          (section: k.$1, index: k.$2, comment: _comments[k]!),
      ],
    );
    return feedback.count == 0 ? null : feedback;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final api = ref.read(apiProvider);
    final taskId = widget.taskId, repository = widget.repository;
    final async = ref.watch(refinementProvider(taskId));
    final r = async.value;
    final run = r?.run, spec = r?.spec;
    final feedback = _feedback(spec);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 20),
                const SizedBox(width: 8),
                Text('AI spec', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                // The rest of the row, so a long label ("Refine with 12 comments") wraps on a phone instead of overflowing.
                if (repository != null && r != null)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: run != null && run.active
                          ? TextButton(
                              onPressed: () =>
                                  runWithFeedback(context, () async {
                                    await api.cancelRun(run.id);
                                    _refresh();
                                  }),
                              child: const Text('Cancel'),
                            )
                          : FilledButton.tonal(
                              onPressed: () => runWithFeedback(
                                context,
                                () async {
                                  await api.refine(taskId, feedback: feedback);
                                  if (mounted) {
                                    setState(_comments.clear); // sent
                                  }
                                  _refresh();
                                },
                              ),
                              child: Text(switch ((spec, feedback?.count)) {
                                (null, _) => 'Refine with AI',
                                (_, null) => 'Refine again',
                                (_, 1) => 'Refine with 1 comment',
                                (_, final n) => 'Refine with $n comments',
                              }),
                            ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (repository == null)
              const Text(
                'Connect a GitHub repository to this board (the link icon on the board) and a worker can turn this brief into a spec.',
              )
            else
              switch (async) {
                AsyncValue(:final error?) when r == null => Text(
                  errorMessage(error),
                ),
                _ when r == null => const LinearProgressIndicator(),
                _ => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (run != null && run.active)
                      _LiveRun(
                        run: run,
                        waiting: r.waiting,
                        repository: repository,
                        onChange: _refresh,
                      ),
                    if (run != null && run.state == 'failed')
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.error,
                        ),
                        title: const Text('The last refinement failed'),
                        subtitle: Text(run.error ?? ''),
                      ),
                    if (spec != null)
                      _SpecView(
                        spec: spec,
                        stale: run != null && run.active,
                        // A succeeded run is the one that wrote the newest spec.
                        madeBy: run != null && run.state == 'succeeded'
                            ? run
                            : null,
                        comments: spec.id == _commentsOn ? _comments : const {},
                        onComment: (key, title) => _comment(spec, key, title),
                        onRemove: (key) =>
                            _edit(spec, () => _comments.remove(key)),
                        onApprove: () => runWithFeedback(context, () async {
                          await api.approveSpec(spec.id);
                          _refresh();
                        }),
                      )
                    else if (run == null)
                      Text(
                        'The Refiner reads $repository on your worker, read-only, and writes requirements, acceptance criteria '
                        'and the code it found. You approve it before anything else happens.',
                      ),
                  ],
                ),
              },
          ],
        ),
      ),
    );
  }
}

String _short(Object? sha) =>
    '$sha'.length > 7 ? '$sha'.substring(0, 7) : '$sha';

String _on(AgentRun run) =>
    run.workerName == null ? '' : ' on ${run.workerName}';

class _LiveRun extends ConsumerWidget {
  const _LiveRun({
    required this.run,
    required this.waiting,
    required this.repository,
    required this.onChange,
  });
  final AgentRun run;
  final Waiting? waiting;
  final String repository;

  /// The run started or ended: the refinement (worker, agent, result) needs reloading.
  final VoidCallback onChange;

  static String describe(RunEvent e) => switch (e.kind) {
    'inspecting' =>
      'Reading commit ${_short(e.data['commitSha'])}${e.data['dirty'] == true ? ' (uncommitted changes are left out)' : ''}',
    'model' => 'Asking ${e.data['model']}',
    'model_failed' =>
      '${e.data['model']} didn\'t produce a spec (${e.data['reason']}); retrying',
    'tool' =>
      '${e.data['tool']} ${e.data['target']}${e.data['ok'] == false ? ' (refused)' : ''}',
    _ => e.kind,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(runEventsProvider(run.id), (previous, next) {
      // Finished, or the watch broke (task deleted, access lost): reload the refinement either way. Server errors retry.
      if (next.hasError) return onChange();
      final s = next.value?.state;
      if (s != 'queued' && s != 'running' && s != null) return onChange();
      // Just claimed: the worker's name and agent come with the refinement, so don't wait for its next recheck.
      if (s == 'running' &&
          run.state == 'queued' &&
          previous?.value?.state != 'running') {
        onChange();
      }
    });
    final progress = ref.watch(runEventsProvider(run.id)).value;
    final state = progress?.state ?? run.state;
    final events = progress?.events ?? const <RunEvent>[];
    final theme = Theme.of(context);
    final viewer = ref.watch(authProvider)?.user.login;
    final queued = state == 'queued';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                queued
                    ? waiting?.describe(
                            viewer: viewer,
                            repository: repository,
                          ) ??
                          'Waiting for the worker of whoever connected $repository…'
                    : 'Refining against $repository with ${run.harnessLabel}${_on(run)}…',
              ),
            ),
            if (queued && (waiting?.mine(viewer) ?? false))
              const WorkersButton(),
          ],
        ),
        if (run.attempt > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${run.attempt >= 3 ? 'Last try' : 'Retrying'} (attempt ${run.attempt} of 3)${run.retryReason == null ? '' : ': ${run.retryReason}'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final e in events.reversed.take(8))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              describe(e),
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _SpecView extends StatelessWidget {
  const _SpecView({
    required this.spec,
    required this.stale,
    required this.madeBy,
    required this.comments,
    required this.onComment,
    required this.onRemove,
    required this.onApprove,
  });
  final Spec spec;
  final bool stale;
  final AgentRun? madeBy;
  final Map<CommentKey, String> comments;

  /// Asks for the comment on [key]; [title] names the item ("Comment on requirement 2").
  final void Function(CommentKey key, String title) onComment;
  final void Function(CommentKey key) onRemove;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Until it is approved, and unless a newer version is being written, each item takes a comment for the next one.
    final open = !spec.approved && !stale;

    /// [child] with its comment action, and the comment under it once there is one.
    Widget commentable(Widget child, CommentKey key, String what) {
      if (!open) return child;
      final comment = comments[key];
      final answer =
          key.$1 == 'ambiguities'; // a comment on a question answers it
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: child),
              if (answer)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => onComment(key, 'Answer $what'),
                  child: const Text('Answer'),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: 'Comment on $what',
                  onPressed: () => onComment(key, 'Comment on $what'),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
            ],
          ),
          if (comment != null)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  Icon(
                    answer
                        ? Icons.question_answer_outlined
                        : Icons.comment_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      comment,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    tooltip: 'Remove comment',
                    onPressed: () => onRemove(key),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    Widget section(
      String title,
      String field,
      String noun,
      List<String> items, {
      bool numbered = false,
    }) => items.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                for (final (i, item) in items.indexed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: commentable(
                      Text('${numbered ? '${i + 1}.' : '•'} $item'),
                      (field, i),
                      '$noun ${i + 1}',
                    ),
                  ),
              ],
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(spec.title, style: theme.textTheme.titleLarge),
            ),
            if (spec.approved)
              const Chip(
                avatar: Icon(Icons.verified_outlined, size: 18),
                label: Text('Approved'),
              ),
          ],
        ),
        Text(
          'Version ${spec.version}${spec.commitSha == null ? '' : ' · commit ${_short(spec.commitSha)}'}'
          '${madeBy == null ? '' : ' · ${madeBy!.harnessLabel}${_on(madeBy!)}'}'
          '${stale ? ' · a new version is being written' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        commentable(Text(spec.summary), ('summary', 0), 'the summary'),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              'Readiness ${spec.readiness}%',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LinearProgressIndicator(value: spec.readiness / 100),
            ),
          ],
        ),
        section(
          'Acceptance criteria',
          'acceptanceCriteria',
          'acceptance criterion',
          spec.acceptanceCriteria,
        ),
        section(
          'Requirements',
          'requirements',
          'requirement',
          spec.requirements,
        ),
        section(
          'Open questions',
          'ambiguities',
          'open question',
          spec.ambiguities,
        ),
        section(
          'Suggested approach',
          'approach',
          'approach step',
          spec.approach,
          numbered: true,
        ),
        if (spec.evidence.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Evidence in the repository', style: theme.textTheme.titleSmall),
          for (final (i, e) in spec.evidence.indexed)
            commentable(
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Tooltip(
                  message: e.verified
                      ? 'Found at these lines in the commit'
                      : 'Not found at these lines; check before relying on it',
                  child: Icon(
                    e.verified
                        ? Icons.check_circle_outline
                        : Icons.help_outline,
                    color: e.verified ? null : theme.colorScheme.error,
                  ),
                ),
                title: Text('${e.path}:${e.startLine}-${e.endLine}'),
                subtitle: Text(e.note),
              ),
              ('evidence', i),
              'evidence ${i + 1}',
            ),
        ],
        if (open) ...[
          const SizedBox(height: 16),
          commentable(
            Text(
              'Anything else for the next version?',
              style: theme.textTheme.bodySmall,
            ),
            _general,
            'the spec as a whole',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check),
              label: const Text('Approve spec'),
            ),
          ),
        ],
      ],
    );
  }
}
